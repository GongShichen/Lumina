import AgentRuntime
import Foundation
import PersonalMemory

public struct LuminaMemoryIngestTextTool: LuminaAgentTool {
    public let memoryStore: LuminaMemoryStore

    public init(memoryStore: LuminaMemoryStore) {
        self.memoryStore = memoryStore
    }

    public var schema: LuminaToolSchema {
        LuminaToolSchema(
            name: "memory.ingest_text",
            description: "把用户明确要求保存的文本写入 Personal Memory。",
            parameters: [
                LuminaToolParameterSchema(name: "title", type: .string, description: "记忆标题。", required: false),
                LuminaToolParameterSchema(name: "body", type: .string, description: "记忆正文。", sensitive: true),
                LuminaToolParameterSchema(name: "source", type: .string, description: "来源说明。", required: false),
                LuminaToolParameterSchema(name: "sensitivity", type: .string, description: "low、normal、sensitive、privateData。", required: false)
            ],
            sideEffect: .appLocalWrite,
            sensitivity: .sensitive,
            acceptedInputModalities: [.text, .structuredData],
            outputModalities: [.text, .structuredData]
        )
    }

    public func call(arguments: [String: LuminaJSONValue], cancellation: LuminaCancellationToken) async throws -> LuminaToolResult {
        try cancellation.checkCancellation()
        let body = arguments.string("body") ?? arguments.string("text") ?? ""
        let title = arguments.string("title") ?? "Lumina Memory"
        let source = arguments.string("source") ?? "user"
        let sensitivity = LuminaMemorySensitivity(rawValue: arguments.string("sensitivity") ?? "") ?? .normal
        let document = LuminaMemoryDocument(
            source: LuminaMemorySource(kind: .appNote, identifier: "user/\(UUID().uuidString)"),
            title: title,
            body: body,
            sensitivity: sensitivity,
            metadata: ["source": source]
        )
        let chunks = await memoryStore.ingest(document)
        return LuminaToolResult(
            callID: UUID(),
            toolName: schema.name,
            status: .succeeded,
            output: [
                "documentID": .string(document.id.uuidString),
                "title": .string(title),
                "chunkCount": .number(Double(chunks.count))
            ],
            content: [.markdown("## 已写入记忆\n\n\(title)")]
        )
    }
}
