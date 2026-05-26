import Foundation
import LuminaAgentRuntime
@testable import LuminaAgentClient
import XCTest

private final class AxCaptureStore: @unchecked Sendable {
    static let shared = AxCaptureStore()

    private let lock = NSLock()
    private var plannerInputs: [String] = []
    private var events: [String] = []
    private var toolCallCount = 0

    func reset() {
        lock.lock()
        plannerInputs = []
        events = []
        toolCallCount = 0
        lock.unlock()
    }

    func appendPlannerInput(_ value: String) {
        lock.lock()
        plannerInputs.append(value)
        lock.unlock()
    }

    func appendEvent(_ value: String) {
        lock.lock()
        events.append(value)
        lock.unlock()
    }

    func incrementToolCallCount() {
        lock.lock()
        toolCallCount += 1
        lock.unlock()
    }

    func snapshot() -> (plannerInputs: [String], events: [String], toolCallCount: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (plannerInputs, events, toolCallCount)
    }
}

private func axCString(_ value: String) -> UnsafeMutablePointer<CChar>? {
    strdup(value)
}

private let axFinalModelCallback: LuminaAgentModelCallback = { plannerInput, _ in
    if let plannerInput {
        AxCaptureStore.shared.appendPlannerInput(String(cString: plannerInput))
    }
    return axCString("{\"schema_version\":\"1.0\",\"step_id\":\"s-final\",\"type\":\"final_answer\",\"thought\":\"done\",\"content\":\"## 完成\\n\\n已处理。\",\"completed\":true,\"requires_followup\":false}")
}

