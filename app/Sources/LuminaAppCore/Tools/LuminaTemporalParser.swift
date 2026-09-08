import Foundation

public struct LuminaStrictScheduleTarget: Sendable, Hashable {
    public var clause: String
    public var date: Date
    public var toolDomain: String?

    public init(clause: String, date: Date, toolDomain: String?) {
        self.clause = clause
        self.date = date
        self.toolDomain = toolDomain
    }
}

public enum LuminaTemporalParser {
    /// Explicit temporal facts only. The permissive UI parser below is intentionally not used.
    public static func strictScheduleTargets(_ text: String, now: Date, calendar: Calendar) -> [LuminaStrictScheduleTarget] {
        // Compound durations need a separate grammar; never silently keep only the first unit.
        if !strictGroups("\\b(?:hours?|minutes?)\\s+and\\s+(?:[0-9]|one|two|three|four|five|six|seven|eight|nine|ten|twenty|thirty)", in: text).isEmpty { return [] }
        let splitPattern = "[，,；;。\\n]+|并且|同时|然后|并在|并于|\\band\\b"
        let separator = try? NSRegularExpression(pattern: splitPattern, options: [.caseInsensitive])
        let separated = separator?.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "\n") ?? text
        let clauses = separated.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        var targets: [LuminaStrictScheduleTarget] = []
        for clause in clauses {
            if let date = strictDate(in: clause, now: now, calendar: calendar) {
                targets.append(LuminaStrictScheduleTarget(clause: clause, date: date, toolDomain: strictDomain(in: clause)))
            } else if hasStrictTimeExpression(clause) {
                // Do not use a neighboring clause's time to fill an unresolved timed operation.
                return []
            }
        }
        return targets
    }

    private static func strictDate(in clause: String, now: Date, calendar: Calendar) -> Date? {
        let normalized = clause.lowercased().replacingOccurrences(of: "：", with: ":")
        guard !["大概", "大约", "左右", "一刻", "三刻", "around", "about"].contains(where: normalized.contains) else { return nil }
        var targetText = normalized
        var sourceText = ""
        let updateMarkers = ["改到", "改为", "改成", "调整到", "推迟到", "提前到", " to "]
        let markerRanges = updateMarkers.compactMap { normalized.range(of: $0, options: .backwards) }
        if let marker = markerRanges.max(by: { $0.lowerBound < $1.lowerBound }),
           hasStrictTimeExpression(String(normalized[marker.upperBound...])) {
            sourceText = String(normalized[..<marker.lowerBound])
            targetText = String(normalized[marker.upperBound...])
        }

        if let relative = strictRelativeDelay(in: targetText) {
            guard relative.count == 1, strictClocks(in: targetText).isEmpty,
                  strictGroups("小时|分钟|\\bhours?\\b|\\bminutes?\\b|\\bseconds?\\b", in: targetText).count <= 1 else { return nil }
            return calendar.date(byAdding: .second, value: relative[0], to: now)
        }
        let clocks = strictClocks(in: targetText)
        guard clocks.count == 1, let clock = clocks.first else { return nil }
        let targetDays = strictDayOffsets(in: targetText)
        let sourceDays = strictDayOffsets(in: sourceText)
        let offsets = targetDays.isEmpty ? sourceDays : targetDays
        guard offsets.count == 1, let offset = offsets.first else { return nil }
        let targetPeriods = strictPeriods(in: targetText)
        let periods = targetPeriods.isEmpty ? strictPeriods(in: sourceText) : targetPeriods
        guard periods.count <= 1, (0...23).contains(clock.hour), (0...59).contains(clock.minute) else { return nil }
        var hour = clock.hour
        if !strictGroups("\\b(?:a\\.?m\\.?|p\\.?m\\.?)\\b", in: targetText).isEmpty, !(1...12).contains(hour) { return nil }
        if let period = periods.first {
            if period == "pm" {
                guard hour != 0 else { return nil }
                if hour < 12 { hour += 12 }
            } else if period == "am" {
                guard hour <= 12 else { return nil }
                if hour == 12 { hour = 0 }
            } else if period == "noon" {
                guard (11...13).contains(hour) else { return nil }
            }
        }
        guard let base = calendar.date(byAdding: .day, value: offset, to: now) else { return nil }
        let baseDay = calendar.startOfDay(for: base)
        let matching = DateComponents(hour: hour, minute: clock.minute, second: 0)
        guard let first = calendar.nextDate(after: baseDay.addingTimeInterval(-1), matching: matching, matchingPolicy: .strict, repeatedTimePolicy: .first),
              let last = calendar.nextDate(after: baseDay.addingTimeInterval(-1), matching: matching, matchingPolicy: .strict, repeatedTimePolicy: .last),
              first == last,
              calendar.isDate(first, inSameDayAs: base),
              calendar.component(.hour, from: first) == hour,
              calendar.component(.minute, from: first) == clock.minute
        else { return nil }
        return first
    }

    private static func strictRelativeDelay(in text: String) -> [Int]? {
        let number = "[0-9零〇一二两三四五六七八九十]+"
        let patterns = [
            "(半|\(number))\\s*(?:个)?\\s*(小时|分钟|分|秒)\\s*后",
            "\\bin\\s+([a-z]+(?:[- ][a-z]+)?|[0-9]+)\\s+(minutes?|hours?|seconds?)\\b"
        ]
        var delays: [Int] = []
        var matched = false
        for pattern in patterns {
            for groups in strictGroups(pattern, in: text) {
                matched = true
                guard groups.count > 2 else { return [] }
                let unit = groups[2]
                if groups[1] == "半" {
                    guard unit == "小时" else { return [] }
                    delays.append(1_800); continue
                }
                guard let amount = strictNumber(groups[1]), amount > 0, amount <= 100_000 else { return [] }
                let multiplier = unit.contains("hour") || unit == "小时" ? 3_600 : unit.contains("min") || unit == "分钟" || unit == "分" ? 60 : 1
                delays.append(amount * multiplier)
            }
        }
        return matched ? delays : nil
    }

    private static func strictClocks(in text: String) -> [(hour: Int, minute: Int)] {
        let number = "[0-9零〇一二两三四五六七八九十]+"
        var clocks: [(hour: Int, minute: Int)] = []
        for groups in strictGroups("(\(number))\\s*点(?:(半)|(\(number))(?:\\s*分|(?=\\s*(?:提醒|创建|安排|设置|的|去|$))))?", in: text) {
            guard let hour = strictNumber(groups[1]) else { return [] }
            let minute = groups[2] == "半" ? 30 : groups[3].isEmpty ? 0 : strictNumber(groups[3]) ?? -1
            clocks.append((hour, minute))
        }
        // English am/pm is kept in the clause for period disambiguation. Match every clock once.
        let englishNumbers = "one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve"
        let pattern = "(?<![a-z0-9])(?:at\\s+)?([0-9]{1,2}|\(englishNumbers))(?::([0-9]{2}))?\\s*(?:a\\.?m\\.?|p\\.?m\\.?|o'clock)(?![a-z])|(?<![0-9])([0-9]{1,2}):([0-9]{2})(?![0-9])|\\bat\\s+([0-9]{1,2}|\(englishNumbers))(?![a-z0-9:])"
        for groups in strictGroups(pattern, in: text) {
            let rawHour = !groups[1].isEmpty ? groups[1] : !groups[3].isEmpty ? groups[3] : groups[5]
            let rawMinute = !groups[2].isEmpty ? groups[2] : groups[4]
            guard let hour = strictNumber(rawHour) else { return [] }
            clocks.append((hour, rawMinute.isEmpty ? 0 : Int(rawMinute) ?? -1))
        }
        return clocks
    }

    private static func strictDayOffsets(in text: String) -> Set<Int> {
        var offsets = Set<Int>()
        if ["今天", "今晚", "今早", "today", "tonight"].contains(where: text.contains) { offsets.insert(0) }
        if ["明天", "明早", "明晚"].contains(where: text.contains) || (text.contains("tomorrow") && !text.contains("day after tomorrow")) { offsets.insert(1) }
        if text.contains("后天") { offsets.insert(text.contains("大后天") ? 3 : 2) }
        if text.contains("day after tomorrow") { offsets.insert(2) }
        return offsets
    }

    private static func strictPeriods(in text: String) -> Set<String> {
        var periods = Set<String>()
        if ["早上", "上午", "明早", "今早", "凌晨", "morning"].contains(where: text.contains) || !strictGroups("\\ba\\.?m\\.?\\b", in: text).isEmpty { periods.insert("am") }
        if ["下午", "晚上", "傍晚", "今晚", "明晚", "afternoon", "evening", "tonight"].contains(where: text.contains) || !strictGroups("\\bp\\.?m\\.?\\b", in: text).isEmpty { periods.insert("pm") }
        if text.contains("中午") || text.contains("noon") { periods.insert("noon") }
        return periods
    }

    private static func hasStrictTimeExpression(_ text: String) -> Bool {
        !strictGroups("[0-9零〇一二两三四五六七八九十]\\s*点|[0-9]:[0-9]|(?:小时|分钟|秒)\\s*后|\\b(?:at|in)\\s+(?:[0-9]|one|two|three|four|five|six|seven|eight|nine|ten)|\\b(?:am|pm)\\b", in: text.lowercased()).isEmpty
    }

    private static func strictDomain(in text: String) -> String? {
        let text = text.lowercased()
        if ["通知", "notification", "notify"].contains(where: text.contains) { return "notification" }
        if ["提醒", "待办", "remind"].contains(where: text.contains) { return "reminder" }
        if ["日程", "日历", "会议", "calendar", "event", "meeting"].contains(where: text.contains) { return "calendar" }
        return nil
    }

    private static func strictNumber(_ value: String) -> Int? {
        let normalized = value.replacingOccurrences(of: "〇", with: "零")
        if !strictGroups("^(?:[0-9]+|[零一二两三四五六七八九]{1,2}|[一二两三四五六七八九]?十[一二三四五六七八九]?)$", in: normalized).isEmpty,
           let parsed = parseNumber(normalized) { return parsed }
        let words = value.replacingOccurrences(of: "-", with: " ").split(separator: " ").map(String.init)
        let numbers = ["zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19, "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50]
        guard (1...2).contains(words.count), let first = words.first.flatMap({ numbers[$0] }) else { return nil }
        if words.count == 1 { return first }
        guard first >= 20, let second = numbers[words[1]], (1...9).contains(second) else { return nil }
        return first + second
    }

    private static func strictGroups(_ pattern: String, in text: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let string = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: string.length)).map { match in
            (0..<match.numberOfRanges).map { index in
                let range = match.range(at: index)
                return range.location == NSNotFound ? "" : string.substring(with: range)
            }
        }
    }

    public static func parseScheduleIntent(
        _ text: String,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> LuminaTemporalParseResult {
        let startDate = relativeDate(in: text, now: now, calendar: calendar)
            ?? wallClockDate(in: text, now: now, calendar: calendar)
            ?? calendar.date(byAdding: .hour, value: 1, to: now)
            ?? now
        let endDate = calendar.date(byAdding: .minute, value: 30, to: startDate)
        return LuminaTemporalParseResult(
            title: title(in: text),
            startDate: startDate,
            endDate: endDate
        )
    }

    private static func relativeDate(in text: String, now: Date, calendar: Calendar) -> Date? {
        let normalized = text.replacingOccurrences(of: " ", with: "")
        if normalized.contains("半小时后") {
            return calendar.date(byAdding: .minute, value: 30, to: now)
        }
        if let minutes = firstNumber(before: "分钟后", in: normalized) ?? firstNumber(before: "分后", in: normalized) {
            return calendar.date(byAdding: .minute, value: minutes, to: now)
        }
        if let hours = firstNumber(before: "小时后", in: normalized) ?? firstNumber(before: "个小时后", in: normalized) {
            return calendar.date(byAdding: .hour, value: hours, to: now)
        }
        return nil
    }

    private static func wallClockDate(in text: String, now: Date, calendar: Calendar) -> Date? {
        let normalized = text.replacingOccurrences(of: " ", with: "")
        guard let hour = firstNumber(afterAny: ["早上", "上午", "中午", "下午", "晚上", "今晚", "明早", "明天", "今天"], before: "点", in: normalized) else {
            return nil
        }
        var adjustedHour = hour
        if (normalized.contains("下午") || normalized.contains("晚上") || normalized.contains("今晚")) && adjustedHour < 12 {
            adjustedHour += 12
        }
        if normalized.contains("中午") && adjustedHour < 11 {
            adjustedHour += 12
        }
        let dayOffset = (normalized.contains("明天") || normalized.contains("明早")) ? 1 : 0
        let base = calendar.date(byAdding: .day, value: dayOffset, to: now) ?? now
        var components = calendar.dateComponents([.year, .month, .day], from: base)
        components.hour = min(max(adjustedHour, 0), 23)
        components.minute = firstNumber(after: "点", before: "分", in: normalized) ?? 0
        components.second = 0
        return calendar.date(from: components)
    }

    private static func title(in text: String) -> String {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.contains("出门") { return "出门" }
        if text.contains("会议") { return "会议" }
        for separator in ["，", ",", "：", ":"] {
            if let range = normalized.range(of: separator) {
                let suffix = String(normalized[range.upperBound...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !suffix.isEmpty {
                    return String(suffix.prefix(24))
                }
            }
        }
        if let range = normalized.range(of: "提醒我") {
            let suffix = String(normalized[range.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !suffix.isEmpty {
                return String(suffix.prefix(24))
            }
        }
        if text.contains("日程") { return "日程" }
        let cleaned = text
            .replacingOccurrences(of: "给我", with: "")
            .replacingOccurrences(of: "帮我", with: "")
            .replacingOccurrences(of: "我", with: "")
            .replacingOccurrences(of: "提醒", with: "")
            .replacingOccurrences(of: "创建一个", with: "")
            .replacingOccurrences(of: "建一个", with: "")
            .replacingOccurrences(of: "定一个日程", with: "")
            .replacingOccurrences(of: "安排一个日程", with: "")
            .replacingOccurrences(of: "创建一个日程", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Lumina 日程" : String(cleaned.prefix(24))
    }

    private static func firstNumber(before marker: String, in text: String) -> Int? {
        guard let range = text.range(of: marker) else { return nil }
        let prefix = String(text[..<range.lowerBound])
        return trailingNumber(in: prefix)
    }

    private static func firstNumber(after marker: String, before endMarker: String, in text: String) -> Int? {
        guard let start = text.range(of: marker) else { return nil }
        let suffix = String(text[start.upperBound...])
        guard let end = suffix.range(of: endMarker) else { return nil }
        return parseNumber(String(suffix[..<end.lowerBound]))
    }

    private static func firstNumber(afterAny markers: [String], before endMarker: String, in text: String) -> Int? {
        for marker in markers {
            if let value = firstNumber(after: marker, before: endMarker, in: text) {
                return value
            }
        }
        return trailingNumber(before: endMarker, in: text)
    }

    private static func trailingNumber(before marker: String, in text: String) -> Int? {
        guard let range = text.range(of: marker) else { return nil }
        return trailingNumber(in: String(text[..<range.lowerBound]))
    }

    private static func trailingNumber(in text: String) -> Int? {
        let scalars = Array(text)
        var value = ""
        for char in scalars.reversed() {
            if char.isNumber || chineseDigits.keys.contains(char) || char == "十" {
                value.insert(char, at: value.startIndex)
            } else if !value.isEmpty {
                break
            }
        }
        return parseNumber(value)
    }

    private static func parseNumber(_ value: String) -> Int? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let number = Int(trimmed) {
            return number
        }
        if trimmed == "十" {
            return 10
        }
        if trimmed.contains("十") {
            let parts = trimmed.split(separator: "十", omittingEmptySubsequences: false)
            let tens = parts.first.flatMap { chineseNumber(String($0)) } ?? 1
            let ones = parts.count > 1 ? (chineseNumber(String(parts[1])) ?? 0) : 0
            return tens * 10 + ones
        }
        return chineseNumber(trimmed)
    }

    private static func chineseNumber(_ value: String) -> Int? {
        var total = 0
        for char in value {
            guard let digit = chineseDigits[char] else { return nil }
            total = total * 10 + digit
        }
        return total == 0 && value != "零" ? nil : total
    }

    private static let chineseDigits: [Character: Int] = [
        "零": 0,
        "一": 1,
        "二": 2,
        "两": 2,
        "三": 3,
        "四": 4,
        "五": 5,
        "六": 6,
        "七": 7,
        "八": 8,
        "九": 9
    ]
}
