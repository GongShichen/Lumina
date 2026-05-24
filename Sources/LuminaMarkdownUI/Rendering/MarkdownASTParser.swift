import Markdown
import SwiftUI

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
