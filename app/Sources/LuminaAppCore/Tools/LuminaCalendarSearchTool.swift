import LuminaAgentRuntime
import Foundation
import PersonalMemory

public struct LuminaCalendarSearchTool: LuminaAgentTool {
    public let store: LuminaVolatileCalendarStore

    public init(store: LuminaVolatileCalendarStore) {
        self.store = store
    }

    public var schema: LuminaToolSchema {
        LuminaToolSchema(
            name: "calendar.search",
            description: "查询近期日历事件。",
            parameters: [
                LuminaToolParameterSchema(name: "query", type: .string, description: "事件关键词；为空时返回近期事件。", required: false),
                LuminaToolParameterSchema(name: "startDateISO", type: .dateISO8601, description: "可选查询开始时间，默认当前时间；相对时间任务应先读取 device.current_time 后填入。", required: false),
                LuminaToolParameterSchema(name: "endDateISO", type: .dateISO8601, description: "可选查询结束时间，必须晚于开始时间，默认开始时间后 30 天。", required: false),
                LuminaToolParameterSchema(name: "limit", type: .number, description: "返回数量，1 至 100 的整数，默认 5。", required: false)
            ],
            sideEffect: .readOnly,
            sensitivity: .privateData,
            acceptedInputModalities: [.text, .structuredData],
            outputModalities: [.text, .structuredData]
        )
    }

    public func call(arguments: [String: LuminaJSONValue], cancellation: LuminaCancellationToken) async throws -> LuminaToolResult {
        try cancellation.checkCancellation()
        let parameters: LuminaCalendarSearchParameters
        switch LuminaCalendarSearchParameters.resolve(arguments: arguments, schema: schema) {
        case let .valid(value): parameters = value
        case let .invalid(failure): return failure
        }
        let matches = await store.searchEvents(query: parameters.query, limit: Int.max)
            .filter { event in
                if let end = event.endDate, end > event.startDate {
                    return event.startDate < parameters.end && end > parameters.start
                }
                return event.startDate >= parameters.start && event.startDate < parameters.end
            }
        let events = matches.prefix(parameters.limit)
        let summaries = events.map { "[id=\($0.id.uuidString)] \($0.title) @ \($0.startDate.formatted(date: .abbreviated, time: .shortened))" }
        let items = events.map { parameters.item(
            identifier: $0.id.uuidString, title: $0.title, startDate: $0.startDate, endDate: $0.endDate
        ) }
        return LuminaToolResult(
            callID: UUID(),
            toolName: schema.name,
            status: .succeeded,
            output: parameters.output(summaries: summaries, items: items, matchedCount: matches.count),
            content: [.markdown(markdownList(title: "日历事件", items: summaries))]
        )
    }

    private func markdownList(title: String, items: [String]) -> String {
        guard !items.isEmpty else { return "### \(title)\n\n没有找到事件。" }
        return "### \(title)\n\n" + items.map { "- \($0)" }.joined(separator: "\n")
    }
}

/// Shared by EventKit and isolated tools so the model sees the same query and result contract.
public struct LuminaCalendarSearchParameters: Sendable {
    public let query: String
    public let limit: Int
    public let start: Date
    public let end: Date
    public let timeZone: TimeZone

    public enum Resolution: Sendable {
        case valid(LuminaCalendarSearchParameters)
        case invalid(LuminaToolResult)
    }

    public static func resolve(
        arguments: [String: LuminaJSONValue],
        schema: LuminaToolSchema,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Resolution {
        func invalid(_ field: String, code: String = "invalid_parameters", reason: String, guidance: String) -> Resolution {
            .invalid(LuminaToolFailureFeedback.validationFailure(
                schema: schema, arguments: arguments, code: code, reason: reason, field: field, guidance: guidance
            ))
        }
        if let query = arguments["query"] {
            guard case .string = query else {
                return invalid("query", reason: "query must be a string; no calendar search was performed.",
                               guidance: "Use a text keyword from the user's request, or omit query to list events within the time range.")
            }
        }
        var dates: [String: Date] = [:]
        for field in ["startDateISO", "endDateISO"] {
            guard let value = arguments[field] else { continue }
            guard case let .string(raw) = value, let date = LuminaToolFailureFeedback.parseDate(raw) else {
                return invalid(field, code: "invalid_date", reason: "\(field) must be a valid ISO8601 date-time with a time zone; no calendar search was performed.",
                               guidance: "Use an ISO8601 date-time with Z or an explicit time-zone offset. For a relative date, read device.current_time first and derive the range from that observation. Do not silently replace an invalid date with the default range.")
            }
            dates[field] = date
        }
        let rawLimit: Double
        if let value = arguments["limit"] {
            guard case let .number(number) = value else {
                return invalid("limit", reason: "limit must be a number containing an integer from 1 to 100; no calendar search was performed.",
                               guidance: "Provide an integer from 1 to 100, or omit limit to use 5.")
            }
            rawLimit = number
        } else {
            rawLimit = 5
        }
        guard rawLimit.isFinite, rawLimit >= 1, rawLimit <= 100, rawLimit.rounded(.towardZero) == rawLimit else {
            return invalid("limit", reason: "limit must be a finite integer from 1 to 100; no calendar search was performed.",
                           guidance: "Provide an integer from 1 to 100, or omit limit to use 5.")
        }
        let start = dates["startDateISO"] ?? now
        let end = dates["endDateISO"] ?? calendar.date(byAdding: .day, value: 30, to: start) ?? start
        guard end > start else {
            return invalid("endDateISO", code: "invalid_date_range", reason: "endDateISO must be later than startDateISO; no calendar search was performed.",
                           guidance: "Use the user's intended start and end times, with endDateISO later than startDateISO. If startDateISO is omitted it defaults to the current time; provide an explicit earlier start when querying past events.")
        }
        return .valid(Self(query: arguments.string("query") ?? "", limit: Int(rawLimit), start: start, end: end, timeZone: calendar.timeZone))
    }

    public func item(identifier: String, title: String, startDate: Date, endDate: Date?) -> LuminaJSONValue {
        .object([
            "id": .string(identifier), "identifier": .string(identifier), "title": .string(title),
            "startDateISO": .string(iso8601(startDate)),
            "endDateISO": endDate.map { .string(iso8601($0)) } ?? .null,
            "timeZone": .string(timeZone.identifier)
        ])
    }

    public func output(summaries: [String], items: [LuminaJSONValue], matchedCount: Int) -> [String: LuminaJSONValue] {
        [
            "events": .array(summaries.map(LuminaJSONValue.string)),
            "items": .array(items),
            "count": .number(Double(items.count)),
            "matchedCount": .number(Double(matchedCount)),
            "truncated": .bool(matchedCount > items.count),
            "timeZoneIdentifier": .string(timeZone.identifier),
            "queryRange": .object([
                "startDateISO": .string(iso8601(start)), "endDateISO": .string(iso8601(end)),
                "timeZone": .string(timeZone.identifier)
            ]),
            "executedArguments": .object([
                "query": .string(query), "limit": .number(Double(limit)),
                "startDateISO": .string(iso8601(start)), "endDateISO": .string(iso8601(end))
            ])
        ]
    }

    private func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = timeZone
        return formatter.string(from: date)
    }
}
