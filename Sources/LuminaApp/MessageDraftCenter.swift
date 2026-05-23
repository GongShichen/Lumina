import Foundation

struct MessageDraft: Identifiable, Hashable, Sendable {
    var id = UUID()
    var recipients: [String]
    var body: String
}

actor MessageDraftCenter {
    private var continuation: AsyncStream<MessageDraft>.Continuation?

    func drafts() -> AsyncStream<MessageDraft> {
        AsyncStream { continuation in
            self.continuation = continuation
        }
    }

    func publish(_ draft: MessageDraft) {
        continuation?.yield(draft)
    }
}
