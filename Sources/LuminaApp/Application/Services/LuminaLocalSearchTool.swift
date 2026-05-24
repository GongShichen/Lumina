import AgentRuntime
@preconcurrency import EventKit
import Foundation
import PersonalMemory

struct LuminaLocalSearchTool: LuminaAgentTool {
    let memoryStore: LuminaMemoryStore

    var schema: LuminaToolSchema {
        LuminaToolSchema(
            name: "local.search",
            description: "搜索端侧 Personal Memory，返回精简摘要和来源。",
            parameters: [
                LuminaToolParameterSchema(name: "query", type: .string, description: "检索问题。"),
                LuminaToolParameterSchema(name: "limit", type: .number, description: "返回数量。", required: false)
            ],
            sideEffect: .readOnly,
            sensitivity: .privateData,
            acceptedInputModalities: [.text, .structuredData],
            outputModalities: [.text, .structuredData]
        )
    }

    func call(arguments: [String: LuminaJSONValue], cancellation: LuminaCancellationToken) async throws -> LuminaToolResult {
        try cancellation.checkCancellation()
        let query = arguments.string("query") ?? ""
        let limit = Int(arguments.number("limit") ?? 5)
        let results = try await memoryStore.search(LuminaMemorySearchQuery(text: query, limit: limit))
        let summaries = results.map { "\($0.chunk.title): \($0.chunk.summary)" }
        return LuminaToolResult(
            callID: UUID(),
            toolName: schema.name,
            status: .succeeded,
            output: ["results": .array(summaries.map(LuminaJSONValue.string))],
            content: [.markdown(markdownList(title: "本地检索结果", items: summaries))]
        )
    }

    private func markdownList(title: String, items: [String]) -> String {
        guard !items.isEmpty else { return "### \(title)\n\n没有找到结果。" }
        return "### \(title)\n\n" + items.map { "- \($0)" }.joined(separator: "\n")
    }
}