private let axAskUserModelCallback: LuminaAgentModelCallback = { plannerInput, _ in
    if let plannerInput {
        AxCaptureStore.shared.appendPlannerInput(String(cString: plannerInput))
    }
    return axCString(#"{"schema_version":"1.0","step_id":"s-ask","type":"ask_user","thought":"Need preference.","questions":[{"id":"time","question":"几点？","options":[{"label":"上午","description":"安排在上午"},{"label":"下午","description":"安排在下午"}]}],"allow_custom_answer":true,"requires_followup":true}"#)
}

private let axStreamingModelCallback: LuminaAgentStreamingModelCallback = { plannerInput, emit, emitContext, _ in
    if let plannerInput {
        AxCaptureStore.shared.appendPlannerInput(String(cString: plannerInput))
    }
    _ = emit?(#"{"delta":"{\"type\":\"final_answer\"","tokenCount":3}"#, emitContext)
    _ = emit?(#"{"delta":",\"content\":\"done\"}","tokenCount":2}"#, emitContext)
    return axCString(#"model said: {"schema_version":"1.0","step_id":"s-stream","type":"final_answer","thought":"done","content":"done","completed":true,"requires_followup":false}"#)
}

private let axEventCallback: LuminaAgentEventCallback = { event, _ in
    if let event {
        AxCaptureStore.shared.appendEvent(String(cString: event))
    }
}

private let axToolCallback: LuminaAgentToolCallback = { _, _ in
    AxCaptureStore.shared.incrementToolCallCount()
    return axCString(#"{"status":"succeeded","content":"should not run"}"#)
}

final class AxAlignmentRuntimeTests: XCTestCase {
    override func setUp() {
        super.setUp()
        AxCaptureStore.shared.reset()
    }

    func testTaskEnvelopeIsSemanticAndMultimodalWithoutRawRequest() throws {
        guard let runtime = LuminaAgentRuntimeCreate(#"{"maximumReActIterations":1}"#) else {
            XCTFail("Failed to create runtime")
            return
        }
        defer { LuminaAgentRuntimeDestroy(runtime) }
        LuminaAgentRuntimeSetModelCallback(runtime, axFinalModelCallback, nil)

        let request = """
        {
          "id":"task-1",
          "systemInstructions":"你是 Lumina，本地优先执行用户任务。",
          "text":"总结这张收据和这段语音",
          "localeIdentifier":"zh-Hans",
          "content":[
            {"modality":"text","text":"总结这张收据和这段语音"},
            {"modality":"image","asset":{"mimeType":"image/jpeg","filename":"receipt.jpg","summary":"咖啡收据","width":1200,"height":900}},
            {"modality":"audio","asset":{"mimeType":"audio/m4a","filename":"note.m4a","summary":"语音备忘","transcript":"下午三点提醒我","durationSeconds":8}},
            {"modality":"structured_data","value":{"source":"test"}}
          ],
          "metadata":{"debug":true}
        }
        """
        let result = request.withCString { LuminaAgentRuntimeRun(runtime, $0) }
        if let result {
            LuminaAgentRuntimeReleaseString(result)
        }

        let input = AxCaptureStore.shared.snapshot().plannerInputs.first ?? ""
        XCTAssertTrue(input.contains(#""instructions":{"system":"你是 Lumina，本地优先执行用户任务。""#))
        XCTAssertTrue(input.contains(#""task":{"user_goal":"总结这张收据和这段语音""#))
        XCTAssertTrue(input.contains(#""modalities":["audio","image","structured_data","text"]"#))
        XCTAssertTrue(input.contains(#""attachments_summary""#))
        XCTAssertTrue(input.contains(#""transcript":"下午三点提醒我""#))
        XCTAssertTrue(input.contains(#""output_contract""#))
        XCTAssertFalse(input.contains(#""raw_request":"#))
    }

    func testStreamingModelCallbackEmitsGenerationEvents() throws {
        guard let runtime = LuminaAgentRuntimeCreate(#"{"maximumReActIterations":1}"#) else {
            XCTFail("Failed to create runtime")
            return
        }
        defer { LuminaAgentRuntimeDestroy(runtime) }
        LuminaAgentRuntimeSetStreamingModelCallback(runtime, axStreamingModelCallback, nil)
        LuminaAgentRuntimeSetEventCallback(runtime, axEventCallback, nil)

        let result = LuminaAgentRuntimeRun(runtime, #"{"id":"stream","text":"hello","content":[{"modality":"text","text":"hello"}]}"#)
        if let result {
            LuminaAgentRuntimeReleaseString(result)
        }

        let events = AxCaptureStore.shared.snapshot().events.joined(separator: "\n")
        XCTAssertTrue(events.contains(#""type":"model_generation_started""#))
        XCTAssertTrue(events.contains(#""type":"model_generation_delta""#))
        XCTAssertTrue(events.contains(#""type":"model_generation_validated""#))
        XCTAssertTrue(events.contains(#""ttft_ms":"#))
        XCTAssertTrue(events.contains(#""tokens_per_second":"#))
        XCTAssertTrue(events.contains(#""extracted_standard_step":true"#))
    }

    func testExplicitSessionPausesForAskUserAndExportsTrace() throws {
        guard let runtime = LuminaAgentRuntimeCreate(#"{"maximumReActIterations":2}"#) else {
            XCTFail("Failed to create runtime")
            return
        }
        defer { LuminaAgentRuntimeDestroy(runtime) }
        LuminaAgentRuntimeSetModelCallback(runtime, axAskUserModelCallback, nil)

        guard let session = LuminaAgentRuntimeCreateSession(runtime, #"{"id":"ask","text":"帮我规划一下","content":[{"modality":"text","text":"帮我规划一下"}]}"#) else {
            XCTFail("Failed to create session")
            return
        }
        defer { LuminaAgentRuntimeDestroySession(session) }

        let runPointer = LuminaAgentRuntimeRunSession(runtime, session)
        let runJSON = runPointer.map { String(cString: $0) } ?? "{}"
        if let runPointer {
            LuminaAgentRuntimeReleaseString(runPointer)
        }
        XCTAssertTrue(runJSON.contains(#""paused":true"#))
        XCTAssertTrue(runJSON.contains(#""kind":"ask_user""#))

        let tracePointer = LuminaAgentRuntimeExportSessionTrace(session, "jsonl")
        let trace = tracePointer.map { String(cString: $0) } ?? ""
        if let tracePointer {
            LuminaAgentRuntimeReleaseString(tracePointer)
        }
        XCTAssertTrue(trace.contains("step_recorded") || trace.contains("session_paused"))
        XCTAssertTrue(trace.split(separator: "\n").allSatisfy { line in
            (try? JSONSerialization.jsonObject(with: Data(line.utf8))) != nil
        })
    }

    func testToolSchemaValidationRejectsMissingRequiredArgumentsBeforeExecution() async {
        let counter = ToolInvocationCounter()
        let tool = AnyLuminaAgentTool(
            schema: LuminaToolSchema(
                name: "local.search",
                description: "Search",
                parameters: [
                    LuminaToolParameterSchema(name: "query", type: .string, description: "Query", required: true)
                ],
                sideEffect: .readOnly
            )
        ) { _, _ in
            await counter.increment()
            return LuminaToolResult(callID: UUID(), toolName: "local.search", status: .succeeded)
        }
        let runtime = LuminaAgentRuntime(
            tools: [tool],
            stepGenerator: ScriptedAxReActModel(steps: [
                .action(thought: "search", call: LuminaToolCall(toolName: "local.search", arguments: [:])),
                .final("done")
            ])
        )

        let result = await runtime.run(request: LuminaAgentRequest(text: "查一下"))
        let invocationCount = await counter.value

        XCTAssertEqual(invocationCount, 0)
        XCTAssertEqual(result.toolResults.first?.status, .failed)
        XCTAssertTrue(result.reactTrace?.observations.first?.summary.contains("missing required parameter") == true)
    }

    func testContractExportContainsReusableRuntimeSchemas() throws {
        let pointer = LuminaAgentRuntimeExportContracts()
        let json = pointer.map { String(cString: $0) } ?? ""
        if let pointer {
            LuminaAgentRuntimeReleaseString(pointer)
        }

        XCTAssertTrue(json.contains("react_step_schema"))
        XCTAssertTrue(json.contains("task_envelope_schema"))
        XCTAssertTrue(json.contains("responder_schema"))
        XCTAssertTrue(json.contains("tool_use"))
        XCTAssertTrue(json.contains("multi_tool_use"))
        XCTAssertTrue(json.contains("cannot_complete"))
    }
}

private actor ToolInvocationCounter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}

private actor ScriptedAxReActModel: LuminaReActStepGenerator {
    private var steps: [LuminaReActStep]

    init(steps: [LuminaReActStep]) {
        self.steps = steps
    }

    func nextStep(context: LuminaReActStepContext) async throws -> LuminaReActStep {
        guard !steps.isEmpty else { return .final("done") }
        return steps.removeFirst()
    }
}
