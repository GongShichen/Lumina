import Foundation

public struct LuminaEmptyRuntimeContextProvider: LuminaRuntimeContextProvider {
    public init() {}

    public func loadContext(_ request: LuminaRuntimeContextRequest) async throws -> LuminaRuntimeContext {
        try Task.checkCancellation()
        return .empty
    }
}
