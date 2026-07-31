import XCTest
@testable import PersonalMemory
#if canImport(AppKit) && canImport(PDFKit)
import AppKit
import PDFKit
#endif

final class PersonalMemoryTests: XCTestCase {
    func testLegacyKeywordMatchKindStillDecodes() throws {
        let decoded = try JSONDecoder().decode(
            LuminaMemoryMatchKind.self,
            from: Data(#""keyword""#.utf8)
        )

        XCTAssertEqual(decoded, .keyword)
    }

    func testSearchTokenizerIsDeterministicAcrossUnicodeCaseNumbersAndCJK() {
        let composed = LuminaSearchTokenizer.tokens(in: "CAFÉ 2026 退款条款")
        let decomposed = LuminaSearchTokenizer.tokens(in: "cafe\u{301} 2026 退款条款")

        XCTAssertEqual(composed, decomposed)
        XCTAssertEqual(composed, ["café", "2026", "退", "款", "退款", "条", "款条", "款", "条款"])
        XCTAssertEqual(LuminaSearchTokenizer.tokens(in: "退款"), ["退", "款", "退款"])
    }

    func testBM25RewardsRareTermsAndWeightedTitleFields() throws {
        var index = LuminaBM25Index<String>()
        index.rebuild([
            LuminaBM25Document(id: "title", title: "Refund", tags: [], body: "policy details"),
            LuminaBM25Document(id: "body", title: "Policy", tags: [], body: "refund details"),
            LuminaBM25Document(id: "common", title: "Policy", tags: [], body: "details common")
        ])

        let weighted = index.search("refund", limit: 3)
        XCTAssertEqual(weighted.map(\.id).prefix(2), ["title", "body"])

        let commonScore = try XCTUnwrap(index.search("policy", limit: 3).first { $0.id == "title" }?.score)
        var rarityIndex = index
        rarityIndex.upsert(LuminaBM25Document(
            id: "title",
            title: "Refund",
            tags: [],
            body: "policy details raretoken"
        ))
        let rareScore = try XCTUnwrap(rarityIndex.search("raretoken", limit: 3).first?.score)
        XCTAssertGreaterThan(rareScore, commonScore)

        rarityIndex.remove(id: "title")
        XCTAssertFalse(rarityIndex.search("raretoken", limit: 3).contains { $0.id == "title" })
    }

    func testBM25FilteredCorpusDoesNotUseHiddenDocumentStatistics() throws {
        var combined = LuminaBM25Index<String>()
        combined.rebuild([
            LuminaBM25Document(id: "visible", title: "", tags: [], body: "refund"),
            LuminaBM25Document(id: "hidden-1", title: "", tags: [], body: "refund"),
            LuminaBM25Document(id: "hidden-2", title: "", tags: [], body: "refund")
        ])
        var isolated = LuminaBM25Index<String>()
        isolated.rebuild([
            LuminaBM25Document(id: "visible", title: "", tags: [], body: "refund")
        ])

        let filteredScore = try XCTUnwrap(
            combined.search("refund", allowedIDs: ["visible"], limit: 1).first?.score
        )
        let isolatedScore = try XCTUnwrap(isolated.search("refund", limit: 1).first?.score)
        XCTAssertEqual(filteredScore, isolatedScore, accuracy: 0.000_001)
    }

    func testRRFProducesStableHybridOrderingWithoutComparingRawScores() {
        let first = LuminaReciprocalRankFusion.merge(
            bm25IDs: ["a", "b", "c"],
            vectorIDs: ["c", "b", "d"],
            limit: 4
        )
        let second = LuminaReciprocalRankFusion.merge(
            bm25IDs: ["a", "b", "c"],
            vectorIDs: ["c", "b", "d"],
            limit: 4
        )

        XCTAssertEqual(first.map(\.id), second.map(\.id))
        XCTAssertEqual(first.first?.id, "c")
        XCTAssertEqual(first.first?.bm25Rank, 3)
        XCTAssertEqual(first.first?.vectorRank, 1)
        XCTAssertEqual(Set(first.map(\.id)).count, first.count)
    }

    func testIngestMakesDocumentSearchableBeforeEmbeddingCompletes() async throws {
        let store = LuminaMemoryStore()
        await store.ingest(LuminaMemoryDocument(
            source: LuminaMemorySource(kind: .appNote, identifier: "note-1"),
            title: "Coffee",
            body: "今天在楼下买了一杯咖啡，花了 42 元。",
            sensitivity: .normal
        ))

        let results = try await store.search(LuminaMemorySearchQuery(text: "咖啡", limit: 3))
        XCTAssertFalse(results.isEmpty)
        XCTAssertEqual(results.first?.matchedBy, .bm25)
    }

    func testMetadataFilterLimitsSourceKind() async throws {
        let store = LuminaMemoryStore()
        await store.ingest(LuminaMemoryDocument(
            source: LuminaMemorySource(kind: .ledger, identifier: "ledger-1"),
            title: "Expense",
            body: "咖啡 42 元",
            sensitivity: .normal
        ))
        await store.ingest(LuminaMemoryDocument(
            source: LuminaMemorySource(kind: .calendar, identifier: "calendar-1"),
            title: "Meeting",
            body: "下午三点产品会议",
            sensitivity: .normal
        ))

        let results = try await store.search(LuminaMemorySearchQuery(text: "咖啡", sourceKinds: [.calendar]))
        XCTAssertTrue(results.isEmpty)
    }

    func testSensitivityFilterHidesPrivateData() async throws {
        let store = LuminaMemoryStore()
        await store.ingest(LuminaMemoryDocument(
            source: LuminaMemorySource(kind: .appNote, identifier: "private"),
            title: "Private",
            body: "非常私密的信息",
            sensitivity: .privateData
        ))

        let results = try await store.search(LuminaMemorySearchQuery(text: "私密", maximumSensitivity: .normal))
        XCTAssertTrue(results.isEmpty)
    }

    func testRecentChunksReturnsRealStoredMemoryOnly() async throws {
        let store = LuminaMemoryStore()
        await store.ingest(LuminaMemoryDocument(
            source: LuminaMemorySource(kind: .appNote, identifier: "older"),
            title: "Older note",
            body: "第一条真实记忆",
            createdAt: Date(timeIntervalSince1970: 100),
            sensitivity: .normal
        ))
        await store.ingest(LuminaMemoryDocument(
            source: LuminaMemorySource(kind: .ledger, identifier: "newer"),
            title: "Newer ledger",
            body: "第二条真实记忆",
            createdAt: Date(timeIntervalSince1970: 200),
            sensitivity: .normal
        ))

        let recent = await store.recentChunks(limit: 1)

        XCTAssertEqual(recent.count, 1)
        XCTAssertEqual(recent.first?.source.identifier, "newer")
    }

    func testRemoveChunkDeletesSingleStoredMemory() async throws {
        let store = LuminaMemoryStore()
        let firstIDs = await store.ingest(LuminaMemoryDocument(
            source: LuminaMemorySource(kind: .appNote, identifier: "first"),
            title: "First memory",
            body: "第一条可删除记忆",
            sensitivity: .normal
        ))
        await store.ingest(LuminaMemoryDocument(
            source: LuminaMemorySource(kind: .appNote, identifier: "second"),
            title: "Second memory",
            body: "第二条需要保留的记忆",
            sensitivity: .normal
        ))

        let removed = await store.removeChunk(id: try XCTUnwrap(firstIDs.first))
        let searchRemoved = try await store.search(LuminaMemorySearchQuery(text: "可删除", limit: 3))
        let searchRemaining = try await store.search(LuminaMemorySearchQuery(text: "保留", limit: 3))
        let stats = await store.stats()

        XCTAssertTrue(removed)
        XCTAssertTrue(searchRemoved.isEmpty)
        XCTAssertEqual(searchRemaining.count, 1)
        XCTAssertEqual(stats.documentCount, 1)
        XCTAssertEqual(stats.chunkCount, 1)
    }

    func testRemoveAllClearsMemoryIndex() async throws {
        let store = LuminaMemoryStore()
        await store.ingest(LuminaMemoryDocument(
            source: LuminaMemorySource(kind: .appNote, identifier: "first"),
            title: "First memory",
            body: "第一条记忆",
            sensitivity: .normal
        ))
        await store.ingest(LuminaMemoryDocument(
            source: LuminaMemorySource(kind: .ledger, identifier: "second"),
            title: "Second memory",
            body: "第二条记忆",
            sensitivity: .normal
        ))

        let removedCount = await store.removeAll()
        let stats = await store.stats()
        let recent = await store.recentChunks(limit: 10)

        XCTAssertEqual(removedCount, 2)
        XCTAssertEqual(stats.documentCount, 0)
        XCTAssertEqual(stats.chunkCount, 0)
        XCTAssertTrue(recent.isEmpty)
    }

    func testDeletionPersistsThroughRepositoryRoundTrip() async throws {
        let repository = LuminaInMemoryMemoryRepository()
        let store = LuminaMemoryStore(repository: repository)
        let ids = await store.ingest(LuminaMemoryDocument(
            source: LuminaMemorySource(kind: .appNote, identifier: "persisted"),
            title: "Persisted",
            body: "本地持久化索引中的记忆",
            sensitivity: .normal
        ))
        _ = await store.removeChunk(id: try XCTUnwrap(ids.first))
        try await store.persist()

        let restored = LuminaMemoryStore(repository: repository)
        try await restored.load()
        let stats = await restored.stats()

        XCTAssertEqual(stats.documentCount, 0)
        XCTAssertEqual(stats.chunkCount, 0)
    }

    func testHashingEmbeddingProducesStableDimension() async throws {
        let provider = LuminaHashingEmbeddingProvider(dimension: 32)
        let embedding = try await provider.embed("local agent runtime")
        XCTAssertEqual(embedding.count, 32)
        XCTAssertGreaterThan(LuminaVectorMath.cosine(embedding, embedding), 0.99)
    }

    func testSearchPerformanceForOneThousandChunks() async throws {
        let store = LuminaMemoryStore()
        for index in 0..<1_000 {
            await store.ingest(LuminaMemoryDocument(
                source: LuminaMemorySource(kind: .appNote, identifier: "note-\(index)"),
                title: "Note \(index)",
                body: "这是第 \(index) 条本地记忆，用于测试端侧检索性能。关键词 coffee-\(index % 10)。",
                sensitivity: .normal
            ))
        }

        let start = ContinuousClock.now
        let results = try await store.search(LuminaMemorySearchQuery(text: "coffee-7", limit: 5))
        let elapsed = start.duration(to: .now)

        XCTAssertFalse(results.isEmpty)
        XCTAssertLessThan(elapsed.components.seconds, 1)
    }

    func testRepositoryRoundTrip() async throws {
        let repository = LuminaInMemoryMemoryRepository()
        let store = LuminaMemoryStore(repository: repository)
        await store.ingest(LuminaMemoryDocument(
            source: LuminaMemorySource(kind: .appNote, identifier: "persisted"),
            title: "Persisted",
            body: "本地持久化索引",
            sensitivity: .normal
        ))
        try await store.persist()

        let restored = LuminaMemoryStore(repository: repository)
        try await restored.load()
        let stats = await restored.stats()

        XCTAssertEqual(stats.documentCount, 1)
        XCTAssertEqual(stats.chunkCount, 1)
    }

    func testSearchReportIncludesMetrics() async throws {
        let store = LuminaMemoryStore()
        await store.ingest(LuminaMemoryDocument(
            source: LuminaMemorySource(kind: .appNote, identifier: "metrics"),
            title: "Metrics",
            body: "性能指标和候选数量",
            sensitivity: .normal
        ))

        let report = try await store.searchWithReport(LuminaMemorySearchQuery(text: "性能", limit: 1))

        XCTAssertEqual(report.candidateCount, 1)
        XCTAssertGreaterThanOrEqual(report.elapsedMilliseconds, 0)
        XCTAssertFalse(report.cacheHit)
    }

    func testKnowledgeImportIsSearchableBeforeEmbeddingAndRemoteAccessIsFailClosed() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("refund.md")
        try Data(
            """
            ---
            category: policy
            ---
            # Refund terms
            Customers may request a lunar-refund within fourteen days.
            """.utf8
        ).write(to: source)
        let repository = LuminaFileKnowledgeRepository(
            rootURL: root.appendingPathComponent("repository", isDirectory: true)
        )
        let store = LuminaKnowledgeStore(
            repository: repository,
            configuration: LuminaKnowledgeStoreConfiguration(scheduleBackgroundEmbedding: false)
        )

        let descriptor = try await store.importKnowledgeBase(
            title: "Imported policy",
            fileURLs: [source]
        )
        let snapshotValue = await store.snapshot(knowledgeBaseID: descriptor.id)
        let importedSnapshot = try XCTUnwrap(snapshotValue)
        let local = await store.searchWithReport(LuminaKnowledgeSearchQuery(
            text: "lunar-refund",
            destination: .local
        ))
        let localCached = await store.searchWithReport(LuminaKnowledgeSearchQuery(
            text: "lunar-refund",
            destination: .local
        ))
        let remote = await store.searchWithReport(LuminaKnowledgeSearchQuery(
            text: "lunar-refund",
            destination: .remote
        ))

        XCTAssertEqual(local.results.first?.matchedBy, .bm25)
        XCTAssertEqual(local.results.first?.citation, "refund.md · Refund terms")
        XCTAssertEqual(importedSnapshot.documents.first?.metadata["category"], "policy")
        XCTAssertFalse(importedSnapshot.chunks.first?.text.contains("category: policy") == true)
        XCTAssertFalse(local.cacheHit)
        XCTAssertTrue(localCached.cacheHit)
        XCTAssertTrue(remote.results.isEmpty)
        XCTAssertFalse(remote.cacheHit)
        let remoteDescriptors = await store.descriptors(
            destination: .remote,
            includeDisabled: false
        )
        XCTAssertEqual(remoteDescriptors.count, 0)

        try await store.setRemoteAccess(.allowRemote, knowledgeBaseID: descriptor.id)
        let authorizedRemote = await store.searchWithReport(LuminaKnowledgeSearchQuery(
            text: "lunar-refund",
            destination: .remote
        ))
        XCTAssertEqual(authorizedRemote.results.first?.chunk.knowledgeBaseID, descriptor.id)
        XCTAssertFalse(authorizedRemote.cacheHit)

        try await store.setRemoteAccess(.localOnly, knowledgeBaseID: descriptor.id)
        let hiddenAgain = await store.search(LuminaKnowledgeSearchQuery(
            text: "lunar-refund",
            destination: .remote
        ))
        XCTAssertTrue(hiddenAgain.isEmpty)
    }

