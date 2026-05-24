import Foundation

public struct LuminaMemoryIndexStats: Codable, Hashable, Sendable {
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
