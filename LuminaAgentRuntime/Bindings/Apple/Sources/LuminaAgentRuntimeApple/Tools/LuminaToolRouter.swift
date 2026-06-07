import Foundation

public actor LuminaToolRouter {
    private var toolsByName: [String: AnyLuminaAgentTool]
    private let permissionGate: any LuminaPermissionGate
    private let confirmationCoordinator: any LuminaConfirmationCoordinator
    private let auditLogger: any LuminaAuditLogger

    public init(
        tools: [AnyLuminaAgentTool],
        permissionGate: any LuminaPermissionGate = LuminaDefaultPermissionGate(),
        confirmationCoordinator: any LuminaConfirmationCoordinator = LuminaAlwaysConfirmCoordinator(),
        auditLogger: any LuminaAuditLogger = LuminaInMemoryAuditLogger()
    ) {
        self.toolsByName = Dictionary(uniqueKeysWithValues: tools.map { ($0.schema.name, $0) })
        self.permissionGate = permissionGate
        self.confirmationCoordinator = confirmationCoordinator
        self.auditLogger = auditLogger
    }

    public func schemas() -> [LuminaToolSchema] {
        toolsByName.values.map(\.schema).sorted { $0.name < $1.name }
    }

    public func execute(call: LuminaToolCall, request: LuminaAgentRequest) async -> (LuminaToolResult, LuminaPermissionDecision, Bool) {
        await execute(call: call, request: request, eventSink: nil)
    }

    public func execute(
        call: LuminaToolCall,
        request: LuminaAgentRequest,
        eventSink: (@Sendable (LuminaAgentRunEvent) -> Void)?
    ) async -> (LuminaToolResult, LuminaPermissionDecision, Bool) {
        guard let tool = toolsByName[call.toolName] else {
            let result = LuminaToolResult(
                callID: call.id,
                toolName: call.toolName,
                status: .failed,
                errorMessage: "Unknown tool: \(call.toolName)"
            )
            return (result, .denied(reason: "Unknown tool"), false)
        }

        let schema = tool.schema
        if let validationError = Self.validate(call.arguments, against: schema) {
            let result = LuminaToolResult(
                callID: call.id,
                toolName: call.toolName,
                status: .failed,
                output: ["summary": .string(validationError)],
                content: [.text(validationError)],
                errorMessage: validationError
            )
            return (result, .denied(reason: validationError), false)
        }
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
                let result = LuminaToolResult(callID: call.id, toolName: call.toolName, status: .denied, errorMessage: "User denied confirmation.")
                await audit(request: request, call: call, schema: schema, decision: decision, confirmed: false, result: result)
                return (result, decision, false)
            }
        case let .denied(reason):
            let result = LuminaToolResult(callID: call.id, toolName: call.toolName, status: .denied, errorMessage: reason)
            await audit(request: request, call: call, schema: schema, decision: decision, confirmed: false, result: result)
            return (result, decision, false)
        }

        do {
            try Task.checkCancellation()
            eventSink?(.toolStarted(call))
            let toolResult = try await tool.call(
                context: LuminaToolExecutionContext(request: request, call: call, schema: schema),
                cancellation: LuminaCancellationToken()
            )
            let result = normalized(toolResult, for: call, schema: schema)
            await audit(request: request, call: call, schema: schema, decision: decision, confirmed: confirmed, result: result)
            eventSink?(.toolFinished(result))
            return (result, decision, confirmed)
        } catch is CancellationError {
            let result = LuminaToolResult(callID: call.id, toolName: call.toolName, status: .cancelled, errorMessage: "Cancelled")
            await audit(request: request, call: call, schema: schema, decision: decision, confirmed: confirmed, result: result)
            eventSink?(.toolFinished(result))
            return (result, decision, confirmed)
        } catch {
            let result = LuminaToolResult(callID: call.id, toolName: call.toolName, status: .failed, errorMessage: (error as NSError).localizedDescription)
            await audit(request: request, call: call, schema: schema, decision: decision, confirmed: confirmed, result: result)
            eventSink?(.toolFinished(result))
            return (result, decision, confirmed)
        }
    }

    public func rollback(call: LuminaToolCall, result: LuminaToolResult) async -> Bool {
        guard let tool = toolsByName[call.toolName] else { return false }
        return await tool.rollback(result: result)
    }

    private func cachedDecision(for call: LuminaToolCall, schema: LuminaToolSchema, request: LuminaAgentRequest) async -> LuminaPermissionDecision {
        await permissionGate.decision(for: call, schema: schema, request: request)
    }

    private func audit(
        request: LuminaAgentRequest,
        call: LuminaToolCall,
        schema: LuminaToolSchema,
        decision: LuminaPermissionDecision,
        confirmed: Bool,
        result: LuminaToolResult
    ) async {
        let record = LuminaAuditRecord(
            requestID: request.id,
            toolName: call.toolName,
            schemaVersion: schema.version,
            arguments: LuminaAuditRedactor.redact(arguments: call.arguments, schema: schema),
            permission: String(describing: decision),
            confirmed: confirmed,
            resultStatus: result.status,
            outputSummary: result.output.keys.sorted().joined(separator: ","),
            errorMessage: result.errorMessage
        )
        await auditLogger.append(record)
    }

    private func normalized(_ result: LuminaToolResult, for call: LuminaToolCall, schema: LuminaToolSchema) -> LuminaToolResult {
        LuminaToolResult(
            callID: call.id,
            toolName: schema.name,
            status: result.status,
            output: result.output,
            content: result.content,
            errorMessage: result.errorMessage,
            rollbackToken: result.rollbackToken
        )
    }

    private static func validate(_ arguments: [String: LuminaJSONValue], against schema: LuminaToolSchema) -> String? {
        for parameter in schema.parameters {
            guard let value = arguments[parameter.name] else {
                if parameter.required {
                    return "missing required parameter \(parameter.name)"
                }
                continue
            }
            if !matches(value, parameter.type) {
                return "parameter \(parameter.name) has invalid type"
            }
        }
        return nil
    }

    private static func matches(_ value: LuminaJSONValue, _ type: LuminaToolParameterType) -> Bool {
        switch (type, value) {
        case (.string, .string),
             (.number, .number),
             (.bool, .bool),
             (.object, .object),
             (.array, .array):
            return true
        case (.dateISO8601, .string):
            return true
        default:
            return false
        }
    }
}
