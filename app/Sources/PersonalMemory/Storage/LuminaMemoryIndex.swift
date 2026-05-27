import Foundation

struct LuminaMemoryIndex: Sendable {
    private var chunks: [UUID: LuminaMemoryChunk]
    private var documentIndex: [UUID: [UUID]]

    init(chunks: [UUID: LuminaMemoryChunk] = [:], documentIndex: [UUID: [UUID]] = [:]) {
        self.chunks = chunks
        self.documentIndex = documentIndex
    }

    var allChunks: [LuminaMemoryChunk] {
        Array(chunks.values)
    }

    func recentChunks(limit: Int, maximumSensitivity: LuminaMemorySensitivity) -> [LuminaMemoryChunk] {
        chunks.values
            .filter { $0.sensitivity <= maximumSensitivity }
            .sorted { $0.createdAt > $1.createdAt }
            .prefix(limit)
            .map { $0 }
    }

    var chunkCount: Int {
        chunks.count
    }

    var embeddedChunkCount: Int {
        chunks.values.filter { $0.embedding != nil }.count
    }

    mutating func load(snapshot: LuminaMemorySnapshot) {
        chunks = Dictionary(uniqueKeysWithValues: snapshot.chunks.map { ($0.id, $0) })
        documentIndex = snapshot.documentIndex
    }

    mutating func ingest(_ newChunks: [LuminaMemoryChunk], documentID: UUID) -> [UUID] {
        let ids = newChunks.map(\.id)
        documentIndex[documentID] = ids
        for chunk in newChunks {
            chunks[chunk.id] = chunk
        }
        return ids
    }

    func chunk(id: UUID) -> LuminaMemoryChunk? {
        chunks[id]
    }

    mutating func updateEmbedding(_ embedding: [Float], for id: UUID) {
        guard var chunk = chunks[id] else { return }
        chunk.embedding = embedding
        chunks[id] = chunk
    }

    mutating func removeDocument(id: UUID) {
        let ids = documentIndex[id] ?? []
        for id in ids {
            chunks[id] = nil
        }
        documentIndex[id] = nil
    }

    @discardableResult
    mutating func removeChunk(id: UUID) -> Bool {
        guard chunks.removeValue(forKey: id) != nil else {
            return false
        }

        for documentID in documentIndex.keys {
            documentIndex[documentID]?.removeAll { $0 == id }
            if documentIndex[documentID]?.isEmpty == true {
                documentIndex[documentID] = nil
            }
        }
        return true
    }

    @discardableResult
    mutating func removeAll() -> Int {
        let removedCount = chunks.count
        chunks.removeAll(keepingCapacity: false)
        documentIndex.removeAll(keepingCapacity: false)
        return removedCount
    }

    func stats(cacheEntryCount: Int) -> LuminaMemoryIndexStats {
        LuminaMemoryIndexStats(
            documentCount: documentIndex.count,
            chunkCount: chunks.count,
            embeddedChunkCount: embeddedChunkCount,
            cacheEntryCount: cacheEntryCount
        )
    }

    func snapshot() -> LuminaMemorySnapshot {
        LuminaMemorySnapshot(chunks: Array(chunks.values), documentIndex: documentIndex)
    }
}
