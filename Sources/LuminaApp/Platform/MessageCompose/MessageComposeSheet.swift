#if canImport(MessageUI) && canImport(UIKit) && !targetEnvironment(macCatalyst)
import MessageUI
import SwiftUI

struct MessageComposeSheet: UIViewControllerRepresentable {
    let draft: LuminaMessageDraft
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIViewController {
        guard MFMessageComposeViewController.canSendText() else {
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
        Coordinator(dismiss: dismiss)
    }

    final class Coordinator: NSObject, MFMessageComposeViewControllerDelegate {
        private let dismiss: DismissAction

        init(dismiss: DismissAction) {
            self.dismiss = dismiss
        }

        func messageComposeViewController(
            _ controller: MFMessageComposeViewController,
            didFinishWith result: MessageComposeResult
        ) {
            dismiss()
        }
    }
}
#else
import SwiftUI

struct MessageComposeSheet: View {
    let draft: LuminaMessageDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("短信编辑器不可用")
                .font(.headline)
            Text("macOS 版本不能通过公开系统 API 打开短信编辑器。请在 iPhone 上使用该能力。")
                .foregroundStyle(.secondary)
            if !draft.body.isEmpty {
                Text(draft.body)
                    .font(.body)
                    .textSelection(.enabled)
            }
        }
        .padding()
    }
}
#endif
