import Foundation

extension LuminaAgentRuntimeClientBox {
    func generateStepJSON(
        plannerInputJSON: String,
        streamEmit: (@Sendable (LuminaStepGenerationProgress) -> Bool)? = nil
    ) async -> String {
        do {
            let context = try await makeStepContext(plannerInputJSON: plannerInputJSON, streamEmit: streamEmit)
            let step = try await stepGenerator.nextStep(context: context)
            return step.runtimeTransportJSON
        } catch {
            return #"{"type":"cannot_complete","thought":"model callback failed","reason":"\#(Self.escape(error.localizedDescription))"}"#
        }
    }

    func executeTool(callJSON: String) async -> String {
        do {
            let parsed = try Self.parseToolCall(callJSON)
            guard let tool = toolsByName[parsed.toolName] else {
                return #"{"status":"failed","content":"","errorMessage":"tool is not registered"}"#
            }
            let request = currentRequest ?? LuminaAgentRequest(text: "")
            let schema = tool.schema
            let call = LuminaToolCall(toolName: parsed.toolName, arguments: parsed.arguments, requiresConfirmation: parsed.requiresConfirmation)
            let context = LuminaToolExecutionContext(request: request, call: call, schema: schema)
            currentEventSink?(.toolStarted(call))
            let result = try await tool.call(context: context, cancellation: LuminaCancellationToken())
            toolResults.append(result)
            currentEventSink?(.toolFinished(result))
            let content = result.content.compactMap(\.textForModelInput).joined(separator: "\n")
            return Self.toolResultJSON(status: result.status.rawValue, content: content, errorMessage: result.errorMessage)
        } catch {
            return Self.toolResultJSON(status: "failed", content: "", errorMessage: error.localizedDescription)
        }
    }

    func loadContext(requestJSON: String) async -> String {
        do {
            let request = try Self.decodeRequest(fromRuntimeJSON: requestJSON)
            let runtimeRequest = LuminaRuntimeContextRequest(
                request: request,
                availableTools: tools.map(\.schema),
                trace: trace,
                iteration: trace.steps.count,
                remainingToolCalls: max(0, configuration.maximumToolCalls - trace.actionCount),
                maximumCharacters: configuration.maximumObservationCharacters
            )
            let context = try await contextProvider.loadContext(runtimeRequest)
            return (try? String(data: JSONEncoder().encode(context), encoding: .utf8)) ?? "null"
        } catch {
            return "null"
        }
    }

    func decidePermission(permissionJSON: String) async -> String {
        do {
            let parsed = try Self.parseToolCall(permissionJSON)
            guard let tool = toolsByName[parsed.toolName] else {
                return #"{"decision":"denied","reason":"tool is not registered"}"#
            }
            let call = LuminaToolCall(toolName: parsed.toolName, arguments: parsed.arguments, requiresConfirmation: parsed.requiresConfirmation)
            let request = currentRequest ?? LuminaAgentRequest(text: "")
            let decision = await permissionGate.decision(for: call, schema: tool.schema, request: request)
            currentEventSink?(.permissionChecked(call, decision))
            switch decision {
            case .allowed:
                return #"{"decision":"allowed"}"#
            case let .requiresConfirmation(reason):
                return #"{"decision":"requires_confirmation","reason":"\#(Self.escape(reason))"}"#
            case let .denied(reason):
                return #"{"decision":"denied","reason":"\#(Self.escape(reason))"}"#
            }
        } catch {
            return #"{"decision":"denied","reason":"\#(Self.escape(error.localizedDescription))"}"#
        }
    }

    func confirm(confirmationJSON: String) async -> String {
        do {
            let parsed = try Self.parseToolCall(confirmationJSON)
            guard let tool = toolsByName[parsed.toolName] else {
                return #"{"confirmed":false,"reason":"tool is not registered"}"#
            }
            let call = LuminaToolCall(toolName: parsed.toolName, arguments: parsed.arguments, requiresConfirmation: true)
            currentEventSink?(.confirmationRequired(call))
            let confirmed = await confirmationCoordinator.confirm(call: call, schema: tool.schema, reason: "Lumina 需要执行 \(tool.schema.name)")
            currentEventSink?(.confirmationResolved(call, confirmed))
            return #"{"confirmed":\#(confirmed)}"#
        } catch {
            return #"{"confirmed":false,"reason":"\#(Self.escape(error.localizedDescription))"}"#
        }
    }

