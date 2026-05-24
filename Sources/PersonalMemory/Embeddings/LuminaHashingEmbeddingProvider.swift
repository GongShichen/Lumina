import Foundation

public struct LuminaHashingEmbeddingProvider: LuminaEmbeddingProvider {
    public let dimension: Int

    public init(dimension: Int = 384) {
        self.dimension = dimension
    }

    public func embed(_ text: String) async throws -> [Float] {
        try Task.checkCancellation()
        var vector = Array(repeating: Float(0), count: dimension)
        let tokens = tokenize(text)
        guard !tokens.isEmpty else { return vector }

        for token in tokens {
            let index = abs(stableHash(token)) % dimension
            vector[index] += 1
        }

        return normalize(vector)
    }

    private func tokenize(_ text: String) -> [String] {
        text
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }

    private func stableHash(_ value: String) -> Int {
        var hash = 5381
        for byte in value.utf8 {
            hash = ((hash << 5) &+ hash) &+ Int(byte)
        }
        return hash
    }

    private func normalize(_ vector: [Float]) -> [Float] {
        let norm = sqrt(vector.reduce(Float(0)) { $0 + $1 * $1 })
        guard norm > 0 else { return vector }
        return vector.map { $0 / norm }
    }
}
