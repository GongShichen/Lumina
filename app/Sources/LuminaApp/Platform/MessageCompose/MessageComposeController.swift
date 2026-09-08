#if canImport(MessageUI) && canImport(UIKit) && !targetEnvironment(macCatalyst)
import MessageUI
import LuminaAppCore
import SwiftUI

struct MessageComposeController: UIViewControllerRepresentable {
    let draft: LuminaMessageDraft
    let onComplete: (LuminaMessageComposeOutcome) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIViewController {
        guard MFMessageComposeViewController.canSendText() else {
            Task { @MainActor in
                onComplete(.failed("当前设备不能发送短信。"))
                dismiss()
            }
            return UIHostingController(rootView: Text("当前设备不能发送短信").padding())
        }

        let controller = MFMessageComposeViewController()
        controller.recipients = draft.recipients
        controller.body = draft.body
        controller.messageComposeDelegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(dismiss: dismiss, onComplete: onComplete)
    }

    final class Coordinator: NSObject, MFMessageComposeViewControllerDelegate {
        private let dismiss: DismissAction
        private let onComplete: (LuminaMessageComposeOutcome) -> Void
        private var didComplete = false

        init(dismiss: DismissAction, onComplete: @escaping (LuminaMessageComposeOutcome) -> Void) {
            self.dismiss = dismiss
            self.onComplete = onComplete
        }

        func messageComposeViewController(
            _ controller: MFMessageComposeViewController,
            didFinishWith result: MessageComposeResult
        ) {
            guard !didComplete else { return }
            didComplete = true
            switch result {
            case .sent: onComplete(.sent)
            case .cancelled: onComplete(.cancelled)
            case .failed: onComplete(.failed("系统短信编辑器报告发送失败。"))
            @unknown default: onComplete(.failed("系统短信编辑器返回未知结果，不能确认是否发送。"))
            }
            dismiss()
        }
    }
}
#endif
