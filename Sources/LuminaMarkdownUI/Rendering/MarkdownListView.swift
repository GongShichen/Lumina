import Markdown
import SwiftUI

struct MarkdownListView: View {
    let kind: MarkdownListKind
    let startIndex: Int
    let items: [MarkdownListItem]
    let depth: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                HStack(alignment: .top, spacing: 9) {
                    marker(for: item, index: index)
                        .frame(width: markerWidth, alignment: .trailing)
                        .padding(.top, 1)
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(item.blocks) { block in
                            MarkdownBlockView(block: block, depth: depth + 1)
                        }
                    }
                }
            }
        }
        .padding(.leading, CGFloat(min(depth, 4)) * 10)
    }

    @ViewBuilder
    private func marker(for item: MarkdownListItem, index: Int) -> some View {
        if let taskState = item.taskState {
            Image(systemName: taskState == .checked ? "checkmark.square.fill" : "square")
                .font(.callout)
                .foregroundStyle(taskState == .checked ? .green : .secondary)
        } else {
            switch kind {
            case .unordered:
                Text(depth.isMultiple(of: 2) ? "•" : "◦")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
            case .ordered:
                Text("\(startIndex + index).")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var markerWidth: CGFloat {
        kind == .ordered ? 30 : 18
    }
}