    func testKnowledgeDuplicateImportAndRepositoryRoundTripWithCacheRepair() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("policy.txt")
        try Data("唯一退款条款：火星订单支持七天退款。".utf8).write(to: source)
        let repositoryRoot = root.appendingPathComponent("repository", isDirectory: true)
        let repository = LuminaFileKnowledgeRepository(rootURL: repositoryRoot)
        let configuration = LuminaKnowledgeStoreConfiguration(scheduleBackgroundEmbedding: false)
        let store = LuminaKnowledgeStore(repository: repository, configuration: configuration)

        let descriptor = try await store.importKnowledgeBase(title: "Policy", fileURLs: [source])
        _ = try await store.addDocuments(to: descriptor.id, fileURLs: [source])
        let storedSnapshot = await store.snapshot(knowledgeBaseID: descriptor.id)
        let snapshot = try XCTUnwrap(storedSnapshot)
        XCTAssertEqual(snapshot.documents.count, 1)

        let cacheURL = repositoryRoot
            .appendingPathComponent("Imported", isDirectory: true)
            .appendingPathComponent(descriptor.id, isDirectory: true)
            .appendingPathComponent("bm25-index-v1.plist")
        try Data("corrupt".utf8).write(to: cacheURL, options: .atomic)

        let restored = LuminaKnowledgeStore(repository: repository, configuration: configuration)
        await restored.load()
        let results = await restored.search(LuminaKnowledgeSearchQuery(text: "火星订单"))
        XCTAssertEqual(results.first?.chunk.knowledgeBaseID, descriptor.id)

