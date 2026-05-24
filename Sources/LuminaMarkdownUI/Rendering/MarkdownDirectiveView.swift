import Markdown
import SwiftUI

struct MarkdownDirectiveView: View {
    let name: String
    let argumentText: String
    let blocks: [MarkdownBlock]
    let depth: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "at")
                    .font(.caption.weight(.semibold))
                Text(name)
                    .font(.caption.weight(.semibold))
                if !argumentText.isEmpty {
                    Text(argumentText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .foregroundStyle(.secondary)

            ForEach(blocks) { block in
                MarkdownBlockView(block: block, depth: depth + 1)
            }
        }
        .padding(10)
        .background(.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
