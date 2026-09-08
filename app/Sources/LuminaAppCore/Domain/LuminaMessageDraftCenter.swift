import Foundation

public enum LuminaMessageComposeOutcome: Sendable, Equatable {
    case sent
    case cancelled
    case failed(String)
}

public actor LuminaMessageDraftCenter {
    private var continuation: AsyncStream<LuminaMessageDraft>.Continuation?
    private var presentationContinuation: AsyncStream<LuminaMessageDraft?>.Continuation?
    private var publishedDrafts: [LuminaMessageDraft] = []
    private var pendingDraft: LuminaMessageDraft?
    private var completions: [UUID: CheckedContinuation<LuminaMessageComposeOutcome, Never>] = [:]

    public init() {}

    public func drafts() -> AsyncStream<LuminaMessageDraft> {
        AsyncStream { continuation in
            self.continuation = continuation
        }
    }

    /// The presentation stream also closes the sheet when its owning task cancels.
    public func presentationChanges() -> AsyncStream<LuminaMessageDraft?> {
        AsyncStream { continuation in
            presentationContinuation = continuation
            continuation.yield(pendingDraft)
        }
    }

    public func publish(_ draft: LuminaMessageDraft) {
        publishedDrafts.append(draft)
        pendingDraft = draft
        continuation?.yield(draft)
        presentationContinuation?.yield(draft)
    }

    public func compose(_ draft: LuminaMessageDraft) async -> LuminaMessageComposeOutcome {
        await withTaskCancellationHandler {
            await withCheckedContinuation { completion in
                guard !Task.isCancelled else {
                    completion.resume(returning: .cancelled)
                    return
                }
                if let pendingDraft { resolve(id: pendingDraft.id, outcome: .cancelled) }
                completions[draft.id] = completion
                publish(draft)
            }
        } onCancel: {
            Task { await self.resolve(id: draft.id, outcome: .cancelled) }
        }
    }

    public func resolve(id: UUID, outcome: LuminaMessageComposeOutcome) {
        guard let completion = completions.removeValue(forKey: id) else { return }
        if pendingDraft?.id == id {
            pendingDraft = nil
            presentationContinuation?.yield(nil)
        }
        completion.resume(returning: outcome)
    }

    public func allDrafts() -> [LuminaMessageDraft] {
        publishedDrafts
    }
}
