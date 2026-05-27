import Markdown
import SwiftUI

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
