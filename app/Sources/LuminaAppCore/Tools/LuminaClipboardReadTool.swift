import LuminaAgentRuntime
import Foundation

public struct LuminaClipboardReadTool: LuminaAgentTool {
    public typealias ReadClipboard = @Sendable () async -> String?

    private let readClipboard: ReadClipboard

    public init(readClipboard: @escaping ReadClipboard = { nil }) {
        self.readClipboard = readClipboard
    }

    public var schema: LuminaToolSchema {
        LuminaToolSchema(
            name: "clipboard.read",
            description: "读取当前剪贴板文本或 URL。",
            parameters: [],
            sideEffect: .readOnly,
            sensitivity: .privateData,
            acceptedInputModalities: [.text, .structuredData],
            outputModalities: [.text, .structuredData]
        )
    }

    public func call(arguments: [String: LuminaJSONValue], cancellation: LuminaCancellationToken) async throws -> LuminaToolResult {
        try cancellation.checkCancellation()
        let value = await readClipboard()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let summary = value.isEmpty ? "剪贴板没有可读取的文本。" : "剪贴板包含 \(value.count) 个字符。"
        return LuminaToolResult(
            callID: UUID(),
            toolName: schema.name,
            status: .succeeded,
            output: [
                "text": value.isEmpty ? .null : .string(value),
                "summary": .string(summary)
            ],
            content: [.markdown("## 剪贴板\n\n\(summary)")]
        )
    }
}
