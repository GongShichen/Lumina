import LuminaAgentRuntime
import Foundation
import PersonalMemory

struct AppEnvironment {
    var memoryStore: LuminaMemoryStore
    var ledgerStore: LuminaLedgerStore
    var subscriptionStore: LuminaSubscriptionStore
    var messageDrafts: LuminaMessageDraftCenter
    var confirmation: AppConfirmationCoordinator
    var askUser: AskUserCoordinator
    var modelReadiness: LuminaModelReadinessStore
    var modelMetrics: LuminaModelInferenceMetricsStore
    var localModelSelection: LuminaLocalModelSelectionStore
    var remoteInferenceSettings: LuminaRemoteInferenceSettingsStore
    var auditLogger: any LuminaAuditLogger
    var auditLogReader: (any LuminaAuditLogReader)?
    var stepGenerator: any LuminaReActStepGenerator
    var contextProvider: any LuminaRuntimeContextProvider
    var runtimeConfiguration: LuminaAgentRuntimeConfiguration

    @MainActor
    static func live() -> AppEnvironment {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("Lumina", isDirectory: true)
            ?? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Lumina", isDirectory: true)

        let modelReadiness = LuminaModelReadinessStore()
        let modelMetrics = LuminaModelInferenceMetricsStore()
        let localModelSelection = LuminaLocalModelSelectionStore()
        let remoteInferenceSettings = LuminaRemoteInferenceSettingsStore()
        let memoryRepository = LuminaJSONMemoryRepository(url: appSupport.appendingPathComponent("memory-index.json"))
        let memoryStore = LuminaMemoryStore(
            embeddingProvider: LocalModelBootstrap.makeEmbeddingProvider(readinessStore: modelReadiness),
            repository: memoryRepository,
            configuration: LuminaMemoryStoreConfiguration(
                cacheLimit: 32,
                maximumVectorCandidates: 2_000,
                embedImmediately: false,
                persistAfterIngest: true,
                persistAfterEmbedding: false
            )
        )

        let auditLogger = LuminaJSONLAuditLogger(url: appSupport.appendingPathComponent("audit.jsonl"))

        return AppEnvironment(
            memoryStore: memoryStore,
            ledgerStore: LuminaLedgerStore(url: appSupport.appendingPathComponent("ledger.json")),
            subscriptionStore: LuminaSubscriptionStore(url: appSupport.appendingPathComponent("subscriptions.json")),
            messageDrafts: LuminaMessageDraftCenter(),
            confirmation: AppConfirmationCoordinator(),
            askUser: AskUserCoordinator(),
            modelReadiness: modelReadiness,
            modelMetrics: modelMetrics,
            localModelSelection: localModelSelection,
            remoteInferenceSettings: remoteInferenceSettings,
            auditLogger: auditLogger,
            auditLogReader: auditLogger,
            stepGenerator: LocalModelBootstrap.makeStepGenerator(
                readinessStore: modelReadiness,
                metricsStore: modelMetrics,
                memoryStore: memoryStore,
                localModelSelection: localModelSelection,
                remoteSettings: remoteInferenceSettings
            ),
            contextProvider: LuminaEmptyRuntimeContextProvider(),
            runtimeConfiguration: LuminaAgentRuntimeConfiguration(
                maximumToolCalls: 8,
                maximumReActIterations: 12,
                maximumObservationCharacters: 1_500,
                contextWindowTokens: 12_000,
                maxOutputTokens: 4_096,
                reservedOutputTokens: 256,
                toolResultTokenBudget: 1_024,
                compactThresholdTokens: 9_000,
                maximumCompactFailures: 3,
                maximumConsecutiveReasoningSteps: 3,
                maximumConsecutiveReplayObservations: 2,
                stopOnToolFailure: false,
                rollbackFailedSideEffects: true,
                emitVerboseEvents: true,
                preservedStepsAfterCompaction: 6
            )
        )
    }
}
