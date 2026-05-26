import Foundation

public protocol LuminaPermissionGate: Sendable {
    func decision(for call: LuminaToolCall, schema: LuminaToolSchema, request: LuminaAgentRequest) async -> LuminaPermissionDecision
}
