import XCTest
@testable import AgentRuntime
import LuminaModelRuntime

#if canImport(CoreML)
import CoreML
#endif

final class ReActRuntimeTests: XCTestCase {
    func testRuntimeExecutesReActActionObservationFinal() async {
        let planner = ScriptedReActPlanner(steps: [
            .action(thought: "Need local context.", call: LuminaToolCall(toolName: "local.search", arguments: ["query": .string("coffee")])),
            .final("### Done\n\nFound context.")
        ])
        let tool = AnyLuminaAgentTool(schema: LuminaToolSchema(name: "local.search", description: "Search", parameters: [], sideEffect: .readOnly)) { _, _ in
            LuminaToolResult(callID: UUID(), toolName: "local.search", status: .succeeded, content: [.markdown("### Result\n\n- coffee")])
        }
        let runtime = LuminaAgentRuntime(tools: [tool], reactPlanner: planner)

        let result = await runtime.run(request: LuminaAgentRequest(text: "查 coffee"))

        XCTAssertEqual(result.status, .succeeded)
        XCTAssertEqual(result.toolResults.count, 1)
        XCTAssertEqual(result.reactTrace?.actionCount, 1)
        XCTAssertTrue(result.reactTrace?.observations.first?.summary.contains("coffee") == true)
    }

    func testRuntimeLoadsInjectedContextBeforeReActPlanning() async {
        let contextProvider = CountingContextProvider()
        let planner = ContextAwareReActPlanner()
        let runtime = LuminaAgentRuntime(
            tools: [],
            reactPlanner: planner,
            contextProvider: contextProvider
        )

        let result = await runtime.run(request: LuminaAgentRequest(text: "用我的记忆回答"))

        let loadCount = await contextProvider.loadCount
        XCTAssertEqual(loadCount, 1)
        XCTAssertTrue(result.plan.summary.contains("真实记忆摘要"))
    }

    func testRuntimeAutoCompactsTraceNearContextBudgetAndPreservesToolBudget() async {
        let tool = AnyLuminaAgentTool(schema: LuminaToolSchema(name: "local.search", description: "Search", parameters: [], sideEffect: .readOnly)) { _, _ in
            LuminaToolResult(
                callID: UUID(),
                toolName: "local.search",
                status: .succeeded,
                content: [.markdown(String(repeating: "本地检索结果很长。", count: 180))]
            )
        }
        let runtime = LuminaAgentRuntime(
            tools: [tool],
            reactPlanner: BudgetAwareReActPlanner(),
            configuration: LuminaAgentRuntimeConfiguration(
                maximumToolCalls: 2,
                maximumReActIterations: 8,
                maximumObservationCharacters: 900,
                contextWindowCharacterBudget: 900,
                autoCompactThreshold: 0.2,
                preservedStepsAfterCompaction: 0
            )
        )

        let result = await runtime.run(request: LuminaAgentRequest(text: "连续检索两次"))

        XCTAssertEqual(result.toolResults.count, 2)
        XCTAssertEqual(result.reactTrace?.actionCount, 2)
        XCTAssertTrue((result.reactTrace?.compactionCount ?? 0) > 0)
        XCTAssertTrue(result.reactTrace?.observations.contains(where: { $0.toolName == "runtime.context_compaction" }) == true)
        XCTAssertTrue(result.plan.summary.contains("compactions="))
    }

    func testReActParserRejectsUnknownTool() throws {
        let json = """
        {"type":"tool_use","thought":"x","tool_name":"missing","parameters":{},"requires_confirmation":false}
        """

        XCTAssertThrowsError(try LuminaReActStepParser.parse(json: json, availableTools: []))
    }

    func testReActParserParsesStandardFinalAnswerShape() throws {
        let step = try LuminaReActStepParser.parse(
            json: """
            {"type":"final_answer","final_answer":"## 完成\\n\\n已处理。"}
            """,
            availableTools: []
        )

        XCTAssertEqual(step.kind, .final)
        XCTAssertEqual(step.finalMarkdown, "## 完成\n\n已处理。")
    }

