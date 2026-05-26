import SwiftUI

struct MessageComposeSheet: View {
    let draft: LuminaMessageDraft

    var body: some View {
        #if canImport(MessageUI) && canImport(UIKit) && !targetEnvironment(macCatalyst)
        MessageComposeController(draft: draft)
        #else
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
        #endif
    }
}
