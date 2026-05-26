import Foundation

public actor LuminaAgentRuntime {
    private let stepGenerator: any LuminaReActStepGenerator
    private let router: LuminaToolRouter
    private let configuration: LuminaAgentRuntimeConfiguration
    private let contextProvider: any LuminaRuntimeContextProvider
    private let contextCompactor: any LuminaReActContextCompactor
    private let hooks: [any LuminaAgentRuntimeHook]

    public init(
        tools: [AnyLuminaAgentTool],
        stepGenerator: any LuminaReActStepGenerator = LuminaUnavailableReActStepGenerator(),
        contextProvider: any LuminaRuntimeContextProvider = LuminaEmptyRuntimeContextProvider(),
        contextCompactor: any LuminaReActContextCompactor = LuminaSummarizingReActContextCompactor(),
        configuration: LuminaAgentRuntimeConfiguration = LuminaAgentRuntimeConfiguration(),
        permissionGate: any LuminaPermissionGate = LuminaDefaultPermissionGate(),
        confirmationCoordinator: any LuminaConfirmationCoordinator = LuminaAlwaysConfirmCoordinator(),
        auditLogger: any LuminaAuditLogger = LuminaInMemoryAuditLogger(),
        hooks: [any LuminaAgentRuntimeHook] = []
    ) {
        self.stepGenerator = stepGenerator
        self.contextProvider = contextProvider
        self.contextCompactor = contextCompactor
        self.configuration = configuration
        self.hooks = hooks
        self.router = LuminaToolRouter(
            tools: tools,
            permissionGate: permissionGate,
            confirmationCoordinator: confirmationCoordinator,
            auditLogger: auditLogger
        )
    }

    public func run(request: LuminaAgentRequest) async -> LuminaAgentRunResult {
        await run(request: request, eventSink: nil)
    }

    public func availableToolSchemas() async -> [LuminaToolSchema] {
        await router.schemas()
    }

    private func run(
        request: LuminaAgentRequest,
        eventSink: (@Sendable (LuminaAgentRunEvent) -> Void)?
    ) async -> LuminaAgentRunResult {
        let totalStart = ContinuousClock.now
        var stepGenerationMilliseconds = Double(0)
        var toolExecutionMilliseconds = Double(0)
        var trace = LuminaReActTrace()
        var results: [LuminaToolResult] = []
        var finalMarkdown: String?
        var activeRequest = request
        var schemas: [LuminaToolSchema] = []

        do {
            try Task.checkCancellation()
            eventSink?(.stepGenerationStarted(request.id))
            schemas = await router.schemas()
            var emptyContext = LuminaRuntimeContext.empty
            if let termination = try await applyHookDirectives(
                event: .runStarted,
                context: hookContext(request: activeRequest, schemas: schemas, trace: trace),
                request: &activeRequest,
                loadedContext: &emptyContext,
                trace: &trace,
                eventSink: eventSink
            ) {
                finalMarkdown = termination.markdown
                trace.terminationReason = termination.reason
            }

            reactLoop: while finalMarkdown == nil && trace.steps.count < configuration.maximumReActIterations {
                try Task.checkCancellation()
                var loadedContext = try await contextProvider.loadContext(LuminaRuntimeContextRequest(
                    request: activeRequest,
                    availableTools: schemas,
                    trace: trace,
                    iteration: trace.steps.count,
                    remainingToolCalls: max(0, configuration.maximumToolCalls - trace.actionCount),
                    maximumCharacters: configuration.maximumObservationCharacters
                ))
                if let termination = try await applyHookDirectives(
                    event: .contextLoaded,
                    context: hookContext(request: activeRequest, schemas: schemas, trace: trace, loadedContext: loadedContext),
                    request: &activeRequest,
                    loadedContext: &loadedContext,
                    trace: &trace,
                    eventSink: eventSink
                ) {
                    finalMarkdown = termination.markdown
                    trace.terminationReason = termination.reason
                    break reactLoop
                }
                trace = try await compactTraceIfNeeded(
                    request: activeRequest,
                    schemas: schemas,
                    trace: trace,
                    loadedContext: loadedContext
                )
                let stepGenerationStart = ContinuousClock.now
                var stepContext = LuminaReActStepContext(
                    request: activeRequest,
                    availableTools: schemas,
                    trace: trace,
                    loadedContext: loadedContext,
                    iteration: trace.steps.count,
                    remainingToolCalls: max(0, configuration.maximumToolCalls - trace.actionCount),
                    maximumObservationCharacters: configuration.maximumObservationCharacters,
                    progressSink: { progress in
                        eventSink?(.stepGenerationProgress(progress))
                    }
                )
                if let termination = try await applyHookDirectives(
                    event: .stepContextReady,
                    context: hookContext(
                        request: activeRequest,
                        schemas: schemas,
                        trace: trace,
                        loadedContext: loadedContext,
                        stepContext: stepContext
                    ),
                    request: &activeRequest,
                    loadedContext: &loadedContext,
                    trace: &trace,
                    eventSink: eventSink
                ) {
                    finalMarkdown = termination.markdown
                    trace.terminationReason = termination.reason
                    break reactLoop
                }
                stepContext.request = activeRequest
                stepContext.loadedContext = loadedContext
                let progressTask = Task { [eventSink, requestID = activeRequest.id, iteration = stepContext.iteration] in
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(2))
                        guard !Task.isCancelled else { break }
                        eventSink?(.stepGenerationProgress(LuminaStepGenerationProgress(
                            requestID: requestID,
                            iteration: iteration,
                            elapsedMilliseconds: LuminaRuntimeClock.milliseconds(since: stepGenerationStart),
                            message: "端侧模型仍在生成 ReAct step"
                        )))
                    }
                }
                var step: LuminaReActStep
                do {
                    step = try await stepGenerator.nextStep(context: stepContext)
                    progressTask.cancel()
                } catch {
                    progressTask.cancel()
                    throw error
                }
                let stepMilliseconds = LuminaRuntimeClock.milliseconds(since: stepGenerationStart)
                step.elapsedMilliseconds = stepMilliseconds
                stepGenerationMilliseconds += stepMilliseconds
                if let termination = try await applyHookDirectives(
                    event: .stepProduced,
                    context: hookContext(
                        request: activeRequest,
                        schemas: schemas,
                        trace: trace,
                        loadedContext: loadedContext,
                        stepContext: stepContext,
                        step: step
                    ),
                    request: &activeRequest,
                    loadedContext: &loadedContext,
                    trace: &trace,
                    eventSink: eventSink
                ) {
                    finalMarkdown = termination.markdown
                    trace.terminationReason = termination.reason
                    break reactLoop
                }

                switch step.kind {
                case .thought:
                    trace.steps.append(step)
                    eventSink?(.thoughtGenerated(step))
                case .action:
                    if let thought = step.thought, !thought.isEmpty {
                        eventSink?(.thoughtGenerated(.thought(thought, elapsedMilliseconds: step.elapsedMilliseconds)))
                    }
                    guard let call = step.action else {
                        finalMarkdown = "### 执行失败\n\nReAct step generator returned an action step without a tool call."
                        trace.terminationReason = "invalid-action"
                        break reactLoop
                    }
                    guard trace.actionCount < configuration.maximumToolCalls else {
                        finalMarkdown = "### 已达到工具调用预算\n\nLumina 已停止继续调用工具，并保留当前结果。"
                        trace.terminationReason = "tool-budget"
                        eventSink?(.finalGenerated(finalMarkdown ?? ""))
                        break reactLoop
                    }
                    trace.steps.append(step)
                    eventSink?(.actionProposed(call))

                    if let termination = try await applyHookDirectives(
                        event: .toolWillExecute,
                        context: hookContext(
                            request: activeRequest,
                            schemas: schemas,
                            trace: trace,
                            loadedContext: loadedContext,
                            stepContext: stepContext,
                            step: step,
                            call: call
                        ),
                        request: &activeRequest,
                        loadedContext: &loadedContext,
                        trace: &trace,
                        eventSink: eventSink
                    ) {
                        finalMarkdown = termination.markdown
                        trace.terminationReason = termination.reason
                        break reactLoop
                    }
                    let toolStart = ContinuousClock.now
                    let (result, permissionDecision, confirmed) = await router.execute(call: call, request: activeRequest, eventSink: eventSink)
                    toolExecutionMilliseconds += LuminaRuntimeClock.milliseconds(since: toolStart)
                    results.append(result)
                    if let termination = try await applyHookDirectives(
                        event: .toolDidExecute,
                        context: hookContext(
                            request: activeRequest,
                            schemas: schemas,
                            trace: trace,
                            loadedContext: loadedContext,
                            stepContext: stepContext,
                            step: step,
                            call: call,
                            result: result
                        ),
                        request: &activeRequest,
                        loadedContext: &loadedContext,
                        trace: &trace,
                        eventSink: eventSink
                    ) {
                        finalMarkdown = termination.markdown
                        trace.terminationReason = termination.reason
                        break reactLoop
                    }

                    if configuration.rollbackFailedSideEffects, result.status == .failed, result.rollbackToken != nil {
                        eventSink?(.rollbackStarted(call))
                        let rolledBack = await router.rollback(call: call, result: result)
                        eventSink?(.rollbackFinished(call, rolledBack))
                    }

                    let observation = LuminaReActObservationCompressor.observation(
                        from: result,
                        permissionDecision: permissionDecision,
                        confirmed: confirmed,
                        maximumCharacters: configuration.maximumObservationCharacters
                    )
                    trace.steps.append(.observation(observation))
                    eventSink?(.observationCreated(observation))
                    if let termination = try await applyHookDirectives(
                        event: .observationCreated,
                        context: hookContext(
                            request: activeRequest,
                            schemas: schemas,
                            trace: trace,
                            loadedContext: loadedContext,
                            stepContext: stepContext,
                            step: step,
                            call: call,
                            result: result,
                            observation: observation
                        ),
                        request: &activeRequest,
                        loadedContext: &loadedContext,
                        trace: &trace,
                        eventSink: eventSink
                    ) {
                        finalMarkdown = termination.markdown
                        trace.terminationReason = termination.reason
                        break reactLoop
                    }

                    if configuration.stopOnToolFailure, result.status != .succeeded {
                        finalMarkdown = "### 执行中止\n\n\(observation.summary)"
                        trace.terminationReason = "tool-failure"
                        break reactLoop
                    }
                case .observation:
                    trace.steps.append(step)
                    if let observation = step.observation {
                        eventSink?(.observationCreated(observation))
                    }
                case .final:
                    trace.steps.append(step)
                    finalMarkdown = step.finalMarkdown
                    if let termination = try await applyHookDirectives(
                        event: .finalGenerated,
                        context: hookContext(
                            request: activeRequest,
                            schemas: schemas,
                            trace: trace,
                            loadedContext: loadedContext,
                            stepContext: stepContext,
                            step: step,
                            finalMarkdown: finalMarkdown
                        ),
                        request: &activeRequest,
                        loadedContext: &loadedContext,
                        trace: &trace,
                        eventSink: eventSink
                    ) {
                        finalMarkdown = termination.markdown
                        trace.terminationReason = termination.reason
                    }
                    eventSink?(.finalGenerated(finalMarkdown ?? ""))
                    trace.terminationReason = trace.terminationReason ?? "final"
                    break reactLoop
                }
            }

            if finalMarkdown == nil {
                finalMarkdown = "### 已达到执行预算\n\nAgent 已停止继续调用工具。"
                trace.terminationReason = trace.terminationReason ?? "budget"
                trace.steps.append(.final(finalMarkdown ?? ""))
                eventSink?(.finalGenerated(finalMarkdown ?? ""))
            }

            let plan = LuminaAgentPlan(
                summary: finalMarkdown ?? "ReAct run finished.",
                toolCalls: trace.steps.compactMap(\.action)
            )
            let result = LuminaAgentRunResult(
                requestID: activeRequest.id,
                plan: plan,
                toolResults: results,
                status: status(for: results),
                timing: LuminaRuntimeTiming(
                    stepGenerationMilliseconds: stepGenerationMilliseconds,
                    toolExecutionMilliseconds: toolExecutionMilliseconds,
                    totalMilliseconds: LuminaRuntimeClock.milliseconds(since: totalStart)
                ),
                reactTrace: trace
            )
            var runEndedContext = LuminaRuntimeContext.empty
            _ = try await applyHookDirectives(
                event: .runEnded,
                context: hookContext(
                    request: activeRequest,
                    schemas: schemas,
                    trace: trace,
                    loadedContext: runEndedContext,
                    finalMarkdown: finalMarkdown,
                    timing: result.timing
                ),
                request: &activeRequest,
                loadedContext: &runEndedContext,
                trace: &trace,
                eventSink: eventSink
            )
            eventSink?(.finished(result))
            return result
        } catch is CancellationError {
            trace.terminationReason = "cancelled"
            var terminalContext = LuminaRuntimeContext.empty
            _ = try? await applyHookDirectives(
                event: .cancelled,
                context: hookContext(request: activeRequest, schemas: schemas, trace: trace, loadedContext: terminalContext),
                request: &activeRequest,
                loadedContext: &terminalContext,
                trace: &trace,
                eventSink: eventSink
            )
            let result = LuminaAgentRunResult(
                requestID: activeRequest.id,
                plan: LuminaAgentPlan(summary: "Cancelled before ReAct loop completed.", toolCalls: trace.steps.compactMap(\.action)),
                toolResults: results,
                status: .cancelled,
                timing: LuminaRuntimeTiming(
                    stepGenerationMilliseconds: stepGenerationMilliseconds,
                    toolExecutionMilliseconds: toolExecutionMilliseconds,
                    totalMilliseconds: LuminaRuntimeClock.milliseconds(since: totalStart)
                ),
                reactTrace: trace
            )
            eventSink?(.finished(result))
            return result
        } catch {
            trace.terminationReason = "step-generation-failed"
            let errorMessage = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            debugLog("Step generation failed: \(errorMessage)")
            var terminalContext = LuminaRuntimeContext.empty
            _ = try? await applyHookDirectives(
                event: .failed,
                context: hookContext(
                    request: activeRequest,
                    schemas: schemas,
                    trace: trace,
                    loadedContext: terminalContext,
                    errorMessage: errorMessage
                ),
                request: &activeRequest,
                loadedContext: &terminalContext,
                trace: &trace,
                eventSink: eventSink
            )
            let result = LuminaAgentRunResult(
                requestID: activeRequest.id,
                plan: LuminaAgentPlan(summary: "ReAct step generation failed: \(errorMessage)", toolCalls: trace.steps.compactMap(\.action)),
                toolResults: results,
                status: .failed,
                timing: LuminaRuntimeTiming(totalMilliseconds: LuminaRuntimeClock.milliseconds(since: totalStart)),
                reactTrace: trace
            )
            eventSink?(.finished(result))
            return result
        }
    }

    private nonisolated func debugLog(_ message: String) {
        #if DEBUG
        print("[Lumina][AgentRuntime] \(message)")
        #endif
    }

    private struct HookTermination: Sendable {
        var markdown: String
        var reason: String
    }

    private func applyHookDirectives(
        event: LuminaAgentRuntimeHookEvent,
        context: LuminaAgentRuntimeHookContext,
        request: inout LuminaAgentRequest,
        loadedContext: inout LuminaRuntimeContext,
        trace: inout LuminaReActTrace,
        eventSink: (@Sendable (LuminaAgentRunEvent) -> Void)?
    ) async throws -> HookTermination? {
        guard !hooks.isEmpty else { return nil }
        var termination: HookTermination?
        for hook in hooks {
            let directives = try await hook.handle(event: event, context: context)
            for directive in directives {
                switch directive {
                case let .appendContextSection(section):
                    guard !loadedContext.sections.contains(where: { $0.id == section.id }) else { continue }
                    loadedContext.sections.append(section)
                    eventSink?(.contextUpdated(loadedContext))
                case let .mergeRequestMetadata(metadata):
                    request.metadata.merge(metadata) { _, new in new }
                case let .terminate(markdown, reason):
                    termination = HookTermination(markdown: markdown, reason: reason)
                case let .annotate(key, value):
                    eventSink?(.hookAnnotated(key, value))
                }
            }
        }
        return termination
    }

    private func hookContext(
        request: LuminaAgentRequest,
        schemas: [LuminaToolSchema],
        trace: LuminaReActTrace,
        loadedContext: LuminaRuntimeContext = .empty,
        stepContext: LuminaReActStepContext? = nil,
        step: LuminaReActStep? = nil,
        call: LuminaToolCall? = nil,
        result: LuminaToolResult? = nil,
        observation: LuminaReActObservation? = nil,
        finalMarkdown: String? = nil,
        timing: LuminaRuntimeTiming? = nil,
        errorMessage: String? = nil
    ) -> LuminaAgentRuntimeHookContext {
        LuminaAgentRuntimeHookContext(
            request: request,
            availableTools: schemas,
            trace: trace,
            loadedContext: loadedContext,
            stepContext: stepContext,
            step: step,
            toolCall: call,
            toolResult: result,
            observation: observation,
            finalMarkdown: finalMarkdown,
            timing: timing,
            errorMessage: errorMessage
        )
    }

    private func compactTraceIfNeeded(
        request: LuminaAgentRequest,
        schemas: [LuminaToolSchema],
        trace: LuminaReActTrace,
        loadedContext: LuminaRuntimeContext
    ) async throws -> LuminaReActTrace {
        guard configuration.contextWindowCharacterBudget > 0,
              configuration.autoCompactThreshold > 0,
              trace.steps.count > configuration.preservedStepsAfterCompaction
        else {
            return trace
        }

        let estimatedCharacters = LuminaReActContextWindowEstimator.estimateCharacters(
            request: request,
            schemas: schemas,
            trace: trace,
            loadedContext: loadedContext
        )
        let thresholdCharacters = Int(Double(configuration.contextWindowCharacterBudget) * configuration.autoCompactThreshold)
        guard estimatedCharacters >= thresholdCharacters else {
            return trace
        }

        let result = try await contextCompactor.compact(LuminaReActCompactionRequest(
            agentRequest: request,
            trace: trace,
            loadedContext: loadedContext,
            availableTools: schemas,
            estimatedCharacters: estimatedCharacters,
            characterBudget: configuration.contextWindowCharacterBudget,
            preservedStepCount: configuration.preservedStepsAfterCompaction,
            maximumSummaryCharacters: max(400, configuration.maximumObservationCharacters)
        ))
        guard result.trace.steps.count < trace.steps.count ||
                result.estimatedCharactersAfter < result.estimatedCharactersBefore
        else {
            return trace
        }
        return result.trace
    }

    public nonisolated func runStream(request: LuminaAgentRequest) -> AsyncStream<LuminaAgentRunEvent> {
        AsyncStream { continuation in
            let task = Task {
                _ = await self.run(request: request) { event in
                    continuation.yield(event)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func status(for results: [LuminaToolResult]) -> LuminaAgentRunStatus {
        guard !results.isEmpty else { return .succeeded }
        if results.allSatisfy({ $0.status == .succeeded }) { return .succeeded }
        if results.contains(where: { $0.status == .succeeded }) { return .partiallySucceeded }
        if results.contains(where: { $0.status == .cancelled }) { return .cancelled }
        return .failed
    }
}
