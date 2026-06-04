import LuminaAgentRuntime
import Foundation

struct LuminaBenchmarkRuntimeMetrics: Codable, Hashable {
    var stepGenerationStartCount: Int = 0
    var modelProgressEventCount: Int = 0
    var resultGeneratedCount: Int = 0
    var observationCount: Int = 0
    var hookEventCount: Int = 0
    var runtimeEventCount: Int = 0
    var toolFailureCount: Int = 0
    var normalizationFailureCount: Int = 0
    var schemaValidationFailureCount: Int = 0
    var modelOwnedObservationRejectCount: Int = 0
    var unknownToolRejectCount: Int = 0
    var retryCount: Int = 0
    var fallbackCount: Int = 0
    var remoteModelInvocationCount: Int = 0
    var localModelInvocationCount: Int = 0
    var cancellationCount: Int = 0
    var toolLoadingCatalogEmittedCount: Int = 0
    var toolLoadingSearchCount: Int = 0
    var toolLoadingDiscoveryHitCount: Int = 0
    var toolLoadingLoadedCount: Int = 0
    var toolLoadingLoadFailedCount: Int = 0
    var toolLoadingUnknownToolCount: Int = 0
    var schemaTokensSavedEstimate: Int = 0
    var contextLoadingCatalogEmittedCount: Int = 0
    var contextLoadingSearchCount: Int = 0
    var contextLoadingLoadedCount: Int = 0
    var contextLoadingRangeLoadedCount: Int = 0
    var contextLoadingCacheHitCount: Int = 0
    var contextLoadingLoadFailedCount: Int = 0
    var contextLoadingTokensEstimate: Int = 0

    var contractFailureCount: Int {
        normalizationFailureCount +
        schemaValidationFailureCount +
        modelOwnedObservationRejectCount +
        unknownToolRejectCount
    }

    mutating func merge(_ other: LuminaBenchmarkRuntimeMetrics) {
        stepGenerationStartCount += other.stepGenerationStartCount
        modelProgressEventCount += other.modelProgressEventCount
        resultGeneratedCount += other.resultGeneratedCount
        observationCount += other.observationCount
        hookEventCount += other.hookEventCount
        runtimeEventCount += other.runtimeEventCount
        toolFailureCount += other.toolFailureCount
        normalizationFailureCount += other.normalizationFailureCount
        schemaValidationFailureCount += other.schemaValidationFailureCount
        modelOwnedObservationRejectCount += other.modelOwnedObservationRejectCount
        unknownToolRejectCount += other.unknownToolRejectCount
        retryCount += other.retryCount
        fallbackCount += other.fallbackCount
        remoteModelInvocationCount += other.remoteModelInvocationCount
        localModelInvocationCount += other.localModelInvocationCount
        cancellationCount += other.cancellationCount
        toolLoadingCatalogEmittedCount += other.toolLoadingCatalogEmittedCount
        toolLoadingSearchCount += other.toolLoadingSearchCount
        toolLoadingDiscoveryHitCount += other.toolLoadingDiscoveryHitCount
        toolLoadingLoadedCount += other.toolLoadingLoadedCount
        toolLoadingLoadFailedCount += other.toolLoadingLoadFailedCount
        toolLoadingUnknownToolCount += other.toolLoadingUnknownToolCount
        schemaTokensSavedEstimate += other.schemaTokensSavedEstimate
        contextLoadingCatalogEmittedCount += other.contextLoadingCatalogEmittedCount
        contextLoadingSearchCount += other.contextLoadingSearchCount
        contextLoadingLoadedCount += other.contextLoadingLoadedCount
        contextLoadingRangeLoadedCount += other.contextLoadingRangeLoadedCount
        contextLoadingCacheHitCount += other.contextLoadingCacheHitCount
        contextLoadingLoadFailedCount += other.contextLoadingLoadFailedCount
        contextLoadingTokensEstimate += other.contextLoadingTokensEstimate
    }
}

struct LuminaObservedRunTimings: Codable, Hashable {
    var wallClockMilliseconds: Double
    var activeRuntimeMilliseconds: Double
    var confirmationWaitMilliseconds: Double
    var systemPermissionWaitMilliseconds: Double
    var observedToolExecutionMilliseconds: Double
    var runtimeMetrics: LuminaBenchmarkRuntimeMetrics

    static let empty = LuminaObservedRunTimings(
        wallClockMilliseconds: 0,
        activeRuntimeMilliseconds: 0,
        confirmationWaitMilliseconds: 0,
        systemPermissionWaitMilliseconds: 0,
        observedToolExecutionMilliseconds: 0,
        runtimeMetrics: LuminaBenchmarkRuntimeMetrics()
    )
}
