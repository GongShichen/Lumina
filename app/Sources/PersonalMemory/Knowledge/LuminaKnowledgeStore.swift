import Foundation

public actor LuminaKnowledgeStore {
    private struct SearchCacheKey: Hashable, Sendable {
        var query: String
        var baseIDs: [String]
        var limit: Int
        var destination: LuminaKnowledgeSearchDestination
        var includeDisabled: Bool
        var capabilityCategories: [String]
        var enabledBaseIDs: [String]
        var generation: Int
        var tokenizerVersion: Int
        var rankingVersion: Int
    }

    private let embeddingProvider: any LuminaEmbeddingProvider
    private let repository: any LuminaKnowledgeRepository
    private let configuration: LuminaKnowledgeStoreConfiguration
    private let chunker: LuminaKnowledgeChunker
    private var bases: [String: LuminaKnowledgeBaseSnapshot] = [:]
    private var preferences: [String: LuminaKnowledgeBasePreferences] = [:]
    private var bm25Index = LuminaBM25Index<String>()
    private var searchCache: [SearchCacheKey: LuminaKnowledgeSearchReport] = [:]
    private var cacheOrder: [SearchCacheKey] = []
    private var generation = 0
    private var loadingFailures: [String] = []
    private var bundledRootURL: URL?

    public init(
        embeddingProvider: any LuminaEmbeddingProvider = LuminaHashingEmbeddingProvider(),
        repository: any LuminaKnowledgeRepository,
        configuration: LuminaKnowledgeStoreConfiguration = LuminaKnowledgeStoreConfiguration()
    ) {
        self.embeddingProvider = embeddingProvider
        self.repository = repository
        self.configuration = configuration
        self.chunker = LuminaKnowledgeChunker(
            targetCharacters: configuration.targetChunkCharacters,
            overlapCharacters: configuration.overlapCharacters
        )
    }

    public func load(bundledRootURL: URL? = nil) async {
        self.bundledRootURL = bundledRootURL
        loadingFailures.removeAll(keepingCapacity: true)
        var loaded: [String: LuminaKnowledgeBaseSnapshot] = [:]

        do {
            preferences = try await repository.loadPreferences()
        } catch {
            preferences = [:]
            loadingFailures.append("catalog.json: \(error.localizedDescription)")
        }

        do {
            for snapshot in try await repository.loadImportedBases() {
                guard snapshot.schemaVersion == 1 else {
                    loadingFailures.append("\(snapshot.descriptor.id): unsupported schema")
                    continue
                }
                let value = normalized(snapshot)
                if let reason = value.descriptor.failureReason,
                   value.descriptor.indexStatus == .failed {
                    loadingFailures.append("\(value.descriptor.id): \(reason)")
                }
                loaded[value.descriptor.id] = value
            }
        } catch {
            loadingFailures.append("Imported: \(error.localizedDescription)")
        }

        if let bundledRootURL {
            for snapshot in await loadBundledBases(from: bundledRootURL) {
                loaded[snapshot.descriptor.id] = normalized(snapshot)
            }
        }

        bases = loaded
        applyPreferences()
        await restoreBM25Index()
        invalidateSearchState()
        if configuration.scheduleBackgroundEmbedding {
            scheduleMissingEmbeddings()
        }
    }

    public func reload() async {
        await load(bundledRootURL: bundledRootURL)
    }

    public func descriptors(
        destination: LuminaKnowledgeSearchDestination? = nil,
        includeDisabled: Bool = true
    ) -> [LuminaKnowledgeBaseDescriptor] {
        bases.values
            .map(\.descriptor)
            .filter { descriptor in
                (includeDisabled || descriptor.enabled)
                    && (destination != .remote || descriptor.remoteAccess == .allowRemote)
            }
            .sorted {
                if $0.origin != $1.origin { return $0.origin == .bundled }
                return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
    }

    public func descriptor(id: String) -> LuminaKnowledgeBaseDescriptor? {
        bases[id]?.descriptor
    }

    public func documents(knowledgeBaseID: String) -> [LuminaKnowledgeDocument] {
        (bases[knowledgeBaseID]?.documents ?? []).sorted {
            $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
    }

    public func snapshot(knowledgeBaseID: String) -> LuminaKnowledgeBaseSnapshot? {
        bases[knowledgeBaseID]
    }

    public func stats() -> LuminaKnowledgeStats {
        let snapshots = bases.values
        return LuminaKnowledgeStats(
            knowledgeBaseCount: snapshots.count,
            documentCount: snapshots.reduce(0) { $0 + $1.documents.count },
            chunkCount: snapshots.reduce(0) { $0 + $1.chunks.count },
            embeddedChunkCount: snapshots.reduce(0) {
                $0 + $1.chunks.filter { $0.embedding?.count == embeddingProvider.dimension }.count
            }
        )
    }

    public func failures() -> [String] {
        loadingFailures
    }

    @discardableResult
    public func importKnowledgeBase(
        title: String,
        fileURLs: [URL],
        progress: (@Sendable (LuminaKnowledgeImportPhase) -> Void)? = nil
    ) async throws -> LuminaKnowledgeBaseDescriptor {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            throw LuminaKnowledgeImportError.invalidManifest("知识库名称不能为空")
        }
        guard !fileURLs.isEmpty, fileURLs.count <= configuration.maximumDocumentsPerBase else {
            throw LuminaKnowledgeImportError.documentLimit
        }

        progress?(.copying)
        let baseID = UUID().uuidString.lowercased()
        let copiedFiles = try copyFiles(fileURLs)
        try Task.checkCancellation()
        progress?(.extracting)
        let extracted = try extractFiles(copiedFiles)
        let built = try buildDocuments(
            baseID: baseID,
            extracted: extracted,
            existingHashes: [],
            manifestDocuments: nil
        )
        try Task.checkCancellation()
        progress?(.indexingBM25)

        let now = Date()
        let descriptor = LuminaKnowledgeBaseDescriptor(
            id: baseID,
            title: trimmedTitle,
            summary: "\(built.documents.count) 个用户导入文档",
            version: "1",
            origin: .userImported,
            enabled: true,
            remoteAccess: .localOnly,
            indexStatus: .ready,
            documentCount: built.documents.count,
            chunkCount: built.chunks.count,
            embeddedChunkCount: 0,
            createdAt: now,
            updatedAt: now
        )
        let snapshot = LuminaKnowledgeBaseSnapshot(
            descriptor: descriptor,
            documents: built.documents,
            chunks: built.chunks
        )
        try validateEnabledChunkLimit(replacing: nil, with: snapshot)
        try Task.checkCancellation()
        try await repository.saveImportedBase(snapshot, sourceFiles: built.sourceFiles)
        bases[baseID] = snapshot
        preferences[baseID] = LuminaKnowledgeBasePreferences(enabled: true, remoteAccess: .localOnly)
        do {
            try await repository.savePreferences(preferences)
        } catch {
            bases[baseID] = nil
            preferences[baseID] = nil
            try? await repository.removeImportedBase(id: baseID)
            throw error
        }
        rebuildBM25Index()
        invalidateSearchState()
        progress?(.readyForSearch)
        if configuration.scheduleBackgroundEmbedding {
            progress?(.embedding)
            scheduleEmbedding(baseID: baseID)
        }
        progress?(.complete)
        return descriptor
    }

    @discardableResult
    public func addDocuments(
        to knowledgeBaseID: String,
        fileURLs: [URL],
        progress: (@Sendable (LuminaKnowledgeImportPhase) -> Void)? = nil
    ) async throws -> LuminaKnowledgeBaseDescriptor {
        guard var snapshot = bases[knowledgeBaseID] else {
            throw LuminaKnowledgeImportError.baseNotFound
        }
        guard snapshot.descriptor.origin == .userImported else {
            throw LuminaKnowledgeImportError.bundledBaseCannotBeDeleted
        }
        guard snapshot.documents.count + fileURLs.count <= configuration.maximumDocumentsPerBase else {
            throw LuminaKnowledgeImportError.documentLimit
        }

        progress?(.copying)
        let copiedFiles = try copyFiles(fileURLs)
        try Task.checkCancellation()
        progress?(.extracting)
        let extracted = try extractFiles(copiedFiles)
        let built = try buildDocuments(
            baseID: knowledgeBaseID,
            extracted: extracted,
            existingHashes: Set(snapshot.documents.map(\.contentHash)),
            manifestDocuments: nil
        )
        try Task.checkCancellation()
        snapshot.documents.append(contentsOf: built.documents)
        snapshot.chunks.append(contentsOf: built.chunks)
        snapshot.descriptor.documentCount = snapshot.documents.count
        snapshot.descriptor.chunkCount = snapshot.chunks.count
        snapshot.descriptor.updatedAt = Date()
        snapshot.descriptor.indexStatus = .ready
        try validateEnabledChunkLimit(replacing: knowledgeBaseID, with: snapshot)
        try Task.checkCancellation()
        try await repository.saveImportedBase(snapshot, sourceFiles: built.sourceFiles)
        bases[knowledgeBaseID] = snapshot
        rebuildBM25Index()
        invalidateSearchState()
        progress?(.readyForSearch)
        if configuration.scheduleBackgroundEmbedding {
            progress?(.embedding)
            scheduleEmbedding(baseID: knowledgeBaseID)
        }
        progress?(.complete)
        return snapshot.descriptor
    }

    public func setEnabled(_ enabled: Bool, knowledgeBaseID: String) async throws {
        guard var snapshot = bases[knowledgeBaseID] else {
            throw LuminaKnowledgeImportError.baseNotFound
        }
        if enabled {
            var proposed = snapshot
            proposed.descriptor.enabled = true
            try validateEnabledChunkLimit(replacing: knowledgeBaseID, with: proposed)
        }
        snapshot.descriptor.enabled = enabled
        snapshot.descriptor.updatedAt = Date()
        bases[knowledgeBaseID] = snapshot
        preferences[knowledgeBaseID] = LuminaKnowledgeBasePreferences(
            enabled: enabled,
            remoteAccess: snapshot.descriptor.remoteAccess
        )
        try await repository.savePreferences(preferences)
        try await persistSnapshotIfNeeded(snapshot)
        invalidateSearchState()
    }

    public func setRemoteAccess(
        _ access: LuminaKnowledgeRemoteAccess,
        knowledgeBaseID: String
    ) async throws {
        guard var snapshot = bases[knowledgeBaseID] else {
            throw LuminaKnowledgeImportError.baseNotFound
        }
        snapshot.descriptor.remoteAccess = access
        snapshot.descriptor.updatedAt = Date()
        bases[knowledgeBaseID] = snapshot
        preferences[knowledgeBaseID] = LuminaKnowledgeBasePreferences(
            enabled: snapshot.descriptor.enabled,
            remoteAccess: access
        )
        invalidateSearchState()
        var firstError: Error?
        do {
            try await repository.savePreferences(preferences)
        } catch {
            firstError = error
        }
        do {
            try await persistSnapshotIfNeeded(snapshot)
        } catch {
            if firstError == nil { firstError = error }
        }
        if let firstError { throw firstError }
    }

    public func removeDocument(id: String, knowledgeBaseID: String) async throws {
        guard var snapshot = bases[knowledgeBaseID] else {
            throw LuminaKnowledgeImportError.baseNotFound
        }
        guard snapshot.descriptor.origin == .userImported else {
            throw LuminaKnowledgeImportError.bundledBaseCannotBeDeleted
        }
        snapshot.documents.removeAll { $0.id == id }
        snapshot.chunks.removeAll { $0.documentID == id }
        snapshot.descriptor.documentCount = snapshot.documents.count
        snapshot.descriptor.chunkCount = snapshot.chunks.count
        snapshot.descriptor.embeddedChunkCount = snapshot.chunks.filter { $0.embedding != nil }.count
        snapshot.descriptor.updatedAt = Date()
        try await repository.saveImportedBase(snapshot, sourceFiles: [:])
        bases[knowledgeBaseID] = snapshot
        rebuildBM25Index()
        invalidateSearchState()
    }

    public func deleteKnowledgeBase(id: String) async throws {
        guard let snapshot = bases[id] else {
            throw LuminaKnowledgeImportError.baseNotFound
        }
        guard snapshot.descriptor.origin == .userImported else {
            throw LuminaKnowledgeImportError.bundledBaseCannotBeDeleted
        }
        bases[id] = nil
        preferences[id] = nil
        rebuildBM25Index()
        invalidateSearchState()
        try await repository.savePreferences(preferences)
        try await repository.removeImportedBase(id: id)
    }

    public func search(_ query: LuminaKnowledgeSearchQuery) async -> [LuminaKnowledgeSearchResult] {
        await searchWithReport(query).results
    }

    public func searchWithReport(_ query: LuminaKnowledgeSearchQuery) async -> LuminaKnowledgeSearchReport {
        let start = ContinuousClock.now
        let normalizedQuery = LuminaSearchTokenizer.normalizedQuery(query.text)
        guard !normalizedQuery.isEmpty else {
            return LuminaKnowledgeSearchReport(
                results: [],
                candidateCount: 0,
                bm25CandidateCount: 0,
                vectorCandidateCount: 0,
                elapsedMilliseconds: LuminaMemoryClock.milliseconds(since: start),
                cacheHit: false
            )
        }

        let allowedBases = allowedBaseIDs(for: query)
        let key = SearchCacheKey(
            query: normalizedQuery,
            baseIDs: (query.knowledgeBaseIDs ?? []).sorted(),
            limit: min(max(query.limit, 1), 100),
            destination: query.destination,
            includeDisabled: query.includeDisabled,
            capabilityCategories: (query.availableCapabilityCategories ?? []).sorted(),
            enabledBaseIDs: allowedBases.sorted(),
            generation: generation,
            tokenizerVersion: LuminaBM25Index<String>.tokenizerVersion,
            rankingVersion: 1
        )
        if var cached = searchCache[key] {
            cached.cacheHit = true
            cached.elapsedMilliseconds = LuminaMemoryClock.milliseconds(since: start)
            return cached
        }

        let chunks = bases.values
            .filter { allowedBases.contains($0.descriptor.id) }
            .flatMap { snapshot -> [LuminaKnowledgeChunk] in
                guard let capabilities = query.availableCapabilityCategories else {
                    return snapshot.chunks
                }
                let allowedDocumentIDs = Set(snapshot.documents.compactMap { document in
                    let required = Set(document.capabilityCategories)
                    return required.isEmpty || required.isSubset(of: capabilities)
                        ? document.id
                        : nil
                })
                return snapshot.chunks.filter { allowedDocumentIDs.contains($0.documentID) }
            }
        let chunksByID = Dictionary(uniqueKeysWithValues: chunks.map { ($0.id, $0) })
        let allowedChunkIDs = Set(chunksByID.keys)
        guard !allowedChunkIDs.isEmpty else {
            return LuminaKnowledgeSearchReport(
                results: [],
                candidateCount: 0,
                bm25CandidateCount: 0,
                vectorCandidateCount: 0,
                elapsedMilliseconds: LuminaMemoryClock.milliseconds(since: start),
                cacheHit: false
            )
        }

        let limit = min(max(query.limit, 1), 100)
        let candidateLimit = max(limit * 8, 40)
        let bm25Hits = bm25Index.search(
            query.text,
            allowedIDs: allowedChunkIDs,
            limit: candidateLimit
        )
        let embedded = chunks.filter { $0.embedding?.count == embeddingProvider.dimension }
        var vectorIDs: [String] = []
        var fallbackReason: String?
        if !embedded.isEmpty {
            do {
                let queryEmbedding = try await embeddingProvider.embed(query.text)
                vectorIDs = embedded
                    .compactMap { chunk -> (String, Float)? in
                        guard let value = chunk.embedding else { return nil }
                        return (chunk.id, LuminaVectorMath.cosine(queryEmbedding, value))
                    }
                    .filter { $0.1 > 0 }
                    .sorted {
                        if $0.1 == $1.1 { return $0.0 < $1.0 }
                        return $0.1 > $1.1
                    }
                    .prefix(candidateLimit)
                    .map(\.0)
            } catch {
                fallbackReason = "vector_unavailable: \(error.localizedDescription)"
            }
        } else {
            fallbackReason = "embeddings_not_ready"
        }

        let fused = LuminaReciprocalRankFusion.merge(
            bm25IDs: bm25Hits.map(\.id),
            vectorIDs: vectorIDs,
            limit: limit
        )
        let results = fused.compactMap { hit -> LuminaKnowledgeSearchResult? in
            guard let chunk = chunksByID[hit.id] else { return nil }
            let matchedBy: LuminaKnowledgeMatchKind
            if hit.bm25Rank != nil && hit.vectorRank != nil {
                matchedBy = .hybrid
            } else if hit.bm25Rank != nil {
                matchedBy = .bm25
            } else {
                matchedBy = .vector
            }
            return LuminaKnowledgeSearchResult(
                chunk: chunk,
                score: hit.score,
                matchedBy: matchedBy,
                bm25Rank: hit.bm25Rank,
                vectorRank: hit.vectorRank
            )
        }
        let report = LuminaKnowledgeSearchReport(
            results: results,
            candidateCount: chunks.count,
            bm25CandidateCount: bm25Hits.count,
            vectorCandidateCount: vectorIDs.count,
            elapsedMilliseconds: LuminaMemoryClock.milliseconds(since: start),
            cacheHit: false,
            fallbackReason: fallbackReason
        )
        remember(report, for: key)
        return report
    }

    public func chunk(
        id: String,
        expectedContentHash: String? = nil,
        destination: LuminaKnowledgeSearchDestination
    ) -> LuminaKnowledgeChunk? {
        guard let snapshot = bases.values.first(where: { value in
            value.chunks.contains(where: { $0.id == id })
        }), isAllowed(snapshot.descriptor, destination: destination, includeDisabled: false),
        let chunk = snapshot.chunks.first(where: { $0.id == id }),
        expectedContentHash == nil || expectedContentHash == chunk.contentHash
        else { return nil }
        return chunk
    }

    public func adjacentChunks(
        to chunkID: String,
        before: Int,
        after: Int,
        excluding loadedIDs: Set<String>,
        destination: LuminaKnowledgeSearchDestination
    ) -> [LuminaKnowledgeChunk] {
        guard let snapshot = bases.values.first(where: {
            $0.chunks.contains(where: { $0.id == chunkID })
        }), isAllowed(snapshot.descriptor, destination: destination, includeDisabled: false),
        let current = snapshot.chunks.first(where: { $0.id == chunkID })
        else { return [] }
        let documentChunks = snapshot.chunks
            .filter { $0.documentID == current.documentID }
            .sorted {
                if $0.ordinal == $1.ordinal { return $0.id < $1.id }
                return $0.ordinal < $1.ordinal
            }
        guard let index = documentChunks.firstIndex(where: { $0.id == current.id }) else { return [] }
        let lower = max(0, index - max(0, before))
        let upper = min(documentChunks.count, index + max(0, after) + 1)
        return documentChunks[lower..<upper].filter {
            $0.id != current.id && !loadedIDs.contains($0.id)
        }
    }

    public func invalidateCaches(knowledgeBaseID: String? = nil) {
        if knowledgeBaseID == nil || bases[knowledgeBaseID!] != nil {
            invalidateSearchState()
        }
    }

    private func copyFiles(_ fileURLs: [URL]) throws -> [(fileName: String, data: Data)] {
        try fileURLs.map { url in
            try Task.checkCancellation()
            let accessed = url.startAccessingSecurityScopedResource()
            defer {
                if accessed { url.stopAccessingSecurityScopedResource() }
            }
            if let fileSize = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
               fileSize > configuration.maximumFileBytes {
                throw LuminaKnowledgeImportError.fileTooLarge(url.lastPathComponent)
            }
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            guard data.count <= configuration.maximumFileBytes else {
                throw LuminaKnowledgeImportError.fileTooLarge(url.lastPathComponent)
            }
            return (url.lastPathComponent, data)
        }
    }

    private func extractFiles(
        _ copiedFiles: [(fileName: String, data: Data)]
    ) throws -> [LuminaExtractedKnowledgeDocument] {
        try copiedFiles.map { file in
            try Task.checkCancellation()
            return try LuminaKnowledgeTextExtractor.extract(
                data: file.data,
                fileName: file.fileName,
                configuration: configuration
            )
        }
    }

    private func buildDocuments(
        baseID: String,
        extracted: [LuminaExtractedKnowledgeDocument],
        existingHashes: Set<String>,
        manifestDocuments: [LuminaKnowledgeBundledManifest.Document]?
    ) throws -> (
        documents: [LuminaKnowledgeDocument],
        chunks: [LuminaKnowledgeChunk],
        sourceFiles: [String: Data]
    ) {
        var hashes = existingHashes
        var documents: [LuminaKnowledgeDocument] = []
        var chunks: [LuminaKnowledgeChunk] = []
        var sourceFiles: [String: Data] = [:]
        for (index, value) in extracted.enumerated() {
            try Task.checkCancellation()
            let contentHash = LuminaKnowledgeStableHash.data(value.data)
            guard hashes.insert(contentHash).inserted else { continue }
            let manifestDocument = manifestDocuments?[index]
            let documentID = manifestDocument?.id
                ?? "document-\(LuminaKnowledgeStableHash.string("\(baseID)|\(contentHash)"))"
            let fileExtension = URL(fileURLWithPath: value.fileName).pathExtension.lowercased()
            let storedFileName = "\(documentID).\(fileExtension)"
            let importedTags = value.metadata["tags"]?
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty } ?? []
            let document = LuminaKnowledgeDocument(
                id: documentID,
                knowledgeBaseID: baseID,
                title: manifestDocument?.title ?? value.title,
                fileName: value.fileName,
                storedFileName: storedFileName,
                mediaType: value.mediaType,
                contentHash: contentHash,
                tags: manifestDocument?.tags ?? importedTags,
                capabilityCategories: manifestDocument?.capabilityCategories ?? [],
                pageCount: value.pageCount,
                characterCount: value.characterCount,
                importStatus: .complete,
                metadata: value.metadata
            )
            documents.append(document)
            chunks.append(contentsOf: chunker.chunks(extracted: value, document: document))
            sourceFiles[storedFileName] = value.data
        }
        return (documents, chunks, sourceFiles)
    }

    private func loadBundledBases(from rootURL: URL) async -> [LuminaKnowledgeBaseSnapshot] {
        guard let baseURLs = try? FileManager.default.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var loaded: [LuminaKnowledgeBaseSnapshot] = []
        for baseURL in baseURLs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            do {
                let manifestURL = baseURL.appendingPathComponent("manifest.json")
                let decoder = JSONDecoder()
                let manifest = try decoder.decode(
                    LuminaKnowledgeBundledManifest.self,
                    from: Data(contentsOf: manifestURL)
                )
                try validate(manifest: manifest, baseURL: baseURL)
                if var cached = try await repository.loadBundledCache(
                    id: manifest.id,
                    version: manifest.version
                ) {
                    cached.descriptor.enabled = manifest.defaultEnabled
                    cached.descriptor.remoteAccess = manifest.remoteAccess
                    loaded.append(cached)
                    continue
                }

                var extracted: [LuminaExtractedKnowledgeDocument] = []
                for document in manifest.documents {
                    let fileURL = baseURL.appendingPathComponent(document.path)
                    let standardizedBase = baseURL.standardizedFileURL.path + "/"
                    guard fileURL.standardizedFileURL.path.hasPrefix(standardizedBase),
                          FileManager.default.fileExists(atPath: fileURL.path)
                    else {
                        throw LuminaKnowledgeImportError.bundledDocumentMissing(document.path)
                    }
                    extracted.append(try LuminaKnowledgeTextExtractor.extract(
                        url: fileURL,
                        configuration: configuration
                    ))
                }
                let built = try buildDocuments(
                    baseID: manifest.id,
                    extracted: extracted,
                    existingHashes: [],
                    manifestDocuments: manifest.documents
                )
                let now = Date()
                let descriptor = LuminaKnowledgeBaseDescriptor(
                    id: manifest.id,
                    title: manifest.title,
                    summary: manifest.summary,
                    version: manifest.version,
                    origin: .bundled,
                    enabled: manifest.defaultEnabled,
                    remoteAccess: manifest.remoteAccess,
                    indexStatus: .ready,
                    documentCount: built.documents.count,
                    chunkCount: built.chunks.count,
                    embeddedChunkCount: 0,
                    createdAt: now,
                    updatedAt: now
                )
                let snapshot = LuminaKnowledgeBaseSnapshot(
                    descriptor: descriptor,
                    documents: built.documents,
                    chunks: built.chunks
                )
                try? await repository.saveBundledCache(snapshot)
                loaded.append(snapshot)
            } catch {
                let id = baseURL.lastPathComponent
                loadingFailures.append("\(id): \(error.localizedDescription)")
                loaded.append(LuminaKnowledgeBaseSnapshot(
                    descriptor: LuminaKnowledgeBaseDescriptor(
                        id: id,
                        title: id,
                        summary: "内置知识库加载失败",
                        version: "unknown",
                        origin: .bundled,
                        enabled: false,
                        remoteAccess: .allowRemote,
                        indexStatus: .failed,
                        failureReason: error.localizedDescription
                    ),
                    documents: [],
                    chunks: []
                ))
            }
        }
        return loaded
    }

    private func normalized(_ input: LuminaKnowledgeBaseSnapshot) -> LuminaKnowledgeBaseSnapshot {
        var snapshot = input
        for index in snapshot.chunks.indices {
            if let embedding = snapshot.chunks[index].embedding,
               embedding.count != embeddingProvider.dimension {
                snapshot.chunks[index].embedding = nil
            }
        }
        snapshot.descriptor.documentCount = snapshot.documents.count
        snapshot.descriptor.chunkCount = snapshot.chunks.count
        snapshot.descriptor.embeddedChunkCount = snapshot.chunks.filter {
            $0.embedding?.count == embeddingProvider.dimension
        }.count
        if snapshot.descriptor.indexStatus != .failed {
            snapshot.descriptor.indexStatus = .ready
        }
        return snapshot
    }

    private func applyPreferences() {
        for id in bases.keys {
            guard var snapshot = bases[id] else { continue }
            if let preference = preferences[id] {
                snapshot.descriptor.enabled = preference.enabled
                if snapshot.descriptor.origin == .userImported {
                    snapshot.descriptor.remoteAccess =
                        snapshot.descriptor.remoteAccess == .allowRemote
                            && preference.remoteAccess == .allowRemote
                        ? .allowRemote
                        : .localOnly
                } else {
                    snapshot.descriptor.remoteAccess = preference.remoteAccess
                }
            } else if snapshot.descriptor.origin == .userImported {
                snapshot.descriptor.remoteAccess = .localOnly
            }
            bases[id] = snapshot
        }
    }

    private func validate(
        manifest: LuminaKnowledgeBundledManifest,
        baseURL: URL
    ) throws {
        guard manifest.schemaVersion == 1 else {
            throw LuminaKnowledgeImportError.invalidManifest(
                "\(baseURL.lastPathComponent) schema \(manifest.schemaVersion)"
            )
        }
        guard manifest.id == baseURL.lastPathComponent,
              !manifest.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !manifest.version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !manifest.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !manifest.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !manifest.documents.isEmpty,
              Set(manifest.documents.map(\.id)).count == manifest.documents.count,
              Set(manifest.documents.map(\.path)).count == manifest.documents.count,
              manifest.documents.allSatisfy({
                  !$0.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      && !$0.path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      && !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              })
        else {
            throw LuminaKnowledgeImportError.invalidManifest(
                "\(baseURL.lastPathComponent) ID/必填字段无效，或包含重复文档"
            )
        }
    }

    private func allowedBaseIDs(for query: LuminaKnowledgeSearchQuery) -> Set<String> {
        Set(bases.values.compactMap { snapshot in
            let descriptor = snapshot.descriptor
            guard isAllowed(
                descriptor,
                destination: query.destination,
                includeDisabled: query.includeDisabled
            ), query.knowledgeBaseIDs?.contains(descriptor.id) != false else {
                return nil
            }
            return descriptor.id
        })
    }

    private func isAllowed(
        _ descriptor: LuminaKnowledgeBaseDescriptor,
        destination: LuminaKnowledgeSearchDestination,
        includeDisabled: Bool
    ) -> Bool {
        guard descriptor.indexStatus == .ready,
              includeDisabled || descriptor.enabled
        else { return false }
        return destination == .local || descriptor.remoteAccess == .allowRemote
    }

    private func validateEnabledChunkLimit(
        replacing baseID: String?,
        with proposed: LuminaKnowledgeBaseSnapshot
    ) throws {
        let existingCount = bases.values.reduce(0) { partial, snapshot in
            guard snapshot.descriptor.enabled, snapshot.descriptor.id != baseID else { return partial }
            return partial + snapshot.chunks.count
        }
        let proposedCount = proposed.descriptor.enabled ? proposed.chunks.count : 0
        guard existingCount + proposedCount <= configuration.maximumEnabledChunks else {
            throw LuminaKnowledgeImportError.chunkLimit
        }
    }

    private func rebuildBM25Index() {
        bm25Index.rebuild(bases.values.flatMap(\.chunks).map(LuminaKnowledgeBM25Document.make))
    }

    private func restoreBM25Index() async {
        var restored = LuminaBM25Index<String>()
        for snapshot in bases.values.sorted(by: { $0.descriptor.id < $1.descriptor.id }) {
            do {
                guard let data = try await repository.loadBM25CacheData(for: snapshot),
                      let cache = try? PropertyListDecoder().decode(
                        LuminaBM25IndexCache.self,
                        from: data
                      ),
                      restored.merge(
                        cache: cache,
                        expectedGeneration: LuminaKnowledgeIndexGeneration.value(for: snapshot),
                        expectedDocumentIDs: Set(snapshot.chunks.map(\.id))
                      )
                else {
                    rebuildBM25Index()
                    return
                }
            } catch {
                rebuildBM25Index()
                return
            }
        }
        bm25Index = restored
    }

    private func invalidateSearchState() {
        generation &+= 1
        searchCache.removeAll(keepingCapacity: true)
        cacheOrder.removeAll(keepingCapacity: true)
    }

    private func remember(_ report: LuminaKnowledgeSearchReport, for key: SearchCacheKey) {
        searchCache[key] = report
        cacheOrder.removeAll { $0 == key }
        cacheOrder.append(key)
        while cacheOrder.count > max(1, configuration.cacheLimit) {
            searchCache[cacheOrder.removeFirst()] = nil
        }
    }

    private func scheduleMissingEmbeddings() {
        for snapshot in bases.values where snapshot.chunks.contains(where: { $0.embedding == nil }) {
            scheduleEmbedding(baseID: snapshot.descriptor.id)
        }
    }

    private func scheduleEmbedding(baseID: String) {
        Task(priority: LuminaEmbeddingScheduler.backgroundPriority) { [weak self] in
            await self?.embedMissing(baseID: baseID)
        }
    }

    private func embedMissing(baseID: String) async {
        guard var snapshot = bases[baseID] else { return }
        snapshot.descriptor.indexStatus = .ready
        for index in snapshot.chunks.indices {
            guard snapshot.chunks[index].embedding == nil else { continue }
            do {
                try Task.checkCancellation()
                snapshot.chunks[index].embedding = try await embeddingProvider.embed(snapshot.chunks[index].text)
            } catch {
                snapshot.descriptor.failureReason = "Embedding degraded: \(error.localizedDescription)"
                break
            }
        }
        snapshot.descriptor.embeddedChunkCount = snapshot.chunks.filter {
            $0.embedding?.count == embeddingProvider.dimension
        }.count
        snapshot.descriptor.updatedAt = Date()
        bases[baseID] = snapshot
        invalidateSearchState()
        guard configuration.persistAfterEmbedding else { return }
        try? await persistSnapshotIfNeeded(snapshot)
    }

    private func persistSnapshotIfNeeded(_ snapshot: LuminaKnowledgeBaseSnapshot) async throws {
        if snapshot.descriptor.origin == .bundled {
            try await repository.saveBundledCache(snapshot)
        } else {
            try await repository.saveImportedBase(snapshot, sourceFiles: [:])
        }
    }
}
