import Markdown
import SwiftUI

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
