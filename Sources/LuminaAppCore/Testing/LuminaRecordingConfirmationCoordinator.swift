import LuminaAgentClient
import Foundation

public actor LuminaRecordingConfirmationCoordinator: LuminaConfirmationCoordinator {
    private var accepted: Bool
    private var requests: [(LuminaToolCall, LuminaToolSchema, String)] = []

    public init(accepted: Bool = true) {
        self.accepted = accepted
    }

    public func setAccepted(_ value: Bool) {
        accepted = value
    }

    public func confirm(call: LuminaToolCall, schema: LuminaToolSchema, reason: String) async -> Bool {
        requests.append((call, schema, reason))
        return accepted
    }

    public func requestCount() -> Int {
        requests.count
    }
}
