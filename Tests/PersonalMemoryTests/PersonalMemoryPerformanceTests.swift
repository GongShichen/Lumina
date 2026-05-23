import XCTest
@testable import PersonalMemory

final class PersonalMemoryPerformanceTests: XCTestCase {
    func testSearchTenThousandChunksLatencyAndCacheHit() async throws {
        let store = MemoryStore(configuration: MemoryStoreConfiguration(
            maximumVectorCandidates: 500,
            scheduleBackgroundEmbedding: false,
            persistAfterIngest: false
        ))
        for document in MemoryDataset.documents(count: 10_000) {
            await store.ingest(document)
        }

        let coldStart = ContinuousClock.now
        let coldReport = try await store.searchWithReport(MemorySearchQuery(text: "coffee-7", limit: 5))
        let coldMilliseconds = TestClock.milliseconds(since: coldStart)

        let warmStart = ContinuousClock.now
        let warmReport = try await store.searchWithReport(MemorySearchQuery(text: "coffee-7", limit: 5))
        let warmMilliseconds = TestClock.milliseconds(since: warmStart)

        XCTAssertFalse(coldReport.results.isEmpty)
        XCTAssertFalse(coldReport.cacheHit)
        XCTAssertTrue(warmReport.cacheHit)
        XCTAssertLessThan(coldMilliseconds, PerformanceBudget.strict ? 750 : 2_500)
        XCTAssertLessThan(warmMilliseconds, PerformanceBudget.strict ? 50 : 250)
    }

    func testHeavyFiftyThousandMetadataFilteredSearchWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["LUMINA_RUN_HEAVY_BENCHMARKS"] == "1" else {
            throw XCTSkip("Set LUMINA_RUN_HEAVY_BENCHMARKS=1 to run 50k chunk benchmark.")
        }
        let store = MemoryStore(configuration: MemoryStoreConfiguration(
            maximumVectorCandidates: 500,
            scheduleBackgroundEmbedding: false,
            persistAfterIngest: false
        ))
        for document in MemoryDataset.documents(count: 50_000) {
            await store.ingest(document)
        }

        let start = ContinuousClock.now
        let report = try await store.searchWithReport(MemorySearchQuery(text: "coffee-7", limit: 5, sourceKinds: [.ledger]))
        let elapsed = TestClock.milliseconds(since: start)

        XCTAssertLessThan(report.candidateCount, 50_000)
        XCTAssertLessThan(elapsed, PerformanceBudget.strict ? 1_000 : 4_000)
    }

    func testIngestDoesNotWaitForEmbedding() async {
        let store = MemoryStore(
            embeddingProvider: SlowEmbeddingProvider(),
            configuration: MemoryStoreConfiguration(
                embedImmediately: false,
                scheduleBackgroundEmbedding: false,
                persistAfterIngest: false
            )
        )
        let start = ContinuousClock.now
        for document in MemoryDataset.documents(count: 1_000) {
            await store.ingest(document)
        }
        let elapsed = TestClock.milliseconds(since: start)
        let stats = await store.stats()

        XCTAssertEqual(stats.documentCount, 1_000)
        XCTAssertEqual(stats.embeddedChunkCount, 0)
        XCTAssertLessThan(elapsed, PerformanceBudget.strict ? 500 : 2_000)
    }

    func testOptionalCoreMLEmbeddingModelContract() async throws {
        guard ProcessInfo.processInfo.environment["LUMINA_RUN_MODEL_BENCHMARKS"] == "1" else {
            throw XCTSkip("Set LUMINA_RUN_MODEL_BENCHMARKS=1 to run Core ML embedding benchmark.")
        }
        guard let path = ProcessInfo.processInfo.environment["LUMINA_EMBEDDING_MODEL"], !path.isEmpty else {
            throw XCTSkip("Set LUMINA_EMBEDDING_MODEL to a compiled BGETextEmbedding .mlmodelc.")
        }
        #if canImport(CoreML)
        let provider = try CoreMLEmbeddingProvider(configuration: .init(
            modelURL: URL(fileURLWithPath: path),
            dimension: 512
        ))
        let start = ContinuousClock.now
        let embedding = try await provider.embed("本地端侧记忆检索")
        let elapsed = TestClock.milliseconds(since: start)

        XCTAssertEqual(embedding.count, 512)
        XCTAssertGreaterThan(VectorMath.cosine(embedding, embedding), 0.99)
        XCTAssertLessThan(elapsed, PerformanceBudget.strict ? 500 : 5_000)
        #else
        throw XCTSkip("CoreML is unavailable on this platform.")
        #endif
    }
}

enum MemoryDataset {
    static func documents(count: Int) -> [MemoryDocument] {
        (0..<count).map { index in
            MemoryDocument(
                source: MemorySource(kind: index.isMultiple(of: 4) ? .ledger : .appNote, identifier: "doc-\(index)"),
                title: "Note \(index)",
                body: "这是第 \(index) 条本地记忆，用于端侧检索 benchmark。关键词 coffee-\(index % 10)。",
                sensitivity: .normal
            )
        }
    }
}

private struct SlowEmbeddingProvider: EmbeddingProvider {
    let dimension = 8

    func embed(_ text: String) async throws -> [Float] {
        try await Task.sleep(nanoseconds: 50_000_000)
        return Array(repeating: 0.1, count: dimension)
    }
}

private enum PerformanceBudget {
    static var strict: Bool {
        ProcessInfo.processInfo.environment["LUMINA_STRICT_PERF"] == "1"
    }
}

private enum TestClock {
    static func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let duration = start.duration(to: .now).components
        return Double(duration.seconds) * 1_000 + Double(duration.attoseconds) / 1e15
    }
}
