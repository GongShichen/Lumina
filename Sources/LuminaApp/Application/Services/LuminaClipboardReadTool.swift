import AgentRuntime
import Foundation

#if canImport(UIKit)
import UIKit
#endif

#if os(macOS) && !targetEnvironment(macCatalyst) && canImport(AppKit)
import AppKit
#endif

struct LuminaClipboardReadTool: LuminaAgentTool {
    var schema: LuminaToolSchema {
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

    func call(arguments: [String: LuminaJSONValue], cancellation: LuminaCancellationToken) async throws -> LuminaToolResult {
        try cancellation.checkCancellation()
        let value = await Self.readClipboardText()
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

    @MainActor
    private static func readClipboardText() -> String {
        #if canImport(UIKit)
        return UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        #elseif os(macOS) && !targetEnvironment(macCatalyst) && canImport(AppKit)
        return NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        #else
        return ""
        #endif
    }
}
