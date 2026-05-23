import AgentRuntime
import Combine
import Foundation
import PersonalMemory

@MainActor
final class AgentAppServices: ObservableObject {
    let memoryStore: MemoryStore
    let ledgerStore: LedgerStore
    let subscriptionStore: SubscriptionStore
    let messageDrafts: MessageDraftCenter
    let confirmation: AppConfirmationCoordinator
    let auditLogger: any AuditLogger
    private let environment: AppEnvironment

    private(set) lazy var runtime: AgentRuntime = {
        AgentRuntime(
            tools: AppToolFactory.makeTools(
                memoryStore: memoryStore,
                ledgerStore: ledgerStore,
                subscriptionStore: subscriptionStore,
                messageDrafts: messageDrafts
            ),
            planner: environment.planner,
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
        self.auditLogger = environment.auditLogger
        Task {
            try? await memoryStore.load()
            await seedDemoMemory()
        }
    }

    func run(_ text: String) async -> AgentRunResult {
        await runtime.run(request: AgentRequest(text: text))
    }

    func run(content: [AgentContentPart]) async -> AgentRunResult {
        await runtime.run(request: AgentRequest(content: content))
    }

    func runStream(content: [AgentContentPart]) -> AsyncStream<AgentRunEvent> {
        runtime.runStream(request: AgentRequest(content: content))
    }

    private func seedDemoMemory() async {
        await memoryStore.ingest(MemoryDocument(
            source: MemorySource(kind: .appNote, identifier: "welcome"),
            title: "Agent Runtime MVP",
            body: "这个 App 演示本地优先 Agent：先检索本地记忆，再经过权限 gate 和用户确认调用 App 工具。",
            sensitivity: .normal
        ))
    }
}
