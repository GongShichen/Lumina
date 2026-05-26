import Foundation

struct LuminaBenchmarkReport: Codable, Hashable {
    let generatedAt: Date
    let taskCount: Int
    let completedCount: Int
    let succeededCount: Int
    let failedCount: Int
    let exactToolMatch: Double
    let microPrecision: Double
    let microRecall: Double
    let microF1: Double
    let latencyP50Milliseconds: Double
    let latencyP95Milliseconds: Double
    let wallClockP95Milliseconds: Double
    let confirmationWaitP95Milliseconds: Double
    let systemPermissionWaitP95Milliseconds: Double
    let stepGenerationP95Milliseconds: Double
    let toolP95Milliseconds: Double
    let modelInvocationCount: Int
    let modelTTFTP50Milliseconds: Double?
    let modelTTFTP95Milliseconds: Double?
    let modelTokensPerSecondP50: Double?
    let modelTokensPerSecondP95: Double?
    let modelPromptTokensP95: Double?
    let modelOutputTokensP95: Double?
    let memoryAccessDisabled: Bool
    let results: [LuminaBenchmarkTaskResult]
    let jsonReportURL: URL?
    let markdownReportURL: URL?

    static func make(results: [LuminaBenchmarkTaskResult], jsonReportURL: URL?, markdownReportURL: URL?) -> LuminaBenchmarkReport {
        let completed = results.count
        let succeeded = results.filter { $0.status == "succeeded" }.count
        let failed = results.filter { $0.status != "succeeded" }.count
        let exact = ratio(results.filter(\.exactMatch).count, completed)
        let modelMetrics = results.flatMap(\.modelMetrics)
        let ttft = modelMetrics.compactMap(\.timeToFirstTokenMilliseconds)

        var truePositive = 0
        var falsePositive = 0
        var falseNegative = 0
        for result in results {
            let expected = Set(result.expectedTools)
            let actual = Set(result.actualTools)
            truePositive += expected.intersection(actual).count
            falsePositive += actual.subtracting(expected).count
            falseNegative += expected.subtracting(actual).count
        }
        let precision = ratio(truePositive, truePositive + falsePositive)
        let recall = ratio(truePositive, truePositive + falseNegative)
        let f1 = precision + recall == 0 ? 0 : 2 * precision * recall / (precision + recall)
        return LuminaBenchmarkReport(
            generatedAt: Date(),
            taskCount: completed,
            completedCount: completed,
            succeededCount: succeeded,
            failedCount: failed,
            exactToolMatch: exact,
            microPrecision: precision,
            microRecall: recall,
            microF1: f1,
            latencyP50Milliseconds: percentile(results.map(\.activeRuntimeMilliseconds), percentile: 0.50),
            latencyP95Milliseconds: percentile(results.map(\.activeRuntimeMilliseconds), percentile: 0.95),
            wallClockP95Milliseconds: percentile(results.map(\.wallClockMilliseconds), percentile: 0.95),
            confirmationWaitP95Milliseconds: percentile(results.map(\.confirmationWaitMilliseconds), percentile: 0.95),
            systemPermissionWaitP95Milliseconds: percentile(results.map(\.systemPermissionWaitMilliseconds), percentile: 0.95),
            stepGenerationP95Milliseconds: percentile(results.map(\.stepGenerationMilliseconds), percentile: 0.95),
            toolP95Milliseconds: percentile(results.map(\.toolMilliseconds), percentile: 0.95),
            modelInvocationCount: modelMetrics.count,
            modelTTFTP50Milliseconds: optionalPercentile(ttft, percentile: 0.50),
            modelTTFTP95Milliseconds: optionalPercentile(ttft, percentile: 0.95),
            modelTokensPerSecondP50: optionalPercentile(modelMetrics.map(\.tokensPerSecond), percentile: 0.50),
            modelTokensPerSecondP95: optionalPercentile(modelMetrics.map(\.tokensPerSecond), percentile: 0.95),
            modelPromptTokensP95: optionalPercentile(modelMetrics.map { Double($0.promptTokens) }, percentile: 0.95),
            modelOutputTokensP95: optionalPercentile(modelMetrics.map { Double($0.outputTokens) }, percentile: 0.95),
            memoryAccessDisabled: true,
            results: results,
            jsonReportURL: jsonReportURL,
            markdownReportURL: markdownReportURL
        )
    }

    private static func ratio(_ numerator: Int, _ denominator: Int) -> Double {
        denominator == 0 ? 0 : Double(numerator) / Double(denominator)
    }

    private static func percentile(_ values: [Double], percentile: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        return optionalPercentile(values, percentile: percentile) ?? 0
    }

    private static func optionalPercentile(_ values: [Double], percentile: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let index = min(sorted.count - 1, max(0, Int((Double(sorted.count - 1) * percentile).rounded())))
        return sorted[index]
    }
}