        let repairedData = try Data(contentsOf: cacheURL)
        XCTAssertNoThrow(
            try PropertyListSerialization.propertyList(
                from: repairedData,
                options: [],
                format: nil
            )
        )
    }

    func testKnowledgeEmbeddingFailureFallsBackToBM25() async throws {
        let baseID = "failing-vector-base"
        let document = LuminaKnowledgeDocument(
            id: "doc",
            knowledgeBaseID: baseID,
            title: "Policy",
            fileName: "policy.txt",
            storedFileName: "doc.txt",
            mediaType: "text/plain",
            contentHash: "document-hash",
            characterCount: 22
        )
        let chunk = LuminaKnowledgeChunk(
            id: "chunk",
            knowledgeBaseID: baseID,
            documentID: document.id,
            ordinal: 0,
            title: "Refund policy",
            text: "The comet refund policy is available.",
            summary: "The comet refund policy is available.",
            locator: LuminaKnowledgeLocator(fileName: document.fileName),
            tags: [],
            contentHash: "chunk-hash",
            embedding: [1, 0]
        )
        let snapshot = LuminaKnowledgeBaseSnapshot(
            descriptor: LuminaKnowledgeBaseDescriptor(
                id: baseID,
                title: "Policy",
                summary: "Test policy",
                version: "1",
                origin: .userImported,
                enabled: true,
                remoteAccess: .localOnly,
                indexStatus: .ready,
                documentCount: 1,
                chunkCount: 1,
                embeddedChunkCount: 1
            ),
            documents: [document],
            chunks: [chunk]
        )
        let store = LuminaKnowledgeStore(
            embeddingProvider: FailingEmbeddingProvider(),
            repository: LuminaInMemoryKnowledgeRepository(imported: [snapshot]),
            configuration: LuminaKnowledgeStoreConfiguration(scheduleBackgroundEmbedding: false)
        )
        await store.load()

        let report = await store.searchWithReport(LuminaKnowledgeSearchQuery(text: "comet refund"))
        XCTAssertEqual(report.results.first?.matchedBy, .bm25)
        XCTAssertEqual(report.bm25CandidateCount, 1)
        XCTAssertEqual(report.vectorCandidateCount, 0)
        XCTAssertTrue(report.fallbackReason?.hasPrefix("vector_unavailable:") == true)
    }

    func testKnowledgeLoadsThreeBundledManifestsAndUTF16Text() async throws {
        let resources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/KnowledgeBases", isDirectory: true)
        let repository = LuminaInMemoryKnowledgeRepository()
        let configuration = LuminaKnowledgeStoreConfiguration(scheduleBackgroundEmbedding: false)
        let store = LuminaKnowledgeStore(repository: repository, configuration: configuration)

        await store.load(bundledRootURL: resources)
        let bundled = await store.descriptors().filter { $0.origin == .bundled }
        XCTAssertEqual(
            Set(bundled.map(\.id)),
            Set(["lumina-guide", "lumina-workflows", "lumina-privacy-and-trust"])
        )
        XCTAssertTrue(bundled.allSatisfy { $0.indexStatus == .ready && $0.remoteAccess == .allowRemote })
        let failures = await store.failures()
        XCTAssertTrue(failures.isEmpty)
        let unrestrictedWorkflow = await store.search(LuminaKnowledgeSearchQuery(
            text: "健康数据敏感度",
            knowledgeBaseIDs: ["lumina-workflows"],
            destination: .local
        ))
        let capabilityFiltered = await store.search(LuminaKnowledgeSearchQuery(
            text: "健康数据敏感度",
            knowledgeBaseIDs: ["lumina-workflows"],
            destination: .local,
            availableCapabilityCategories: ["location"]
        ))
        XCTAssertFalse(unrestrictedWorkflow.isEmpty)
        XCTAssertTrue(capabilityFiltered.isEmpty)

        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let utf16URL = root.appendingPathComponent("utf16.txt")
        try XCTUnwrap("UTF16 火星咖啡知识".data(using: .utf16)).write(to: utf16URL)
        let importStore = LuminaKnowledgeStore(
            repository: LuminaInMemoryKnowledgeRepository(),
            configuration: configuration
        )
        _ = try await importStore.importKnowledgeBase(title: "UTF16", fileURLs: [utf16URL])
        let results = await importStore.search(LuminaKnowledgeSearchQuery(text: "火星咖啡"))
        XCTAssertFalse(results.isEmpty)
    }

    func testBundledCorruptDerivedCacheRebuildsAndKeepsEnabledPreference() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundledRoot = root.appendingPathComponent("bundled", isDirectory: true)
        let baseRoot = bundledRoot.appendingPathComponent("test-guide", isDirectory: true)
        try FileManager.default.createDirectory(at: baseRoot, withIntermediateDirectories: true)
        try Data(
            """
            {
              "schema_version": 1,
              "id": "test-guide",
              "version": "2",
              "title": "Test Guide",
              "summary": "Versioned bundled test knowledge.",
              "default_enabled": true,
              "remote_access": "allowRemote",
              "documents": [{
                "id": "guide-doc",
                "path": "guide.md",
                "title": "Guide",
                "tags": ["guide"],
                "capability_categories": []
              }]
            }
            """.utf8
        ).write(to: baseRoot.appendingPathComponent("manifest.json"))
        try Data("# Guide\nA bundled quasar-search fact.".utf8)
            .write(to: baseRoot.appendingPathComponent("guide.md"))

        let repositoryRoot = root.appendingPathComponent("repository", isDirectory: true)
        let corruptCache = repositoryRoot
            .appendingPathComponent("BundledCache/test-guide/2", isDirectory: true)
        try FileManager.default.createDirectory(at: corruptCache, withIntermediateDirectories: true)
        try Data("corrupt".utf8).write(to: corruptCache.appendingPathComponent("chunks.json"))
        let repository = LuminaFileKnowledgeRepository(rootURL: repositoryRoot)
        try await repository.savePreferences([
            "test-guide": LuminaKnowledgeBasePreferences(enabled: false, remoteAccess: .allowRemote)
        ])
        let store = LuminaKnowledgeStore(
            repository: repository,
            configuration: LuminaKnowledgeStoreConfiguration(scheduleBackgroundEmbedding: false)
        )

        await store.load(bundledRootURL: bundledRoot)

        let loadedDescriptor = await store.descriptor(id: "test-guide")
        let descriptor = try XCTUnwrap(loadedDescriptor)
        XCTAssertEqual(descriptor.version, "2")
        XCTAssertFalse(descriptor.enabled)
        XCTAssertEqual(descriptor.indexStatus, .ready)
        let results = await store.search(LuminaKnowledgeSearchQuery(
            text: "quasar-search",
            knowledgeBaseIDs: ["test-guide"],
            includeDisabled: true
        ))
        XCTAssertFalse(results.isEmpty)
        let cacheDecoder = JSONDecoder()
        cacheDecoder.dateDecodingStrategy = .iso8601
        XCTAssertNoThrow(
            try cacheDecoder.decode(
                LuminaKnowledgeBaseSnapshot.self,
                from: Data(contentsOf: corruptCache.appendingPathComponent("chunks.json"))
            )
        )
    }

    #if canImport(AppKit) && canImport(PDFKit)
    func testKnowledgePDFExtractionPreservesPageCitationAndRejectsInvalidPDF() throws {
        let pdfData = try searchablePDFData(pages: [
            "First page introduction",
            "Refunds are available for fourteen days."
        ])
        let extracted = try LuminaKnowledgeTextExtractor.extract(
            data: pdfData,
            fileName: "refund-policy.pdf",
            configuration: LuminaKnowledgeStoreConfiguration(scheduleBackgroundEmbedding: false)
        )

        XCTAssertEqual(extracted.pageCount, 2)
        XCTAssertEqual(extracted.sections.last?.pageNumber, 2)
        XCTAssertTrue(extracted.sections.last?.text.contains("fourteen days") == true)

        XCTAssertThrowsError(
            try LuminaKnowledgeTextExtractor.extract(
                data: Data("not a pdf".utf8),
                fileName: "broken.pdf",
                configuration: LuminaKnowledgeStoreConfiguration(scheduleBackgroundEmbedding: false)
            )
        ) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "PDF 已损坏或无法读取：broken.pdf"
            )
        }
    }
    #endif

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumina-knowledge-tests-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    #if canImport(AppKit) && canImport(PDFKit)
    private func searchablePDFData(pages: [String]) throws -> Data {
        let data = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard
            let consumer = CGDataConsumer(data: data),
            let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)
        else {
            throw NSError(domain: "PersonalMemoryTests.PDF", code: 1)
        }

        for text in pages {
            context.beginPDFPage(nil)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            NSString(string: text).draw(
                at: CGPoint(x: 72, y: 680),
                withAttributes: [.font: NSFont.systemFont(ofSize: 14)]
            )
            NSGraphicsContext.restoreGraphicsState()
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }
    #endif
}

private struct FailingEmbeddingProvider: LuminaEmbeddingProvider {
    struct Failure: LocalizedError {
        var errorDescription: String? { "test embedding unavailable" }
    }

    let dimension = 2

    func embed(_ text: String) async throws -> [Float] {
        throw Failure()
    }
}
