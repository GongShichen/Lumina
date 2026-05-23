import Foundation

public actor MemoryStore {
    private var chunks: [UUID: MemoryChunk] = [:]
    private var documentIndex: [UUID: [UUID]] = [:]
    private let chunker: MemoryChunker
    private let embeddingProvider: any EmbeddingProvider
    private let repository: (any MemoryRepository)?
    private let configuration: MemoryStoreConfiguration
    private var recentSearchCache: [String: [MemorySearchResult]] = [:]

    public init(
        chunker: MemoryChunker = MemoryChunker(),
        embeddingProvider: any EmbeddingProvider = HashingEmbeddingProvider(),
        repository: (any MemoryRepository)? = nil,
        configuration: MemoryStoreConfiguration = MemoryStoreConfiguration()
    ) {
        self.chunker = chunker
        self.embeddingProvider = embeddingProvider
        self.repository = repository
        self.configuration = configuration
    }

    public func load() async throws {
        guard let snapshot = try await repository?.load() else { return }
        self.chunks = Dictionary(uniqueKeysWithValues: snapshot.chunks.map { ($0.id, $0) })
        self.documentIndex = snapshot.documentIndex
        self.recentSearchCache.removeAll(keepingCapacity: true)
    }

    public func persist() async throws {
        try await repository?.save(snapshot())
    }

    @discardableResult
    public func ingest(_ document: MemoryDocument) async -> [UUID] {
        let newChunks = chunker.chunks(for: document)
        let ids = newChunks.map(\.id)
        documentIndex[document.id] = ids
        for chunk in newChunks {
            chunks[chunk.id] = chunk
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

    public func search(_ query: MemorySearchQuery) async throws -> [MemorySearchResult] {
        try await searchWithReport(query).results
    }

    public func searchWithReport(_ query: MemorySearchQuery) async throws -> MemorySearchReport {
        let start = ContinuousClock.now
        try Task.checkCancellation()
        let cacheKey = makeCacheKey(query)
        if let cached = recentSearchCache[cacheKey] {
            return MemorySearchReport(
                results: cached,
                candidateCount: cached.count,
                vectorCandidateCount: cached.filter { $0.matchedBy == .vector }.count,
                elapsedMilliseconds: MemoryClock.milliseconds(since: start),
                cacheHit: true
            )
        }

        let candidates = metadataFilteredChunks(for: query)
        guard !candidates.isEmpty else {
            return MemorySearchReport(
                results: [],
                candidateCount: 0,
                vectorCandidateCount: 0,
                elapsedMilliseconds: MemoryClock.milliseconds(since: start),
                cacheHit: false
            )
        }

        let keywordResults = keywordRank(query.text, candidates: candidates)
        let embeddedCandidates = candidates
            .filter { $0.embedding != nil }
            .prefix(configuration.maximumVectorCandidates)

        var vectorResults: [MemorySearchResult] = []
        if !embeddedCandidates.isEmpty {
            let queryEmbedding = try await embeddingProvider.embed(query.text)
            vectorResults = embeddedCandidates.map { chunk in
                MemorySearchResult(
                    chunk: chunk,
                    score: VectorMath.cosine(queryEmbedding, chunk.embedding ?? []),
                    matchedBy: .vector
                )
            }
        }

        let merged = merge(vectorResults: vectorResults, keywordResults: keywordResults, limit: query.limit)
        rememberCache(merged, key: cacheKey)
        return MemorySearchReport(
            results: merged,
            candidateCount: candidates.count,
            vectorCandidateCount: embeddedCandidates.count,
            elapsedMilliseconds: MemoryClock.milliseconds(since: start),
            cacheHit: false
        )
    }

    public func allChunksCount() -> Int {
        chunks.count
    }

    public func embeddedChunksCount() -> Int {
        chunks.values.filter { $0.embedding != nil }.count
    }

    public func removeDocument(id: UUID) {
        let ids = documentIndex[id] ?? []
        for id in ids {
            chunks[id] = nil
        }
        documentIndex[id] = nil
        recentSearchCache.removeAll(keepingCapacity: true)
        if configuration.persistAfterIngest {
            Task { try? await persist() }
        }
    }

    public func stats() -> MemoryIndexStats {
        MemoryIndexStats(
            documentCount: documentIndex.count,
            chunkCount: chunks.count,
            embeddedChunkCount: chunks.values.filter { $0.embedding != nil }.count,
            cacheEntryCount: recentSearchCache.count
        )
    }

    public func snapshot() -> MemorySnapshot {
        MemorySnapshot(chunks: Array(chunks.values), documentIndex: documentIndex)
    }

    private func scheduleEmbedding(for ids: [UUID]) {
        let priority: TaskPriority = ProcessInfo.processInfo.isLowPowerModeEnabled ? .background : .utility
        Task(priority: priority) { [weak self] in
            await self?.embedMissing(ids: ids)
        }
    }

    private func embedMissing(ids: [UUID]) async {
        for id in ids {
            do {
                try Task.checkCancellation()
                guard var chunk = chunks[id], chunk.embedding == nil else { continue }
                chunk.embedding = try await embeddingProvider.embed(chunk.text)
                chunks[id] = chunk
                if configuration.persistAfterEmbedding {
                    try? await persist()
                }
            } catch {
                return
            }
        }
    }

    private func metadataFilteredChunks(for query: MemorySearchQuery) -> [MemoryChunk] {
        chunks.values.lazy.filter { chunk in
            if let sourceKinds = query.sourceKinds, !sourceKinds.contains(chunk.source.kind) {
                return false
            }
            if let since = query.since, chunk.createdAt < since {
                return false
            }
            if let until = query.until, chunk.createdAt > until {
                return false
            }
            if chunk.sensitivity > query.maximumSensitivity {
                return false
            }
            return true
        }.map { $0 }
    }

    private func keywordRank(_ query: String, candidates: [MemoryChunk]) -> [MemorySearchResult] {
        let tokens = Set(query.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
        guard !tokens.isEmpty else {
            return candidates.prefix(10).map { MemorySearchResult(chunk: $0, score: 0.05, matchedBy: .metadata) }
        }

        return candidates.compactMap { chunk in
            let haystack = "\(chunk.title) \(chunk.text) \(chunk.metadata.values.joined(separator: " "))".lowercased()
            let hits = tokens.reduce(0) { count, token in
                haystack.contains(token) ? count + 1 : count
            }
            guard hits > 0 else { return nil }
            return MemorySearchResult(chunk: chunk, score: Float(hits) / Float(tokens.count), matchedBy: .keyword)
        }
    }

    private func merge(
        vectorResults: [MemorySearchResult],
        keywordResults: [MemorySearchResult],
        limit: Int
    ) -> [MemorySearchResult] {
        var bestByChunk: [UUID: MemorySearchResult] = [:]
        for result in vectorResults + keywordResults {
            let current = bestByChunk[result.chunk.id]
            if current == nil || result.score > current!.score {
                bestByChunk[result.chunk.id] = result
            }
        }
        return bestByChunk.values
            .sorted { lhs, rhs in
                if lhs.score == rhs.score {
                    return lhs.chunk.createdAt > rhs.chunk.createdAt
                }
                return lhs.score > rhs.score
            }
            .prefix(max(1, limit))
            .map { $0 }
    }

    private func makeCacheKey(_ query: MemorySearchQuery) -> String {
        let sources = query.sourceKinds?.map(\.rawValue).sorted().joined(separator: ",") ?? "*"
        return [
            query.text,
            String(query.limit),
            sources,
            query.since?.timeIntervalSince1970.description ?? "",
            query.until?.timeIntervalSince1970.description ?? "",
            query.maximumSensitivity.rawValue
        ].joined(separator: "|")
    }

    private func rememberCache(_ results: [MemorySearchResult], key: String) {
        if recentSearchCache.count >= configuration.cacheLimit {
            recentSearchCache.removeValue(forKey: recentSearchCache.keys.sorted().first ?? key)
        }
        recentSearchCache[key] = results
    }
}
