import AgentRuntime
import Foundation
import PersonalMemory

struct AppEnvironment {
    var memoryStore: MemoryStore
    var ledgerStore: LedgerStore
    var subscriptionStore: SubscriptionStore
    var messageDrafts: MessageDraftCenter
    var confirmation: AppConfirmationCoordinator
    var auditLogger: any AuditLogger
    var planner: any Planner
    var runtimeConfiguration: AgentRuntimeConfiguration

    @MainActor
    static func live() -> AppEnvironment {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("Lumina", isDirectory: true)
            ?? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Lumina", isDirectory: true)

        let memoryRepository = JSONMemoryRepository(url: appSupport.appendingPathComponent("memory-index.json"))
        let memoryStore = MemoryStore(
            embeddingProvider: LocalModelBootstrap.makeEmbeddingProvider(),
            repository: memoryRepository,
            configuration: MemoryStoreConfiguration(
                cacheLimit: 32,
                maximumVectorCandidates: 2_000,
                embedImmediately: false,
                persistAfterIngest: true,
                persistAfterEmbedding: false
            )
        )

        return AppEnvironment(
            memoryStore: memoryStore,
            ledgerStore: LedgerStore(),
            subscriptionStore: SubscriptionStore(),
            messageDrafts: MessageDraftCenter(),
            confirmation: AppConfirmationCoordinator(),
            auditLogger: JSONLAuditLogger(url: appSupport.appendingPathComponent("audit.jsonl")),
            planner: LocalModelBootstrap.makePlanner(),
            runtimeConfiguration: AgentRuntimeConfiguration(
                maximumToolCalls: 8,
                stopOnToolFailure: false,
                rollbackFailedSideEffects: true,
                emitVerboseEvents: true
            )
        )
    }
}

