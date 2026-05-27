import Foundation

public protocol LuminaReActContextCompactor: Sendable {
    func compact(_ request: LuminaReActCompactionRequest) async throws -> LuminaReActCompactionResult
}