    func testReActParserRejectsLegacyActionShape() throws {
        let json = """
        {"kind":"action","thought":"x","action":{"toolName":"local.search","arguments":{},"requiresConfirmation":false}}
        """

        XCTAssertThrowsError(try LuminaReActStepParser.parse(
            json: json,
            availableTools: [LuminaToolSchema(name: "local.search", description: "Search", parameters: [], sideEffect: .readOnly)]
        ))
    }

    func testReActParserAcceptsFlatToolUseShape() throws {
        let schema = LuminaToolSchema(name: "local.search", description: "Search", parameters: [], sideEffect: .readOnly)

        let step = try LuminaReActStepParser.parse(
            json: """
            {"type":"tool_use","thought":"x","tool_name":"local.search","parameters":{"query":"coffee"},"requires_confirmation":false}
            """,
            availableTools: [schema]
        )

        XCTAssertEqual(step.action?.toolName, "local.search")
        XCTAssertEqual(step.action?.arguments["query"], .string("coffee"))
    }

    func testReActParserRejectsNonStandardToolCallAliases() throws {
        let schema = LuminaToolSchema(name: "local.search", description: "Search", parameters: [], sideEffect: .readOnly)

        XCTAssertThrowsError(try LuminaReActStepParser.parse(
            json: """
            {"type":"tool_use","thought":"x","tool_call":{"name":"local.search","parameters":{}}}
            """,
            availableTools: [schema]
        ))

        XCTAssertThrowsError(try LuminaReActStepParser.parse(
            json: """
            {"type":"tool_use","reasoning":"x","tool_name":"local.search","parameters":{},"requires_confirmation":false}
            """,
            availableTools: [schema]
        ))

        XCTAssertThrowsError(try LuminaReActStepParser.parse(
            json: """
            {"type":"tool_use","thought":"x","tool_use":{"name":"local.search","input":{},"requires_confirmation":false}}
            """,
            availableTools: [schema]
        ))
    }

    func testIterationLimitReturnsMarkdownFinal() async {
        let planner = ScriptedReActPlanner(steps: [.thought("still thinking"), .thought("again")])
        let runtime = LuminaAgentRuntime(
            tools: [],
            reactPlanner: planner,
            configuration: LuminaAgentRuntimeConfiguration(maximumToolCalls: 2, maximumReActIterations: 1)
        )

        let result = await runtime.run(request: LuminaAgentRequest(text: "do it"))

        XCTAssertEqual(result.status, .succeeded)
        XCTAssertEqual(result.reactTrace?.terminationReason, "budget")
        XCTAssertTrue(result.plan.summary.contains("执行预算"))
    }

    func testReActFinalDoesNotNestMarkdownHeadingInsideListItem() async {
        let planner = StaticReActPlanner(toolName: "device.current_time")
        let tool = AnyLuminaAgentTool(schema: LuminaToolSchema(name: "device.current_time", description: "Current time", parameters: [], sideEffect: .readOnly)) { _, _ in
            LuminaToolResult(
                callID: UUID(),
                toolName: "device.current_time",
                status: .succeeded,
                output: ["localizedTime": .string("10:41")],
                content: [.markdown("### 本机时间\n\n- 时间：10:41")]
            )
        }
        let runtime = LuminaAgentRuntime(tools: [tool], reactPlanner: planner)

        let result = await runtime.run(request: LuminaAgentRequest(text: "现在几点"))

        XCTAssertFalse(result.plan.summary.contains("- **device.current_time**: ###"))
        XCTAssertTrue(result.plan.summary.contains("## 执行结果"))
        XCTAssertTrue(result.plan.summary.contains("### 本机时间"))
        XCTAssertFalse(result.plan.summary.contains("localizedTime"))
    }

