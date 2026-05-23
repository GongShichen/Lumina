import XCTest
@testable import PersonalMemory

final class PersonalMemoryTests: XCTestCase {
    func testIngestMakesDocumentSearchableBeforeEmbeddingCompletes() async throws {
        let store = MemoryStore()
        await store.ingest(MemoryDocument(
            source: MemorySource(kind: .appNote, identifier: "note-1"),
            title: "Coffee",
            body: "今天在楼下买了一杯咖啡，花了 42 元。",
            sensitivity: .normal
        ))

        let results = try await store.search(MemorySearchQuery(text: "咖啡", limit: 3))
        XCTAssertFalse(results.isEmpty)
        XCTAssertEqual(results.first?.matchedBy, .keyword)
    }

    func testMetadataFilterLimitsSourceKind() async throws {
        let store = MemoryStore()
        await store.ingest(MemoryDocument(
            source: MemorySource(kind: .ledger, identifier: "ledger-1"),
            title: "Expense",
            body: "咖啡 42 元",
            sensitivity: .normal
        ))
        await store.ingest(MemoryDocument(
            source: MemorySource(kind: .calendar, identifier: "calendar-1"),
            title: "Meeting",
            body: "下午三点产品会议",
            sensitivity: .normal
        ))

        let results = try await store.search(MemorySearchQuery(text: "咖啡", sourceKinds: [.calendar]))
        XCTAssertTrue(results.isEmpty)
    }

    func testSensitivityFilterHidesPrivateData() async throws {
        let store = MemoryStore()
        await store.ingest(MemoryDocument(
            source: MemorySource(kind: .appNote, identifier: "private"),
            title: "Private",
            body: "非常私密的信息",
            sensitivity: .privateData
        ))

        let results = try await store.search(MemorySearchQuery(text: "私密", maximumSensitivity: .normal))
        XCTAssertTrue(results.isEmpty)
    }

    func testHashingEmbeddingProducesStableDimension() async throws {
        let provider = HashingEmbeddingProvider(dimension: 32)
        let embedding = try await provider.embed("local agent runtime")
        XCTAssertEqual(embedding.count, 32)
        XCTAssertGreaterThan(VectorMath.cosine(embedding, embedding), 0.99)
    }

    func testSearchPerformanceForOneThousandChunks() async throws {
        let store = MemoryStore()
        for index in 0..<1_000 {
            await store.ingest(MemoryDocument(
                source: MemorySource(kind: .appNote, identifier: "note-\(index)"),
                title: "Note \(index)",
                body: "这是第 \(index) 条本地记忆，用于测试端侧检索性能。关键词 coffee-\(index % 10)。",
                sensitivity: .normal
            ))
        }

        let start = ContinuousClock.now
        let results = try await store.search(MemorySearchQuery(text: "coffee-7", limit: 5))
        let elapsed = start.duration(to: .now)

        XCTAssertFalse(results.isEmpty)
        XCTAssertLessThan(elapsed.components.seconds, 1)
    }

    func testRepositoryRoundTrip() async throws {
        let repository = InMemoryMemoryRepository()
        let store = MemoryStore(repository: repository)
        await store.ingest(MemoryDocument(
            source: MemorySource(kind: .appNote, identifier: "persisted"),
            title: "Persisted",
            body: "本地持久化索引",
            sensitivity: .normal
        ))
        try await store.persist()

        let restored = MemoryStore(repository: repository)
        try await restored.load()
        let stats = await restored.stats()

        XCTAssertEqual(stats.documentCount, 1)
        XCTAssertEqual(stats.chunkCount, 1)
    }

    func testSearchReportIncludesMetrics() async throws {
        let store = MemoryStore()
        await store.ingest(MemoryDocument(
            source: MemorySource(kind: .appNote, identifier: "metrics"),
            title: "Metrics",
            body: "性能指标和候选数量",
            sensitivity: .normal
        ))

        let report = try await store.searchWithReport(MemorySearchQuery(text: "性能", limit: 1))

        XCTAssertEqual(report.candidateCount, 1)
        XCTAssertGreaterThanOrEqual(report.elapsedMilliseconds, 0)
        XCTAssertFalse(report.cacheHit)
    }
}
