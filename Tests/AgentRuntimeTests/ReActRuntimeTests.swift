import XCTest
@testable import AgentRuntime

final class ReActRuntimeTests: XCTestCase {
    func testRuntimeExecutesReActActionObservationFinal() async {
        let planner = ScriptedReActPlanner(steps: [
            .action(thought: "Need local context.", call: ToolCall(toolName: "local.search", arguments: ["query": .string("coffee")])),
            .final("### Done\n\nFound context.")
        ])
        let tool = AnyAgentTool(schema: ToolSchema(name: "local.search", description: "Search", parameters: [], sideEffect: .readOnly)) { _, _ in
            ToolResult(callID: UUID(), toolName: "local.search", status: .succeeded, content: [.markdown("### Result\n\n- coffee")])
        }
        let runtime = AgentRuntime(tools: [tool], reactPlanner: planner)

        let result = await runtime.run(request: AgentRequest(text: "查 coffee"))

        XCTAssertEqual(result.status, .succeeded)
        XCTAssertEqual(result.toolResults.count, 1)
        XCTAssertEqual(result.reactTrace?.actionCount, 1)
        XCTAssertTrue(result.reactTrace?.observations.first?.summary.contains("coffee") == true)
    }

    func testReActParserRejectsUnknownTool() throws {
        let json = """
        {"kind":"action","thought":"x","action":{"toolName":"missing","arguments":{},"requiresConfirmation":false}}
        """

        XCTAssertThrowsError(try ReActStepParser.parse(json: json, availableTools: []))
    }

    func testIterationLimitReturnsMarkdownFinal() async {
        let planner = ScriptedReActPlanner(steps: [.thought("still thinking"), .thought("again")])
        let runtime = AgentRuntime(
            tools: [],
            reactPlanner: planner,
            configuration: AgentRuntimeConfiguration(maximumToolCalls: 2, maximumReActIterations: 1)
        )

        let result = await runtime.run(request: AgentRequest(text: "do it"))

        XCTAssertEqual(result.status, .succeeded)
        XCTAssertEqual(result.reactTrace?.terminationReason, "budget")
        XCTAssertTrue(result.plan.summary.contains("执行预算"))
    }
}

final class AgentRuntimePerformanceTests: XCTestCase {
    func testRunStreamFirstEventLatency() async {
        let runtime = AgentRuntime(tools: [], planner: RuleBasedPlanner())
        let start = ContinuousClock.now
        var firstEventMilliseconds = Double.greatestFiniteMagnitude

        for await _ in runtime.runStream(request: AgentRequest(text: "hello")) {
            firstEventMilliseconds = TestClock.milliseconds(since: start)
            break
        }

        XCTAssertLessThan(firstEventMilliseconds, PerformanceBudget.strict ? 50 : 500)
    }

    func testMockReActReadOnlyRunLatency() async {
        let tool = AnyAgentTool(schema: ToolSchema(name: "local.search", description: "Search", parameters: [], sideEffect: .readOnly)) { _, _ in
            ToolResult(callID: UUID(), toolName: "local.search", status: .succeeded)
        }
        var samples: [Double] = []

        for _ in 0..<20 {
            let planner = ScriptedReActPlanner(steps: [
                .action(thought: "search", call: ToolCall(toolName: "local.search", arguments: [:])),
                .final("done")
            ])
            let runtime = AgentRuntime(tools: [tool], reactPlanner: planner)
            let start = ContinuousClock.now
            _ = await runtime.run(request: AgentRequest(text: "查"))
            samples.append(TestClock.milliseconds(since: start))
        }

        XCTAssertLessThan(samples.percentile95, PerformanceBudget.strict ? 180 : 800)
    }

    func testCancellationLatencyForSlowPlanner() async {
        let runtime = AgentRuntime(tools: [], reactPlanner: SlowReActPlanner(delayNanoseconds: 2_000_000_000))
        let task = Task { await runtime.run(request: AgentRequest(text: "cancel")) }
        try? await Task.sleep(nanoseconds: 50_000_000)
        let start = ContinuousClock.now
        task.cancel()
        let result = await task.value
        let elapsed = TestClock.milliseconds(since: start)

        XCTAssertEqual(result.status, .cancelled)
        XCTAssertLessThan(elapsed, PerformanceBudget.strict ? 100 : 500)
    }

    func testOptionalCoreMLPlannerModelContract() async throws {
        guard ProcessInfo.processInfo.environment["LUMINA_RUN_MODEL_BENCHMARKS"] == "1" else {
            throw XCTSkip("Set LUMINA_RUN_MODEL_BENCHMARKS=1 to run Core ML planner benchmark.")
        }
        guard let path = ProcessInfo.processInfo.environment["LUMINA_GEMMA4_PLANNER_MODEL"], !path.isEmpty else {
            throw XCTSkip("Set LUMINA_GEMMA4_PLANNER_MODEL to a compiled planner .mlmodelc.")
        }
        #if canImport(CoreML)
        let model = try CoreMLTextToJSONModel(configuration: .init(modelURL: URL(fileURLWithPath: path)))
        let start = ContinuousClock.now
        let json = try await model.generateJSON(prompt: """
        Return {"summary":"ok","toolCalls":[]} exactly.
        """)
        let elapsed = TestClock.milliseconds(since: start)

        XCTAssertFalse(json.isEmpty)
        XCTAssertLessThan(elapsed, PerformanceBudget.strict ? 2_000 : 10_000)
        #else
        throw XCTSkip("CoreML is unavailable on this platform.")
        #endif
    }
}

private actor ScriptedReActPlanner: ReActPlanner {
    private var steps: [ReActStep]

    init(steps: [ReActStep]) {
        self.steps = steps
    }

    func nextStep(context: ReActPlannerContext) async throws -> ReActStep {
        guard !steps.isEmpty else { return .final("done") }
        return steps.removeFirst()
    }
}

private struct SlowReActPlanner: ReActPlanner {
    var delayNanoseconds: UInt64

    func nextStep(context: ReActPlannerContext) async throws -> ReActStep {
        try await Task.sleep(nanoseconds: delayNanoseconds)
        return .final("done")
    }
}

enum PerformanceBudget {
    static var strict: Bool {
        ProcessInfo.processInfo.environment["LUMINA_STRICT_PERF"] == "1"
    }
}

enum TestClock {
    static func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let duration = start.duration(to: .now).components
        return Double(duration.seconds) * 1_000 + Double(duration.attoseconds) / 1e15
    }
}

private extension Array where Element == Double {
    var percentile95: Double {
        guard !isEmpty else { return 0 }
        let sortedValues = sorted()
        let index = Swift.min(sortedValues.count - 1, Int(Double(sortedValues.count - 1) * 0.95))
        return sortedValues[index]
    }
}
