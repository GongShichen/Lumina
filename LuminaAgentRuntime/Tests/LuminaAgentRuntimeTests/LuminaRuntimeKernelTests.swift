import Foundation
import LuminaAgentRuntimeCore
@testable import LuminaAgentRuntimeApple
import XCTest

private final class LuminaRuntimeCaptureStore: @unchecked Sendable {
    static let shared = LuminaRuntimeCaptureStore()

    private let lock = NSLock()
    private var plannerInputs: [String] = []
    private var events: [String] = []
    private var traces: [String] = []
    private var metrics: [String] = []
    private var toolCalls: [String] = []
    private var toolCallCount = 0
    private var modelCallCount = 0

    func reset() {
        lock.lock()
        plannerInputs = []
        events = []
        traces = []
        metrics = []
        toolCalls = []
        toolCallCount = 0
        modelCallCount = 0
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

    func appendTrace(_ value: String) {
        lock.lock()
        traces.append(value)
        lock.unlock()
    }

    func appendMetric(_ value: String) {
        lock.lock()
        metrics.append(value)
        lock.unlock()
    }

    func incrementToolCallCount() {
        lock.lock()
        toolCallCount += 1
        lock.unlock()
    }

    func appendToolCall(_ value: String) {
        lock.lock()
        toolCalls.append(value)
        toolCallCount += 1
        lock.unlock()
    }

    func incrementModelCallCount() -> Int {
        lock.lock()
        modelCallCount += 1
        let value = modelCallCount
        lock.unlock()
        return value
    }

    func snapshot() -> (plannerInputs: [String], events: [String], traces: [String], metrics: [String], toolCalls: [String], toolCallCount: Int, modelCallCount: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (plannerInputs, events, traces, metrics, toolCalls, toolCallCount, modelCallCount)
    }
}

private func luminaRuntimeCString(_ value: String) -> UnsafeMutablePointer<CChar>? {
    strdup(value)
}

private let luminaTraceCallback: LuminaAgentTraceCallback = { record, _ in
    if let record {
        LuminaRuntimeCaptureStore.shared.appendTrace(String(cString: record))
    }
}

private let luminaMetricsCallback: LuminaAgentMetricsCallback = { metric, _ in
    if let metric {
        LuminaRuntimeCaptureStore.shared.appendMetric(String(cString: metric))
    }
}

private let luminaFinalModelCallback: LuminaAgentModelCallback = { plannerInput, _ in
    if let plannerInput {
        LuminaRuntimeCaptureStore.shared.appendPlannerInput(String(cString: plannerInput))
    }
    return luminaRuntimeCString("{\"schema_version\":\"1.0\",\"step_id\":\"s-final\",\"type\":\"result\",\"thought\":\"done\",\"content\":\"## 完成\\n\\n已处理。\",\"completed\":true,\"requires_followup\":false}")
}

private let luminaAskUserModelCallback: LuminaAgentModelCallback = { plannerInput, _ in
    if let plannerInput {
        LuminaRuntimeCaptureStore.shared.appendPlannerInput(String(cString: plannerInput))
    }
    return luminaRuntimeCString(#"{"schema_version":"1.0","step_id":"s-ask","type":"ask_user","thought":"Need preference.","questions":[{"id":"time","question":"几点？","options":[{"label":"上午","description":"安排在上午"},{"label":"下午","description":"安排在下午"}]}],"allow_custom_answer":true,"requires_followup":true}"#)
}

private let luminaAskThenFinalModelCallback: LuminaAgentModelCallback = { plannerInput, _ in
    if let plannerInput {
        LuminaRuntimeCaptureStore.shared.appendPlannerInput(String(cString: plannerInput))
    }
    let call = LuminaRuntimeCaptureStore.shared.incrementModelCallCount()
    if call == 1 {
        return luminaRuntimeCString(#"{"schema_version":"1.0","step_id":"s-ask","type":"ask_user","thought":"Need preference.","questions":[{"id":"time","question":"几点？","options":[{"label":"上午","description":"安排在上午"},{"label":"下午","description":"安排在下午"}]}],"allow_custom_answer":true,"requires_followup":true}"#)
    }
    return luminaRuntimeCString(###"{"schema_version":"1.0","step_id":"s-final","type":"result","thought":"User answered.","content":"## 已继续\n\n收到你的回答，继续完成。","completed":true,"requires_followup":false}"###)
}

private let luminaNeedsContextThenFinalModelCallback: LuminaAgentModelCallback = { plannerInput, _ in
    if let plannerInput {
        LuminaRuntimeCaptureStore.shared.appendPlannerInput(String(cString: plannerInput))
    }
    let call = LuminaRuntimeCaptureStore.shared.incrementModelCallCount()
    if call == 1 {
        return luminaRuntimeCString(#"{"schema_version":"1.0","step_id":"s-context","type":"reasoning","thought":"Need deeper context.","needs_more_context":true,"confidence":0.7,"requires_followup":true}"#)
    }
    return luminaRuntimeCString(###"{"schema_version":"1.0","step_id":"s-final","type":"result","thought":"Context loaded.","content":"## 完成\n\n已使用更深层上下文。","completed":true,"requires_followup":false}"###)
}

private let luminaToolDiscoveryThenFinalModelCallback: LuminaAgentModelCallback = { plannerInput, _ in
    if let plannerInput {
        LuminaRuntimeCaptureStore.shared.appendPlannerInput(String(cString: plannerInput))
    }
    let call = LuminaRuntimeCaptureStore.shared.incrementModelCallCount()
    if call == 1 {
        return luminaRuntimeCString(#"{"schema_version":"1.0","step_id":"s-discover","type":"tool_discovery","thought":"Need focused calendar schema.","query":"calendar","category":"pim","max_results":2,"include_schemas":true,"requires_followup":true}"#)
    }
    return luminaRuntimeCString(###"{"schema_version":"1.0","step_id":"s-final","type":"result","thought":"Saw focused schema.","content":"## 完成\n\n已查看工具 schema。","completed":true,"requires_followup":false}"###)
}

private let luminaRepeatedIdenticalToolThenFinalModelCallback: LuminaAgentModelCallback = { plannerInput, _ in
    if let plannerInput {
        LuminaRuntimeCaptureStore.shared.appendPlannerInput(String(cString: plannerInput))
    }
    let call = LuminaRuntimeCaptureStore.shared.incrementModelCallCount()
    if call <= 2 {
        return luminaRuntimeCString(#"{"schema_version":"1.0","step_id":"s-open","type":"tool_use","thought":"Open the external surface once.","tool_name":"external.open","parameters":{"target":"compose","payload":"Hello"},"requires_followup":true}"#)
    }
    return luminaRuntimeCString(###"{"schema_version":"1.0","step_id":"s-final","type":"result","thought":"Handled.","content":"## 完成\n\n工具结果已处理。","completed":true,"requires_followup":false}"###)
}

private let luminaDifferentParametersThenFinalModelCallback: LuminaAgentModelCallback = { plannerInput, _ in
    if let plannerInput {
        LuminaRuntimeCaptureStore.shared.appendPlannerInput(String(cString: plannerInput))
    }
    let call = LuminaRuntimeCaptureStore.shared.incrementModelCallCount()
    if call == 1 {
        return luminaRuntimeCString(#"{"schema_version":"1.0","step_id":"s-a","type":"tool_use","thought":"Lookup A.","tool_name":"data.lookup","parameters":{"query":"A"},"requires_followup":true}"#)
    }
    if call == 2 {
        return luminaRuntimeCString(#"{"schema_version":"1.0","step_id":"s-b","type":"tool_use","thought":"Lookup B.","tool_name":"data.lookup","parameters":{"query":"B"},"requires_followup":true}"#)
    }
    return luminaRuntimeCString(###"{"schema_version":"1.0","step_id":"s-final","type":"result","thought":"Done.","content":"## 完成","completed":true,"requires_followup":false}"###)
}

private let luminaDifferentIdempotencyKeysThenFinalModelCallback: LuminaAgentModelCallback = { plannerInput, _ in
    if let plannerInput {
        LuminaRuntimeCaptureStore.shared.appendPlannerInput(String(cString: plannerInput))
    }
    let call = LuminaRuntimeCaptureStore.shared.incrementModelCallCount()
    if call == 1 {
        return luminaRuntimeCString(#"{"schema_version":"1.0","step_id":"s-one","type":"tool_use","thought":"Create first instance.","tool_name":"record.create","parameters":{"title":"same","idempotency_key":"one"},"requires_followup":true}"#)
    }
    if call == 2 {
        return luminaRuntimeCString(#"{"schema_version":"1.0","step_id":"s-two","type":"tool_use","thought":"Create second instance.","tool_name":"record.create","parameters":{"title":"same","idempotency_key":"two"},"requires_followup":true}"#)
    }
    return luminaRuntimeCString(###"{"schema_version":"1.0","step_id":"s-final","type":"result","thought":"Done.","content":"## 完成","completed":true,"requires_followup":false}"###)
}

private let luminaAlwaysExecuteThenFinalModelCallback: LuminaAgentModelCallback = { plannerInput, _ in
    if let plannerInput {
        LuminaRuntimeCaptureStore.shared.appendPlannerInput(String(cString: plannerInput))
    }
    let call = LuminaRuntimeCaptureStore.shared.incrementModelCallCount()
    if call <= 2 {
        return luminaRuntimeCString(#"{"schema_version":"1.0","step_id":"s-status","type":"tool_use","thought":"Read fresh status.","tool_name":"status.read","parameters":{"scope":"live"},"requires_followup":true}"#)
    }
    return luminaRuntimeCString(###"{"schema_version":"1.0","step_id":"s-final","type":"result","thought":"Done.","content":"## 完成","completed":true,"requires_followup":false}"###)
}

private let luminaReorderedParametersThenFinalModelCallback: LuminaAgentModelCallback = { plannerInput, _ in
    if let plannerInput {
        LuminaRuntimeCaptureStore.shared.appendPlannerInput(String(cString: plannerInput))
    }
    let call = LuminaRuntimeCaptureStore.shared.incrementModelCallCount()
    if call == 1 {
        return luminaRuntimeCString(#"{"schema_version":"1.0","step_id":"s-first","type":"tool_use","thought":"Call once.","tool_name":"canonical.action","parameters":{"b":"2","a":"1"},"requires_followup":true}"#)
    }
    if call == 2 {
        return luminaRuntimeCString(#"{"schema_version":"1.0","step_id":"s-second","type":"tool_use","thought":"Call duplicate with reordered parameters.","tool_name":"canonical.action","parameters":{"a":"1","b":"2"},"requires_followup":true}"#)
    }
    return luminaRuntimeCString(###"{"schema_version":"1.0","step_id":"s-final","type":"result","thought":"Done.","content":"## 完成","completed":true,"requires_followup":false}"###)
}

private let luminaUnsafeToolThenFinalModelCallback: LuminaAgentModelCallback = { plannerInput, _ in
    if let plannerInput {
        LuminaRuntimeCaptureStore.shared.appendPlannerInput(String(cString: plannerInput))
    }
    let call = LuminaRuntimeCaptureStore.shared.incrementModelCallCount()
    if call == 1 {
        return luminaRuntimeCString(#"{"schema_version":"1.0","step_id":"s-unsafe","type":"tool_use","thought":"Use proposed tool.","tool_name":"unsafe.write","parameters":{"query":"secret"},"requires_followup":true}"#)
    }
    return luminaRuntimeCString(###"{"schema_version":"1.0","step_id":"s-final","type":"result","thought":"Done.","content":"## 完成","completed":true,"requires_followup":false}"###)
}

private let luminaContextCallback: LuminaAgentContextCallback = { contextRequest, _ in
    let request = contextRequest.map { String(cString: $0) } ?? ""
    if request.contains(#""request_more_context":true"#) {
        return luminaRuntimeCString(#"[{"id":"deep","title":"Deep context","summary":"更深层上下文","priority":10,"disclosure_level":1}]"#)
    }
    return luminaRuntimeCString(#"[{"id":"initial","title":"Initial context","summary":"首轮摘要","priority":100,"disclosure_level":0}]"#)
}

private let luminaStreamingModelCallback: LuminaAgentStreamingModelCallback = { plannerInput, emit, emitContext, _ in
    if let plannerInput {
        LuminaRuntimeCaptureStore.shared.appendPlannerInput(String(cString: plannerInput))
    }
    _ = emit?(#"{"delta":"{\"type\":\"result\"","tokenCount":3}"#, emitContext)
    _ = emit?(#"{"delta":",\"content\":\"done\"}","tokenCount":2}"#, emitContext)
    return luminaRuntimeCString(#"model said: {"schema_version":"1.0","step_id":"s-stream","type":"result","thought":"done","content":"done","completed":true,"requires_followup":false}"#)
}

private let luminaEventCallback: LuminaAgentEventCallback = { event, _ in
    if let event {
        LuminaRuntimeCaptureStore.shared.appendEvent(String(cString: event))
    }
}

private let luminaToolCallback: LuminaAgentToolCallback = { _, _ in
    LuminaRuntimeCaptureStore.shared.incrementToolCallCount()
    return luminaRuntimeCString(#"{"status":"succeeded","content":"should not run"}"#)
}

private let luminaRecordingToolCallback: LuminaAgentToolCallback = { call, _ in
    if let call {
        LuminaRuntimeCaptureStore.shared.appendToolCall(String(cString: call))
    }
    return luminaRuntimeCString(#"{"status":"succeeded","content":"rewritten tool ran"}"#)
}

private let luminaRejectRequestGuardrailCallback: LuminaAgentGuardrailCallback = { request, _ in
    let text = request.map { String(cString: $0) } ?? ""
    if text.contains(#""stage":"request""#) {
        return luminaRuntimeCString(#"{"decision":"reject","message":"blocked by core guardrail"}"#)
    }
    return luminaRuntimeCString(#"{"decision":"allow"}"#)
}

private let luminaRewriteToolHookCallback: LuminaAgentHookCallback = { event, _ in
    let text = event.map { String(cString: $0) } ?? ""
    if text.contains(#""route_id":"rewrite-unsafe""#) {
        return luminaRuntimeCString(#"{"directives":[{"type":"rewrite_tool_call","tool_name":"data.lookup","parameters":{"query":"safe"},"requires_confirmation":false}]}"#)
    }
    return luminaRuntimeCString("{}")
}

private func registerAskUserSchema(on runtime: OpaquePointer) {
    let pointer = LuminaAgentRuntimeRegisterToolSchema(
        runtime,
        #"{"name":"ask_user","description":"Ask the user for missing information.","category":"control","searchHint":"clarify user preference choice question","sideEffect":"readOnly","readOnly":true,"requiresUserInteraction":true,"parameters":[{"name":"questions","type":"array","required":true},{"name":"reason","type":"string","required":false},{"name":"sensitivity","type":"string","required":false},{"name":"timeoutSeconds","type":"number","required":false},{"name":"allow_custom_answer","type":"boolean","required":false}]}"#
    )
    if let pointer {
        LuminaAgentRuntimeReleaseString(pointer)
    }
}

final class LuminaRuntimeKernelTests: XCTestCase {
    override func setUp() {
        super.setUp()
        LuminaRuntimeCaptureStore.shared.reset()
    }

    func testCanonicalContractRejectsLegacyFinalAnswerType() {
        let legacy = #"{"type":"final_answer","content":"done"}"#
        let result = legacy.withCString { LuminaReActValidateStepJSON($0) }
        defer { LuminaAgentRuntimeReleaseString(result) }
        let text = result.map { String(cString: $0) } ?? ""
        XCTAssertTrue(text.contains(#""ok":false"#))
        XCTAssertTrue(text.contains("unknown ReAct step type"))
    }

    func testXMLTagDialectNormalizesToCanonicalResultAndToolUse() {
        let resultOutput = "<thought>done</thought><result>完成</result>"
        let normalizedResult = resultOutput.withCString { text in
            "xml_tags".withCString { dialect in
                LuminaReActNormalizeStepText(text, dialect)
            }
        }
        defer { LuminaAgentRuntimeReleaseString(normalizedResult) }
        let resultText = normalizedResult.map { String(cString: $0) } ?? ""
        XCTAssertTrue(resultText.contains(#""ok":true"#))
        XCTAssertTrue(resultText.contains(#"\"type\":\"result\""#))

        let toolOutput = #"<thought>need time</thought><tool_use name="device.current_time">{}</tool_use>"#
        let normalizedTool = toolOutput.withCString { text in
            "xml_tags".withCString { dialect in
                LuminaReActNormalizeStepText(text, dialect)
            }
        }
        defer { LuminaAgentRuntimeReleaseString(normalizedTool) }
        let toolText = normalizedTool.map { String(cString: $0) } ?? ""
        XCTAssertTrue(toolText.contains(#""ok":true"#))
        XCTAssertTrue(toolText.contains(#"\"type\":\"tool_use\""#))
        XCTAssertTrue(toolText.contains(#"\"tool_name\":\"device.current_time\""#))

        let sideEffectToolOutput = #"<thought>create it</thought><tool_use name="calendar.create" requires_confirmation="true">{"title":"Demo","startDateISO":"2026-05-31T12:00:00+08:00"}</tool_use>"#
        let normalizedSideEffectTool = sideEffectToolOutput.withCString { text in
            "xml_tags".withCString { dialect in
                LuminaReActNormalizeStepText(text, dialect)
            }
        }
        defer { LuminaAgentRuntimeReleaseString(normalizedSideEffectTool) }
        let sideEffectToolText = normalizedSideEffectTool.map { String(cString: $0) } ?? ""
        XCTAssertTrue(sideEffectToolText.contains(#""ok":true"#))
        XCTAssertTrue(sideEffectToolText.contains(#"\"requires_confirmation\":true"#))

        let askUserOutput = #"<thought>need preference</thought><ask_user>{"reason":"缺少偏好","questions":[{"id":"p","question":"选哪个？"}],"sensitivity":"normal","timeout_seconds":120,"allow_custom_answer":true}</ask_user>"#
        let normalizedAskUser = askUserOutput.withCString { text in
            "xml_tags".withCString { dialect in
                LuminaReActNormalizeStepText(text, dialect)
            }
        }
        defer { LuminaAgentRuntimeReleaseString(normalizedAskUser) }
        let askUserText = normalizedAskUser.map { String(cString: $0) } ?? ""
        XCTAssertTrue(askUserText.contains(#""ok":true"#))
        XCTAssertTrue(askUserText.contains(#"\"type\":\"ask_user\""#))
    }

    func testObservabilitySinksAreOptionalAndIndependentlyRegistered() throws {
        guard let silentRuntime = LuminaAgentRuntimeCreate(luminaKernelRuntimeConfigurationJSON(maxIterations: 1)) else {
            XCTFail("Failed to create runtime")
            return
        }
        defer { LuminaAgentRuntimeDestroy(silentRuntime) }
        LuminaAgentRuntimeSetModelCallback(silentRuntime, luminaFinalModelCallback, nil)
        var result = "{}".withCString { LuminaAgentRuntimeRun(silentRuntime, $0) }
        if let result { LuminaAgentRuntimeReleaseString(result) }
        XCTAssertTrue(LuminaRuntimeCaptureStore.shared.snapshot().traces.isEmpty)
        XCTAssertTrue(LuminaRuntimeCaptureStore.shared.snapshot().metrics.isEmpty)

        LuminaRuntimeCaptureStore.shared.reset()
        guard let observableRuntime = LuminaAgentRuntimeCreate(luminaKernelRuntimeConfigurationJSON(maxIterations: 1)) else {
            XCTFail("Failed to create runtime")
            return
        }
        defer { LuminaAgentRuntimeDestroy(observableRuntime) }
        LuminaAgentRuntimeSetModelCallback(observableRuntime, luminaFinalModelCallback, nil)
        LuminaAgentRuntimeSetTraceCallback(observableRuntime, luminaTraceCallback, nil)
        LuminaAgentRuntimeSetMetricsCallback(observableRuntime, luminaMetricsCallback, nil)
        result = "{}".withCString { LuminaAgentRuntimeRun(observableRuntime, $0) }
        if let result { LuminaAgentRuntimeReleaseString(result) }
        let snapshot = LuminaRuntimeCaptureStore.shared.snapshot()
        XCTAssertFalse(snapshot.traces.isEmpty)
        XCTAssertFalse(snapshot.metrics.isEmpty)
        XCTAssertTrue(snapshot.traces.contains { $0.contains("run_finished") })
    }

    func testTaskEnvelopeIsSemanticAndMultimodalWithoutRawRequest() throws {
        guard let runtime = LuminaAgentRuntimeCreate(luminaKernelRuntimeConfigurationJSON(maxIterations: 1)) else {
            XCTFail("Failed to create runtime")
            return
        }
        defer { LuminaAgentRuntimeDestroy(runtime) }
        LuminaAgentRuntimeSetModelCallback(runtime, luminaFinalModelCallback, nil)

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

        let input = LuminaRuntimeCaptureStore.shared.snapshot().plannerInputs.first ?? ""
        XCTAssertTrue(input.contains(#""instructions":{"system":"你是 Lumina，本地优先执行用户任务。""#))
        XCTAssertTrue(input.contains(#""task":{"user_goal":"总结这张收据和这段语音""#))
        XCTAssertTrue(input.contains(#""modalities":["audio","image","structured_data","text"]"#))
        XCTAssertTrue(input.contains(#""attachments_summary""#))
        XCTAssertTrue(input.contains(#""transcript":"下午三点提醒我""#))
        XCTAssertTrue(input.contains(#""output_contract""#))
        XCTAssertFalse(input.contains(#""raw_request":"#))
    }

    func testStreamingModelCallbackEmitsGenerationEvents() throws {
        guard let runtime = LuminaAgentRuntimeCreate(luminaKernelRuntimeConfigurationJSON(maxIterations: 1)) else {
            XCTFail("Failed to create runtime")
            return
        }
        defer { LuminaAgentRuntimeDestroy(runtime) }
        LuminaAgentRuntimeSetStreamingModelCallback(runtime, luminaStreamingModelCallback, nil)
        LuminaAgentRuntimeSetEventCallback(runtime, luminaEventCallback, nil)

        let result = LuminaAgentRuntimeRun(runtime, #"{"id":"stream","text":"hello","content":[{"modality":"text","text":"hello"}]}"#)
        if let result {
            LuminaAgentRuntimeReleaseString(result)
        }

        let events = LuminaRuntimeCaptureStore.shared.snapshot().events.joined(separator: "\n")
        XCTAssertTrue(events.contains(#""type":"model_generation_started""#))
        XCTAssertTrue(events.contains(#""type":"model_generation_delta""#))
        XCTAssertTrue(events.contains(#""type":"model_generation_validated""#))
        XCTAssertTrue(events.contains(#""ttft_ms":"#))
        XCTAssertTrue(events.contains(#""tokens_per_second":"#))
        XCTAssertTrue(events.contains(#""extracted_standard_step":true"#))
    }

    func testExplicitSessionPausesForAskUserAndExportsTrace() throws {
        guard let runtime = LuminaAgentRuntimeCreate(luminaKernelRuntimeConfigurationJSON(maxIterations: 2)) else {
            XCTFail("Failed to create runtime")
            return
        }
        defer { LuminaAgentRuntimeDestroy(runtime) }
        LuminaAgentRuntimeSetModelCallback(runtime, luminaAskUserModelCallback, nil)
        registerAskUserSchema(on: runtime)

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

    func testExplicitSessionCanResumeAfterAskUserAnswer() throws {
        guard let runtime = LuminaAgentRuntimeCreate(luminaKernelRuntimeConfigurationJSON(maxIterations: 3)) else {
            XCTFail("Failed to create runtime")
            return
        }
        defer { LuminaAgentRuntimeDestroy(runtime) }
        LuminaAgentRuntimeSetModelCallback(runtime, luminaAskThenFinalModelCallback, nil)
        registerAskUserSchema(on: runtime)

        guard let session = LuminaAgentRuntimeCreateSession(runtime, #"{"id":"ask-resume","text":"帮我规划一下","content":[{"modality":"text","text":"帮我规划一下"}]}"#) else {
            XCTFail("Failed to create session")
            return
        }
        defer { LuminaAgentRuntimeDestroySession(session) }

        let pausedPointer = LuminaAgentRuntimeRunSession(runtime, session)
        let pausedJSON = pausedPointer.map { String(cString: $0) } ?? "{}"
        if let pausedPointer {
            LuminaAgentRuntimeReleaseString(pausedPointer)
        }
        XCTAssertTrue(pausedJSON.contains(#""paused":true"#))

        let resumedPointer = LuminaAgentRuntimeResumeSession(runtime, session, #"{"status":"succeeded","content":"用户选择上午"}"#)
        let resumedJSON = resumedPointer.map { String(cString: $0) } ?? "{}"
        if let resumedPointer {
            LuminaAgentRuntimeReleaseString(resumedPointer)
        }
        XCTAssertTrue(resumedJSON.contains(#""status":"succeeded""#))
        XCTAssertTrue(resumedJSON.contains("已继续"))
    }

    func testReasoningCanRequestProgressiveContextDisclosure() throws {
        guard let runtime = LuminaAgentRuntimeCreate(luminaKernelRuntimeConfigurationJSON(maxIterations: 3)) else {
            XCTFail("Failed to create runtime")
            return
        }
        defer { LuminaAgentRuntimeDestroy(runtime) }
        LuminaAgentRuntimeSetModelCallback(runtime, luminaNeedsContextThenFinalModelCallback, nil)
        LuminaAgentRuntimeSetContextCallback(runtime, luminaContextCallback, nil)

        let result = LuminaAgentRuntimeRun(runtime, #"{"id":"context","text":"需要上下文","content":[{"modality":"text","text":"需要上下文"}]}"#)
        if let result {
            LuminaAgentRuntimeReleaseString(result)
        }

        let inputs = LuminaRuntimeCaptureStore.shared.snapshot().plannerInputs
        XCTAssertEqual(inputs.count, 2)
        XCTAssertTrue(inputs[0].contains("首轮摘要"))
        XCTAssertTrue(inputs[1].contains("更深层上下文"))
    }

    func testToolDiscoveryReturnsFocusedSchemaWithoutExecutingTool() throws {
        guard let runtime = LuminaAgentRuntimeCreate(luminaKernelRuntimeConfigurationJSON(maxIterations: 3)) else {
            XCTFail("Failed to create runtime")
            return
        }
        defer { LuminaAgentRuntimeDestroy(runtime) }
        LuminaAgentRuntimeSetModelCallback(runtime, luminaToolDiscoveryThenFinalModelCallback, nil)
        LuminaAgentRuntimeSetToolCallback(runtime, luminaToolCallback, nil)
        let schemaPointer = LuminaAgentRuntimeRegisterToolSchema(
            runtime,
            #"{"name":"calendar.search","description":"Search calendar events.","category":"pim","aliases":["find events"],"searchHint":"calendar events schedule","sideEffect":"readOnly","readOnly":true,"concurrencySafe":true,"parameters":[{"name":"query","type":"string","required":true}]}"#
        )
        if let schemaPointer {
            LuminaAgentRuntimeReleaseString(schemaPointer)
        }

        let resultPointer = LuminaAgentRuntimeRun(runtime, #"{"id":"discover","text":"有哪些日历工具","content":[{"modality":"text","text":"有哪些日历工具"}]}"#)
        let result = resultPointer.map { String(cString: $0) } ?? "{}"
        if let resultPointer {
            LuminaAgentRuntimeReleaseString(resultPointer)
        }

        let snapshot = LuminaRuntimeCaptureStore.shared.snapshot()
        XCTAssertTrue(result.contains(#""status":"succeeded""#))
        XCTAssertEqual(snapshot.toolCallCount, 0)
        XCTAssertTrue(snapshot.plannerInputs.first?.contains(#""focused_schemas":[]"#) == true)
        XCTAssertTrue(snapshot.plannerInputs.dropFirst().joined(separator: "\n").contains(#""calendar.search""#))
    }

    func testIdenticalToolCallReplaysPreviousObservationWithoutExecutingAgain() throws {
        guard let runtime = LuminaAgentRuntimeCreate(luminaKernelRuntimeConfigurationJSON(maxIterations: 4)) else {
            XCTFail("Failed to create runtime")
            return
        }
        defer { LuminaAgentRuntimeDestroy(runtime) }
        LuminaAgentRuntimeSetModelCallback(runtime, luminaRepeatedIdenticalToolThenFinalModelCallback, nil)
        LuminaAgentRuntimeSetToolCallback(runtime, luminaToolCallback, nil)
        let schemaPointer = LuminaAgentRuntimeRegisterToolSchema(
            runtime,
            #"{"name":"external.open","description":"Open an external user-visible surface.","category":"external","sideEffect":"externalCommunication","requiresUserInteraction":true,"idempotencyPolicy":"replay_identical","parameters":[{"name":"target","type":"string","required":true},{"name":"payload","type":"string","required":true}]}"#
        )
        if let schemaPointer {
            LuminaAgentRuntimeReleaseString(schemaPointer)
        }

        let resultPointer = LuminaAgentRuntimeRun(runtime, #"{"id":"external","text":"打开外部界面","content":[{"modality":"text","text":"打开外部界面"}]}"#)
        let result = resultPointer.map { String(cString: $0) } ?? "{}"
        if let resultPointer {
            LuminaAgentRuntimeReleaseString(resultPointer)
        }

        let snapshot = LuminaRuntimeCaptureStore.shared.snapshot()
        XCTAssertTrue(result.contains(#""status":"succeeded""#))
        XCTAssertEqual(snapshot.toolCallCount, 1)
        XCTAssertTrue(snapshot.plannerInputs.dropFirst().first?.contains(#""toolName":"external.open""#) == true)
        XCTAssertTrue(snapshot.plannerInputs.dropFirst().first?.contains(#""status":"succeeded""#) == true)
        XCTAssertTrue(snapshot.plannerInputs.last?.contains(#""replayed":true"#) == true)
        XCTAssertTrue(snapshot.plannerInputs.last?.contains("Runtime 已检测到同一个 tool_name + parameters") == true)
    }

    func testSameToolDifferentParametersExecuteSeparately() throws {
        guard let runtime = LuminaAgentRuntimeCreate(luminaKernelRuntimeConfigurationJSON(maxIterations: 4)) else {
            XCTFail("Failed to create runtime")
            return
        }
        defer { LuminaAgentRuntimeDestroy(runtime) }
        LuminaAgentRuntimeSetModelCallback(runtime, luminaDifferentParametersThenFinalModelCallback, nil)
        LuminaAgentRuntimeSetToolCallback(runtime, luminaToolCallback, nil)
        let schemaPointer = LuminaAgentRuntimeRegisterToolSchema(
            runtime,
            #"{"name":"data.lookup","description":"Lookup local data.","category":"data","sideEffect":"readOnly","idempotencyPolicy":"replay_identical","parameters":[{"name":"query","type":"string","required":true}]}"#
        )
        if let schemaPointer {
            LuminaAgentRuntimeReleaseString(schemaPointer)
        }

        let resultPointer = LuminaAgentRuntimeRun(runtime, #"{"id":"lookup","text":"查询两个值","content":[{"modality":"text","text":"查询两个值"}]}"#)
        if let resultPointer {
            LuminaAgentRuntimeReleaseString(resultPointer)
        }

        XCTAssertEqual(LuminaRuntimeCaptureStore.shared.snapshot().toolCallCount, 2)
    }

    func testSameParametersWithDifferentIdempotencyKeysExecuteSeparately() throws {
        guard let runtime = LuminaAgentRuntimeCreate(luminaKernelRuntimeConfigurationJSON(maxIterations: 4)) else {
            XCTFail("Failed to create runtime")
            return
        }
        defer { LuminaAgentRuntimeDestroy(runtime) }
        LuminaAgentRuntimeSetModelCallback(runtime, luminaDifferentIdempotencyKeysThenFinalModelCallback, nil)
        LuminaAgentRuntimeSetToolCallback(runtime, luminaToolCallback, nil)
        let schemaPointer = LuminaAgentRuntimeRegisterToolSchema(
            runtime,
            #"{"name":"record.create","description":"Create a record.","category":"data","sideEffect":"appLocalWrite","idempotencyPolicy":"caller_keyed","parameters":[{"name":"title","type":"string","required":true},{"name":"idempotency_key","type":"string","required":false}]}"#
        )
        if let schemaPointer {
            LuminaAgentRuntimeReleaseString(schemaPointer)
        }

        let resultPointer = LuminaAgentRuntimeRun(runtime, #"{"id":"records","text":"创建两条记录","content":[{"modality":"text","text":"创建两条记录"}]}"#)
        if let resultPointer {
            LuminaAgentRuntimeReleaseString(resultPointer)
        }

        XCTAssertEqual(LuminaRuntimeCaptureStore.shared.snapshot().toolCallCount, 2)
    }

    func testAlwaysExecutePolicyBypassesReplay() throws {
        guard let runtime = LuminaAgentRuntimeCreate(luminaKernelRuntimeConfigurationJSON(maxIterations: 4)) else {
            XCTFail("Failed to create runtime")
            return
        }
        defer { LuminaAgentRuntimeDestroy(runtime) }
        LuminaAgentRuntimeSetModelCallback(runtime, luminaAlwaysExecuteThenFinalModelCallback, nil)
        LuminaAgentRuntimeSetToolCallback(runtime, luminaToolCallback, nil)
        let schemaPointer = LuminaAgentRuntimeRegisterToolSchema(
            runtime,
            #"{"name":"status.read","description":"Read volatile status.","category":"system","sideEffect":"readOnly","idempotencyPolicy":"always_execute","parameters":[{"name":"scope","type":"string","required":true}]}"#
        )
        if let schemaPointer {
            LuminaAgentRuntimeReleaseString(schemaPointer)
        }

        let resultPointer = LuminaAgentRuntimeRun(runtime, #"{"id":"status","text":"读取两次实时状态","content":[{"modality":"text","text":"读取两次实时状态"}]}"#)
        if let resultPointer {
            LuminaAgentRuntimeReleaseString(resultPointer)
        }

        XCTAssertEqual(LuminaRuntimeCaptureStore.shared.snapshot().toolCallCount, 2)
    }

    func testCanonicalParameterOrderingFeedsReplayLedger() throws {
        guard let runtime = LuminaAgentRuntimeCreate(luminaKernelRuntimeConfigurationJSON(maxIterations: 4)) else {
            XCTFail("Failed to create runtime")
            return
        }
        defer { LuminaAgentRuntimeDestroy(runtime) }
        LuminaAgentRuntimeSetModelCallback(runtime, luminaReorderedParametersThenFinalModelCallback, nil)
        LuminaAgentRuntimeSetToolCallback(runtime, luminaToolCallback, nil)
        let schemaPointer = LuminaAgentRuntimeRegisterToolSchema(
            runtime,
            #"{"name":"canonical.action","description":"Action with canonical parameters.","category":"data","sideEffect":"readOnly","idempotencyPolicy":"replay_identical","parameters":[{"name":"a","type":"string","required":true},{"name":"b","type":"string","required":true}]}"#
        )
        if let schemaPointer {
            LuminaAgentRuntimeReleaseString(schemaPointer)
        }

        let resultPointer = LuminaAgentRuntimeRun(runtime, #"{"id":"canonical","text":"重复参数顺序不同","content":[{"modality":"text","text":"重复参数顺序不同"}]}"#)
        if let resultPointer {
            LuminaAgentRuntimeReleaseString(resultPointer)
        }

        let snapshot = LuminaRuntimeCaptureStore.shared.snapshot()
        XCTAssertEqual(snapshot.toolCallCount, 1)
        XCTAssertTrue(snapshot.plannerInputs.last?.contains(#""duplicate_of":"tool-call-1""#) == true)
    }

    func testRuntimeRequiresCallerProvidedBudgets() throws {
        guard let runtime = LuminaAgentRuntimeCreate("{}") else {
            XCTFail("Failed to create runtime")
            return
        }
        defer { LuminaAgentRuntimeDestroy(runtime) }
        LuminaAgentRuntimeSetModelCallback(runtime, luminaFinalModelCallback, nil)

        let resultPointer = LuminaAgentRuntimeRun(runtime, #"{"id":"missing-budget","text":"hello"}"#)
        let result = resultPointer.map { String(cString: $0) } ?? "{}"
        if let resultPointer {
            LuminaAgentRuntimeReleaseString(resultPointer)
        }

        XCTAssertTrue(result.contains("Runtime 配置无效"))
        XCTAssertTrue(result.contains("missing required runtime budget"))
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
            stepGenerator: ScriptedLuminaReActModel(steps: [
                .action(thought: "search", call: LuminaToolCall(toolName: "local.search", arguments: [:])),
                .result("done")
            ]),
            configuration: luminaTestRuntimeConfiguration
        )

        let result = await runtime.run(request: LuminaAgentRequest(text: "查一下"))
        let invocationCount = await counter.value

        XCTAssertEqual(invocationCount, 0)
        XCTAssertEqual(result.toolResults.first?.status, .failed)
        XCTAssertTrue(result.reactTrace?.observations.first?.summary.contains("missing required parameter") == true)
    }

    func testCoreGuardrailRejectsRequestBeforeModelGeneration() throws {
        guard let runtime = LuminaAgentRuntimeCreate(luminaKernelRuntimeConfigurationJSON(maxIterations: 1)) else {
            XCTFail("Failed to create runtime")
            return
        }
        defer { LuminaAgentRuntimeDestroy(runtime) }
        LuminaAgentRuntimeSetModelCallback(runtime, luminaFinalModelCallback, nil)
        LuminaAgentRuntimeSetGuardrailCallback(runtime, luminaRejectRequestGuardrailCallback, nil)

        let pointer = LuminaAgentRuntimeRun(runtime, #"{"id":"blocked","text":"stop"}"#)
        let result = pointer.map { String(cString: $0) } ?? ""
        if let pointer {
            LuminaAgentRuntimeReleaseString(pointer)
        }

        XCTAssertTrue(result.contains(#""status":"failed""#))
        XCTAssertTrue(result.contains("blocked by core guardrail"))
        XCTAssertTrue(LuminaRuntimeCaptureStore.shared.snapshot().plannerInputs.isEmpty)
    }

    func testCoreHookRouteRewritesToolCallBeforePermissionAndExecution() throws {
        guard let runtime = LuminaAgentRuntimeCreate(luminaKernelRuntimeConfigurationJSON(maxIterations: 3)) else {
            XCTFail("Failed to create runtime")
            return
        }
        defer { LuminaAgentRuntimeDestroy(runtime) }
        LuminaAgentRuntimeSetModelCallback(runtime, luminaUnsafeToolThenFinalModelCallback, nil)
        LuminaAgentRuntimeSetToolCallback(runtime, luminaRecordingToolCallback, nil)
        LuminaAgentRuntimeSetHookCallback(runtime, luminaRewriteToolHookCallback, nil)
        LuminaAgentRuntimeSetEventCallback(runtime, luminaEventCallback, nil)

        let unsafeSchema = LuminaAgentRuntimeRegisterToolSchema(
            runtime,
            #"{"name":"unsafe.write","description":"Unsafe write.","category":"test","sideEffect":"systemWrite","sensitivity":"sensitive","parameters":[{"name":"query","type":"string","required":true}]}"#
        )
        if let unsafeSchema { LuminaAgentRuntimeReleaseString(unsafeSchema) }
        let safeSchema = LuminaAgentRuntimeRegisterToolSchema(
            runtime,
            #"{"name":"data.lookup","description":"Lookup data.","category":"test","sideEffect":"readOnly","sensitivity":"normal","parameters":[{"name":"query","type":"string","required":true}]}"#
        )
        if let safeSchema { LuminaAgentRuntimeReleaseString(safeSchema) }
        let route = LuminaAgentRuntimeRegisterHookRoute(
            runtime,
            #"{"id":"rewrite-unsafe","events":["before_tool"],"tool_name_patterns":["unsafe.*"],"sensitivities":["sensitive"],"side_effects":["systemWrite"]}"#
        )
        if let route { LuminaAgentRuntimeReleaseString(route) }

        let resultPointer = LuminaAgentRuntimeRun(runtime, #"{"id":"rewrite","text":"rewrite tool"}"#)
        if let resultPointer {
            LuminaAgentRuntimeReleaseString(resultPointer)
        }
        let snapshot = LuminaRuntimeCaptureStore.shared.snapshot()

        XCTAssertEqual(snapshot.toolCallCount, 1)
        XCTAssertTrue(snapshot.toolCalls.first?.contains(#""tool_name":"data.lookup""#) == true)
        XCTAssertTrue(snapshot.toolCalls.first?.contains(#""query":"safe""#) == true)
        XCTAssertTrue(snapshot.events.joined(separator: "\n").contains("tool_call_rewritten"))
    }

    func testCoreStateAndCheckpointRoundTripThroughCABI() throws {
        guard let runtime = LuminaAgentRuntimeCreate(luminaKernelRuntimeConfigurationJSON(maxIterations: 2)) else {
            XCTFail("Failed to create runtime")
            return
        }
        defer { LuminaAgentRuntimeDestroy(runtime) }
        guard let session = LuminaAgentRuntimeCreateSession(runtime, #"{"id":"state","text":"remember"}"#) else {
            XCTFail("Failed to create session")
            return
        }
        defer { LuminaAgentRuntimeDestroySession(session) }

        let setPointer = LuminaAgentRuntimeSessionSetState(runtime, session, "session", "topic", #"{"value":"core"}"#)
        let setText = setPointer.map { String(cString: $0) } ?? ""
        if let setPointer { LuminaAgentRuntimeReleaseString(setPointer) }
        XCTAssertTrue(setText.contains(#""ok":true"#))

        let checkpointPointer = LuminaAgentRuntimeExportSessionCheckpoint(session)
        let checkpoint = checkpointPointer.map { String(cString: $0) } ?? ""
        if let checkpointPointer { LuminaAgentRuntimeReleaseString(checkpointPointer) }
        XCTAssertTrue(checkpoint.contains("runtime_checkpoint"))
        XCTAssertTrue(checkpoint.contains("runtime_state"))

        guard let restored = checkpoint.withCString({ LuminaAgentRuntimeCreateSessionFromCheckpoint(runtime, $0) }) else {
            XCTFail("Failed to restore session")
            return
        }
        defer { LuminaAgentRuntimeDestroySession(restored) }
        let getPointer = LuminaAgentRuntimeSessionGetState(restored, "session", "topic")
        let getText = getPointer.map { String(cString: $0) } ?? ""
        if let getPointer { LuminaAgentRuntimeReleaseString(getPointer) }

        XCTAssertTrue(getText.contains(#""value":{"value":"core"}"#))
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

private actor ScriptedLuminaReActModel: LuminaReActStepGenerator {
    private var steps: [LuminaReActStep]

    init(steps: [LuminaReActStep]) {
        self.steps = steps
    }

    func nextStep(context: LuminaReActStepContext) async throws -> LuminaReActStep {
        guard !steps.isEmpty else { return .result("done") }
        return steps.removeFirst()
    }
}