    func testReActFinalDeduplicatesRepeatedObservations() async {
        let planner = StaticReActPlanner(toolName: "local.search")
        let tool = AnyLuminaAgentTool(schema: LuminaToolSchema(name: "local.search", description: "Search", parameters: [], sideEffect: .readOnly)) { _, _ in
            LuminaToolResult(
                callID: UUID(),
                toolName: "local.search",
                status: .succeeded,
                output: ["results": .array([])],
                content: [.markdown("### 本地检索结果\n\n没有找到结果。")]
            )
        }
        let runtime = LuminaAgentRuntime(
            tools: [tool],
            reactPlanner: planner,
            configuration: LuminaAgentRuntimeConfiguration(maximumToolCalls: 3)
        )

        let result = await runtime.run(request: LuminaAgentRequest(text: "查本地数据"))

        XCTAssertEqual(result.toolResults.count, 1)
        XCTAssertEqual(result.plan.summary.components(separatedBy: "### 本地检索结果").count - 1, 1)
        XCTAssertFalse(result.plan.summary.contains("results"))
    }
}

final class AgentRuntimePerformanceTests: XCTestCase {
    func testRunStreamFirstEventLatency() async {
        let runtime = LuminaAgentRuntime(tools: [], reactPlanner: LuminaNoOpReActPlanner())
        let start = ContinuousClock.now
        var firstEventMilliseconds = Double.greatestFiniteMagnitude

        for await _ in runtime.runStream(request: LuminaAgentRequest(text: "hello")) {
            firstEventMilliseconds = TestClock.milliseconds(since: start)
            break
        }

        XCTAssertLessThan(firstEventMilliseconds, PerformanceBudget.strict ? 50 : 500)
    }

    func testNoAvailablePlannerFailsRunInsteadOfCompleting() async {
        let runtime = LuminaAgentRuntime(tools: [], reactPlanner: LuminaNoOpReActPlanner())

        let result = await runtime.run(request: LuminaAgentRequest(text: "帮我创建提醒"))

        XCTAssertEqual(result.status, .failed)
        XCTAssertTrue(result.plan.summary.contains("No available ReAct planner"))
        XCTAssertTrue(result.toolResults.isEmpty)
    }

    func testMockReActReadOnlyRunLatency() async {
        let tool = AnyLuminaAgentTool(schema: LuminaToolSchema(name: "local.search", description: "Search", parameters: [], sideEffect: .readOnly)) { _, _ in
            LuminaToolResult(callID: UUID(), toolName: "local.search", status: .succeeded)
        }
        var samples: [Double] = []

        for _ in 0..<20 {
            let planner = ScriptedReActPlanner(steps: [
                .action(thought: "search", call: LuminaToolCall(toolName: "local.search", arguments: [:])),
                .final("done")
            ])
            let runtime = LuminaAgentRuntime(tools: [tool], reactPlanner: planner)
            let start = ContinuousClock.now
            _ = await runtime.run(request: LuminaAgentRequest(text: "查"))
            samples.append(TestClock.milliseconds(since: start))
        }

        XCTAssertLessThan(samples.percentile95, PerformanceBudget.strict ? 180 : 800)
    }

    func testCancellationLatencyForSlowPlanner() async {
        let runtime = LuminaAgentRuntime(tools: [], reactPlanner: SlowReActPlanner(delayNanoseconds: 2_000_000_000))
        let task = Task { await runtime.run(request: LuminaAgentRequest(text: "cancel")) }
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
        let model = try LuminaCoreMLTextToJSONModel(configuration: .init(modelURL: URL(fileURLWithPath: path)))
        let start = ContinuousClock.now
        let json = try await model.generateJSON(prompt: """
        Return {"type":"final_answer","final_answer":"ok"} exactly.
        """)
        let elapsed = TestClock.milliseconds(since: start)

        XCTAssertFalse(json.isEmpty)
        XCTAssertLessThan(elapsed, PerformanceBudget.strict ? 2_000 : 10_000)
        #else
        throw XCTSkip("CoreML is unavailable on this platform.")
        #endif
    }

