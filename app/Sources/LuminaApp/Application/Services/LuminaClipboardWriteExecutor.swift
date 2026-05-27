import LuminaAgentRuntime
import Foundation

#if canImport(UIKit)
import UIKit
#endif

#if os(macOS) && !targetEnvironment(macCatalyst) && canImport(AppKit)
import AppKit
#endif

enum LuminaClipboardWriteExecutor {
    static func writeClipboard(arguments: [String: LuminaJSONValue]) async throws -> LuminaToolResult {
        let text = arguments.string("text") ?? ""
        guard !text.isEmpty else {
            return result(status: .failed, message: "没有要写入剪贴板的文本。")
        }
        await MainActor.run {
            #if canImport(UIKit)
            UIPasteboard.general.string = text
            #elseif os(macOS) && !targetEnvironment(macCatalyst) && canImport(AppKit)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            #endif
        }
        return result(status: .succeeded, message: "已写入剪贴板，长度 \(text.count) 个字符。")
    }

    private static func result(status: LuminaToolResultStatus, message: String) -> LuminaToolResult {
        LuminaToolResult(
            callID: UUID(),
            toolName: "clipboard.write",
            status: status,
            output: ["summary": .string(message)],
            content: [.markdown(message)],
            errorMessage: status == .failed ? message : nil
        )
    }
}
