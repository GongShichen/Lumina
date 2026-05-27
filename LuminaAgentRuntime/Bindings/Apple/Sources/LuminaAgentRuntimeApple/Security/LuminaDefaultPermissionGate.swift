import Foundation

public struct LuminaDefaultPermissionGate: LuminaPermissionGate {
    public init() {}

    public func decision(for call: LuminaToolCall, schema: LuminaToolSchema, request: LuminaAgentRequest) async -> LuminaPermissionDecision {
        switch schema.sideEffect {
        case .readOnly:
            return .allowed
        case .appLocalWrite:
            return .requiresConfirmation(reason: "This action changes app-local data.")
        case .systemWrite:
            return .requiresConfirmation(reason: "This action changes system data.")
        case .externalCommunication:
            return .requiresConfirmation(reason: "This action may communicate outside the app.")
        }
    }
}
