import XCTest
@testable import LuminaMarkdownUI

final class LuminaMarkdownUIPerformanceTests: XCTestCase {
    func testLargeMarkdownParseLatency() {
        let markdown = MarkdownDataset.largeDocument(repetitions: 200)
        let start = ContinuousClock.now
        let document = MarkdownASTParser().parse(markdown)
        let elapsed = TestClock.milliseconds(since: start)

        XCTAssertFalse(document.blocks.isEmpty)
        XCTAssertLessThan(elapsed, PerformanceBudget.strict ? 800 : 2_500)
    }

    func testMarkdownCacheLatency() {
        let markdown = MarkdownDataset.largeDocument(repetitions: 40)
        _ = MarkdownDocumentCache.shared.document(for: markdown)
        let start = ContinuousClock.now
        let cached = MarkdownDocumentCache.shared.document(for: markdown)
        let elapsed = TestClock.milliseconds(since: start)

        XCTAssertFalse(cached.blocks.isEmpty)
        XCTAssertLessThan(elapsed, PerformanceBudget.strict ? 20 : 100)
    }
}

enum MarkdownDataset {
    static func largeDocument(repetitions: Int) -> String {
        Array(repeating: """
        ## 本地检索结果

        > Observation: memory returned compact cited snippets.

        - [x] metadata filter
        - [ ] vector rerank

        ```swift
        let latencyBudget = 120
        ```

        | 来源 | 置信度 |
        | --- | ---: |
        | Calendar | high |

        <aside>raw html</aside>
        """, count: repetitions).joined(separator: "\n\n")
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
