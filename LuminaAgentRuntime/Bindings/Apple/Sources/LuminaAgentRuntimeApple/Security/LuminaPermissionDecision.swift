import Foundation

public enum LuminaPermissionDecision: Codable, Hashable, Sendable {
    case allowed
    case requiresConfirmation(reason: String)
    case denied(reason: String)

    public var isAllowedWithoutConfirmation: Bool {
        if case .allowed = self { return true }
        return false
    }
}
