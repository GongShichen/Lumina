import Markdown
import SwiftUI

struct MarkdownHeadingView: View {
    let level: Int
    let inlineMarkdown: String

    var body: some View {
        InlineMarkdownText(inlineMarkdown)
            .font(font)
            .fontWeight(level <= 2 ? .semibold : .medium)
            .foregroundStyle(.primary)
            .padding(.top, level == 1 ? 8 : 4)
            .padding(.bottom, level <= 2 ? 2 : 0)
            .accessibilityAddTraits(.isHeader)
    }

    private var font: Font {
        switch level {
        case 1:
            return .title2
        case 2:
            return .title3
        case 3:
            return .headline
        case 4:
            return .subheadline.weight(.semibold)
        default:
            return .callout.weight(.semibold)
        }
    }
}