    func writeAudit(auditJSON: String) async {
        let record = LuminaAuditRecord(
            requestID: currentRequest?.id ?? UUID(),
            toolName: "runtime",
            schemaVersion: 1,
            arguments: [:],
            permission: "runtime",
            confirmed: true,
            resultStatus: .succeeded,
            outputSummary: auditJSON
        )
        await auditLogger.append(record)
    }

    func dispatchHook(hookJSON: String) async -> String {
        currentEventSink?(.hookAnnotated("runtime", .string(hookJSON)))
        guard !hooks.isEmpty else { return "{}" }
        let object = (try? JSONSerialization.jsonObject(with: Data(hookJSON.utf8))) as? [String: Any]
        let event = Self.hookEvent(from: object?["lifecycle"] as? String)
        let context = LuminaAgentRuntimeHookContext(
            request: currentRequest ?? LuminaAgentRequest(text: ""),
            availableTools: tools.map(\.schema),
            trace: trace
        )
        do {
            for hook in hooks {
                for directive in try await hook.handle(event: event, context: context) {
                    switch directive {
                    case let .appendContextSection(section):
                        hookContextSections.append(section)
                    case let .terminate(markdown, reason):
                        return #"{"terminate":true,"markdown":"\#(Self.escape(markdown))","reason":"\#(Self.escape(reason))"}"#
                    case let .annotate(key, value):
                        currentEventSink?(.hookAnnotated(key, value))
                    case .mergeRequestMetadata:
                        break
                    }
                }
            }
            return "{}"
        } catch {
            return "{\"terminate\":true,\"markdown\":\"### Hook failed\\n\\n\(Self.escape(error.localizedDescription))\",\"reason\":\"hook failed\"}"
        }
    }

    func consumeRuntimeEvent(eventJSON: String) {
        guard let data = eventJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String
        else { return }
        if type == "observation_created",
           let payload = object["payload"] as? [String: Any],
           let observation = Self.observationFromRuntimePayload(payload) {
            if trace.steps.last?.observation != observation {
                trace.steps.append(.observation(observation))
            }
            if !toolResults.contains(where: { $0.toolName == observation.toolName && $0.status == observation.status }) {
                toolResults.append(LuminaToolResult(
                    callID: UUID(),
                    toolName: observation.toolName,
                    status: observation.status,
                    output: [:],
                    content: [.text(observation.summary)],
                    errorMessage: observation.errorMessage
                ))
            }
            currentEventSink?(.observationCreated(observation))
        } else if type == "step_produced",
                  let payload = object["payload"] as? [String: Any],
                  let step = Self.stepFromRuntimePayload(payload) {
            trace.steps.append(step)
            switch step.kind {
            case .thought:
                currentEventSink?(.thoughtGenerated(step))
            case .action:
                if let call = step.action { currentEventSink?(.actionProposed(call)) }
            case .final:
                currentEventSink?(.finalGenerated(step.finalMarkdown ?? ""))
            case .observation:
                if let observation = step.observation { currentEventSink?(.observationCreated(observation)) }
            }
        }
    }

