import Foundation

public struct LuminaMemorySearchResult: Codable, Hashable, Sendable {
    public var chunk: LuminaMemoryChunk
    public var score: Float
    public var matchedBy: LuminaMemoryMatchKind
    public var bm25Rank: Int?
    public var vectorRank: Int?

    public init(
        chunk: LuminaMemoryChunk,
        score: Float,
        matchedBy: LuminaMemoryMatchKind,
        bm25Rank: Int? = nil,
        vectorRank: Int? = nil
    ) {
        self.chunk = chunk
        self.score = score
        self.matchedBy = matchedBy
        self.bm25Rank = bm25Rank
        self.vectorRank = vectorRank
    }
}
