import XCTest
@testable import LuminaAgentRuntimeApple

final class RuntimeChainIntegrityTests: XCTestCase {
    func testOutputGuardrailPublishesSameSanitizedOutputToModelEventsAndFinalResult() async throws {
        let model = ChainRecordingModel(steps: [.action(thought: "read", call: readCall(1)), .result("done")])
        let runtime = LuminaAgentRuntime(
            tools: [readTool], stepGenerator: model,
            configuration: luminaTestRuntimeConfiguration(emitVerboseEvents: false),
            guardrails: LuminaRuntimeGuardrails(toolOutput: [ChainRedactingGuardrail()])
        )
        var finishedTools: [LuminaToolResult] = []
        var final: LuminaAgentRunResult?
        for await event in runtime.runStream(request: LuminaAgentRequest(text: "Read the record.")) {
            if case let .toolFinished(result) = event { finishedTools.append(result) }
            if case let .finished(result) = event { final = result }
        }
        let result = try XCTUnwrap(final)
        let contexts = await model.contexts
        let observed = try XCTUnwrap(contexts.last?.trace.observations.last)
        XCTAssertEqual(finishedTools.count, 1)
        XCTAssertEqual(result.toolResults.count, 1)
        XCTAssertEqual(finishedTools.first?.output, ["value": .string("sanitized")])
        XCTAssertEqual(finishedTools, result.toolResults)
        XCTAssertEqual(observed.output, result.toolResults.first?.output)
        XCTAssertFalse(finishedTools.flatMap(\.content).compactMap(\.textForModelInput).joined().contains("RAW"))
        XCTAssertEqual(observed.callID, "tool-call-1")
    }

    func testSameNameCallsKeepDistinctIdentitiesAndAllBatchPlanEntries() async throws {
        let model = ChainRecordingModel(steps: [
            .multiAction(thought: "read twice", calls: [readCall(1), readCall(2)]),
            .action(thought: "read again", call: readCall(3)), .result("done")
        ])
        let runtime = LuminaAgentRuntime(tools: [readTool], stepGenerator: model,
                                        configuration: luminaTestRuntimeConfiguration(emitVerboseEvents: false))
        var started: [LuminaToolCall] = []
        var completed: [LuminaToolResult] = []
        var final: LuminaAgentRunResult?
        for await event in runtime.runStream(request: LuminaAgentRequest(text: "Read three records.")) {
            if case let .toolStarted(call) = event { started.append(call) }
            if case let .toolFinished(result) = event { completed.append(result) }
            if case let .finished(result) = event { final = result }
        }
        let result = try XCTUnwrap(final)
        let contexts = await model.contexts
        XCTAssertEqual(result.plan.toolCalls.map(\.arguments), [readCall(1), readCall(2), readCall(3)].map(\.arguments))
        XCTAssertEqual(result.toolResults.count, 3)
        XCTAssertEqual(completed, result.toolResults)
        XCTAssertEqual(Set(result.toolResults.map(\.callID)).count, 3)
        XCTAssertEqual(started.map(\.id), completed.map(\.callID))
        XCTAssertEqual(contexts.last?.trace.observations.count, 3)
        XCTAssertEqual(contexts.last?.trace.actionCount, 3)
        XCTAssertEqual(contexts.last?.remainingToolCalls, 5)
        XCTAssertEqual(result.reactTrace?.actionCount, 3)
    }

    func testInterruptedBatchCountsOnlyCallsThatConsumedBudget() async throws {
        let model = ChainRecordingModel(steps: [.multiAction(thought: "read three", calls: [readCall(1), readCall(2), readCall(3)])])
        let failing = AnyLuminaAgentTool(schema: readTool.schema) { _, _ in
            LuminaToolResult(callID: UUID(), toolName: "record.read", status: .failed, errorMessage: "read unavailable")
        }
        let runtime = LuminaAgentRuntime(tools: [failing], stepGenerator: model,
            configuration: luminaTestRuntimeConfiguration(stopOnToolFailure: true, continueReadOnlyMultiToolFailures: false))
        let result = await runtime.run(request: LuminaAgentRequest(text: "Read three records."))
        XCTAssertEqual(result.plan.toolCalls.count, 3)
        XCTAssertEqual(result.toolResults.count, 1)
        XCTAssertEqual(result.reactTrace?.actionCount, 1)
    }

