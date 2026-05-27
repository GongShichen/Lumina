import Markdown
import SwiftUI

struct MarkdownTableView: View {
    let table: MarkdownTable

    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                if !table.header.isEmpty {
                    GridRow {
                        ForEach(Array(table.header.enumerated()), id: \.offset) { index, cell in
                            tableCell(cell, column: index, isHeader: true)
                        }
                    }
                }

                ForEach(Array(table.rows.enumerated()), id: \.offset) { rowIndex, row in
                    GridRow {
                        ForEach(Array(normalized(row).enumerated()), id: \.offset) { columnIndex, cell in
                            tableCell(cell, column: columnIndex, isHeader: false)
                                .background(rowIndex.isMultiple(of: 2) ? Color.clear : Color.secondary.opacity(0.045))
                        }
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(.secondary.opacity(0.16), lineWidth: 1)
            }
            .padding(.vertical, 2)
        }
    }

    private func tableCell(_ value: String, column: Int, isHeader: Bool) -> some View {
        InlineMarkdownText(value)
            .font(isHeader ? .caption.weight(.semibold) : .caption)
            .multilineTextAlignment(textAlignment(for: column))
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .frame(minWidth: 96, alignment: frameAlignment(for: column))
            .background(isHeader ? Color.secondary.opacity(0.10) : Color.clear)
            .border(.secondary.opacity(0.10), width: 0.5)
    }

    private func normalized(_ row: [String]) -> [String] {
        let count = Swift.max(table.header.count, row.count)
        guard row.count < count else { return row }
        return row + Array(repeating: "", count: count - row.count)
    }

    private func alignment(for column: Int) -> MarkdownTableAlignment? {
        guard table.alignments.indices.contains(column) else { return nil }
        return table.alignments[column]
    }

    private func textAlignment(for column: Int) -> TextAlignment {
        switch alignment(for: column) {
        case .center:
            return .center
        case .right:
            return .trailing
        case .left, nil:
            return .leading
        }
    }

    private func frameAlignment(for column: Int) -> Alignment {
        switch alignment(for: column) {
        case .center:
            return .center
        case .right:
            return .trailing
        case .left, nil:
            return .leading
        }
    }
}
