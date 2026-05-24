import Foundation

public protocol LuminaRuntimeContextProvider: Sendable {
    func loadContext(_ request: LuminaRuntimeContextRequest) async throws -> LuminaRuntimeContext
}
