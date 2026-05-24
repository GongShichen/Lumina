import Foundation

public actor LuminaMessageDraftCenter {
    private var continuation: AsyncStream<LuminaMessageDraft>.Continuation?
    private var publishedDrafts: [LuminaMessageDraft] = []

    public init() {}

    public func drafts() -> AsyncStream<LuminaMessageDraft> {
        AsyncStream { continuation in
            self.continuation = continuation
        }
    }

    public func publish(_ draft: LuminaMessageDraft) {
        publishedDrafts.append(draft)
        continuation?.yield(draft)
    }

    public func allDrafts() -> [LuminaMessageDraft] {
        publishedDrafts
    }
}