    func makeStepContext(
        plannerInputJSON: String,
        streamEmit: (@Sendable (LuminaStepGenerationProgress) -> Bool)? = nil
    ) async throws -> LuminaReActStepContext {
        let data = Data(plannerInputJSON.utf8)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let runtimeDebug = object?["runtime_debug"] as? [String: Any]
        let requestObject = (runtimeDebug?["raw_request"] as? [String: Any]) ?? (object?["request"] as? [String: Any])
        let request = try Self.decodeRequest(fromObject: requestObject) ?? (currentRequest ?? LuminaAgentRequest(text: ""))
        currentRequest = request
        var loadedContext = LuminaRuntimeContext.empty
        let contextEnvelope = object?["context"] as? [String: Any]
        if let loadedSections = contextEnvelope?["loaded_sections"],
           JSONSerialization.isValidJSONObject(["sections": loadedSections]),
           let contextData = try? JSONSerialization.data(withJSONObject: ["sections": loadedSections]),
           let context = try? JSONDecoder().decode(LuminaRuntimeContext.self, from: contextData) {
            loadedContext = context
        } else if let contextObject = object?["context"],
           JSONSerialization.isValidJSONObject(contextObject),
           let contextData = try? JSONSerialization.data(withJSONObject: contextObject),
           let context = try? JSONDecoder().decode(LuminaRuntimeContext.self, from: contextData) {
            loadedContext = context
        }
        if !hookContextSections.isEmpty {
            loadedContext.sections.append(contentsOf: hookContextSections)
        }
        let estimatedCharacters = LuminaReActContextWindowEstimator.estimateCharacters(
            request: request,
            schemas: tools.map(\.schema),
            trace: trace,
            loadedContext: loadedContext
        )
        let compactThreshold = Int(Double(configuration.contextWindowCharacterBudget) * configuration.autoCompactThreshold)
        if estimatedCharacters > compactThreshold {
            let compaction = try await contextCompactor.compact(LuminaReActCompactionRequest(
                agentRequest: request,
                trace: trace,
                loadedContext: loadedContext,
                availableTools: tools.map(\.schema),
                estimatedCharacters: estimatedCharacters,
                characterBudget: configuration.contextWindowCharacterBudget,
                preservedStepCount: configuration.preservedStepsAfterCompaction,
                maximumSummaryCharacters: configuration.maximumObservationCharacters
            ))
            if compaction.trace != trace {
                trace = compaction.trace
                if let observation = trace.steps.first?.observation,
                   observation.toolName == "runtime.context_compaction" {
                    currentEventSink?(.observationCreated(observation))
                }
            }
        }
        let budget = (object?["execution_budget"] as? [String: Any]) ?? (object?["budget"] as? [String: Any])
        let progress = object?["progress"] as? [String: Any]
        if let lastObservation = (progress?["last_observation"] as? [String: Any]) ?? (object?["last_observation"] as? [String: Any]),
           let observation = Self.observationFromRuntimePayload(lastObservation) {
            if trace.steps.last?.observation != observation {
                trace.steps.append(.observation(observation))
            }
        }
        let schemas = tools.map(\.schema)
        let iteration = budget?["iteration"] as? Int ?? trace.steps.count
        let remainingToolCalls = (budget?["remaining_tool_calls"] as? Int) ?? (budget?["remainingToolCalls"] as? Int) ?? max(0, configuration.maximumToolCalls - trace.actionCount)
        let progressSink: (@Sendable (LuminaStepGenerationProgress) -> Void)?
        if let eventSink = currentEventSink {
            progressSink = { progress in
                eventSink(.stepGenerationProgress(progress))
                if streamEmit?(progress) == false {
                    self.requestCancellation()
                }
            }
        } else {
            if let streamEmit {
                progressSink = { progress in
                    if streamEmit(progress) == false {
                        self.requestCancellation()
                    }
                }
            } else {
                progressSink = nil
            }
        }

        return LuminaReActStepContext(
            request: request,
            availableTools: schemas,
            trace: trace,
            loadedContext: loadedContext,
            iteration: iteration,
            remainingToolCalls: remainingToolCalls,
            maximumObservationCharacters: configuration.maximumObservationCharacters,
            progressSink: progressSink
        )
    }

    static func decodeRequest(fromRuntimeJSON json: String) throws -> LuminaAgentRequest {
        let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        return try decodeRequest(fromObject: object) ?? LuminaAgentRequest(text: "")
    }

