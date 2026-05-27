import Markdown
import SwiftUI

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
