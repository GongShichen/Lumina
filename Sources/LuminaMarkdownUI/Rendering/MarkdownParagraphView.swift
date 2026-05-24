import Markdown
import SwiftUI

struct MarkdownParagraphView: View {
    let inlineMarkdown: String

    var body: some View {
        InlineMarkdownText(inlineMarkdown)
            .font(.callout)
            .lineSpacing(3)
    }
}
