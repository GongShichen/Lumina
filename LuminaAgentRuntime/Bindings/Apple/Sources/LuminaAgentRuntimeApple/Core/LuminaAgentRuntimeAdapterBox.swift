import Foundation

final class LuminaAgentRuntimeAdapterBox: @unchecked Sendable {
    let tools: [AnyLuminaAgentTool]
    let toolsByName: [String: AnyLuminaAgentTool]
    let stepGenerator: any LuminaReActStepGenerator
    let contextProvider: any LuminaRuntimeContextProvider
    let contextCompactor: any LuminaReActContextCompactor
    let configuration: LuminaAgentRuntimeConfiguration
    let permissionGate: any LuminaPermissionGate
    let confirmationCoordinator: any LuminaConfirmationCoordinator
    let auditLogger: any LuminaAuditLogger
    let hooks: [any LuminaAgentRuntimeHook]
    var currentEventSink: (@Sendable (LuminaAgentRunEvent) -> Void)?
    var currentRequest: LuminaAgentRequest?
    var trace = LuminaReActTrace()
    var toolResults: [LuminaToolResult] = []
    var hookContextSections: [LuminaRuntimeContextSection] = []
    var timingStartedAt: ContinuousClock.Instant?
    var stepGenerationMilliseconds: Double = 0
    var toolExecutionMilliseconds: Double = 0
    private let cancellationLock = NSLock()
    private var cancellationRequested = false

    init(
        tools: [AnyLuminaAgentTool],
        stepGenerator: any LuminaReActStepGenerator,
        contextProvider: any LuminaRuntimeContextProvider,
        contextCompactor: any LuminaReActContextCompactor,
        configuration: LuminaAgentRuntimeConfiguration,
        permissionGate: any LuminaPermissionGate,
        confirmationCoordinator: any LuminaConfirmationCoordinator,
        auditLogger: any LuminaAuditLogger,
        hooks: [any LuminaAgentRuntimeHook]
    ) {
        self.tools = tools
        self.toolsByName = Dictionary(uniqueKeysWithValues: tools.map { ($0.schema.name, $0) })
        self.stepGenerator = stepGenerator
        self.contextProvider = contextProvider
        self.contextCompactor = contextCompactor
        self.configuration = configuration
        self.permissionGate = permissionGate
        self.confirmationCoordinator = confirmationCoordinator
        self.auditLogger = auditLogger
        self.hooks = hooks
    }

    func requestCancellation() {
        cancellationLock.lock()
        cancellationRequested = true
        cancellationLock.unlock()
    }

    func resetCancellation() {
        cancellationLock.lock()
        cancellationRequested = false
        cancellationLock.unlock()
    }

    func isCancellationRequested() -> Bool {
        cancellationLock.lock()
        defer { cancellationLock.unlock() }
        return cancellationRequested
    }

    func makeRunResult(fromRuntimeResultJSON json: String, request: LuminaAgentRequest) -> LuminaAgentRunResult {
        let object = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
        let statusText = object?["status"] as? String
        let status = LuminaAgentRunStatus(rawValue: statusText ?? "") ?? ((object?["ok"] as? Bool) == false ? .failed : .succeeded)
        let finalMarkdown = (object?["finalMarkdown"] as? String) ?? trace.steps.last?.finalMarkdown ?? "### 执行结束"
        var finalTrace = trace
        if finalTrace.terminationReason == nil,
           let terminationReason = object?["terminationReason"] as? String,
           !terminationReason.isEmpty {
            finalTrace.terminationReason = terminationReason == "iteration-budget" ? "budget" : terminationReason
        }
        let timing = LuminaRuntimeTiming(
            stepGenerationMilliseconds: stepGenerationMilliseconds,
            toolExecutionMilliseconds: toolExecutionMilliseconds,
            totalMilliseconds: timingStartedAt.map { LuminaRuntimeClock.milliseconds(since: $0) } ?? 0
        )
        return LuminaAgentRunResult(
            requestID: request.id,
            plan: LuminaAgentPlan(summary: finalMarkdown, toolCalls: trace.steps.compactMap(\.action)),
            toolResults: toolResults,
            status: status,
            timing: timing,
            reactTrace: finalTrace
        )
    }
}
