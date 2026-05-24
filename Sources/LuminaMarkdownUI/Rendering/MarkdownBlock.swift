import Markdown
import SwiftUI

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
