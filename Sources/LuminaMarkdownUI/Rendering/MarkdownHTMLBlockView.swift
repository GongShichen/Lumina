import Markdown
import SwiftUI

struct MarkdownHTMLBlockView: View {
    let rawHTML: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("HTML", systemImage: "chevron.left.forwardslash.chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: true) {
                Text(rawHTML)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
            }
        }
        .padding(10)
        .background(.secondary.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
