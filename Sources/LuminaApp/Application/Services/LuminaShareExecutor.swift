import AgentRuntime
import Foundation

#if canImport(UIKit)
import UIKit
#endif

enum LuminaShareExecutor {
    static func prepareShare(arguments: [String: LuminaJSONValue]) async throws -> LuminaToolResult {
        let text = arguments.string("text") ?? ""
        let filePath = arguments.string("filePath")
        #if canImport(UIKit)
        let itemCount = (text.isEmpty ? 0 : 1) + (filePath == nil ? 0 : 1)
        guard itemCount > 0 else {
            return result(status: .failed, message: "没有可分享的文本或文件。", output: [:])
        }
        await MainActor.run {
            let items: [Any] = [
                text.isEmpty ? nil : text as NSString,
                filePath.map { URL(fileURLWithPath: $0) }
            ].compactMap { $0 }
            guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
                  let controller = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController else {
                return
            }
            let activity = UIActivityViewController(activityItems: items, applicationActivities: nil)
            controller.present(activity, animated: true)
        }
        return result(status: .succeeded, message: "分享面板已打开。", output: ["itemCount": .number(Double(itemCount))])
        #else
        return result(status: .failed, message: "当前平台没有启用系统分享面板。", output: ["unavailable": .bool(true)])
        #endif
    }

    private static func result(status: LuminaToolResultStatus, message: String, output: [String: LuminaJSONValue]) -> LuminaToolResult {
        LuminaToolResult(
            callID: UUID(),
            toolName: "share.prepare",
            status: status,
            output: output.merging(["summary": .string(message)]) { current, _ in current },
            content: [.markdown(message)],
            errorMessage: status == .failed ? message : nil
        )
    }
}
