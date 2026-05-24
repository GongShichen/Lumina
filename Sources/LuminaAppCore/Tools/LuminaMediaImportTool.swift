import AgentRuntime
import Foundation
import PersonalMemory

public struct LuminaMediaImportTool: LuminaAgentTool {
    public let memoryStore: LuminaMemoryStore

    public init(memoryStore: LuminaMemoryStore) {
        self.memoryStore = memoryStore
    }

    public var schema: LuminaToolSchema {
        LuminaToolSchema(
            name: "media.import",
            description: "把用户输入的图片、音频、视频或文件作为本地记忆导入，并保留媒体引用。",
            parameters: [
                LuminaToolParameterSchema(name: "note", type: .string, description: "用户对媒体的说明。", required: false, sensitive: true)
            ],
            sideEffect: .appLocalWrite,
            sensitivity: .privateData,
            acceptedInputModalities: [.image, .audio, .video, .file, .text, .structuredData],
            outputModalities: [.text, .image, .audio, .video, .file, .structuredData]
        )
    }

    public func call(arguments: [String: LuminaJSONValue], cancellation: LuminaCancellationToken) async throws -> LuminaToolResult {
        try cancellation.checkCancellation()
        return LuminaToolResult(callID: UUID(), toolName: schema.name, status: .failed, errorMessage: "media.import requires request content.")
    }

    public func call(context: LuminaToolExecutionContext, cancellation: LuminaCancellationToken) async throws -> LuminaToolResult {
        try cancellation.checkCancellation()
        let mediaParts = context.request.content.filter { [.image, .audio, .video, .file].contains($0.modality) }
        guard !mediaParts.isEmpty else {
            return LuminaToolResult(callID: context.call.id, toolName: schema.name, status: .failed, errorMessage: "No media content found in request.")
        }
        let note = context.call.arguments.string("note") ?? context.request.text
        let body = ([note] + mediaParts.compactMap(\.textForPlanning)).joined(separator: "\n")
        let chunkIDs = await memoryStore.ingest(LuminaMemoryDocument(
            source: LuminaMemorySource(kind: .imported, identifier: context.request.id.uuidString),
            title: "Imported Media",
            body: body,
            sensitivity: .privateData,
            metadata: ["modalities": mediaParts.map(\.modality.rawValue).joined(separator: ",")]
        ))
        return LuminaToolResult(
            callID: context.call.id,
            toolName: schema.name,
            status: .succeeded,
            output: ["chunkCount": .number(Double(chunkIDs.count))],
            content: [.markdown("### 媒体已导入\n\n- 附件数：\(mediaParts.count)\n- 写入 chunks：\(chunkIDs.count)")] + mediaParts
        )
    }
}
