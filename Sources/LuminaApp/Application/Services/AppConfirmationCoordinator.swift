import LuminaAgentClient
import Foundation

@MainActor
final class AppConfirmationCoordinator: ObservableObject, LuminaConfirmationCoordinator {
    @Published var pending: ConfirmationRequest?
    private var continuations: [UUID: CheckedContinuation<Bool, Never>] = [:]

    nonisolated func confirm(call: LuminaToolCall, schema: LuminaToolSchema, reason: String) async -> Bool {
        await MainActor.run {
            // Hop to MainActor before creating UI state.
        }
        return await withCheckedContinuation { continuation in
            Task { @MainActor in
                let request = ConfirmationRequest(id: UUID(), call: call, schema: schema, reason: reason)
                continuations[request.id] = continuation
                pending = request
            }
        }
    }

    func resolve(id: UUID, accepted: Bool) {
        let continuation = continuations.removeValue(forKey: id)
        pending = nil
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
