import Markdown
import SwiftUI

struct MarkdownCustomBlockView: View {
    let blocks: [MarkdownBlock]
    let depth: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(blocks) { block in
                MarkdownBlockView(block: block, depth: depth + 1)
            }
        }
        .padding(.leading, 8)
    }
}
