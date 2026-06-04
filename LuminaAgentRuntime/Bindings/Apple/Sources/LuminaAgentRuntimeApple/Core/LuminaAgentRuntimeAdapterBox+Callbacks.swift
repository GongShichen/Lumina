import Foundation

extension LuminaAgentRuntimeAdapterBox {
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
            let startedAt = ContinuousClock.now
            currentEventSink?(.toolStarted(call))
            let result = try await tool.call(context: context, cancellation: LuminaCancellationToken())
            toolExecutionMilliseconds += Self.milliseconds(since: startedAt)
            toolResults.append(result)
            currentEventSink?(.toolFinished(result))
            let content = result.content.compactMap(\.textForModelInput).joined(separator: "\n")
            return Self.toolResultJSON(status: result.status.rawValue, content: content, errorMessage: result.errorMessage)
        } catch {
            return Self.toolResultJSON(status: "failed", content: "", errorMessage: error.localizedDescription)
        }
    }

    func evaluateGuardrail(guardrailJSON: String) async -> String {
        guard let object = try? JSONSerialization.jsonObject(with: Data(guardrailJSON.utf8)) as? [String: Any],
              let stage = object["stage"] as? String
        else { return Self.guardrailDecisionJSON("reject", message: "invalid guardrail request") }
        let payload = object["payload"] as? [String: Any] ?? [:]
        do {
            switch stage {
            case "request":
                guard !guardrails.input.isEmpty else { return Self.guardrailDecisionJSON("allow") }
                let request = try Self.decodeRequest(fromObject: payload) ?? (currentRequest ?? LuminaAgentRequest(text: ""))
                currentRequest = request
                var current = request
                var rewritten = false
                for guardrail in guardrails.input {
                    switch await guardrail.evaluate(request: current) {
                    case .allow:
                        continue
                    case let .rewrite(value):
                        current = value
                        rewritten = true
                    case let .reject(message):
                        return Self.guardrailDecisionJSON("reject", message: message)
                    case let .tripwireFailure(message):
                        return Self.guardrailDecisionJSON("tripwire_failure", message: message)
                    }
                }
                guard rewritten,
                      let data = try? JSONEncoder().encode(current),
                      let payload = try? JSONSerialization.jsonObject(with: data)
                else { return Self.guardrailDecisionJSON("allow") }
                currentRequest = current
                return Self.guardrailDecisionJSON("rewrite", payload: payload)

            case "tool_input":
                guard !guardrails.toolInput.isEmpty else { return Self.guardrailDecisionJSON("allow") }
                let call = try Self.toolCallFromObject(payload)
                guard let tool = toolsByName[call.toolName] else {
                    return Self.guardrailDecisionJSON("reject", message: "tool is not registered")
                }
                let request = currentRequest ?? LuminaAgentRequest(text: "")
                var current = call
                var rewritten = false
                for guardrail in guardrails.toolInput {
                    switch await guardrail.evaluate(call: current, schema: tool.schema, request: request) {
                    case .allow:
                        continue
                    case let .rewrite(value):
                        current = value
                        rewritten = true
                    case let .reject(message):
                        return Self.guardrailDecisionJSON("reject", message: message)
                    case let .tripwireFailure(message):
                        return Self.guardrailDecisionJSON("tripwire_failure", message: message)
                    }
                }
                return rewritten
                    ? Self.guardrailDecisionJSON("rewrite", payload: Self.foundationObject(from: current))
                    : Self.guardrailDecisionJSON("allow")

            case "tool_output":
                guard !guardrails.toolOutput.isEmpty else { return Self.guardrailDecisionJSON("allow") }
                let callObject = payload["call"] as? [String: Any] ?? [:]
                let resultObject = payload["result"] as? [String: Any] ?? [:]
                let call = try Self.toolCallFromObject(callObject)
                guard let tool = toolsByName[call.toolName] else {
                    return Self.guardrailDecisionJSON("reject", message: "tool is not registered")
                }
                let request = currentRequest ?? LuminaAgentRequest(text: "")
                var result = Self.toolResultFromObject(resultObject, fallbackToolName: call.toolName)
                var rewritten = false
                for guardrail in guardrails.toolOutput {
                    switch await guardrail.evaluate(result: result, call: call, schema: tool.schema, request: request) {
                    case .allow:
                        continue
                    case let .rewrite(value):
                        result = value
                        rewritten = true
                    case let .reject(message):
                        return Self.guardrailDecisionJSON("reject", message: message)
                    case let .tripwireFailure(message):
                        return Self.guardrailDecisionJSON("tripwire_failure", message: message)
                    }
                }
                return rewritten
                    ? Self.guardrailDecisionJSON("rewrite", payload: ["result": Self.foundationObject(from: result)])
                    : Self.guardrailDecisionJSON("allow")

            case "result":
                guard !guardrails.result.isEmpty else { return Self.guardrailDecisionJSON("allow") }
                let request = currentRequest ?? LuminaAgentRequest(text: "")
                var markdown = payload["resultMarkdown"] as? String ?? payload["content"] as? String ?? ""
                var rewritten = false
                for guardrail in guardrails.result {
                    switch await guardrail.evaluate(markdown: markdown, request: request) {
                    case .allow:
                        continue
                    case let .rewrite(value):
                        markdown = value
                        rewritten = true
                    case let .reject(message):
                        return Self.guardrailDecisionJSON("reject", message: message)
                    case let .tripwireFailure(message):
                        return Self.guardrailDecisionJSON("tripwire_failure", message: message)
                    }
                }
                return rewritten
                    ? Self.guardrailDecisionJSON("rewrite", payload: ["resultMarkdown": markdown])
                    : Self.guardrailDecisionJSON("allow")

            default:
                return Self.guardrailDecisionJSON("allow")
            }
        } catch {
            return Self.guardrailDecisionJSON("reject", message: error.localizedDescription)
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
        let routeID = object?["route_id"] as? String
        let event = Self.hookEvent(from: object?["lifecycle"] as? String)
        let payload = object?["payload"] as? [String: Any]
        let lifecyclePayload = Self.jsonObject(fromAny: payload ?? [:])
        let toolCall = Self.toolCallFromHookPayload(payload)
        let toolResult = Self.toolResultFromHookPayload(payload)
        let context = LuminaAgentRuntimeHookContext(
            request: currentRequest ?? LuminaAgentRequest(text: ""),
            lifecyclePayload: lifecyclePayload,
            availableTools: tools.map(\.schema),
            trace: trace,
            toolCall: toolCall,
            toolResult: toolResult
        )
        do {
            var directiveObjects: [[String: Any]] = []
            let selectedHooks: [(Int, any LuminaAgentRuntimeHook)]
            if let routeID, let index = Self.hookIndex(fromRouteID: routeID), hooks.indices.contains(index) {
                selectedHooks = [(index, hooks[index])]
            } else {
                selectedHooks = Array(hooks.enumerated())
            }
            for (_, hook) in selectedHooks {
                if routeID == nil,
                   let matchingHook = hook as? any LuminaMatchingAgentRuntimeHook,
                   !matchingHook.matcher.matches(event: event, context: context) {
                    continue
                }
                for directive in try await hook.handle(event: event, context: context) {
                    switch directive {
                    case .proceed:
                        directiveObjects.append(["type": "proceed"])
                    case let .appendContextSection(section):
                        directiveObjects.append([
                            "type": "append_context",
                            "context": ["sections": [Self.foundationObject(fromEncodable: section) ?? [:]]]
                        ])
                    case let .terminate(markdown, reason):
                        directiveObjects.append(["type": "fail", "markdown": markdown, "reason": reason])
                    case let .fail(markdown, reason):
                        directiveObjects.append(["type": "fail", "markdown": markdown, "reason": reason])
                    case let .pause(kind, payload, reason):
                        directiveObjects.append([
                            "type": "pause",
                            "kind": kind,
                            "payload": Self.foundationObject(from: payload),
                            "reason": reason
                        ])
                    case let .rejectToolCall(reason):
                        directiveObjects.append(["type": "reject_tool_call", "reason": reason])
                    case let .rewriteToolCall(call):
                        directiveObjects.append([
                            "type": "rewrite_tool_call",
                            "tool_name": call.toolName,
                            "parameters": Self.foundationObject(from: .object(call.arguments)),
                            "requires_confirmation": call.requiresConfirmation
                        ])
                    case let .requireConfirmation(reason):
                        directiveObjects.append(["type": "require_confirmation", "reason": reason])
                    case let .annotate(key, value):
                        currentEventSink?(.hookAnnotated(key, value))
                    case .mergeRequestMetadata:
                        break
                    }
                }
            }
            guard !directiveObjects.isEmpty else { return "{}" }
            let envelope: [String: Any] = [
                "directives": directiveObjects.sorted { Self.directivePriority($0) > Self.directivePriority($1) }
            ]
            guard JSONSerialization.isValidJSONObject(envelope),
                  let data = try? JSONSerialization.data(withJSONObject: envelope),
                  let json = String(data: data, encoding: .utf8)
            else { return "{}" }
            return json
        } catch {
            return "{\"terminate\":true,\"markdown\":\"### Hook failed\\n\\n\(Self.escape(error.localizedDescription))\",\"reason\":\"hook failed\"}"
        }
    }

    func decideRetry(retryJSON: String) async -> String {
        guard let retryProvider else { return "" }
        do {
            let request = try JSONDecoder().decode(LuminaRuntimeRetryRequest.self, from: Data(retryJSON.utf8))
            let decision = await retryProvider.decideRetry(for: request)
            let data = try JSONEncoder().encode(decision)
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return ""
        }
    }

    func hookRouteJSON(index: Int) -> String {
        var object: [String: Any] = ["id": Self.hookRouteID(index: index)]
        if hooks.indices.contains(index),
           let hook = hooks[index] as? any LuminaMatchingAgentRuntimeHook {
            object["events"] = hook.matcher.events.map { Self.lifecycleName(for: $0) }
            object["tool_name_patterns"] = hook.matcher.toolNamePatterns
            object["sensitivities"] = hook.matcher.sensitivities.map(\.rawValue)
            object["side_effects"] = hook.matcher.sideEffects.map(\.rawValue)
        }
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let json = String(data: data, encoding: .utf8)
        else { return #"{"id":"swift-hook"}"# }
        return json
    }

    func consumeRuntimeEvent(eventJSON: String) {
        guard let data = eventJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String
        else { return }
        let outerPayload = object["payload"] as? [String: Any]
        let runtimePayload = (outerPayload?["payload"] as? [String: Any]) ?? outerPayload
        if type == "observation_created",
           let payload = runtimePayload,
           let observation = Self.observationFromRuntimePayload(payload) {
            if trace.steps.last?.observation != observation {
                trace.steps.append(.observation(observation))
            }
            var output: [String: LuminaJSONValue] = [:]
            if observation.replayed {
                output["replayed"] = .bool(true)
            }
            if let duplicateOf = observation.duplicateOf {
                output["duplicate_of"] = .string(duplicateOf)
            }
            if observation.replayed || !toolResults.contains(where: { $0.toolName == observation.toolName && $0.status == observation.status }) {
                toolResults.append(LuminaToolResult(
                    callID: UUID(),
                    toolName: observation.toolName,
                    status: observation.status,
                    output: output,
                    content: [.text(observation.summary)],
                    errorMessage: observation.errorMessage
                ))
            }
            currentEventSink?(.observationCreated(observation))
        } else if type == "step_produced",
                  let payload = runtimePayload,
                  let step = Self.stepFromRuntimePayload(payload) {
            trace.steps.append(step)
            switch step.kind {
            case .thought:
                currentEventSink?(.thoughtGenerated(step))
            case .action:
                if let call = step.action { currentEventSink?(.actionProposed(call)) }
            case .result:
                currentEventSink?(.resultGenerated(step.resultMarkdown ?? ""))
            case .observation:
                if let observation = step.observation { currentEventSink?(.observationCreated(observation)) }
            }
        } else {
            currentEventSink?(.hookAnnotated("runtime_event.\(type)", .string(eventJSON)))
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
                self.stepGenerationMilliseconds = max(self.stepGenerationMilliseconds, progress.elapsedMilliseconds)
                eventSink(.stepGenerationProgress(progress))
                if streamEmit?(progress) == false {
                    self.requestCancellation()
                }
            }
        } else {
            if let streamEmit {
                progressSink = { progress in
                    self.stepGenerationMilliseconds = max(self.stepGenerationMilliseconds, progress.elapsedMilliseconds)
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

    func compactContext(compactionJSON: String) async -> String {
        guard let object = try? JSONSerialization.jsonObject(with: Data(compactionJSON.utf8)) as? [String: Any] else {
            return #"{"status":"skipped","reason":"invalid compaction request"}"#
        }
        let strategy = object["strategy"] as? String ?? ""
        guard strategy == "summarizing_compact" || strategy == "partial_summarize" else {
            return #"{"status":"skipped"}"#
        }
        let frame = object["context_frame"] as? [String: Any]
        let requestObject = frame?["request"] as? [String: Any]
        let request = (try? Self.decodeRequest(fromObject: requestObject)) ?? (currentRequest ?? LuminaAgentRequest(text: ""))
        var loadedContext = LuminaRuntimeContext.empty
        if let contextObject = frame?["context"],
           JSONSerialization.isValidJSONObject(contextObject),
           let contextData = try? JSONSerialization.data(withJSONObject: contextObject),
           let context = try? JSONDecoder().decode(LuminaRuntimeContext.self, from: contextData) {
            loadedContext = context
        }
        let estimatedCharacters = LuminaReActContextWindowEstimator.estimateCharacters(
            request: request,
            schemas: tools.map(\.schema),
            trace: trace,
            loadedContext: loadedContext
        )
        do {
            let compaction = try await contextCompactor.compact(LuminaReActCompactionRequest(
                agentRequest: request,
                trace: trace,
                loadedContext: loadedContext,
                availableTools: tools.map(\.schema),
                estimatedCharacters: estimatedCharacters,
                characterBudget: max(1, configuration.contextWindowTokens - configuration.reservedOutputTokens) * 4,
                preservedStepCount: configuration.preservedStepsAfterCompaction,
                maximumSummaryCharacters: configuration.maximumObservationCharacters
            ))
            guard compaction.trace != trace || !compaction.summary.isEmpty else {
                return #"{"status":"skipped"}"#
            }
            trace = compaction.trace
            if let observation = trace.steps.first?.observation,
               observation.toolName == "runtime.context_compaction" {
                currentEventSink?(.observationCreated(observation))
            }
            let contextEnvelope: [String: Any] = [
                "sections": [],
                "compact_summary": compaction.summary,
                "source": "apple_compaction_provider"
            ]
            let response: [String: Any] = [
                "status": "compacted",
                "compacted_context": contextEnvelope,
                "tokens_saved_estimate": max(0, (compaction.estimatedCharactersBefore - compaction.estimatedCharactersAfter) / 4),
                "boundary": [
                    "type": "compact_boundary",
                    "trigger": object["trigger"] as? String ?? "auto",
                    "strategy": strategy
                ]
            ]
            return Self.jsonString(from: response)
        } catch {
            return Self.jsonString(from: [
                "status": "failed",
                "failure_reason": String(describing: error)
            ])
        }
    }

    static func decodeRequest(fromRuntimeJSON json: String) throws -> LuminaAgentRequest {
        let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        return try decodeRequest(fromObject: object) ?? LuminaAgentRequest(text: "")
    }

    static func jsonString(from object: Any) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object),
              let string = String(data: data, encoding: .utf8)
        else {
            return "{}"
        }
        return string
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
            throw NSError(domain: "LuminaAgentRuntimeApple", code: 1, userInfo: [NSLocalizedDescriptionKey: "missing tool_name"])
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
        case "result":
            return .result(payload["content"] as? String ?? "", thought: thought)
        case "cannot_complete":
            return .result("### 无法完成\n\n\(payload["reason"] as? String ?? "")", thought: thought)
        default:
            return nil
        }
    }

    static func observationFromRuntimePayload(_ payload: [String: Any]) -> LuminaReActObservation? {
        guard let toolName = payload["toolName"] as? String ?? payload["tool_name"] as? String else { return nil }
        let status = LuminaToolResultStatus(rawValue: payload["status"] as? String ?? "") ?? .failed
        let outputData = try? JSONSerialization.data(withJSONObject: payload["output"] ?? [:])
        let output = outputData.flatMap { try? JSONDecoder().decode([String: LuminaJSONValue].self, from: $0) } ?? [:]
        return LuminaReActObservation(
            toolName: toolName,
            status: status,
            summary: payload["summary"] as? String ?? payload["content"] as? String ?? "",
            output: output,
            errorMessage: payload["errorMessage"] as? String,
            replayed: payload["replayed"] as? Bool ?? false,
            duplicateOf: payload["duplicate_of"] as? String
        )
    }

    static func hookEvent(from lifecycle: String?) -> LuminaAgentRuntimeHookEvent {
        switch lifecycle {
        case "run_started": return .runStarted
        case "session_started": return .sessionStarted
        case "context_loaded": return .contextLoaded
        case "context_updated": return .contextUpdated
        case "planner_input_ready": return .stepContextReady
        case "before_model": return .beforeModel
        case "after_model": return .afterModel
        case "before_normalization": return .beforeNormalization
        case "after_normalization": return .afterNormalization
        case "before_tool": return .beforeTool
        case "step_produced": return .stepProduced
        case "tool_will_execute": return .toolWillExecute
        case "tool_did_execute": return .toolDidExecute
        case "after_tool": return .afterTool
        case "before_permission": return .beforePermission
        case "after_permission": return .afterPermission
        case "before_confirmation": return .beforeConfirmation
        case "after_confirmation": return .afterConfirmation
        case "before_compaction": return .beforeCompaction
        case "observation_created": return .observationCreated
        case "result_generated": return .resultGenerated
        case "run_finished": return .runEnded
        case "session_ended": return .sessionEnded
        case "run_paused", "session_paused": return .paused
        case "cancelled": return .cancelled
        default: return .failed
        }
    }

    static func directivePriority(_ object: [String: Any]) -> Int {
        switch object["type"] as? String {
        case "fail": return 600
        case "pause": return 500
        case "reject_tool_call": return 400
        case "rewrite_tool_call": return 300
        case "require_confirmation": return 200
        case "append_context": return 100
        default: return 0
        }
    }

    static func toolCallFromHookPayload(_ payload: [String: Any]?) -> LuminaToolCall? {
        guard let payload else { return nil }
        let callObject = payload["call"] as? [String: Any] ?? payload
        return try? toolCallFromObject(callObject)
    }

    static func toolCallFromObject(_ callObject: [String: Any]) throws -> LuminaToolCall {
        guard let toolName = callObject["tool_name"] as? String ?? callObject["toolName"] as? String else {
            throw NSError(domain: "LuminaAgentRuntimeApple", code: 1, userInfo: [NSLocalizedDescriptionKey: "missing tool_name"])
        }
        let parameters = callObject["parameters"] ?? callObject["arguments"] ?? [:]
        let parameterData = try? JSONSerialization.data(withJSONObject: parameters)
        let arguments = parameterData.flatMap { try? JSONDecoder().decode([String: LuminaJSONValue].self, from: $0) } ?? [:]
        return LuminaToolCall(
            toolName: toolName,
            arguments: arguments,
            requiresConfirmation: callObject["requires_confirmation"] as? Bool ?? callObject["requiresConfirmation"] as? Bool ?? false
        )
    }

    static func toolResultFromHookPayload(_ payload: [String: Any]?) -> LuminaToolResult? {
        guard let payload,
              let resultObject = payload["result"] as? [String: Any]
        else { return nil }
        let call = toolCallFromHookPayload(payload)
        let outputData = try? JSONSerialization.data(withJSONObject: resultObject["output"] ?? [:])
        let output = outputData.flatMap { try? JSONDecoder().decode([String: LuminaJSONValue].self, from: $0) } ?? [:]
        let status = LuminaToolResultStatus(rawValue: resultObject["status"] as? String ?? "") ?? .failed
        return LuminaToolResult(
            callID: call?.id ?? UUID(),
            toolName: call?.toolName ?? "runtime",
            status: status,
            output: output,
            content: (resultObject["content"] as? String).map { [.text($0)] } ?? [],
            errorMessage: resultObject["errorMessage"] as? String
        )
    }

    static func toolResultFromObject(_ object: [String: Any], fallbackToolName: String) -> LuminaToolResult {
        let outputData = try? JSONSerialization.data(withJSONObject: object["output"] ?? [:])
        let output = outputData.flatMap { try? JSONDecoder().decode([String: LuminaJSONValue].self, from: $0) } ?? [:]
        let status = LuminaToolResultStatus(rawValue: object["status"] as? String ?? "") ?? .failed
        return LuminaToolResult(
            callID: UUID(),
            toolName: object["toolName"] as? String ?? object["tool_name"] as? String ?? fallbackToolName,
            status: status,
            output: output,
            content: (object["content"] as? String).map { [.text($0)] } ?? [],
            errorMessage: object["errorMessage"] as? String
        )
    }

    static func jsonObject(fromAny value: Any) -> [String: LuminaJSONValue] {
        guard let data = try? JSONSerialization.data(withJSONObject: value),
              let decoded = try? JSONDecoder().decode([String: LuminaJSONValue].self, from: data)
        else { return [:] }
        return decoded
    }

    static func foundationObject(from value: LuminaJSONValue) -> Any {
        switch value {
        case let .string(value): return value
        case let .number(value): return value
        case let .bool(value): return value
        case let .object(value): return value.mapValues(foundationObject(from:))
        case let .array(value): return value.map(foundationObject(from:))
        case .null: return NSNull()
        }
    }

    static func foundationObject(from call: LuminaToolCall) -> [String: Any] {
        [
            "tool_name": call.toolName,
            "parameters": foundationObject(from: .object(call.arguments)),
            "requires_confirmation": call.requiresConfirmation
        ]
    }

    static func foundationObject(from result: LuminaToolResult) -> [String: Any] {
        var object: [String: Any] = [
            "status": result.status.rawValue,
            "content": result.content.compactMap(\.textForModelInput).joined(separator: "\n"),
            "output": foundationObject(from: .object(result.output))
        ]
        if let errorMessage = result.errorMessage {
            object["errorMessage"] = errorMessage
        }
        return object
    }

    static func foundationObject<T: Encodable>(fromEncodable value: T) -> Any? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    static func guardrailDecisionJSON(_ decision: String, message: String? = nil, payload: Any? = nil) -> String {
        var object: [String: Any] = ["decision": decision]
        if let message {
            object["message"] = message
        }
        if let payload {
            object["payload"] = payload
        }
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object),
              let json = String(data: data, encoding: .utf8)
        else { return #"{"decision":"reject","message":"failed to encode guardrail decision"}"# }
        return json
    }

    static func hookRouteID(index: Int) -> String {
        "swift-hook-\(index)"
    }

    static func hookIndex(fromRouteID routeID: String) -> Int? {
        guard routeID.hasPrefix("swift-hook-") else { return nil }
        return Int(routeID.dropFirst("swift-hook-".count))
    }

    static func lifecycleName(for event: LuminaAgentRuntimeHookEvent) -> String {
        switch event {
        case .runStarted: return "run_started"
        case .sessionStarted: return "session_started"
        case .contextLoaded: return "context_loaded"
        case .contextUpdated: return "context_updated"
        case .stepContextReady: return "planner_input_ready"
        case .beforeModel: return "before_model"
        case .afterModel: return "after_model"
        case .beforeNormalization: return "before_normalization"
        case .afterNormalization: return "after_normalization"
        case .stepProduced: return "step_produced"
        case .beforeTool: return "before_tool"
        case .toolWillExecute: return "tool_will_execute"
        case .toolDidExecute: return "tool_did_execute"
        case .afterTool: return "after_tool"
        case .beforePermission: return "before_permission"
        case .afterPermission: return "after_permission"
        case .beforeConfirmation: return "before_confirmation"
        case .afterConfirmation: return "after_confirmation"
        case .beforeCompaction: return "before_compaction"
        case .observationCreated: return "observation_created"
        case .resultGenerated: return "result_generated"
        case .runEnded: return "run_finished"
        case .sessionEnded: return "session_ended"
        case .paused: return "run_paused"
        case .cancelled: return "cancelled"
        case .failed: return "failed"
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

    private static func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let duration = start.duration(to: ContinuousClock.now)
        return Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
    }
}
