import Markdown
import SwiftUI

struct MarkdownFallbackBlockView: View {
    let markdown: String

    var body: some View {
        InlineMarkdownText(markdown)
            .font(.callout)
            .padding(10)
            .background(.secondary.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
