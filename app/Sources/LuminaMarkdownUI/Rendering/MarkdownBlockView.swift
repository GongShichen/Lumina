import Markdown
import SwiftUI

struct MarkdownBlockView: View {
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
