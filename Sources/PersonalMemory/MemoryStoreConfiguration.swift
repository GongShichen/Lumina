import Foundation

public struct MemoryStoreConfiguration: Codable, Hashable, Sendable {
    public var cacheLimit: Int
    public var maximumVectorCandidates: Int
    public var embedImmediately: Bool
    public var scheduleBackgroundEmbedding: Bool
    public var persistAfterIngest: Bool
    public var persistAfterEmbedding: Bool

    public init(
        cacheLimit: Int = 24,
        maximumVectorCandidates: Int = 2_000,
        embedImmediately: Bool = false,
        scheduleBackgroundEmbedding: Bool = true,
        persistAfterIngest: Bool = true,
        persistAfterEmbedding: Bool = false
    ) {
        self.cacheLimit = cacheLimit
        self.maximumVectorCandidates = maximumVectorCandidates
        self.embedImmediately = embedImmediately
        self.scheduleBackgroundEmbedding = scheduleBackgroundEmbedding
        self.persistAfterIngest = persistAfterIngest
        self.persistAfterEmbedding = persistAfterEmbedding
    }
}

public struct MemoryIndexStats: Codable, Hashable, Sendable {
    public var documentCount: Int
    public var chunkCount: Int
    public var embeddedChunkCount: Int
    public var cacheEntryCount: Int

    public init(
        documentCount: Int,
        chunkCount: Int,
        embeddedChunkCount: Int,
        cacheEntryCount: Int
    ) {
        self.documentCount = documentCount
        self.chunkCount = chunkCount
        self.embeddedChunkCount = embeddedChunkCount
        self.cacheEntryCount = cacheEntryCount
    }
}

public struct MemorySearchReport: Codable, Hashable, Sendable {
    public var results: [MemorySearchResult]
    public var candidateCount: Int
    public var vectorCandidateCount: Int
    public var elapsedMilliseconds: Double
    public var cacheHit: Bool

    public init(
        results: [MemorySearchResult],
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

enum MemoryClock {
    static func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let duration = start.duration(to: .now)
        let components = duration.components
        return Double(components.seconds) * 1_000 + Double(components.attoseconds) / 1e15
    }
}
