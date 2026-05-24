import Foundation

public struct LuminaMemorySearchResult: Codable, Hashable, Sendable {
    public var chunk: LuminaMemoryChunk
    public var score: Float
    public var matchedBy: LuminaMemoryMatchKind

    public init(chunk: LuminaMemoryChunk, score: Float, matchedBy: LuminaMemoryMatchKind) {
        self.chunk = chunk
        self.score = score
        self.matchedBy = matchedBy
    }
}
