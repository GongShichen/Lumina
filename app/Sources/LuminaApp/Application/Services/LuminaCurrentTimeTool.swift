import LuminaAgentRuntime
import Foundation

struct LuminaCurrentTimeTool: LuminaAgentTool {
    var now: @Sendable () -> Date = Date.init
    var calendar: Calendar = .current
    var locale: Locale = .current
    var timeZone: TimeZone = .current

    var schema: LuminaToolSchema {
        LuminaToolSchema(
            name: "device.current_time",
            description: "读取本机当前时间、日期、时区和适合问候语的时间段。",
            parameters: [],
            sideEffect: .readOnly,
            sensitivity: .low,
            acceptedInputModalities: [.text, .structuredData],
            outputModalities: [.text, .structuredData]
        )
    }

    func call(arguments: [String: LuminaJSONValue], cancellation: LuminaCancellationToken) async throws -> LuminaToolResult {
        try cancellation.checkCancellation()
        let snapshot = makeSnapshot()
        return LuminaToolResult(
            callID: UUID(),
            toolName: schema.name,
            status: .succeeded,
            output: snapshot.output,
            content: [.markdown(snapshot.markdown)]
        )
    }

    private func makeSnapshot() -> LuminaCurrentTimeSnapshot {
        let date = now()
        var calendar = calendar
        calendar.locale = locale
        calendar.timeZone = timeZone

        let dateFormatter = DateFormatter()
        dateFormatter.locale = locale
        dateFormatter.timeZone = timeZone
        dateFormatter.dateStyle = .full
        dateFormatter.timeStyle = .none

        let timeFormatter = DateFormatter()
        timeFormatter.locale = locale
        timeFormatter.timeZone = timeZone
        timeFormatter.dateStyle = .none
        timeFormatter.timeStyle = .medium

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.timeZone = timeZone

        let hour = calendar.component(.hour, from: date)
        let weekday = calendar.weekdaySymbols[calendar.component(.weekday, from: date) - 1]
        let period = LuminaCurrentTimeSnapshot.dayPeriod(forHour: hour)
        return LuminaCurrentTimeSnapshot(
            iso8601: isoFormatter.string(from: date),
            localizedDate: dateFormatter.string(from: date),
            localizedTime: timeFormatter.string(from: date),
            weekday: weekday,
            hour: hour,
            dayPeriod: period,
            timeZoneIdentifier: timeZone.identifier,
            secondsFromGMT: timeZone.secondsFromGMT(for: date)
        )
    }

    private struct LuminaCurrentTimeSnapshot {
        var iso8601: String
        var localizedDate: String
        var localizedTime: String
        var weekday: String
        var hour: Int
        var dayPeriod: String
        var timeZoneIdentifier: String
        var secondsFromGMT: Int

        var output: [String: LuminaJSONValue] {
            [
                "iso8601": .string(iso8601),
                "currentDateISO": .string(iso8601),
                "localizedDate": .string(localizedDate),
                "localizedTime": .string(localizedTime),
                "weekday": .string(weekday),
                "hour": .number(Double(hour)),
                "dayPeriod": .string(dayPeriod),
                "timeZoneIdentifier": .string(timeZoneIdentifier),
                "timeZone": .string(timeZoneIdentifier),
                "secondsFromGMT": .number(Double(secondsFromGMT))
            ]
        }

        var markdown: String {
            """
            ### 本机时间

            - 日期：\(localizedDate)
            - 时间：\(localizedTime)
            - 时区：\(timeZoneIdentifier)
            - 问候时段：\(dayPeriod)
            """
        }

        static func dayPeriod(forHour hour: Int) -> String {
            switch hour {
            case 5..<12:
                return "早上"
            case 12..<18:
                return "下午"
            case 18..<23:
                return "晚上"
            default:
                return "夜里"
            }
        }
    }
}
