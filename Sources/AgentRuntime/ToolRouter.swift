import Foundation

public actor ToolRouter {
    private var toolsByName: [String: AnyAgentTool]
    private let permissionGate: any PermissionGate
    private let confirmationCoordinator: any ConfirmationCoordinator
    private let auditLogger: any AuditLogger
    private var permissionCache: [String: PermissionDecision] = [:]

    public init(
        tools: [AnyAgentTool],
        permissionGate: any PermissionGate = DefaultPermissionGate(),
        confirmationCoordinator: any ConfirmationCoordinator = AlwaysConfirmCoordinator(),
        auditLogger: any AuditLogger = InMemoryAuditLogger()
    ) {
        self.toolsByName = Dictionary(uniqueKeysWithValues: tools.map { ($0.schema.name, $0) })
        self.permissionGate = permissionGate
        self.confirmationCoordinator = confirmationCoordinator
        self.auditLogger = auditLogger
    }

    public func schemas() -> [ToolSchema] {
        toolsByName.values.map(\.schema).sorted { $0.name < $1.name }
    }

    public func execute(call: ToolCall, request: AgentRequest) async -> (ToolResult, PermissionDecision, Bool) {
        await execute(call: call, request: request, eventSink: nil)
    }

    public func execute(
        call: ToolCall,
        request: AgentRequest,
        eventSink: (@Sendable (AgentRunEvent) -> Void)?
    ) async -> (ToolResult, PermissionDecision, Bool) {
        guard let tool = toolsByName[call.toolName] else {
            let result = ToolResult(
                callID: call.id,
                toolName: call.toolName,
                status: .failed,
                errorMessage: "Unknown tool: \(call.toolName)"
            )
            return (result, .denied(reason: "Unknown tool"), false)
        }

        let schema = tool.schema
        let decision = await cachedDecision(for: call, schema: schema, request: request)
        eventSink?(.permissionChecked(call, decision))
        var confirmed = false

        switch decision {
        case .allowed:
            break
        case let .requiresConfirmation(reason):
            eventSink?(.confirmationRequired(call))
            confirmed = await confirmationCoordinator.confirm(call: call, schema: schema, reason: reason)
            eventSink?(.confirmationResolved(call, confirmed))
            guard confirmed else {
                let result = ToolResult(callID: call.id, toolName: call.toolName, status: .denied, errorMessage: "User denied confirmation.")
                await audit(request: request, call: call, schema: schema, decision: decision, confirmed: false, result: result)
                return (result, decision, false)
            }
        case let .denied(reason):
            let result = ToolResult(callID: call.id, toolName: call.toolName, status: .denied, errorMessage: reason)
            await audit(request: request, call: call, schema: schema, decision: decision, confirmed: false, result: result)
            return (result, decision, false)
        }

        do {
            try Task.checkCancellation()
            eventSink?(.toolStarted(call))
            let toolResult = try await tool.call(
                context: ToolExecutionContext(request: request, call: call, schema: schema),
                cancellation: CancellationToken()
            )
            let result = normalized(toolResult, for: call, schema: schema)
            await audit(request: request, call: call, schema: schema, decision: decision, confirmed: confirmed, result: result)
            eventSink?(.toolFinished(result))
            return (result, decision, confirmed)
        } catch is CancellationError {
            let result = ToolResult(callID: call.id, toolName: call.toolName, status: .cancelled, errorMessage: "Cancelled")
            await audit(request: request, call: call, schema: schema, decision: decision, confirmed: confirmed, result: result)
            eventSink?(.toolFinished(result))
            return (result, decision, confirmed)
        } catch {
            let result = ToolResult(callID: call.id, toolName: call.toolName, status: .failed, errorMessage: String(describing: error))
            await audit(request: request, call: call, schema: schema, decision: decision, confirmed: confirmed, result: result)
            eventSink?(.toolFinished(result))
            return (result, decision, confirmed)
        }
    }

    public func rollback(call: ToolCall, result: ToolResult) async -> Bool {
        guard let tool = toolsByName[call.toolName] else { return false }
        return await tool.rollback(result: result)
    }

    private func cachedDecision(for call: ToolCall, schema: ToolSchema, request: AgentRequest) async -> PermissionDecision {
        let key = "\(schema.name)#\(schema.version)#\(schema.sideEffect.rawValue)"
        if let cached = permissionCache[key] {
            return cached
        }
        let decision = await permissionGate.decision(for: call, schema: schema, request: request)
        if case .allowed = decision {
            permissionCache[key] = decision
        }
        return decision
    }

    private func audit(
        request: AgentRequest,
        call: ToolCall,
        schema: ToolSchema,
        decision: PermissionDecision,
        confirmed: Bool,
        result: ToolResult
    ) async {
        let record = AuditRecord(
            requestID: request.id,
            toolName: call.toolName,
            schemaVersion: schema.version,
            arguments: AuditRedactor.redact(arguments: call.arguments, schema: schema),
            permission: String(describing: decision),
            confirmed: confirmed,
            resultStatus: result.status,
            outputSummary: result.output.keys.sorted().joined(separator: ","),
            errorMessage: result.errorMessage
        )
        await auditLogger.append(record)
    }

    private func normalized(_ result: ToolResult, for call: ToolCall, schema: ToolSchema) -> ToolResult {
        ToolResult(
            callID: call.id,
            toolName: schema.name,
            status: result.status,
            output: result.output,
            content: result.content,
            errorMessage: result.errorMessage,
            rollbackToken: result.rollbackToken
        )
    }
}