    func testReplayKeepsItsOwnCallIdentityAndReferencesOriginalCall() async throws {
        let call = LuminaToolCall(toolName: "record.create", arguments: ["title": .string("Breakfast")])
        let model = ChainRecordingModel(steps: [
            .action(thought: "create", call: call), .action(thought: "repeat", call: call), .result("done")
        ])
        let tool = AnyLuminaAgentTool(schema: LuminaToolSchema(
            name: "record.create", description: "Create a record.",
            parameters: [.init(name: "title", type: .string, description: "Title.")],
            sideEffect: .appLocalWrite, idempotencyPolicy: "caller_keyed"
        )) { _, _ in
            LuminaToolResult(callID: UUID(), toolName: "record.create", status: .succeeded,
                             output: ["id": .string("created-once")])
        }
        let runtime = LuminaAgentRuntime(tools: [tool], stepGenerator: model, configuration: luminaTestRuntimeConfiguration)
        var completed: [LuminaToolResult] = []
        var final: LuminaAgentRunResult?
        for await event in runtime.runStream(request: LuminaAgentRequest(text: "Create one record.")) {
            if case let .toolFinished(result) = event { completed.append(result) }
            if case let .finished(result) = event { final = result }
        }
        let result = try XCTUnwrap(final)
        let contexts = await model.contexts
        let observations = try XCTUnwrap(contexts.last?.trace.observations)
        XCTAssertEqual(result.toolResults.count, 2)
        XCTAssertEqual(Set(result.toolResults.map(\.callID)).count, 2)
        XCTAssertEqual(completed, result.toolResults)
        XCTAssertEqual(observations.map(\.callID), ["tool-call-1", "tool-call-2"])
        XCTAssertEqual(observations.last?.duplicateOf, observations.first?.callID)
        XCTAssertEqual(result.toolResults.last?.output["replayed"], .bool(true))
    }

    func testTraceCountsBatchCallsAndPreservesAuthoritativeCountAfterCompaction() async throws {
        let trace = LuminaReActTrace(steps: [
            .multiAction(thought: "read", calls: [readCall(1), readCall(2)]),
            .action(thought: "third", call: readCall(3))
        ])
        XCTAssertEqual(trace.actionCount, 3)
        var interrupted = trace
        interrupted.consumedToolCallCount = 1
        XCTAssertEqual(interrupted.actionCount, 1)
        let encoded = try JSONEncoder().encode(interrupted)
        XCTAssertEqual(try JSONDecoder().decode(LuminaReActTrace.self, from: encoded).actionCount, 1)
        let legacy = #"{"steps":[],"compactedActionCount":2,"compactionCount":1}"#
        XCTAssertEqual(try JSONDecoder().decode(LuminaReActTrace.self, from: Data(legacy.utf8)).actionCount, 2)
        for source in [trace, interrupted] {
            let compacted = try await LuminaSummarizingReActContextCompactor().compact(.init(
                agentRequest: LuminaAgentRequest(text: "read"), trace: source, loadedContext: .empty,
                availableTools: [readTool.schema], estimatedCharacters: 1000, characterBudget: 500,
                preservedStepCount: 1, maximumSummaryCharacters: 500
            ))
            XCTAssertEqual(compacted.trace.compactedActionCount, 2)
            XCTAssertEqual(compacted.trace.actionCount, source.actionCount)
        }
    }

    func testCancellingStreamConsumerCancelsInFlightModel() async {
        let started = expectation(description: "model started")
        let cancelled = expectation(description: "model cancellation propagated")
        let model = ChainCancellationModel(started: started, cancelled: cancelled)
        let runtime = LuminaAgentRuntime(tools: [], stepGenerator: model, configuration: luminaTestRuntimeConfiguration)
        let consumer = Task {
            for await _ in runtime.runStream(request: LuminaAgentRequest(text: "wait")) {}
        }
        await fulfillment(of: [started], timeout: 2)
        consumer.cancel()
        await fulfillment(of: [cancelled], timeout: 2)
        await consumer.value
    }

    func testCancellingStreamConsumerCancelsInFlightTool() async {
        let started = expectation(description: "tool started")
        let cancelled = expectation(description: "tool cancellation propagated")
        let model = ChainRecordingModel(steps: [.action(thought: "read", call: readCall(1))])
        let tool = AnyLuminaAgentTool(schema: readTool.schema) { _, _ in
            started.fulfill()
            do {
                try await Task.sleep(for: .seconds(30))
                return LuminaToolResult(callID: UUID(), toolName: "record.read", status: .succeeded)
            } catch {
                cancelled.fulfill()
                throw error
            }
        }
        let runtime = LuminaAgentRuntime(tools: [tool], stepGenerator: model, configuration: luminaTestRuntimeConfiguration)
        let consumer = Task {
            for await _ in runtime.runStream(request: LuminaAgentRequest(text: "read")) {}
        }
        await fulfillment(of: [started], timeout: 2)
        consumer.cancel()
        await fulfillment(of: [cancelled], timeout: 2)
        await consumer.value
    }

    func testToolThrownCancellationRemainsCancelledInsteadOfFailed() async {
        let model = ChainRecordingModel(steps: [.action(thought: "read", call: readCall(1))])
        let tool = AnyLuminaAgentTool(schema: readTool.schema) { _, _ in throw CancellationError() }
        let runtime = LuminaAgentRuntime(tools: [tool], stepGenerator: model, configuration: luminaTestRuntimeConfiguration)
        let result = await runtime.run(request: LuminaAgentRequest(text: "read"))
        XCTAssertEqual(result.toolResults.first?.status, .cancelled)
    }

