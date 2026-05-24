import Foundation

public struct LuminaNoOpReActContextCompactor: LuminaReActContextCompactor {
    public init() {}

    public func compact(_ request: LuminaReActCompactionRequest) async throws -> LuminaReActCompactionResult {
        try Task.checkCancellation()
        return LuminaReActCompactionResult(
            trace: request.trace,
            summary: "",
            estimatedCharactersBefore: request.estimatedCharacters,
            estimatedCharactersAfter: request.estimatedCharacters
        )
    }
}
