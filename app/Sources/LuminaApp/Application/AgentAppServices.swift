import LuminaAgentRuntime
import Combine
import Foundation
import LuminaAppCore
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
    let localModelSelection: LuminaLocalModelSelectionStore
    let remoteInferenceSettings: LuminaRemoteInferenceSettingsStore
    let auditLogger: any LuminaAuditLogger
    let auditLogReader: (any LuminaAuditLogReader)?
    let evaluationCalendarStore = LuminaVolatileCalendarStore()
    private let environment: AppEnvironment
    private let loadTask: Task<Void, Never>

    private(set) lazy var runtime: LuminaAgentRuntime = {
        makeRuntime(
            tools: allAppTools(),
            contextProvider: environment.contextProvider
        )
    }()

    private(set) lazy var homeRuntime: LuminaAgentRuntime = {
        let allowedHomeTools: Set<String> = ["device.current_time", "memory.stats", "memory.recent"]
        let tools = allAppTools().filter { allowedHomeTools.contains($0.schema.name) }
        return makeRuntime(tools: tools, contextProvider: LuminaEmptyRuntimeContextProvider())
    }()

    private(set) lazy var evaluationRuntime: LuminaAgentRuntime = {
        let tools = AppToolFactory.makeEvaluationTools(
            memoryStore: memoryStore,
            ledgerStore: ledgerStore,
            subscriptionStore: subscriptionStore,
            messageDrafts: messageDrafts,
            calendarStore: evaluationCalendarStore
        )
        var configuration = environment.runtimeConfiguration
        configuration.stopOnToolFailure = true
        configuration.maximumConsecutiveReplayObservations = 3
        return makeRuntime(
            tools: tools,
            contextProvider: LuminaEmptyRuntimeContextProvider(),
            confirmationCoordinator: LuminaAlwaysConfirmCoordinator(),
            configuration: configuration
        )
    }()

    private func allAppTools() -> [AnyLuminaAgentTool] {
        AppToolFactory.makeTools(
            memoryStore: memoryStore,
            ledgerStore: ledgerStore,
            subscriptionStore: subscriptionStore,
            messageDrafts: messageDrafts,
            askUser: askUser
        )
    }

    private func makeRuntime(
        tools: [AnyLuminaAgentTool],
        contextProvider: any LuminaRuntimeContextProvider,
        confirmationCoordinator: (any LuminaConfirmationCoordinator)? = nil,
        configuration: LuminaAgentRuntimeConfiguration? = nil
    ) -> LuminaAgentRuntime {
        LuminaAgentRuntime(
            tools: tools,
            stepGenerator: environment.stepGenerator,
            contextProvider: contextProvider,
            configuration: configuration ?? environment.runtimeConfiguration,
            permissionGate: LuminaAppRuntimePermissionGate(),
            confirmationCoordinator: confirmationCoordinator ?? confirmation,
            auditLogger: auditLogger,
            hooks: [LuminaAppMemoryPolicyRuntimeHook()]
        )
    }

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
        self.localModelSelection = environment.localModelSelection
        self.remoteInferenceSettings = environment.remoteInferenceSettings
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
        await runtime.run(request: LuminaAgentRequest(systemInstructions: LuminaAppSystemInstructions.taskExecution, text: text))
    }

    func run(content: [LuminaAgentContentPart]) async -> LuminaAgentRunResult {
        await runtime.run(request: LuminaAgentRequest(systemInstructions: LuminaAppSystemInstructions.taskExecution, content: content))
    }

    func runStream(content: [LuminaAgentContentPart]) -> AsyncStream<LuminaAgentRunEvent> {
        runtime.runStream(request: LuminaAgentRequest(systemInstructions: LuminaAppSystemInstructions.taskExecution, content: content))
    }

    func runEvaluationStream(content: [LuminaAgentContentPart]) -> AsyncStream<LuminaAgentRunEvent> {
        evaluationRuntime.runStream(request: LuminaAgentRequest(
            systemInstructions: LuminaAppSystemInstructions.evaluation,
            content: content,
            metadata: [
                LuminaAppContextProvider.disableMemoryContextMetadataKey: .bool(true),
                "lumina.evaluation.memory_access_disabled": .bool(true),
                "lumina.evaluation.ask_user_disabled": .bool(true)
            ]
        ))
    }

    func makeBenchmarkRunner() -> LuminaInAppBenchmarkRunner {
        let reports = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("BenchmarkReports", isDirectory: true)
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("BenchmarkReports", isDirectory: true)
        return LuminaInAppBenchmarkRunner(services: self, reportDirectory: reports)
    }

    func makeAgenticRLRunner() -> LuminaInAppAgenticRLRunner {
        let reports = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("TrajectoryReports", isDirectory: true)
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("TrajectoryReports", isDirectory: true)
        return LuminaInAppAgenticRLRunner(services: self, reportDirectory: reports)
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
