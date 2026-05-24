import Foundation

public struct LuminaMemoryStoreConfiguration: Codable, Hashable, Sendable {
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
