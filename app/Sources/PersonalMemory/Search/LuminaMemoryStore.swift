import Foundation

public actor LuminaMemoryStore {
    private var index = LuminaMemoryIndex()
    private var bm25Index = LuminaBM25Index<UUID>()
    private let chunker: LuminaMemoryChunker
    private let embeddingProvider: any LuminaEmbeddingProvider
    private let repository: (any LuminaMemoryRepository)?
    private let configuration: LuminaMemoryStoreConfiguration
    private var recentSearchCache: LuminaMemorySearchCache

    public init(
        chunker: LuminaMemoryChunker = LuminaMemoryChunker(),
        embeddingProvider: any LuminaEmbeddingProvider = LuminaHashingEmbeddingProvider(),
        repository: (any LuminaMemoryRepository)? = nil,
        configuration: LuminaMemoryStoreConfiguration = LuminaMemoryStoreConfiguration()
    ) {
        self.chunker = chunker
        self.embeddingProvider = embeddingProvider
        self.repository = repository
        self.configuration = configuration
        self.recentSearchCache = LuminaMemorySearchCache(limit: configuration.cacheLimit)
    }

    public func load() async throws {
        guard let snapshot = try await repository?.load() else { return }
        self.index.load(snapshot: snapshot)
        rebuildBM25Index()
        self.recentSearchCache.removeAll(keepingCapacity: true)
    }

    public func persist() async throws {
        try await repository?.save(snapshot())
    }

    @discardableResult
    public func ingest(_ document: LuminaMemoryDocument) async -> [UUID] {
        let newChunks = chunker.chunks(for: document)
        let ids = index.ingest(newChunks, documentID: document.id)
        for chunk in newChunks {
            bm25Index.upsert(Self.bm25Document(for: chunk))
        }
        recentSearchCache.removeAll(keepingCapacity: true)
        if configuration.embedImmediately {
            Task { await embedMissing(ids: ids) }
        } else if configuration.scheduleBackgroundEmbedding {
            scheduleEmbedding(for: ids)
        }
        if configuration.persistAfterIngest {
            Task { try? await persist() }
        }
        return ids
    }

    public func search(_ query: LuminaMemorySearchQuery) async throws -> [LuminaMemorySearchResult] {
        try await searchWithReport(query).results
    }

    public func searchWithReport(_ query: LuminaMemorySearchQuery) async throws -> LuminaMemorySearchReport {
        let start = ContinuousClock.now
        try Task.checkCancellation()
        if let cached = recentSearchCache.results(for: query) {
            return LuminaMemorySearchReport(
                results: cached,
                candidateCount: cached.count,
                vectorCandidateCount: cached.filter { $0.matchedBy == .vector }.count,
                elapsedMilliseconds: LuminaMemoryClock.milliseconds(since: start),
                cacheHit: true
            )
        }

        let candidates = LuminaMemorySearchFilter.candidates(for: query, in: index.allChunks)
        guard !candidates.isEmpty else {
            return LuminaMemorySearchReport(
                results: [],
                candidateCount: 0,
                vectorCandidateCount: 0,
                elapsedMilliseconds: LuminaMemoryClock.milliseconds(since: start),
                cacheHit: false
            )
        }

        if LuminaSearchTokenizer.tokens(in: query.text).isEmpty {
            let results = candidates
                .sorted { $0.createdAt > $1.createdAt }
                .prefix(max(1, query.limit))
                .map { LuminaMemorySearchResult(chunk: $0, score: 0.05, matchedBy: .metadata) }
            recentSearchCache.remember(results, for: query)
            return LuminaMemorySearchReport(
                results: results,
                candidateCount: candidates.count,
                vectorCandidateCount: 0,
                elapsedMilliseconds: LuminaMemoryClock.milliseconds(since: start),
                cacheHit: false
            )
        }

        let candidateIDs = Set(candidates.map(\.id))
        let candidateLimit = max(query.limit * 8, 40)
        let bm25Results = bm25Index.search(query.text, allowedIDs: candidateIDs, limit: candidateLimit)
        let embeddedCandidates = candidates
            .filter { $0.embedding != nil }
            .prefix(configuration.maximumVectorCandidates)

        var vectorIDs: [UUID] = []
        if !embeddedCandidates.isEmpty {
            do {
                let queryEmbedding = try await embeddingProvider.embed(query.text)
                vectorIDs = embeddedCandidates
                    .map { chunk in
                        (chunk.id, LuminaVectorMath.cosine(queryEmbedding, chunk.embedding ?? []))
                    }
                    .filter { $0.1 > 0 }
                    .sorted {
                        if $0.1 == $1.1 { return $0.0.uuidString < $1.0.uuidString }
                        return $0.1 > $1.1
                    }
                    .prefix(candidateLimit)
                    .map(\.0)
            } catch {
                vectorIDs = []
            }
        }

        let chunksByID = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0) })
        let merged = LuminaMemorySearchRanker.merge(
            bm25Results: bm25Results,
            vectorIDs: vectorIDs,
            chunksByID: chunksByID,
            limit: query.limit
        )
        recentSearchCache.remember(merged, for: query)
        return LuminaMemorySearchReport(
            results: merged,
            candidateCount: candidates.count,
            vectorCandidateCount: embeddedCandidates.count,
            elapsedMilliseconds: LuminaMemoryClock.milliseconds(since: start),
            cacheHit: false
        )
    }

    public func allChunksCount() -> Int {
        index.chunkCount
    }

    public func embeddedChunksCount() -> Int {
        index.embeddedChunkCount
    }

    public func removeDocument(id: UUID) {
        index.removeDocument(id: id)
        rebuildBM25Index()
        recentSearchCache.removeAll(keepingCapacity: true)
        if configuration.persistAfterIngest {
            Task { try? await persist() }
        }
    }

    @discardableResult
    public func removeChunk(id: UUID) -> Bool {
        let removed = index.removeChunk(id: id)
        guard removed else {
            return false
        }
        bm25Index.remove(id: id)
        recentSearchCache.removeAll(keepingCapacity: true)
        if configuration.persistAfterIngest {
            Task { try? await persist() }
        }
        return true
    }

    @discardableResult
    public func removeAll() -> Int {
        let removedCount = index.removeAll()
        guard removedCount > 0 else {
            return 0
        }
        bm25Index.removeAll()
        recentSearchCache.removeAll(keepingCapacity: true)
        if configuration.persistAfterIngest {
            Task { try? await persist() }
        }
        return removedCount
    }

    public func stats() -> LuminaMemoryIndexStats {
        index.stats(cacheEntryCount: recentSearchCache.count)
    }

    public func recentChunks(limit: Int = 10, maximumSensitivity: LuminaMemorySensitivity = .privateData) -> [LuminaMemoryChunk] {
        index.recentChunks(limit: limit, maximumSensitivity: maximumSensitivity)
    }

    public func snapshot() -> LuminaMemorySnapshot {
        index.snapshot()
    }

    private func scheduleEmbedding(for ids: [UUID]) {
        Task(priority: LuminaEmbeddingScheduler.backgroundPriority) { [weak self] in
            await self?.embedMissing(ids: ids)
        }
    }

    private func embedMissing(ids: [UUID]) async {
        for id in ids {
            do {
                try Task.checkCancellation()
                guard let chunk = index.chunk(id: id), chunk.embedding == nil else { continue }
                let embedding = try await embeddingProvider.embed(chunk.text)
                index.updateEmbedding(embedding, for: id)
                if configuration.persistAfterEmbedding {
                    try? await persist()
                }
            } catch {
                return
            }
        }
    }

    private func rebuildBM25Index() {
        bm25Index.rebuild(index.allChunks.map(Self.bm25Document(for:)))
    }

    private static func bm25Document(for chunk: LuminaMemoryChunk) -> LuminaBM25Document<UUID> {
        LuminaBM25Document(
            id: chunk.id,
            title: chunk.title,
            tags: Array(chunk.metadata.values),
            body: chunk.text
        )
    }
}
