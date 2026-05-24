import AgentRuntime
import Combine
import Foundation
import PersonalMemory

@MainActor
final class AgentAppServices: ObservableObject {
    let memoryStore: LuminaMemoryStore
    let ledgerStore: LuminaLedgerStore
    let subscriptionStore: LuminaSubscriptionStore
    let messageDrafts: LuminaMessageDraftCenter
    let confirmation: AppConfirmationCoordinator
    let askUser: AskUserCoordinator
    let modelReadiness: LuminaModelReadinessStore
    let modelMetrics: LuminaModelInferenceMetricsStore
    let auditLogger: any LuminaAuditLogger
    let auditLogReader: (any LuminaAuditLogReader)?
    private let environment: AppEnvironment
    private let loadTask: Task<Void, Never>

    private(set) lazy var runtime: LuminaAgentRuntime = {
        LuminaAgentRuntime(
            tools: AppToolFactory.makeTools(
                memoryStore: memoryStore,
                ledgerStore: ledgerStore,
                subscriptionStore: subscriptionStore,
                messageDrafts: messageDrafts,
                askUser: askUser
            ),
            reactPlanner: environment.reactPlanner,
            contextProvider: environment.contextProvider,
            configuration: environment.runtimeConfiguration,
            confirmationCoordinator: confirmation,
            auditLogger: auditLogger
        )
    }()

    init(environment: AppEnvironment = .live()) {
        self.environment = environment
        self.memoryStore = environment.memoryStore
        self.ledgerStore = environment.ledgerStore
        self.subscriptionStore = environment.subscriptionStore
        self.messageDrafts = environment.messageDrafts
        self.confirmation = environment.confirmation
        self.askUser = environment.askUser
        self.modelReadiness = environment.modelReadiness
        self.modelMetrics = environment.modelMetrics
        self.auditLogger = environment.auditLogger
        self.auditLogReader = environment.auditLogReader
        let memoryStore = environment.memoryStore
        let ledgerStore = environment.ledgerStore
        let subscriptionStore = environment.subscriptionStore
        self.loadTask = Task {
            try? await memoryStore.load()
            try? await ledgerStore.load()
            try? await subscriptionStore.load()
            await Self.removeLegacyWelcomeMemory(from: memoryStore)
        }
    }

    func waitUntilLoaded() async {
        await loadTask.value
    }

    func beginSession() {
        confirmation.resetForNewSession()
        askUser.resetForNewSession()
    }

    func run(_ text: String) async -> LuminaAgentRunResult {
        await runtime.run(request: LuminaAgentRequest(text: text))
    }

    func run(content: [LuminaAgentContentPart]) async -> LuminaAgentRunResult {
        await runtime.run(request: LuminaAgentRequest(content: content))
    }

    func runStream(content: [LuminaAgentContentPart]) -> AsyncStream<LuminaAgentRunEvent> {
        runtime.runStream(request: LuminaAgentRequest(content: content))
    }

    func makeBenchmarkRunner() -> LuminaInAppBenchmarkRunner {
        let reports = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("BenchmarkReports", isDirectory: true)
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("BenchmarkReports", isDirectory: true)
        return LuminaInAppBenchmarkRunner(services: self, reportDirectory: reports)
    }

    func recentAuditRecords(limit: Int = 20) async -> [LuminaAuditRecord] {
        guard let auditLogReader else { return [] }
        return await auditLogReader.recentRecords(limit: limit)
    }

    private static func removeLegacyWelcomeMemory(from memoryStore: LuminaMemoryStore) async {
        let chunks = await memoryStore.recentChunks(limit: 1_000, maximumSensitivity: .privateData)
        for chunk in chunks where chunk.source.kind == .appNote && chunk.source.identifier == "welcome" {
            _ = await memoryStore.removeChunk(id: chunk.id)
        }
    }
}