    static func decodeRequest(fromObject object: [String: Any]?) throws -> LuminaAgentRequest? {
        guard let object,
              JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object)
        else { return nil }
        return try? JSONDecoder().decode(LuminaAgentRequest.self, from: data)
    }

    static func parseToolCall(_ json: String) throws -> (toolName: String, arguments: [String: LuminaJSONValue], requiresConfirmation: Bool) {
        let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        guard let toolName = object?["tool_name"] as? String ?? object?["toolName"] as? String else {
            throw NSError(domain: "LuminaAgentClient", code: 1, userInfo: [NSLocalizedDescriptionKey: "missing tool_name"])
        }
        let parameters = object?["parameters"] ?? object?["arguments"] ?? [:]
        let parameterData = try JSONSerialization.data(withJSONObject: parameters)
        let arguments = (try? JSONDecoder().decode([String: LuminaJSONValue].self, from: parameterData)) ?? [:]
        let requiresConfirmation = object?["requires_confirmation"] as? Bool ?? object?["requiresConfirmation"] as? Bool ?? false
        return (toolName, arguments, requiresConfirmation)
    }

    static func stepFromRuntimePayload(_ payload: [String: Any]) -> LuminaReActStep? {
        let type = (payload["type"] as? String)?.lowercased()
        let thought = payload["thought"] as? String
        switch type {
        case "reasoning":
            return .thought(thought ?? "")
        case "tool_use":
            guard let toolName = payload["tool_name"] as? String else { return nil }
            let parameters = payload["parameters"] ?? [:]
            let parameterData = try? JSONSerialization.data(withJSONObject: parameters)
            let arguments = parameterData.flatMap { try? JSONDecoder().decode([String: LuminaJSONValue].self, from: $0) } ?? [:]
            return .action(
                thought: thought ?? "",
                call: LuminaToolCall(toolName: toolName, arguments: arguments, requiresConfirmation: payload["requires_confirmation"] as? Bool ?? false)
            )
        case "final_answer":
            return .final(payload["content"] as? String ?? "", thought: thought)
        case "cannot_complete":
            return .final("### 无法完成\n\n\(payload["reason"] as? String ?? "")", thought: thought)
        default:
            return nil
        }
    }

    static func observationFromRuntimePayload(_ payload: [String: Any]) -> LuminaReActObservation? {
        guard let toolName = payload["toolName"] as? String ?? payload["tool_name"] as? String else { return nil }
        let status = LuminaToolResultStatus(rawValue: payload["status"] as? String ?? "") ?? .failed
        return LuminaReActObservation(
            toolName: toolName,
            status: status,
            summary: payload["summary"] as? String ?? payload["content"] as? String ?? "",
            errorMessage: payload["errorMessage"] as? String
        )
    }

    static func hookEvent(from lifecycle: String?) -> LuminaAgentRuntimeHookEvent {
        switch lifecycle {
        case "run_started": return .runStarted
        case "context_loaded": return .contextLoaded
        case "planner_input_ready": return .stepContextReady
        case "step_produced": return .stepProduced
        case "tool_will_execute": return .toolWillExecute
        case "tool_did_execute": return .toolDidExecute
        case "observation_created": return .observationCreated
        case "final_generated": return .finalGenerated
        case "run_finished": return .runEnded
        case "cancelled": return .cancelled
        default: return .failed
        }
    }

    static func toolResultJSON(status: String, content: String, errorMessage: String?) -> String {
        var object: [String: Any] = ["status": status, "content": content]
        if let errorMessage {
            object["errorMessage"] = errorMessage
        }
        let data = try? JSONSerialization.data(withJSONObject: object)
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? #"{"status":"failed","content":"","errorMessage":"failed to encode tool result"}"#
    }

    static func escape(_ value: String) -> String {
        let data = try? JSONEncoder().encode(value)
        let encoded = data.flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
        return String(encoded.dropFirst().dropLast())
    }

    static func streamingDeltaJSON(from progress: LuminaStepGenerationProgress) -> String {
        var object: [String: Any] = [
            "phase": progress.message,
            "elapsedMilliseconds": progress.elapsedMilliseconds,
            "tokenCount": max(0, progress.outputTokens)
        ]
        if let promptTokens = progress.promptTokens {
            object["promptTokens"] = promptTokens
        }
        if let sampledTokens = progress.sampledTokens {
            object["sampledTokens"] = sampledTokens
        }
        if let partialOutput = progress.partialOutput, !partialOutput.isEmpty {
            object["delta"] = partialOutput
        } else {
            object["delta"] = progress.message
        }
        let data = try? JSONSerialization.data(withJSONObject: object)
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? #"{"delta":"","tokenCount":0}"#
    }
}
