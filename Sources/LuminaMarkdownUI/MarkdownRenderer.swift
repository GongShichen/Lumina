import Markdown
import SwiftUI

public struct MarkdownView: View {
    private let markdown: String
    @State private var document: ParsedMarkdownDocument?

    public init(markdown: String) {
        self.markdown = markdown
    }

    public var body: some View {
        Group {
            if let document {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(document.blocks) { block in
                        MarkdownBlockView(block: block, depth: 0)
                    }
                }
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: markdown) {
            if let cached = MarkdownDocumentCache.shared.cachedDocument(for: markdown) {
                document = cached
                return
            }

            document = nil
            let parsed = await Task.detached(priority: .userInitiated) {
                MarkdownDocumentCache.shared.document(for: markdown)
            }.value
            guard !Task.isCancelled else { return }
            document = parsed
        }
    }
}

public struct ParsedMarkdownDocument: Hashable, Sendable {
    public var blocks: [MarkdownBlock]

    public init(blocks: [MarkdownBlock]) {
        self.blocks = blocks
    }
}

public enum MarkdownBlock: Hashable, Identifiable, Sendable {
    case heading(id: UUID, level: Int, inlineMarkdown: String)
    case paragraph(id: UUID, inlineMarkdown: String)
    case blockQuote(id: UUID, blocks: [MarkdownBlock])
    case list(id: UUID, kind: MarkdownListKind, startIndex: Int, items: [MarkdownListItem])
    case codeBlock(id: UUID, language: String?, code: String)
    case htmlBlock(id: UUID, rawHTML: String)
    case table(id: UUID, table: MarkdownTable)
    case thematicBreak(id: UUID)
    case directive(id: UUID, name: String, argumentText: String, blocks: [MarkdownBlock])
    case customBlock(id: UUID, blocks: [MarkdownBlock])
    case fallback(id: UUID, markdown: String)

    public var id: UUID {
        switch self {
        case let .heading(id, _, _),
             let .paragraph(id, _),
             let .blockQuote(id, _),
             let .list(id, _, _, _),
             let .codeBlock(id, _, _),
             let .htmlBlock(id, _),
             let .table(id, _),
             let .thematicBreak(id),
             let .directive(id, _, _, _),
             let .customBlock(id, _),
             let .fallback(id, _):
            return id
        }
    }
}

public enum MarkdownListKind: Hashable, Sendable {
    case unordered
    case ordered
}

public enum MarkdownTaskState: Hashable, Sendable {
    case checked
    case unchecked
}

public struct MarkdownListItem: Hashable, Identifiable, Sendable {
    public var id: UUID
    public var taskState: MarkdownTaskState?
    public var blocks: [MarkdownBlock]

    public init(id: UUID = UUID(), taskState: MarkdownTaskState? = nil, blocks: [MarkdownBlock]) {
        self.id = id
        self.taskState = taskState
        self.blocks = blocks
    }
}

public struct MarkdownTable: Hashable, Sendable {
    public var header: [String]
    public var rows: [[String]]
    public var alignments: [MarkdownTableAlignment?]

    public init(header: [String], rows: [[String]], alignments: [MarkdownTableAlignment?]) {
        self.header = header
        self.rows = rows
        self.alignments = alignments
    }
}

public enum MarkdownTableAlignment: Hashable, Sendable {
    case left
    case center
    case right
}

public struct MarkdownASTParser: Sendable {
    public init() {}

    public func parse(_ markdown: String) -> ParsedMarkdownDocument {
        let document = Document(parsing: markdown, options: [.parseBlockDirectives])
        return ParsedMarkdownDocument(blocks: document.children.compactMap(convertBlock))
    }

    private func convertBlock(_ markup: Markup) -> MarkdownBlock? {
        switch markup {
        case let heading as Heading:
            return .heading(id: UUID(), level: heading.level, inlineMarkdown: inlineMarkdown(from: heading))
        case let paragraph as Paragraph:
            return .paragraph(id: UUID(), inlineMarkdown: inlineMarkdown(from: paragraph))
        case let blockQuote as BlockQuote:
            return .blockQuote(id: UUID(), blocks: blockQuote.children.compactMap(convertBlock))
        case let unorderedList as UnorderedList:
            return .list(id: UUID(), kind: .unordered, startIndex: 1, items: unorderedList.children.compactMap(convertListItem))
        case let orderedList as OrderedList:
            return .list(
                id: UUID(),
                kind: .ordered,
                startIndex: Int(orderedList.startIndex),
                items: orderedList.children.compactMap(convertListItem)
            )
        case let codeBlock as CodeBlock:
            return .codeBlock(id: UUID(), language: codeBlock.language, code: codeBlock.code)
        case let htmlBlock as HTMLBlock:
            return .htmlBlock(id: UUID(), rawHTML: htmlBlock.rawHTML)
        case _ as ThematicBreak:
            return .thematicBreak(id: UUID())
        case let table as Markdown.Table:
            return .table(id: UUID(), table: convertTable(table))
        case let directive as BlockDirective:
            return .directive(
                id: UUID(),
                name: directive.name,
                argumentText: directive.argumentText.sourceText,
                blocks: directive.children.compactMap(convertBlock)
            )
        case let customBlock as CustomBlock:
            return .customBlock(id: UUID(), blocks: customBlock.children.compactMap(convertBlock))
        default:
            let formatted = markup.format().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !formatted.isEmpty else { return nil }
            return .fallback(id: UUID(), markdown: formatted)
        }
    }

