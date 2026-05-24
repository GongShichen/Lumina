import Foundation

public struct LuminaAlwaysConfirmCoordinator: LuminaConfirmationCoordinator {
    public init() {}

    public func confirm(call: LuminaToolCall, schema: LuminaToolSchema, reason: String) async -> Bool {
        true
    }
}
