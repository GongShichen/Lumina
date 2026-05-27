import XCTest
@testable import PersonalMemory

final class PersonalMemoryTests: XCTestCase {
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
        XCTAssertEqual(results.first?.matchedBy, .keyword)
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
}
