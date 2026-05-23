import AgentRuntime
import Foundation

public actor RecordingConfirmationCoordinator: ConfirmationCoordinator {
    private var accepted: Bool
    private var requests: [(ToolCall, ToolSchema, String)] = []

    public init(accepted: Bool = true) {
        self.accepted = accepted
    }

    public func setAccepted(_ value: Bool) {
        accepted = value
    }

    public func confirm(call: ToolCall, schema: ToolSchema, reason: String) async -> Bool {
        requests.append((call, schema, reason))
        return accepted
    }

    public func requestCount() -> Int {
        requests.count
    }
}
