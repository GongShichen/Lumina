import Markdown
import SwiftUI

struct MarkdownBlockQuoteView: View {
    let blocks: [MarkdownBlock]
    let depth: Int

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(.secondary.opacity(0.42))
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(blocks) { block in
                    MarkdownBlockView(block: block, depth: depth + 1)
                }
            }
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(.secondary.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