    func testPermissionAndConfirmationWaitForActualDecisionAndCancelExplicitly() async {
        for stage in ["permission", "confirmation"] {
            let entered = expectation(description: "\(stage) waits for a decision")
            let released = expectation(description: "\(stage) delayed decision released")
            let gate = ChainManualDecision(entered: entered, released: released)
            let model = ChainRecordingModel(steps: [.action(thought: "read", call: readCall(1))])
            var schema = readTool.schema
            schema.sideEffect = .appLocalWrite
            let tool = AnyLuminaAgentTool(schema: schema) { _, _ in
                LuminaToolResult(callID: UUID(), toolName: "record.read", status: .succeeded)
            }
            let runtime = LuminaAgentRuntime(
                tools: [tool], stepGenerator: model, configuration: luminaTestRuntimeConfiguration,
                permissionGate: stage == "permission" ? gate : ChainConfirmationPermission(),
                confirmationCoordinator: gate
            )
            let completed = expectation(description: "\(stage) explicit cancellation ends run")
            let run = Task {
                let result = await runtime.run(request: LuminaAgentRequest(text: "read"))
                completed.fulfill()
                return result
            }
            await fulfillment(of: [entered], timeout: 2)
            run.cancel()
            await fulfillment(of: [completed], timeout: 2)
            let result = await run.value
            XCTAssertEqual(result.status, .cancelled)
            XCTAssertFalse(result.toolResults.contains { $0.status == .succeeded })
            // A UI provider can deliver its user response after cancellation. This must be ignored.
            await gate.resolve()
            await fulfillment(of: [released], timeout: 2)
        }
    }

    private func readCall(_ value: Int) -> LuminaToolCall {
        LuminaToolCall(toolName: "record.read", arguments: ["index": .number(Double(value))])
    }

    private var readTool: AnyLuminaAgentTool {
        AnyLuminaAgentTool(schema: LuminaToolSchema(
            name: "record.read", description: "Read a record.",
            parameters: [.init(name: "index", type: .number, description: "Record index.")], sideEffect: .readOnly
        )) { _, _ in
            LuminaToolResult(callID: UUID(), toolName: "record.read", status: .succeeded,
                             output: ["value": .string("RAW")], content: [.text("RAW")])
        }
    }
}

private actor ChainRecordingModel: LuminaReActStepGenerator {
    var steps: [LuminaReActStep]
    var contexts: [LuminaReActStepContext] = []
    init(steps: [LuminaReActStep]) { self.steps = steps }
    func nextStep(context: LuminaReActStepContext) async throws -> LuminaReActStep {
        contexts.append(context)
        return steps.isEmpty ? .result("done") : steps.removeFirst()
    }
}

private struct ChainRedactingGuardrail: LuminaToolOutputGuardrail {
    func evaluate(result: LuminaToolResult, call: LuminaToolCall, schema: LuminaToolSchema,
                  request: LuminaAgentRequest) async -> LuminaGuardrailDecision<LuminaToolResult> {
        var result = result
        result.output = ["value": .string("sanitized")]
        result.content = [.text("sanitized")]
        return .rewrite(result)
    }
}

private struct ChainCancellationModel: LuminaReActStepGenerator {
    let started: XCTestExpectation
    let cancelled: XCTestExpectation
    func nextStep(context: LuminaReActStepContext) async throws -> LuminaReActStep {
        started.fulfill()
        do {
            try await Task.sleep(for: .seconds(30))
            return .result("too late")
        } catch {
            cancelled.fulfill()
            throw error
        }
    }
}

private struct ChainConfirmationPermission: LuminaPermissionGate {
    func decision(for call: LuminaToolCall, schema: LuminaToolSchema,
                  request: LuminaAgentRequest) async -> LuminaPermissionDecision {
        .requiresConfirmation(reason: "Wait for user decision.")
    }
}

private actor ChainManualDecision: LuminaPermissionGate, LuminaConfirmationCoordinator {
    let entered: XCTestExpectation
    let released: XCTestExpectation
    var continuation: CheckedContinuation<Void, Never>?
    init(entered: XCTestExpectation, released: XCTestExpectation) {
        self.entered = entered
        self.released = released
    }
    private func waitForDecision() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            entered.fulfill()
        }
        released.fulfill()
    }
    func resolve() {
        continuation?.resume()
        continuation = nil
    }
    func decision(for call: LuminaToolCall, schema: LuminaToolSchema,
                  request: LuminaAgentRequest) async -> LuminaPermissionDecision {
        await waitForDecision()
        return .allowed
    }
    func confirm(call: LuminaToolCall, schema: LuminaToolSchema, reason: String) async -> Bool {
        await waitForDecision()
        return true
    }
}
