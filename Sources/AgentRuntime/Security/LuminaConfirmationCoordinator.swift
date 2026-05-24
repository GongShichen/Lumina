import Foundation

public protocol LuminaConfirmationCoordinator: Sendable {
    func confirm(call: LuminaToolCall, schema: LuminaToolSchema, reason: String) async -> Bool
}
