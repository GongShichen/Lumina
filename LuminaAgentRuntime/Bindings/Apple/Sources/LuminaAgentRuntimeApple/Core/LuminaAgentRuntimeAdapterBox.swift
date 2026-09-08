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
    let observabilitySinks: LuminaRuntimeObservabilitySinks
    let guardrails: LuminaRuntimeGuardrails
    let retryProvider: (any LuminaRuntimeRetryProvider)?
    let contextLoadingPlugin: (any LuminaContextLoadingPlugin)?
    let toolLoadingPlugin: (any LuminaToolLoadingPlugin)?
    let sessionHistoryStore: (any LuminaSessionHistoryStore)?
    var currentEventSink: (@Sendable (LuminaAgentRunEvent) -> Void)?
    var currentRequest: LuminaAgentRequest?
    var trace = LuminaReActTrace()
    var toolResults: [LuminaToolResult] = []
    // C++ call IDs are authoritative and need not be UUID strings.
    var runtimeCallIDs: [String: UUID] = [:]
    var toolResultIndices: [String: Int] = [:]
    var timingStartedAt: ContinuousClock.Instant?
    var stepGenerationMilliseconds: Double = 0
    var toolExecutionMilliseconds: Double = 0
    var registeredSkillMetadataCount = 0
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
        hooks: [any LuminaAgentRuntimeHook],
        observabilitySinks: LuminaRuntimeObservabilitySinks,
        guardrails: LuminaRuntimeGuardrails,
        retryProvider: (any LuminaRuntimeRetryProvider)?,
        contextLoadingPlugin: (any LuminaContextLoadingPlugin)?,
        toolLoadingPlugin: (any LuminaToolLoadingPlugin)?,
        sessionHistoryStore: (any LuminaSessionHistoryStore)?
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
        self.observabilitySinks = observabilitySinks
        self.guardrails = guardrails
        self.retryProvider = retryProvider
        self.contextLoadingPlugin = contextLoadingPlugin
        self.toolLoadingPlugin = toolLoadingPlugin
        self.sessionHistoryStore = sessionHistoryStore
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

    func modelVisibleToolSchemas() -> [LuminaToolSchema] {
        var schemas = tools.map(\.schema)
        let hostToolNames = Set(schemas.map(\.name))
        let builtinSchemas = Self.runtimeDiscoveryToolSchemas(includeSkillDiscovery: registeredSkillMetadataCount > 0 || hostToolNames.contains("Skill"))
        for schema in builtinSchemas where !hostToolNames.contains(schema.name) {
            schemas.append(schema)
        }
        return schemas
    }

    func modelVisibleToolSchema(named name: String) -> LuminaToolSchema? {
        if let tool = toolsByName[name] {
            return tool.schema
        }
        return modelVisibleToolSchemas().first { $0.name == name }
    }

    private static func runtimeDiscoveryToolSchemas(includeSkillDiscovery: Bool) -> [LuminaToolSchema] {
        var schemas: [LuminaToolSchema] = []
        if includeSkillDiscovery {
            schemas.append(LuminaToolSchema(
                name: "runtime.skill_discovery",
                description: "Discover available local skills. Use this before invoking Skill when the task may match a skill but the exact canonical skill name is uncertain.",
                parameters: [
                    LuminaToolParameterSchema(name: "query", type: .string, description: "Skill search query or select:canonical-skill-name.", required: false),
                    LuminaToolParameterSchema(name: "max_results", type: .number, description: "Maximum number of skill matches.", required: false)
                ],
                sideEffect: .readOnly,
                sensitivity: .normal,
                destructive: false,
                concurrencySafe: true,
                alwaysLoad: true,
                deferByDefault: false,
                requiresConfirmation: false
            ))
        }
        schemas.append(LuminaToolSchema(
            name: "runtime.mcp_discovery",
            description: "Discover MCP-style external provider tools and load selected deferred schemas for this session.",
            parameters: [
                LuminaToolParameterSchema(name: "query", type: .string, description: "MCP tool search query or select:mcp.tool-name.", required: false),
                LuminaToolParameterSchema(name: "max_results", type: .number, description: "Maximum number of MCP tool matches.", required: false),
                LuminaToolParameterSchema(name: "include_schemas", type: .bool, description: "Whether matching deferred schemas should be loaded for this session.", required: false)
            ],
            sideEffect: .readOnly,
            sensitivity: .normal,
            destructive: false,
            concurrencySafe: true,
            alwaysLoad: true,
            deferByDefault: false,
            requiresConfirmation: false
        ))
        return schemas
    }

    func makeRunResult(fromRuntimeResultJSON json: String, request: LuminaAgentRequest) -> LuminaAgentRunResult {
        let object = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
        let statusText = object?["status"] as? String
        let status = LuminaAgentRunStatus(rawValue: statusText ?? "") ?? ((object?["ok"] as? Bool) == false ? .failed : .succeeded)
        let resultMarkdown = (object?["resultMarkdown"] as? String) ?? trace.steps.last?.resultMarkdown ?? "### 执行结束"
        var finalTrace = trace
        if let actionCount = object?["actionCount"] as? Int {
            finalTrace.consumedToolCallCount = actionCount
        }
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
            plan: LuminaAgentPlan(summary: resultMarkdown, toolCalls: trace.steps.flatMap { step in
                step.kind == .multiAction ? step.toolCalls : step.action.map { [$0] } ?? []
            }),
            toolResults: toolResults,
            status: status,
            timing: timing,
            reactTrace: finalTrace
        )
    }
}
