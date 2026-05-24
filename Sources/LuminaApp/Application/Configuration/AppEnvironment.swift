import AgentRuntime
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
    var auditLogger: any LuminaAuditLogger
    var auditLogReader: (any LuminaAuditLogReader)?
    var reactPlanner: any LuminaReActPlanner
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
            auditLogger: auditLogger,
            auditLogReader: auditLogger,
            reactPlanner: LocalModelBootstrap.makePlanner(readinessStore: modelReadiness, metricsStore: modelMetrics, memoryStore: memoryStore),
            contextProvider: LuminaAppContextProvider(memoryStore: memoryStore),
            runtimeConfiguration: LuminaAgentRuntimeConfiguration(
                maximumToolCalls: 8,
                stopOnToolFailure: false,
                rollbackFailedSideEffects: true,
                emitVerboseEvents: true
            )
        )
    }
}
