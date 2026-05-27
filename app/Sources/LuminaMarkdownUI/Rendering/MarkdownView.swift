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
