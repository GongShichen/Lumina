import Foundation

public protocol LuminaEmbeddingProvider: Sendable {
    var dimension: Int { get }
    func embed(_ text: String) async throws -> [Float]
}