    func testOptionalGemma4StatefulCoreMLAssetsLoad() throws {
        guard ProcessInfo.processInfo.environment["LUMINA_RUN_MODEL_BENCHMARKS"] == "1" else {
            throw XCTSkip("Set LUMINA_RUN_MODEL_BENCHMARKS=1 to run Gemma4 asset smoke test.")
        }
        guard let path = ProcessInfo.processInfo.environment["LUMINA_GEMMA4_STATEFUL_MODEL"], !path.isEmpty else {
            throw XCTSkip("Set LUMINA_GEMMA4_STATEFUL_MODEL to the downloaded Gemma4Planner directory.")
        }
        #if canImport(CoreML)
        let root = URL(fileURLWithPath: path)
        let chunks = [1, 2, 3].map { root.appendingPathComponent("chunk_\($0).mlmodelc") }
        for chunk in chunks {
            XCTAssertTrue(FileManager.default.fileExists(atPath: chunk.path), "Missing \(chunk.lastPathComponent)")
        }

        let start = ContinuousClock.now
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndNeuralEngine
        for chunk in chunks {
            _ = try MLModel(contentsOf: chunk, configuration: configuration)
        }
        let elapsed = TestClock.milliseconds(since: start)

        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("hf_model/tokenizer.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("model_config.json").path))
        XCTAssertLessThan(elapsed, PerformanceBudget.strict ? 30_000 : 120_000)
        #else
        throw XCTSkip("CoreML is unavailable on this platform.")
        #endif
    }
}

private actor ScriptedReActPlanner: LuminaReActPlanner {
    private var steps: [LuminaReActStep]

    init(steps: [LuminaReActStep]) {
        self.steps = steps
    }

    func nextStep(context: LuminaReActPlannerContext) async throws -> LuminaReActStep {
        guard !steps.isEmpty else { return .final("done") }
        return steps.removeFirst()
    }
}

private struct SlowReActPlanner: LuminaReActPlanner {
    var delayNanoseconds: UInt64

    func nextStep(context: LuminaReActPlannerContext) async throws -> LuminaReActStep {
        try await Task.sleep(nanoseconds: delayNanoseconds)
        return .final("done")
    }
}

private struct StaticReActPlanner: LuminaReActPlanner {
    var toolName: String

    func nextStep(context: LuminaReActPlannerContext) async throws -> LuminaReActStep {
        guard context.trace.actionCount == 0 else {
            let observations = context.trace.observations.reduce(into: [LuminaReActObservation]()) { partial, observation in
                let signature = "\(observation.toolName)|\(observation.status.rawValue)|\(observation.summary)"
                guard !partial.contains(where: { "\($0.toolName)|\($0.status.rawValue)|\($0.summary)" == signature }) else { return }
                partial.append(observation)
            }
            let markdown = observations.map { observation in
                let summary = observation.summary.trimmingCharacters(in: .whitespacesAndNewlines)
                return summary.hasPrefix("#") ? summary : "### \(observation.toolName)\n\n\(summary)"
            }.joined(separator: "\n\n")
            return .final("## 执行结果\n\n\(markdown)")
        }
        return .action(thought: "static", call: LuminaToolCall(toolName: toolName, arguments: [:]))
    }
}

private actor CountingContextProvider: LuminaRuntimeContextProvider {
    private(set) var loadCount = 0

    func loadContext(_ request: LuminaRuntimeContextRequest) async throws -> LuminaRuntimeContext {
        loadCount += 1
        return LuminaRuntimeContext(sections: [
            LuminaRuntimeContextSection(
                id: "memory:real",
                title: "真实记忆",
                summary: "真实记忆摘要",
                content: "真实记忆摘要",
                source: "local/test",
                sensitivity: .normal,
                disclosureLevel: 0
            )
        ])
    }
}

private struct ContextAwareReActPlanner: LuminaReActPlanner {
    func nextStep(context: LuminaReActPlannerContext) async throws -> LuminaReActStep {
        LuminaReActStep(kind: .final, finalMarkdown: context.loadedContext.sections.first?.summary ?? "missing context")
    }
}

private struct BudgetAwareReActPlanner: LuminaReActPlanner {
    func nextStep(context: LuminaReActPlannerContext) async throws -> LuminaReActStep {
        guard context.trace.actionCount < 2 else {
            return .final("done compactions=\(context.trace.compactionCount)")
        }
        return .action(
            thought: "search",
            call: LuminaToolCall(toolName: "local.search", arguments: ["query": .string("budget")])
        )
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
