import Foundation

struct LuminaBenchmarkReport: Codable, Hashable {
    let generatedAt: Date
    let localModelSelectionRawValue: String?
    let localModelDisplayName: String?
    let modelSource: String?
    let taskCount: Int
    let completedCount: Int
    let succeededCount: Int
    let failedCount: Int
    let outcomePassedCount: Int
    let outcomePassRate: Double
    let passAt1Count: Int
    let passAt1Rate: Double
    let strictToolPassCount: Int
    let strictToolPassRate: Double
    let toolExecutionAt1Count: Int
    let toolExecutionAt1Rate: Double
    let semanticPassedCount: Int
    let semanticPassRate: Double
    let missingToolCount: Int
    let unexpectedToolCount: Int
    let failedToolCount: Int
    let replayedToolCount: Int
    let orderedToolMatchCount: Int
    let orderedToolMatchRate: Double
    let toolAttemptCount: Int
    let toolExecutionCount: Int
    let toolReplayCount: Int
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
    let runtimeContractFailureCount: Int
    let runtimeContractFailureRate: Double
    let normalizationFailureCount: Int
    let schemaValidationFailureCount: Int
    let modelOwnedObservationRejectCount: Int
    let unknownToolRejectCount: Int
    let retryCount: Int
    let fallbackCount: Int
    let remoteModelInvocationCount: Int
    let localModelInvocationCount: Int
    let modelGenerationValidatedCount: Int
    let modelStreamContainsSpecialTokensCount: Int
    let hostReturnedCanonicalStepCount: Int
    let coreExtractedSpecialTokenStepCount: Int
    let canonicalToolUseStepCount: Int
    let canonicalResultStepCount: Int
    let legacyOutputSchemaObservedCount: Int
    let runtimeObservationCount: Int
    let resultGeneratedCount: Int
    let hookEventCount: Int
    let toolFailureCount: Int
    let multiToolGenerationCount: Int
    let multiToolCallCount: Int
    let multiToolPartialFailureCount: Int
    let internalToolIgnoredCount: Int
    let sideEffectBatchStopCount: Int
    let schemaTokensSavedEstimate: Int
    let toolDiscoveryHitRate: Double
    let deferredUnknownToolRate: Double
    let toolLoadingSearchCount: Int
    let toolLoadingLoadedCount: Int
    let toolLoadingLoadFailedCount: Int
    let contextLoadingCatalogEmittedCount: Int
    let contextLoadingSearchCount: Int
    let contextLoadingLoadedCount: Int
    let contextLoadingRangeLoadedCount: Int
    let contextLoadingCacheHitCount: Int
    let contextLoadingLoadFailedCount: Int
    let contextLoadingHitRate: Double
    let contextLoadingTokensEstimate: Int
    let memoryAccessDisabled: Bool
    let results: [LuminaBenchmarkTaskResult]
    let jsonReportURL: URL?
    let markdownReportURL: URL?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case generatedAt
        case localModelSelectionRawValue
        case localModelDisplayName
        case modelSource
        case taskCount
        case completedCount
        case succeededCount
        case failedCount
        case outcomePassedCount
        case outcomePassRate
        case passAt1Count
        case passAt1Rate
        case strictToolPassCount
        case strictToolPassRate
        case toolExecutionAt1Count
        case toolExecutionAt1Rate
        case semanticPassedCount
        case semanticPassRate
        case missingToolCount
        case unexpectedToolCount
        case failedToolCount
        case replayedToolCount
        case orderedToolMatchCount
        case orderedToolMatchRate
        case toolAttemptCount
        case toolExecutionCount
        case toolReplayCount
        case exactToolMatch
        case microPrecision
        case microRecall
        case microF1
        case latencyP50Milliseconds
        case latencyP95Milliseconds
        case wallClockP95Milliseconds
        case confirmationWaitP95Milliseconds
        case systemPermissionWaitP95Milliseconds
        case stepGenerationP95Milliseconds
        case toolP95Milliseconds
        case modelInvocationCount
        case modelTTFTP50Milliseconds
        case modelTTFTP95Milliseconds
        case modelTokensPerSecondP50
        case modelTokensPerSecondP95
        case modelPromptTokensP95
        case modelOutputTokensP95
        case runtimeContractFailureCount
        case runtimeContractFailureRate
        case normalizationFailureCount
        case schemaValidationFailureCount
        case modelOwnedObservationRejectCount
        case unknownToolRejectCount
        case retryCount
        case fallbackCount
        case remoteModelInvocationCount
        case localModelInvocationCount
        case modelGenerationValidatedCount
        case modelStreamContainsSpecialTokensCount
        case hostReturnedCanonicalStepCount
        case coreExtractedSpecialTokenStepCount
        case canonicalToolUseStepCount
        case canonicalResultStepCount
        case legacyOutputSchemaObservedCount
        case runtimeObservationCount
        case resultGeneratedCount
        case hookEventCount
        case toolFailureCount
        case multiToolGenerationCount
        case multiToolCallCount
        case multiToolPartialFailureCount
        case internalToolIgnoredCount
        case sideEffectBatchStopCount
        case schemaTokensSavedEstimate
        case toolDiscoveryHitRate
        case deferredUnknownToolRate
        case toolLoadingSearchCount
        case toolLoadingLoadedCount
        case toolLoadingLoadFailedCount
        case contextLoadingCatalogEmittedCount
        case contextLoadingSearchCount
        case contextLoadingLoadedCount
        case contextLoadingRangeLoadedCount
        case contextLoadingCacheHitCount
        case contextLoadingLoadFailedCount
        case contextLoadingHitRate
        case contextLoadingTokensEstimate
        case memoryAccessDisabled
        case results
        case jsonReportURL
        case markdownReportURL
    }

    static func make(
        results: [LuminaBenchmarkTaskResult],
        jsonReportURL: URL?,
        markdownReportURL: URL?,
        localModelSelectionRawValue: String? = nil,
        localModelDisplayName: String? = nil,
        modelSource: String? = nil
    ) -> LuminaBenchmarkReport {
        let completed = results.count
        let succeeded = results.filter { $0.status == "succeeded" }.count
        let failed = results.filter { $0.status != "succeeded" }.count
        let outcomePassed = results.filter(\.outcomePassed).count
        let passAt1 = results.filter(\.passAt1).count
        let strictToolPass = results.filter(\.strictToolPassed).count
        let toolRequired = results.filter { !$0.expectedTools.isEmpty }.count
        let toolExecutionAt1 = results.filter(\.toolExecutedAt1).count
        let semanticPassed = results.filter(\.semanticPassed).count
        let orderedToolMatch = results.filter(\.orderedToolMatch).count
        let exact = ratio(results.filter(\.exactMatch).count, completed)
        let missingToolCount = results.reduce(0) { $0 + $1.missingTools.count }
        let unexpectedToolCount = results.reduce(0) { $0 + $1.unexpectedTools.count }
        let failedToolCount = results.reduce(0) { $0 + $1.failedToolCount }
        let replayedToolCount = results.reduce(0) { $0 + $1.toolReplayCount }
        let toolAttemptCount = results.reduce(0) { $0 + $1.toolAttemptCount }
        let toolExecutionCount = results.reduce(0) { $0 + $1.toolExecutionCount }
        let toolReplayCount = results.reduce(0) { $0 + $1.toolReplayCount }
        let modelMetrics = results.flatMap(\.modelMetrics)
        let ttft = modelMetrics.compactMap(\.timeToFirstTokenMilliseconds)
        let runtimeMetrics = results.reduce(into: LuminaBenchmarkRuntimeMetrics()) { partial, result in
            partial.merge(result.runtimeMetrics)
        }

        var truePositive = 0
        var falsePositive = 0
        var falseNegative = 0
        for result in results {
            let expected = Set(result.expectedTools)
            let actual = Set(result.successfulTools)
            let allExecuted = Set(result.actualTools)
            truePositive += expected.intersection(actual).count
            falsePositive += allExecuted.subtracting(expected).count
            falseNegative += expected.subtracting(actual).count
        }
        let precision = ratio(truePositive, truePositive + falsePositive)
        let recall = ratio(truePositive, truePositive + falseNegative)
        let f1 = precision + recall == 0 ? 0 : 2 * precision * recall / (precision + recall)
        return LuminaBenchmarkReport(
            generatedAt: Date(),
            localModelSelectionRawValue: localModelSelectionRawValue,
            localModelDisplayName: localModelDisplayName,
            modelSource: modelSource,
            taskCount: completed,
            completedCount: completed,
            succeededCount: succeeded,
            failedCount: failed,
            outcomePassedCount: outcomePassed,
            outcomePassRate: ratio(outcomePassed, completed),
            passAt1Count: passAt1,
            passAt1Rate: ratio(passAt1, completed),
            strictToolPassCount: strictToolPass,
            strictToolPassRate: ratio(strictToolPass, completed),
            toolExecutionAt1Count: toolExecutionAt1,
            toolExecutionAt1Rate: ratio(toolExecutionAt1, toolRequired),
            semanticPassedCount: semanticPassed,
            semanticPassRate: ratio(semanticPassed, completed),
            missingToolCount: missingToolCount,
            unexpectedToolCount: unexpectedToolCount,
            failedToolCount: failedToolCount,
            replayedToolCount: replayedToolCount,
            orderedToolMatchCount: orderedToolMatch,
            orderedToolMatchRate: ratio(orderedToolMatch, completed),
            toolAttemptCount: toolAttemptCount,
            toolExecutionCount: toolExecutionCount,
            toolReplayCount: toolReplayCount,
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
            runtimeContractFailureCount: runtimeMetrics.contractFailureCount,
            runtimeContractFailureRate: ratio(runtimeMetrics.contractFailureCount, max(1, completed)),
            normalizationFailureCount: runtimeMetrics.normalizationFailureCount,
            schemaValidationFailureCount: runtimeMetrics.schemaValidationFailureCount,
            modelOwnedObservationRejectCount: runtimeMetrics.modelOwnedObservationRejectCount,
            unknownToolRejectCount: runtimeMetrics.unknownToolRejectCount,
            retryCount: runtimeMetrics.retryCount,
            fallbackCount: runtimeMetrics.fallbackCount,
            remoteModelInvocationCount: runtimeMetrics.remoteModelInvocationCount,
            localModelInvocationCount: runtimeMetrics.localModelInvocationCount,
            modelGenerationValidatedCount: runtimeMetrics.modelGenerationValidatedCount,
            modelStreamContainsSpecialTokensCount: runtimeMetrics.modelStreamContainsSpecialTokensCount,
            hostReturnedCanonicalStepCount: runtimeMetrics.hostReturnedCanonicalStepCount,
            coreExtractedSpecialTokenStepCount: runtimeMetrics.coreExtractedSpecialTokenStepCount,
            canonicalToolUseStepCount: runtimeMetrics.canonicalToolUseStepCount,
            canonicalResultStepCount: runtimeMetrics.canonicalResultStepCount,
            legacyOutputSchemaObservedCount: runtimeMetrics.legacyOutputSchemaObservedCount,
            runtimeObservationCount: runtimeMetrics.observationCount,
            resultGeneratedCount: runtimeMetrics.resultGeneratedCount,
            hookEventCount: runtimeMetrics.hookEventCount,
            toolFailureCount: runtimeMetrics.toolFailureCount,
            multiToolGenerationCount: runtimeMetrics.multiToolGenerationCount,
            multiToolCallCount: runtimeMetrics.multiToolCallCount,
            multiToolPartialFailureCount: runtimeMetrics.multiToolPartialFailureCount,
            internalToolIgnoredCount: runtimeMetrics.internalToolIgnoredCount,
            sideEffectBatchStopCount: runtimeMetrics.sideEffectBatchStopCount,
            schemaTokensSavedEstimate: runtimeMetrics.schemaTokensSavedEstimate,
            toolDiscoveryHitRate: ratio(runtimeMetrics.toolLoadingDiscoveryHitCount, runtimeMetrics.toolLoadingSearchCount),
            deferredUnknownToolRate: ratio(runtimeMetrics.toolLoadingUnknownToolCount, max(1, runtimeMetrics.toolLoadingSearchCount + runtimeMetrics.toolLoadingLoadedCount)),
            toolLoadingSearchCount: runtimeMetrics.toolLoadingSearchCount,
            toolLoadingLoadedCount: runtimeMetrics.toolLoadingLoadedCount,
            toolLoadingLoadFailedCount: runtimeMetrics.toolLoadingLoadFailedCount,
            contextLoadingCatalogEmittedCount: runtimeMetrics.contextLoadingCatalogEmittedCount,
            contextLoadingSearchCount: runtimeMetrics.contextLoadingSearchCount,
            contextLoadingLoadedCount: runtimeMetrics.contextLoadingLoadedCount,
            contextLoadingRangeLoadedCount: runtimeMetrics.contextLoadingRangeLoadedCount,
            contextLoadingCacheHitCount: runtimeMetrics.contextLoadingCacheHitCount,
            contextLoadingLoadFailedCount: runtimeMetrics.contextLoadingLoadFailedCount,
            contextLoadingHitRate: ratio(
                runtimeMetrics.contextLoadingLoadedCount + runtimeMetrics.contextLoadingRangeLoadedCount + runtimeMetrics.contextLoadingCacheHitCount,
                runtimeMetrics.contextLoadingSearchCount
            ),
            contextLoadingTokensEstimate: runtimeMetrics.contextLoadingTokensEstimate,
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
