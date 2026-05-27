import Markdown
import SwiftUI

final class ParsedMarkdownBox {
    let document: ParsedMarkdownDocument

    init(_ document: ParsedMarkdownDocument) {
        self.document = document
    }
}
