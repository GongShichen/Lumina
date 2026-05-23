import AgentRuntime
import Foundation

struct ConfirmationRequest: Identifiable {
    let id: UUID
    let call: ToolCall
    let schema: ToolSchema
    let reason: String
}

@MainActor
final class AppConfirmationCoordinator: ObservableObject, ConfirmationCoordinator {
    @Published var pending: ConfirmationRequest?
    private var continuations: [UUID: CheckedContinuation<Bool, Never>] = [:]

    nonisolated func confirm(call: ToolCall, schema: ToolSchema, reason: String) async -> Bool {
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
}
