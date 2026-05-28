import LuminaAgentRuntime
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
            description: "把 agent 判断值得跨会话保留的长期记忆写入 Personal Memory。",
            parameters: [
                LuminaToolParameterSchema(name: "title", type: .string, description: "记忆标题。", required: false),
                LuminaToolParameterSchema(name: "body", type: .string, description: "记忆正文。", sensitive: true),
                LuminaToolParameterSchema(name: "source", type: .string, description: "来源说明。", required: false),
                LuminaToolParameterSchema(name: "sensitivity", type: .string, description: "low、normal、sensitive、privateData。", required: false),
                LuminaToolParameterSchema(name: "reason", type: .string, description: "为什么值得保存为长期记忆。", required: false),
                LuminaToolParameterSchema(name: "memoryType", type: .string, description: "preference、fact、plan、instruction、summary。", required: false),
                LuminaToolParameterSchema(name: "retentionHint", type: .string, description: "short、medium、long。", required: false)
            ],
            sideEffect: .appLocalWrite,
            sensitivity: .sensitive,
            acceptedInputModalities: [.text, .structuredData],
            outputModalities: [.text, .structuredData],
            idempotencyPolicy: "caller_keyed"
        )
    }

    public func call(arguments: [String: LuminaJSONValue], cancellation: LuminaCancellationToken) async throws -> LuminaToolResult {
        try cancellation.checkCancellation()
        let body = arguments.string("body") ?? arguments.string("text") ?? ""
        let title = arguments.string("title") ?? "Lumina Memory"
        let source = arguments.string("source") ?? "user"
        let sensitivity = effectiveSensitivity(arguments: arguments, source: source)
        let document = LuminaMemoryDocument(
            source: LuminaMemorySource(kind: .appNote, identifier: "user/\(UUID().uuidString)"),
            title: title,
            body: body,
            sensitivity: sensitivity,
            metadata: [
                "source": source,
                "reason": arguments.string("reason") ?? "",
                "memoryType": arguments.string("memoryType") ?? "summary",
                "retentionHint": arguments.string("retentionHint") ?? "medium"
            ]
        )
        let chunks = await memoryStore.ingest(document)
        return LuminaToolResult(
            callID: UUID(),
            toolName: schema.name,
            status: .succeeded,
            output: [
                "documentID": .string(document.id.uuidString),
                "title": .string(title),
                "chunkCount": .number(Double(chunks.count)),
                "sensitivity": .string(sensitivity.rawValue),
                "reason": .string(arguments.string("reason") ?? ""),
                "confirmationRequired": .bool(sensitivity == .sensitive || sensitivity == .privateData)
            ],
            content: [.markdown("## 已写入记忆\n\n\(title)")]
        )
    }

    private func effectiveSensitivity(arguments: [String: LuminaJSONValue], source: String) -> LuminaMemorySensitivity {
        let requested = LuminaMemorySensitivity(rawValue: arguments.string("sensitivity") ?? "") ?? .normal
        let sensitiveHints = ["contact", "health", "location", "communication", "message", "email", "clipboard", "document"]
        let lowercasedSource = source.lowercased()
        guard sensitiveHints.contains(where: { lowercasedSource.contains($0) }) else {
            return requested
        }
        return max(requested, .sensitive)
    }
}
