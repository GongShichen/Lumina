import Foundation
import LuminaAgentRuntimeApple

public actor BenchmarkTraceCollector: LuminaRuntimeTraceSink, LuminaRuntimeMetricsSink {
    public private(set) var traces: [String] = []
    public private(set) var metrics: [String] = []

    public init() {}

    public func recordTrace(_ recordJSON: String) {
        traces.append(recordJSON)
    }

    public func recordMetric(_ metricJSON: String) {
        metrics.append(metricJSON)
    }
}

public struct BenchmarkCase: Sendable {
    public var id: String
    public var prompt: String
    public var expectedTools: [String]

    public init(id: String, prompt: String, expectedTools: [String]) {
        self.id = id
        self.prompt = prompt
        self.expectedTools = expectedTools
    }
}

public struct BenchmarkCaseResult: Sendable {
    public var id: String
    public var status: LuminaAgentRunStatus
    public var result: String
    public var expectedTools: [String]
    public var toolNames: [String]
    public var exactToolMatch: Bool
    public var precision: Double
    public var recall: Double
    public var f1: Double
    public var semanticPassed: Bool
    public var semanticFailures: [String]
    public var traceCount: Int
    public var metricCount: Int
    public var runtimeContractFailureCount: Int
    public var wallClockMilliseconds: Double
}

public struct BenchmarkSummary: Sendable {
    public var results: [BenchmarkCaseResult]
    public var completedCount: Int
    public var succeededCount: Int
    public var exactToolMatchRate: Double
    public var semanticPassRate: Double
    public var microPrecision: Double
    public var microRecall: Double
    public var microF1: Double
    public var runtimeContractFailureCount: Int
    public var wallClockP95Milliseconds: Double
}

public enum ExternalBenchmarkHarness {
    public static func run(
        cases: [BenchmarkCase],
        runtimeFactory: @Sendable @escaping (BenchmarkTraceCollector) -> LuminaAgentRuntime,
        semanticVerifier: @Sendable @escaping (BenchmarkCase, LuminaAgentRunResult) -> [String] = { _, _ in [] }
    ) async -> BenchmarkSummary {
        var results: [BenchmarkCaseResult] = []
        for benchmarkCase in cases {
            let collector = BenchmarkTraceCollector()
            let runtime = runtimeFactory(collector)
            let startedAt = ContinuousClock.now
            let run = await runtime.run(request: LuminaAgentRequest(text: benchmarkCase.prompt))
            let elapsed = startedAt.duration(to: ContinuousClock.now).components
            let expected = Set(benchmarkCase.expectedTools)
            let tools = run.toolResults.map(\.toolName)
            let actual = Set(tools)
            let truePositive = Double(expected.intersection(actual).count)
            let falsePositive = Double(actual.subtracting(expected).count)
            let falseNegative = Double(expected.subtracting(actual).count)
            let precision = truePositive + falsePositive == 0 ? 0 : truePositive / (truePositive + falsePositive)
            let recall = truePositive + falseNegative == 0 ? 0 : truePositive / (truePositive + falseNegative)
            let semanticFailures = semanticVerifier(benchmarkCase, run)
            let traces = await collector.traces
            let metrics = await collector.metrics
            results.append(BenchmarkCaseResult(
                id: benchmarkCase.id,
                status: run.status,
                result: run.plan.summary,
                expectedTools: benchmarkCase.expectedTools,
                toolNames: tools,
                exactToolMatch: expected == actual,
                precision: precision,
                recall: recall,
                f1: precision + recall == 0 ? 0 : 2 * precision * recall / (precision + recall),
                semanticPassed: semanticFailures.isEmpty,
                semanticFailures: semanticFailures,
                traceCount: traces.count,
                metricCount: metrics.count,
                runtimeContractFailureCount: contractFailureCount(traces: traces),
                wallClockMilliseconds: Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1_000_000_000_000_000
            ))
        }
        return summarize(results)
    }

    private static func summarize(_ results: [BenchmarkCaseResult]) -> BenchmarkSummary {
        var truePositive = 0
        var falsePositive = 0
        var falseNegative = 0
        for result in results {
            let expected = Set(result.expectedTools)
            let actual = Set(result.toolNames)
            truePositive += expected.intersection(actual).count
            falsePositive += actual.subtracting(expected).count
            falseNegative += expected.subtracting(actual).count
        }
        let precision = ratio(truePositive, truePositive + falsePositive)
        let recall = ratio(truePositive, truePositive + falseNegative)
        return BenchmarkSummary(
            results: results,
            completedCount: results.count,
            succeededCount: results.filter { $0.status == .succeeded && $0.exactToolMatch && $0.semanticPassed }.count,
            exactToolMatchRate: ratio(results.filter(\.exactToolMatch).count, results.count),
            semanticPassRate: ratio(results.filter(\.semanticPassed).count, results.count),
            microPrecision: precision,
            microRecall: recall,
            microF1: precision + recall == 0 ? 0 : 2 * precision * recall / (precision + recall),
            runtimeContractFailureCount: results.reduce(0) { $0 + $1.runtimeContractFailureCount },
            wallClockP95Milliseconds: percentile(results.map(\.wallClockMilliseconds), p: 0.95)
        )
    }

    private static func contractFailureCount(traces: [String]) -> Int {
        traces.filter { trace in
            let lowered = trace.lowercased()
            return lowered.contains("normalization") ||
                lowered.contains("invalid schema") ||
                lowered.contains("unknown tool") ||
                lowered.contains("observation") && lowered.contains("model")
        }.count
    }

    private static func ratio(_ numerator: Int, _ denominator: Int) -> Double {
        denominator == 0 ? 0 : Double(numerator) / Double(denominator)
    }

    private static func percentile(_ values: [Double], p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let index = min(sorted.count - 1, max(0, Int((Double(sorted.count - 1) * p).rounded())))
        return sorted[index]
    }
}
