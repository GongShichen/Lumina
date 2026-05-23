import Foundation

public actor AgentRuntime {
    private let reactPlanner: any ReActPlanner
    private let router: ToolRouter
    private let configuration: AgentRuntimeConfiguration

    public init(
        tools: [AnyAgentTool],
        planner: any Planner = FoundationModelsPlanner(),
        reactPlanner: (any ReActPlanner)? = nil,
        configuration: AgentRuntimeConfiguration = AgentRuntimeConfiguration(),
        permissionGate: any PermissionGate = DefaultPermissionGate(),
        confirmationCoordinator: any ConfirmationCoordinator = AlwaysConfirmCoordinator(),
        auditLogger: any AuditLogger = InMemoryAuditLogger()
    ) {
        self.reactPlanner = reactPlanner ?? PlanBasedReActPlanner(planner: planner)
        self.configuration = configuration
        self.router = ToolRouter(
            tools: tools,
            permissionGate: permissionGate,
            confirmationCoordinator: confirmationCoordinator,
            auditLogger: auditLogger
        )
    }

    public func run(request: AgentRequest) async -> AgentRunResult {
        await run(request: request, eventSink: nil)
    }

    private func run(
        request: AgentRequest,
        eventSink: (@Sendable (AgentRunEvent) -> Void)?
    ) async -> AgentRunResult {
        let totalStart = ContinuousClock.now
        var planningMilliseconds = Double(0)
        var toolExecutionMilliseconds = Double(0)
        var trace = ReActTrace()
        var results: [ToolResult] = []
        var finalMarkdown: String?

        do {
            try Task.checkCancellation()
            eventSink?(.planningStarted(request.id))
            let schemas = await router.schemas()

            while trace.steps.count < configuration.maximumReActIterations &&
                trace.actionCount < configuration.maximumToolCalls {
                try Task.checkCancellation()
                let planningStart = ContinuousClock.now
                var step = try await reactPlanner.nextStep(context: ReActPlannerContext(
                    request: request,
                    availableTools: schemas,
                    trace: trace,
                    iteration: trace.steps.count,
                    remainingToolCalls: max(0, configuration.maximumToolCalls - trace.actionCount),
                    maximumObservationCharacters: configuration.maximumObservationCharacters
                ))
                let stepMilliseconds = RuntimeClock.milliseconds(since: planningStart)
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
                        break
                    }
                    trace.steps.append(step)
                    eventSink?(.actionProposed(call))
                    eventSink?(.planCreated(AgentPlan(
                        summary: step.thought ?? "ReAct action proposed.",
                        toolCalls: trace.steps.compactMap(\.action)
                    )))

                    let toolStart = ContinuousClock.now
                    let (result, _, _) = await router.execute(call: call, request: request, eventSink: eventSink)
                    toolExecutionMilliseconds += RuntimeClock.milliseconds(since: toolStart)
                    results.append(result)

                    if configuration.rollbackFailedSideEffects, result.status == .failed, result.rollbackToken != nil {
                        eventSink?(.rollbackStarted(call))
                        let rolledBack = await router.rollback(call: call, result: result)
                        eventSink?(.rollbackFinished(call, rolledBack))
                    }

                    let observation = ReActObservationCompressor.observation(
                        from: result,
                        maximumCharacters: configuration.maximumObservationCharacters
                    )
                    trace.steps.append(.observation(observation))
                    eventSink?(.observationCreated(observation))

                    if configuration.stopOnToolFailure, result.status != .succeeded {
                        finalMarkdown = "### 执行中止\n\n\(observation.summary)"
                        trace.terminationReason = "tool-failure"
                        break
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
                    break
                }
            }

            if finalMarkdown == nil {
                finalMarkdown = "### 已达到执行预算\n\nAgent 已停止继续调用工具。"
                trace.terminationReason = trace.terminationReason ?? "budget"
                trace.steps.append(.final(finalMarkdown ?? ""))
                eventSink?(.finalGenerated(finalMarkdown ?? ""))
            }

            let plan = AgentPlan(
                summary: finalMarkdown ?? "ReAct run finished.",
                toolCalls: trace.steps.compactMap(\.action)
            )
            let result = AgentRunResult(
                requestID: request.id,
                plan: plan,
                toolResults: results,
                status: status(for: results),
                timing: RuntimeTiming(
                    planningMilliseconds: planningMilliseconds,
                    toolExecutionMilliseconds: toolExecutionMilliseconds,
                    totalMilliseconds: RuntimeClock.milliseconds(since: totalStart)
                ),
                reactTrace: trace
            )
            eventSink?(.finished(result))
            return result
        } catch is CancellationError {
            trace.terminationReason = "cancelled"
            let result = AgentRunResult(
                requestID: request.id,
                plan: AgentPlan(summary: "Cancelled before ReAct loop completed.", toolCalls: trace.steps.compactMap(\.action)),
                toolResults: results,
                status: .cancelled,
                timing: RuntimeTiming(
                    planningMilliseconds: planningMilliseconds,
                    toolExecutionMilliseconds: toolExecutionMilliseconds,
                    totalMilliseconds: RuntimeClock.milliseconds(since: totalStart)
                ),
                reactTrace: trace
            )
            eventSink?(.finished(result))
            return result
        } catch {
            trace.terminationReason = "planning-failed"
            let result = AgentRunResult(
                requestID: request.id,
                plan: AgentPlan(summary: "ReAct planning failed: \(error)", toolCalls: trace.steps.compactMap(\.action)),
                toolResults: results,
                status: .failed,
                timing: RuntimeTiming(totalMilliseconds: RuntimeClock.milliseconds(since: totalStart)),
                reactTrace: trace
            )
            eventSink?(.finished(result))
            return result
        }
    }

    public nonisolated func runStream(request: AgentRequest) -> AsyncStream<AgentRunEvent> {
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

    private func status(for results: [ToolResult]) -> AgentRunStatus {
        guard !results.isEmpty else { return .succeeded }
        if results.allSatisfy({ $0.status == .succeeded }) { return .succeeded }
        if results.contains(where: { $0.status == .succeeded }) { return .partiallySucceeded }
        if results.contains(where: { $0.status == .cancelled }) { return .cancelled }
        return .failed
    }
}
