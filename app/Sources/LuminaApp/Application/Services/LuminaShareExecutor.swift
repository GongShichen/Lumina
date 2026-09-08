import LuminaAgentRuntime
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
        return try await ShareRequest().run(text: text, filePath: filePath, itemCount: itemCount)
        #else
        return result(status: .failed, message: "当前平台没有启用系统分享面板。", output: ["unavailable": .bool(true)])
        #endif
    }

    #if canImport(UIKit)
    @MainActor
    private final class ShareRequest {
        private var continuation: CheckedContinuation<LuminaToolResult, Error>?
        private var activity: UIActivityViewController?

        func run(text: String, filePath: String?, itemCount: Int) async throws -> LuminaToolResult {
            try Task.checkCancellation()
            return try await withTaskCancellationHandler {
                let value = try await withCheckedThrowingContinuation { continuation in
                    self.continuation = continuation
                    guard !Task.isCancelled else {
                        finish(.failure(CancellationError()))
                        return
                    }
                    guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
                        .first(where: { $0.activationState == .foregroundActive }),
                        var presenter = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController else {
                        finish(.success(LuminaShareExecutor.result(status: .failed, message: "无法显示分享面板：没有可用的前台窗口。", output: [:])))
                        return
                    }
                    while let presented = presenter.presentedViewController, !presented.isBeingDismissed {
                        presenter = presented
                    }
                    guard presenter.viewIfLoaded?.window != nil, !presenter.isBeingDismissed else {
                        finish(.success(LuminaShareExecutor.result(status: .failed, message: "无法显示分享面板：当前窗口尚未准备好。", output: [:])))
                        return
                    }
                    var items: [Any] = []
                    if !text.isEmpty { items.append(text as NSString) }
                    if let filePath { items.append(URL(fileURLWithPath: filePath)) }
                    let activity = UIActivityViewController(activityItems: items, applicationActivities: nil)
                    self.activity = activity
                    if let popover = activity.popoverPresentationController {
                        popover.sourceView = presenter.view
                        popover.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 1, height: 1)
                        popover.permittedArrowDirections = []
                    }
                    activity.completionWithItemsHandler = { [weak self] activityType, completed, _, error in
                        Task { @MainActor in
                            let output: [String: LuminaJSONValue] = [
                                "itemCount": .number(Double(itemCount)),
                                "completed": .bool(completed),
                                "activityType": activityType.map { .string($0.rawValue) } ?? .null
                            ]
                            let status: LuminaToolResultStatus = error != nil ? .failed : (completed ? .succeeded : .cancelled)
                            let message = error.map { "分享失败：\($0.localizedDescription)" } ?? (completed ? "分享已完成。" : "用户取消了分享。")
                            self?.finish(.success(LuminaShareExecutor.result(status: status, message: message, output: output)))
                        }
                    }
                    presenter.present(activity, animated: true)
                }
                try Task.checkCancellation()
                return value
            } onCancel: {
                Task { @MainActor in
                    self.activity?.completionWithItemsHandler = nil
                    self.activity?.dismiss(animated: true)
                    self.finish(.failure(CancellationError()))
                }
            }
        }

        private func finish(_ result: Result<LuminaToolResult, Error>) {
            guard let continuation else { return }
            self.continuation = nil
            activity?.completionWithItemsHandler = nil
            activity = nil
            continuation.resume(with: result)
        }
    }
    #endif

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