    private func convertListItem(_ markup: Markup) -> MarkdownListItem? {
        guard let item = markup as? ListItem else { return nil }
        return MarkdownListItem(
            taskState: taskState(from: item.checkbox),
            blocks: item.children.compactMap(convertBlock)
        )
    }

    private func taskState(from checkbox: Checkbox?) -> MarkdownTaskState? {
        switch checkbox {
        case .checked:
            return .checked
        case .unchecked:
            return .unchecked
        case nil:
            return nil
        }
    }

    private func convertTable(_ table: Markdown.Table) -> MarkdownTable {
        MarkdownTable(
            header: table.head.cells.map { inlineMarkdown(from: $0) },
            rows: table.body.rows.map { row in
                row.cells.map { inlineMarkdown(from: $0) }
            },
            alignments: table.columnAlignments.map { alignment in
                switch alignment {
                case .left:
                    return .left
                case .center:
                    return .center
                case .right:
                    return .right
                case nil:
                    return nil
                }
            }
        )
    }

    private func inlineMarkdown(from markup: Markup) -> String {
        markup.children
            .map { $0.format() }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

final class MarkdownDocumentCache: @unchecked Sendable {
    static let shared = MarkdownDocumentCache()

    private let cache = NSCache<NSString, ParsedMarkdownBox>()
    private let parser = MarkdownASTParser()

    private init() {
        cache.countLimit = 128
        cache.totalCostLimit = 2_000_000
    }

    func document(for markdown: String) -> ParsedMarkdownDocument {
        let key = markdown as NSString
        if let cached = cache.object(forKey: key) {
            return cached.document
        }
        let document = parser.parse(markdown)
        cache.setObject(ParsedMarkdownBox(document), forKey: key, cost: markdown.utf8.count)
        return document
    }

    func cachedDocument(for markdown: String) -> ParsedMarkdownDocument? {
        cache.object(forKey: markdown as NSString)?.document
    }
}

private final class ParsedMarkdownBox {
    let document: ParsedMarkdownDocument

    init(_ document: ParsedMarkdownDocument) {
        self.document = document
    }
}

private extension DirectiveArgumentText {
    var sourceText: String {
        segments
            .map { String($0.trimmedText) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct MarkdownBlockView: View {
    let block: MarkdownBlock
    let depth: Int

    var body: some View {
        switch block {
        case let .heading(_, level, inlineMarkdown):
            MarkdownHeadingView(level: level, inlineMarkdown: inlineMarkdown)
        case let .paragraph(_, inlineMarkdown):
            MarkdownParagraphView(inlineMarkdown: inlineMarkdown)
        case let .blockQuote(_, blocks):
            MarkdownBlockQuoteView(blocks: blocks, depth: depth)
        case let .list(_, kind, startIndex, items):
            MarkdownListView(kind: kind, startIndex: startIndex, items: items, depth: depth)
        case let .codeBlock(_, language, code):
            MarkdownCodeBlockView(language: language, code: code)
        case let .htmlBlock(_, rawHTML):
            MarkdownHTMLBlockView(rawHTML: rawHTML)
        case let .table(_, table):
            MarkdownTableView(table: table)
        case .thematicBreak:
            MarkdownThematicBreakView()
        case let .directive(_, name, argumentText, blocks):
            MarkdownDirectiveView(name: name, argumentText: argumentText, blocks: blocks, depth: depth)
        case let .customBlock(_, blocks):
            MarkdownCustomBlockView(blocks: blocks, depth: depth)
        case let .fallback(_, markdown):
            MarkdownFallbackBlockView(markdown: markdown)
        }
    }
}

private struct MarkdownHeadingView: View {
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

private struct MarkdownParagraphView: View {
    let inlineMarkdown: String

    var body: some View {
        InlineMarkdownText(inlineMarkdown)
            .font(.callout)
            .lineSpacing(3)
    }
}

private struct MarkdownBlockQuoteView: View {
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

private struct MarkdownListView: View {
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

private struct MarkdownCodeBlockView: View {
    let language: String?
    let code: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let language, !language.isEmpty {
                HStack {
                    Text(language.uppercased())
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(.secondary.opacity(0.10))
            }

            ScrollView(.horizontal, showsIndicators: true) {
                Text(code)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(.secondary.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(.secondary.opacity(0.12), lineWidth: 1)
        }
    }
}

private struct MarkdownHTMLBlockView: View {
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

private struct MarkdownTableView: View {
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

private struct MarkdownThematicBreakView: View {
    var body: some View {
        Divider()
            .overlay(.secondary.opacity(0.5))
            .padding(.vertical, 6)
    }
}

private struct MarkdownDirectiveView: View {
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

private struct MarkdownCustomBlockView: View {
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

private struct MarkdownFallbackBlockView: View {
    let markdown: String

    var body: some View {
        InlineMarkdownText(markdown)
            .font(.callout)
            .padding(10)
            .background(.secondary.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct InlineMarkdownText: View {
    let markdown: String

    init(_ markdown: String) {
        self.markdown = markdown
    }

    var body: some View {
        if let attributed = try? AttributedString(
            markdown: markdown,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            Text(attributed)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(markdown)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
