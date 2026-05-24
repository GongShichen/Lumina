import Foundation

public struct LuminaMemorySearchReport: Codable, Hashable, Sendable {
    public var results: [LuminaMemorySearchResult]
    public var candidateCount: Int
    public var vectorCandidateCount: Int
    public var elapsedMilliseconds: Double
    public var cacheHit: Bool

    public init(
        results: [LuminaMemorySearchResult],
        candidateCount: Int,
        vectorCandidateCount: Int,
        elapsedMilliseconds: Double,
        cacheHit: Bool
    ) {
        self.results = results
        self.candidateCount = candidateCount
        self.vectorCandidateCount = vectorCandidateCount
        self.elapsedMilliseconds = elapsedMilliseconds
        self.cacheHit = cacheHit
    }
}
