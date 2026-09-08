import LuminaAgentRuntime
import Foundation

@MainActor
final class AppConfirmationCoordinator: ObservableObject, LuminaConfirmationCoordinator {
    @Published var pending: ConfirmationRequest?
    private var continuations: [UUID: CheckedContinuation<Bool, Never>] = [:]

    nonisolated func confirm(call: LuminaToolCall, schema: LuminaToolSchema, reason: String) async -> Bool {
        let accepted = await waitForDecision(ConfirmationRequest(id: UUID(), call: call, schema: schema, reason: reason))
        return accepted && !Task.isCancelled
    }

    private func waitForDecision(_ request: ConfirmationRequest) async -> Bool {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: false)
                    return
                }
                // A replaced sheet must never leave its original tool suspended.
                if let pending { resolve(id: pending.id, accepted: false) }
                continuations[request.id] = continuation
                pending = request
            }
        } onCancel: {
            Task { @MainActor in
                self.resolve(id: request.id, accepted: false)
            }
        }
    }

    func resolve(id: UUID, accepted: Bool) {
        let continuation = continuations.removeValue(forKey: id)
        if pending?.id == id { pending = nil }
        continuation?.resume(returning: accepted)
    }

    func resetForNewSession() {
        pending = nil
        for continuation in continuations.values {
            continuation.resume(returning: false)
        }
        continuations.removeAll()
    }
}
