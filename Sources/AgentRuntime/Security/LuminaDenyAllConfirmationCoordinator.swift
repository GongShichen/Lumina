import Foundation

public struct LuminaDenyAllConfirmationCoordinator: LuminaConfirmationCoordinator {
    public init() {}

    public func confirm(call: LuminaToolCall, schema: LuminaToolSchema, reason: String) async -> Bool {
        false
    }
}
