import Foundation

public enum PermissionDecision: Codable, Hashable, Sendable {
    case allowed
    case requiresConfirmation(reason: String)
    case denied(reason: String)

    public var isAllowedWithoutConfirmation: Bool {
        if case .allowed = self { return true }
        return false
    }
}

public protocol PermissionGate: Sendable {
    func decision(for call: ToolCall, schema: ToolSchema, request: AgentRequest) async -> PermissionDecision
}

public struct DefaultPermissionGate: PermissionGate {
    public init() {}

    public func decision(for call: ToolCall, schema: ToolSchema, request: AgentRequest) async -> PermissionDecision {
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

public protocol ConfirmationCoordinator: Sendable {
    func confirm(call: ToolCall, schema: ToolSchema, reason: String) async -> Bool
}

public struct AlwaysConfirmCoordinator: ConfirmationCoordinator {
    public init() {}

    public func confirm(call: ToolCall, schema: ToolSchema, reason: String) async -> Bool {
        true
    }
}

public struct DenyAllConfirmationCoordinator: ConfirmationCoordinator {
    public init() {}

    public func confirm(call: ToolCall, schema: ToolSchema, reason: String) async -> Bool {
        false
    }
}
