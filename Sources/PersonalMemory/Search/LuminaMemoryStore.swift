import Foundation

public actor LuminaMemoryStore {
    private var index = LuminaMemoryIndex()
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
        self.recentSearchCache.removeAll(keepingCapacity: true)
    }

    public func persist() async throws {
        try await repository?.save(snapshot())
    }

    @discardableResult
    public func ingest(_ document: LuminaMemoryDocument) async -> [UUID] {
        let newChunks = chunker.chunks(for: document)
        let ids = index.ingest(newChunks, documentID: document.id)
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

        let keywordResults = LuminaMemorySearchRanker.keywordRank(query.text, candidates: candidates)
        let embeddedCandidates = candidates
            .filter { $0.embedding != nil }
            .prefix(configuration.maximumVectorCandidates)

        var vectorResults: [LuminaMemorySearchResult] = []
        if !embeddedCandidates.isEmpty {
            let queryEmbedding = try await embeddingProvider.embed(query.text)
            vectorResults = embeddedCandidates.map { chunk in
                LuminaMemorySearchResult(
                    chunk: chunk,
                    score: LuminaVectorMath.cosine(queryEmbedding, chunk.embedding ?? []),
                    matchedBy: .vector
                )
            }
        }

        let merged = LuminaMemorySearchRanker.merge(vectorResults: vectorResults, keywordResults: keywordResults, limit: query.limit)
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
}
