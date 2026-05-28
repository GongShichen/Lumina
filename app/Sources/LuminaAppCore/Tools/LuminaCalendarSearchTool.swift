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
                LuminaToolParameterSchema(name: "query", type: .string, description: "事件关键词。", required: false),
                LuminaToolParameterSchema(name: "startDateISO", type: .dateISO8601, description: "可选查询开始时间。", required: false),
                LuminaToolParameterSchema(name: "endDateISO", type: .dateISO8601, description: "可选查询结束时间。", required: false),
                LuminaToolParameterSchema(name: "limit", type: .number, description: "返回数量。", required: false)
            ],
            sideEffect: .readOnly,
            sensitivity: .privateData,
            acceptedInputModalities: [.text, .structuredData],
            outputModalities: [.text, .structuredData]
        )
    }

    public func call(arguments: [String: LuminaJSONValue], cancellation: LuminaCancellationToken) async throws -> LuminaToolResult {
        try cancellation.checkCancellation()
        let events = await store.searchEvents(query: arguments.string("query") ?? "", limit: Int(arguments.number("limit") ?? 5))
        let summaries = events.map { "\($0.title) @ \($0.startDate.formatted(date: .abbreviated, time: .shortened))" }
        return LuminaToolResult(
            callID: UUID(),
            toolName: schema.name,
            status: .succeeded,
            output: ["events": .array(summaries.map(LuminaJSONValue.string))],
            content: [.markdown(markdownList(title: "日历事件", items: summaries))]
        )
    }

    private func markdownList(title: String, items: [String]) -> String {
        guard !items.isEmpty else { return "### \(title)\n\n没有找到事件。" }
        return "### \(title)\n\n" + items.map { "- \($0)" }.joined(separator: "\n")
    }
}
