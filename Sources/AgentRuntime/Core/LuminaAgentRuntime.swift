import Foundation

public actor LuminaAgentRuntime {
    private let reactPlanner: any LuminaReActPlanner
    private let router: LuminaToolRouter
    private let configuration: LuminaAgentRuntimeConfiguration
    private let contextProvider: any LuminaRuntimeContextProvider
    private let contextCompactor: any LuminaReActContextCompactor

    public init(
        tools: [AnyLuminaAgentTool],
        reactPlanner: any LuminaReActPlanner = LuminaNoOpReActPlanner(),
        contextProvider: any LuminaRuntimeContextProvider = LuminaEmptyRuntimeContextProvider(),
        contextCompactor: any LuminaReActContextCompactor = LuminaSummarizingReActContextCompactor(),
        configuration: LuminaAgentRuntimeConfiguration = LuminaAgentRuntimeConfiguration(),
        permissionGate: any LuminaPermissionGate = LuminaDefaultPermissionGate(),
        confirmationCoordinator: any LuminaConfirmationCoordinator = LuminaAlwaysConfirmCoordinator(),
        auditLogger: any LuminaAuditLogger = LuminaInMemoryAuditLogger()
    ) {
        self.reactPlanner = reactPlanner
        self.contextProvider = contextProvider
        self.contextCompactor = contextCompactor
        self.configuration = configuration
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
        var planningMilliseconds = Double(0)
        var toolExecutionMilliseconds = Double(0)
        var trace = LuminaReActTrace()
        var results: [LuminaToolResult] = []
        var finalMarkdown: String?

        do {
            try Task.checkCancellation()
            eventSink?(.planningStarted(request.id))
            let schemas = await router.schemas()

            reactLoop: while trace.steps.count < configuration.maximumReActIterations {
                try Task.checkCancellation()
                let loadedContext = try await contextProvider.loadContext(LuminaRuntimeContextRequest(
                    request: request,
                    availableTools: schemas,
                    trace: trace,
                    iteration: trace.steps.count,
                    remainingToolCalls: max(0, configuration.maximumToolCalls - trace.actionCount),
                    maximumCharacters: configuration.maximumObservationCharacters
                ))
                trace = try await compactTraceIfNeeded(
                    request: request,
                    schemas: schemas,
                    trace: trace,
                    loadedContext: loadedContext
                )
                let planningStart = ContinuousClock.now
                var step = try await reactPlanner.nextStep(context: LuminaReActPlannerContext(
                    request: request,
                    availableTools: schemas,
                    trace: trace,
                    loadedContext: loadedContext,
                    iteration: trace.steps.count,
                    remainingToolCalls: max(0, configuration.maximumToolCalls - trace.actionCount),
                    maximumObservationCharacters: configuration.maximumObservationCharacters
                ))
                let stepMilliseconds = LuminaRuntimeClock.milliseconds(since: planningStart)
                step.elapsedMilliseconds = stepMilliseconds
                planningMilliseconds += stepMilliseconds

                switch step.kind {
                case .thought:
                    trace.steps.append(step)
                    eventSink?(.thoughtGenerated(step))
                case .action:
                    if let thought = step.thought, !thought.isEmpty {
                        eventSink?(.thoughtGenerated(.thought(thought, elapsedMilliseconds: step.elapsedMilliseconds)))
                    }
                    guard let call = step.action else {
                        finalMarkdown = "### 执行失败\n\nReAct planner returned an action step without a tool call."
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
                    eventSink?(.planCreated(LuminaAgentPlan(
                        summary: step.thought ?? "ReAct action proposed.",
                        toolCalls: trace.steps.compactMap(\.action)
                    )))

                    let toolStart = ContinuousClock.now
                    let (result, _, _) = await router.execute(call: call, request: request, eventSink: eventSink)
                    toolExecutionMilliseconds += LuminaRuntimeClock.milliseconds(since: toolStart)
                    results.append(result)

                    if configuration.rollbackFailedSideEffects, result.status == .failed, result.rollbackToken != nil {
                        eventSink?(.rollbackStarted(call))
                        let rolledBack = await router.rollback(call: call, result: result)
                        eventSink?(.rollbackFinished(call, rolledBack))
                    }

                    let observation = LuminaReActObservationCompressor.observation(
                        from: result,
                        maximumCharacters: configuration.maximumObservationCharacters
                    )
                    trace.steps.append(.observation(observation))
                    eventSink?(.observationCreated(observation))

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
                    eventSink?(.finalGenerated(step.finalMarkdown ?? ""))
                    trace.terminationReason = "final"
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
                requestID: request.id,
                plan: plan,
                toolResults: results,
                status: status(for: results),
                timing: LuminaRuntimeTiming(
                    planningMilliseconds: planningMilliseconds,
                    toolExecutionMilliseconds: toolExecutionMilliseconds,
                    totalMilliseconds: LuminaRuntimeClock.milliseconds(since: totalStart)
                ),
                reactTrace: trace
            )
            eventSink?(.finished(result))
            return result
        } catch is CancellationError {
            trace.terminationReason = "cancelled"
            let result = LuminaAgentRunResult(
                requestID: request.id,
                plan: LuminaAgentPlan(summary: "Cancelled before ReAct loop completed.", toolCalls: trace.steps.compactMap(\.action)),
                toolResults: results,
                status: .cancelled,
                timing: LuminaRuntimeTiming(
                    planningMilliseconds: planningMilliseconds,
                    toolExecutionMilliseconds: toolExecutionMilliseconds,
                    totalMilliseconds: LuminaRuntimeClock.milliseconds(since: totalStart)
                ),
                reactTrace: trace
            )
            eventSink?(.finished(result))
            return result
        } catch {
            trace.terminationReason = "planning-failed"
            let errorMessage = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            debugLog("Planning failed: \(errorMessage)")
            let result = LuminaAgentRunResult(
                requestID: request.id,
                plan: LuminaAgentPlan(summary: "ReAct planning failed: \(errorMessage)", toolCalls: trace.steps.compactMap(\.action)),
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
