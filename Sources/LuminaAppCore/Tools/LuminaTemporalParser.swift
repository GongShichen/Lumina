import Foundation

public enum LuminaTemporalParser {
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
