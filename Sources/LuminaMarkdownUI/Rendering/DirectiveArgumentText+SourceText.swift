import Markdown
import SwiftUI

extension DirectiveArgumentText {
    var sourceText: String {
        segments
            .map { String($0.trimmedText) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
