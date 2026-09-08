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
    private var spans: [String] = []
    private var historyEvents: [String] = []
    private var retryRequests: [String] = []
    private var compactionRequests: [String] = []
    private var contextLoadingRequests: [String] = []
    private var toolLoadingRequests: [String] = []
    private var toolCalls: [String] = []
    private var toolCallCount = 0
    private var modelCallCount = 0

    func reset() {
        lock.lock()
        plannerInputs = []
        events = []
        traces = []
        metrics = []
        spans = []
        historyEvents = []
        retryRequests = []
        compactionRequests = []
        contextLoadingRequests = []
        toolLoadingRequests = []
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

    func appendSpan(_ value: String) {
        lock.lock()
        spans.append(value)
        lock.unlock()
    }

    func appendHistoryEvent(_ value: String) {
        lock.lock()
        historyEvents.append(value)
        lock.unlock()
    }

    func appendRetryRequest(_ value: String) {
        lock.lock()
        retryRequests.append(value)
        lock.unlock()
    }

    func appendCompactionRequest(_ value: String) {
        lock.lock()
        compactionRequests.append(value)
        lock.unlock()
    }

    func appendContextLoadingRequest(_ value: String) {
        lock.lock()
        contextLoadingRequests.append(value)
        lock.unlock()
    }

    func appendToolLoadingRequest(_ value: String) {
        lock.lock()
        toolLoadingRequests.append(value)
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

    func appendToolCallAndReturnCount(_ value: String) -> Int {
        lock.lock()
        toolCalls.append(value)
        toolCallCount += 1
        let value = toolCallCount
        lock.unlock()
        return value
    }

    func incrementModelCallCount() -> Int {
        lock.lock()
        modelCallCount += 1
        let value = modelCallCount
        lock.unlock()
        return value
    }

    func snapshot() -> (plannerInputs: [String], events: [String], traces: [String], metrics: [String], spans: [String], historyEvents: [String], retryRequests: [String], compactionRequests: [String], contextLoadingRequests: [String], toolLoadingRequests: [String], toolCalls: [String], toolCallCount: Int, modelCallCount: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (plannerInputs, events, traces, metrics, spans, historyEvents, retryRequests, compactionRequests, contextLoadingRequests, toolLoadingRequests, toolCalls, toolCallCount, modelCallCount)
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

private let luminaSpanCallback: LuminaAgentSpanCallback = { span, _ in
    if let span {
        LuminaRuntimeCaptureStore.shared.appendSpan(String(cString: span))
    }
}

private let luminaHistoryCallback: LuminaAgentSessionHistoryCallback = { event, _ in
    if let event {
        LuminaRuntimeCaptureStore.shared.appendHistoryEvent(String(cString: event))
    }
}

private let luminaFinalModelCallback: LuminaAgentModelCallback = { plannerInput, _ in
    if let plannerInput {
        LuminaRuntimeCaptureStore.shared.appendPlannerInput(String(cString: plannerInput))
    }
    return luminaRuntimeCString("{\"schema_version\":\"1.0\",\"step_id\":\"s-final\",\"type\":\"result\",\"thought\":\"done\",\"content\":\"## 完成\\n\\n已处理。\",\"completed\":true,\"requires_followup\":false}")
}

private let luminaEmptyThenFinalModelCallback: LuminaAgentModelCallback = { plannerInput, _ in
    if let plannerInput {
        LuminaRuntimeCaptureStore.shared.appendPlannerInput(String(cString: plannerInput))
    }
    let call = LuminaRuntimeCaptureStore.shared.incrementModelCallCount()
    if call == 1 {
        return luminaRuntimeCString("")
    }
    return luminaRuntimeCString("{\"schema_version\":\"1.0\",\"step_id\":\"s-final\",\"type\":\"result\",\"thought\":\"retried\",\"content\":\"## 完成\\n\\n重试后完成。\",\"completed\":true,\"requires_followup\":false}")
}

private let luminaInvalidThenFinalModelCallback: LuminaAgentModelCallback = { plannerInput, _ in
    if let plannerInput {
        LuminaRuntimeCaptureStore.shared.appendPlannerInput(String(cString: plannerInput))
    }
    let call = LuminaRuntimeCaptureStore.shared.incrementModelCallCount()
    if call == 1 {
        return luminaRuntimeCString(#"<think>missing closing transport</think><tool_call><function=device.current_time>"#)
    }
    return luminaRuntimeCString("{\"schema_version\":\"1.0\",\"step_id\":\"s-final\",\"type\":\"result\",\"thought\":\"normalized\",\"content\":\"## 完成\\n\\n修复后完成。\",\"completed\":true,\"requires_followup\":false}")
}

private let luminaPromptTooLongThenFinalModelCallback: LuminaAgentModelCallback = { plannerInput, _ in
    if let plannerInput {
        LuminaRuntimeCaptureStore.shared.appendPlannerInput(String(cString: plannerInput))
    }
    let call = LuminaRuntimeCaptureStore.shared.incrementModelCallCount()
    if call == 1 {
        return luminaRuntimeCString(#"{"error":{"code":"context_length_exceeded","message":"maximum context length exceeded"}}"#)
    }
    return luminaRuntimeCString("{\"schema_version\":\"1.0\",\"step_id\":\"s-final\",\"type\":\"result\",\"thought\":\"compacted\",\"content\":\"## 完成\\n\\nreactive compact 后完成。\",\"completed\":true,\"requires_followup\":false}")
}

private let luminaProviderMetadataCallback: LuminaAgentModelMetadataCallback = { _, _ in
    luminaRuntimeCString(#"{"model_id":"test-dynamic-window","max_context_tokens":640,"provider_native_context_management":true}"#)
}

private let luminaAskUserModelCallback: LuminaAgentModelCallback = { plannerInput, _ in
    if let plannerInput {
        LuminaRuntimeCaptureStore.shared.appendPlannerInput(String(cString: plannerInput))
    }
    return luminaRuntimeCString(#"{"schema_version":"1.0","step_id":"s-ask","type":"ask_user","thinking":"Need preference.","questions":[{"id":"time","question":"几点？","options":[{"label":"上午","description":"安排在上午"},{"label":"下午","description":"安排在下午"}]}],"allow_custom_answer":true,"requires_followup":true}"#)
}

private let luminaAskThenFinalModelCallback: LuminaAgentModelCallback = { plannerInput, _ in
    if let plannerInput {
        LuminaRuntimeCaptureStore.shared.appendPlannerInput(String(cString: plannerInput))
    }
    let call = LuminaRuntimeCaptureStore.shared.incrementModelCallCount()
    if call == 1 {
        return luminaRuntimeCString(#"{"schema_version":"1.0","step_id":"s-ask","type":"ask_user","thinking":"Need preference.","questions":[{"id":"time","question":"几点？","options":[{"label":"上午","description":"安排在上午"},{"label":"下午","description":"安排在下午"}]}],"allow_custom_answer":true,"requires_followup":true}"#)
    }
    return luminaRuntimeCString(###"{"schema_version":"1.0","step_id":"s-final","type":"result","thinking":"User answered.","content":"## 已继续\n\n收到你的回答，继续完成。","completed":true,"requires_followup":false}"###)
}

private let luminaNeedsContextThenFinalModelCallback: LuminaAgentModelCallback = { plannerInput, _ in
    if let plannerInput {
        LuminaRuntimeCaptureStore.shared.appendPlannerInput(String(cString: plannerInput))
    }
    let call = LuminaRuntimeCaptureStore.shared.incrementModelCallCount()
    if call == 1 {
        return luminaRuntimeCString(#"{"schema_version":"1.0","step_id":"s-context","type":"reasoning","thinking":"Need deeper context.","needs_more_context":true,"confidence":0.7,"requires_followup":true}"#)
    }
    return luminaRuntimeCString(###"{"schema_version":"1.0","step_id":"s-final","type":"result","thinking":"Context loaded.","content":"## 完成\n\n已使用更深层上下文。","completed":true,"requires_followup":false}"###)
}

private let luminaToolDiscoveryThenFinalModelCallback: LuminaAgentModelCallback = { plannerInput, _ in
    if let plannerInput {
        LuminaRuntimeCaptureStore.shared.appendPlannerInput(String(cString: plannerInput))
    }
    let call = LuminaRuntimeCaptureStore.shared.incrementModelCallCount()
    if call == 1 {
        return luminaRuntimeCString(#"{"schema_version":"1.0","step_id":"s-discover","type":"tool_discovery","thinking":"Need focused calendar schema.","query":"calendar","category":"pim","max_results":2,"include_schemas":true,"requires_followup":true}"#)
    }
    return luminaRuntimeCString(###"{"schema_version":"1.0","step_id":"s-final","type":"result","thinking":"Saw focused schema.","content":"## 完成\n\n已查看工具 schema。","completed":true,"requires_followup":false}"###)
}

private let luminaDeferredToolDirectThenFinalModelCallback: LuminaAgentModelCallback = { plannerInput, _ in
    if let plannerInput {
        LuminaRuntimeCaptureStore.shared.appendPlannerInput(String(cString: plannerInput))
    }
    let call = LuminaRuntimeCaptureStore.shared.incrementModelCallCount()
    if call == 1 {
        return luminaRuntimeCString(#"{"schema_version":"1.0","step_id":"s-direct","type":"tool_use","thinking":"Try the deferred tool immediately.","tool_name":"deferred.search","parameters":{"query":"demo"},"requires_followup":true}"#)
    }
    return luminaRuntimeCString(###"{"schema_version":"1.0","step_id":"s-final","type":"result","thinking":"Handled contract failure.","content":"## 完成","completed":true,"requires_followup":false}"###)
}

private let luminaDeferredDiscoveryUseThenFinalModelCallback: LuminaAgentModelCallback = { plannerInput, _ in
    if let plannerInput {
        LuminaRuntimeCaptureStore.shared.appendPlannerInput(String(cString: plannerInput))
    }
    let call = LuminaRuntimeCaptureStore.shared.incrementModelCallCount()
    if call == 1 {
        return luminaRuntimeCString(#"{"schema_version":"1.0","step_id":"s-discover","type":"tool_discovery","thinking":"Load the focused deferred schema.","query":"select:deferred.search","category":"search","max_results":1,"include_schemas":true,"requires_followup":true}"#)
    }
    if call == 2 {
        return luminaRuntimeCString(#"{"schema_version":"1.0","step_id":"s-use","type":"tool_use","thinking":"Use the now-loaded tool.","tool_name":"deferred.search","parameters":{"query":"demo"},"requires_followup":true}"#)
    }
    return luminaRuntimeCString(###"{"schema_version":"1.0","step_id":"s-final","type":"result","thinking":"Tool ran.","content":"## 完成","completed":true,"requires_followup":false}"###)
}

private let luminaPluginDeferredDiscoveryThenFinalModelCallback: LuminaAgentModelCallback = { plannerInput, _ in
    if let plannerInput {
        LuminaRuntimeCaptureStore.shared.appendPlannerInput(String(cString: plannerInput))
    }
    let call = LuminaRuntimeCaptureStore.shared.incrementModelCallCount()
    if call == 1 {
        return luminaRuntimeCString(#"{"schema_version":"1.0","step_id":"s-plugin-discover","type":"tool_discovery","thinking":"Ask host plugin to load schema.","query":"select:plugin.lazy","category":"plugin","max_results":1,"include_schemas":true,"requires_followup":true}"#)
    }
    return luminaRuntimeCString(###"{"schema_version":"1.0","step_id":"s-final","type":"result","thinking":"Loaded by plugin.","content":"## 完成","completed":true,"requires_followup":false}"###)
}

private let luminaRepeatedIdenticalToolThenFinalModelCallback: LuminaAgentModelCallback = { plannerInput, _ in
    if let plannerInput {
        LuminaRuntimeCaptureStore.shared.appendPlannerInput(String(cString: plannerInput))
    }
    let call = LuminaRuntimeCaptureStore.shared.incrementModelCallCount()
    if call <= 2 {
        return luminaRuntimeCString(#"{"schema_version":"1.0","step_id":"s-open","type":"tool_use","thinking":"Open the external surface once.","tool_name":"external.open","parameters":{"target":"compose","payload":"Hello"},"requires_followup":true}"#)
    }
    return luminaRuntimeCString(###"{"schema_version":"1.0","step_id":"s-final","type":"result","thinking":"Handled.","content":"## 完成\n\n工具结果已处理。","completed":true,"requires_followup":false}"###)
}

private let luminaReadToolThenFinalModelCallback: LuminaAgentModelCallback = { plannerInput, _ in
    if let plannerInput {
        LuminaRuntimeCaptureStore.shared.appendPlannerInput(String(cString: plannerInput))
    }
    let call = LuminaRuntimeCaptureStore.shared.incrementModelCallCount()
    if call == 1 {
        return luminaRuntimeCString(#"{"schema_version":"1.0","step_id":"s-read","type":"tool_use","thinking":"Read retryable status.","tool_name":"status.read","parameters":{"scope":"cached"},"requires_followup":true}"#)
    }
    return luminaRuntimeCString(###"{"schema_version":"1.0","step_id":"s-final","type":"result","thinking":"Handled retry result.","content":"## 完成\n\n工具重试后完成。","completed":true,"requires_followup":false}"###)
}

private let luminaDifferentParametersThenFinalModelCallback: LuminaAgentModelCallback = { plannerInput, _ in
    if let plannerInput {
        LuminaRuntimeCaptureStore.shared.appendPlannerInput(String(cString: plannerInput))
    }
    let call = LuminaRuntimeCaptureStore.shared.incrementModelCallCount()
    if call == 1 {
        return luminaRuntimeCString(#"{"schema_version":"1.0","step_id":"s-a","type":"tool_use","thinking":"Lookup A.","tool_name":"data.lookup","parameters":{"query":"A"},"requires_followup":true}"#)
    }
    if call == 2 {
        return luminaRuntimeCString(#"{"schema_version":"1.0","step_id":"s-b","type":"tool_use","thinking":"Lookup B.","tool_name":"data.lookup","parameters":{"query":"B"},"requires_followup":true}"#)
    }
    return luminaRuntimeCString(###"{"schema_version":"1.0","step_id":"s-final","type":"result","thinking":"Done.","content":"## 完成","completed":true,"requires_followup":false}"###)
}

private let luminaDifferentIdempotencyKeysThenFinalModelCallback: LuminaAgentModelCallback = { plannerInput, _ in
    if let plannerInput {
        LuminaRuntimeCaptureStore.shared.appendPlannerInput(String(cString: plannerInput))
    }
    let call = LuminaRuntimeCaptureStore.shared.incrementModelCallCount()
    if call == 1 {
        return luminaRuntimeCString(#"{"schema_version":"1.0","step_id":"s-one","type":"tool_use","thinking":"Create first instance.","tool_name":"record.create","parameters":{"title":"same","idempotency_key":"one"},"requires_followup":true}"#)
    }
    if call == 2 {
        return luminaRuntimeCString(#"{"schema_version":"1.0","step_id":"s-two","type":"tool_use","thinking":"Create second instance.","tool_name":"record.create","parameters":{"title":"same","idempotency_key":"two"},"requires_followup":true}"#)
    }
    return luminaRuntimeCString(###"{"schema_version":"1.0","step_id":"s-final","type":"result","thinking":"Done.","content":"## 完成","completed":true,"requires_followup":false}"###)
}

private let luminaAlwaysExecuteThenFinalModelCallback: LuminaAgentModelCallback = { plannerInput, _ in
    if let plannerInput {
        LuminaRuntimeCaptureStore.shared.appendPlannerInput(String(cString: plannerInput))
    }
    let call = LuminaRuntimeCaptureStore.shared.incrementModelCallCount()
    if call <= 2 {
        return luminaRuntimeCString(#"{"schema_version":"1.0","step_id":"s-status","type":"tool_use","thinking":"Read fresh status.","tool_name":"status.read","parameters":{"scope":"live"},"requires_followup":true}"#)
    }
    return luminaRuntimeCString(###"{"schema_version":"1.0","step_id":"s-final","type":"result","thinking":"Done.","content":"## 完成","completed":true,"requires_followup":false}"###)
}

private let luminaReorderedParametersThenFinalModelCallback: LuminaAgentModelCallback = { plannerInput, _ in
    if let plannerInput {
        LuminaRuntimeCaptureStore.shared.appendPlannerInput(String(cString: plannerInput))
    }
    let call = LuminaRuntimeCaptureStore.shared.incrementModelCallCount()
    if call == 1 {
        return luminaRuntimeCString(#"{"schema_version":"1.0","step_id":"s-first","type":"tool_use","thinking":"Call once.","tool_name":"canonical.action","parameters":{"b":"2","a":"1"},"requires_followup":true}"#)
    }
    if call == 2 {
        return luminaRuntimeCString(#"{"schema_version":"1.0","step_id":"s-second","type":"tool_use","thinking":"Call duplicate with reordered parameters.","tool_name":"canonical.action","parameters":{"a":"1","b":"2"},"requires_followup":true}"#)
    }
    return luminaRuntimeCString(###"{"schema_version":"1.0","step_id":"s-final","type":"result","thinking":"Done.","content":"## 完成","completed":true,"requires_followup":false}"###)
}

private let luminaUnsafeToolThenFinalModelCallback: LuminaAgentModelCallback = { plannerInput, _ in
    if let plannerInput {
        LuminaRuntimeCaptureStore.shared.appendPlannerInput(String(cString: plannerInput))
    }
    let call = LuminaRuntimeCaptureStore.shared.incrementModelCallCount()
    if call == 1 {
        return luminaRuntimeCString(#"{"schema_version":"1.0","step_id":"s-unsafe","type":"tool_use","thinking":"Use proposed tool.","tool_name":"unsafe.write","parameters":{"query":"secret"},"requires_followup":true}"#)
    }
    return luminaRuntimeCString(###"{"schema_version":"1.0","step_id":"s-final","type":"result","thinking":"Done.","content":"## 完成","completed":true,"requires_followup":false}"###)
}

private let luminaExternalProviderThenFinalModelCallback: LuminaAgentModelCallback = { plannerInput, _ in
    if let plannerInput {
        LuminaRuntimeCaptureStore.shared.appendPlannerInput(String(cString: plannerInput))
    }
    let call = LuminaRuntimeCaptureStore.shared.incrementModelCallCount()
    if call == 1 {
        return luminaRuntimeCString(#"{"schema_version":"1.0","step_id":"s-provider","type":"tool_use","thinking":"Use provider tool.","tool_name":"mcp.echo","parameters":{"text":"hello"},"requires_followup":true}"#)
    }
    return luminaRuntimeCString(###"{"schema_version":"1.0","step_id":"s-final","type":"result","thinking":"Done.","content":"## Provider done","completed":true,"requires_followup":false}"###)
}

private let luminaSkillDiscoveryThenFinalModelCallback: LuminaAgentModelCallback = { plannerInput, _ in
    if let plannerInput {
        LuminaRuntimeCaptureStore.shared.appendPlannerInput(String(cString: plannerInput))
    }
    let call = LuminaRuntimeCaptureStore.shared.incrementModelCallCount()
    if call == 1 {
        return luminaRuntimeCString(#"{"schema_version":"1.0","step_id":"s-skill-discover","type":"tool_use","thinking":"Find a matching local skill.","tool_name":"runtime.skill_discovery","parameters":{"query":"ios","max_results":3},"requires_followup":true}"#)
    }
    return luminaRuntimeCString(###"{"schema_version":"1.0","step_id":"s-final","type":"result","thinking":"Skill catalog observed.","content":"## Skill discovery done","completed":true,"requires_followup":false}"###)
}

private let luminaMCPDiscoveryThenFinalModelCallback: LuminaAgentModelCallback = { plannerInput, _ in
    if let plannerInput {
        LuminaRuntimeCaptureStore.shared.appendPlannerInput(String(cString: plannerInput))
    }
    let call = LuminaRuntimeCaptureStore.shared.incrementModelCallCount()
    if call == 1 {
        return luminaRuntimeCString(#"{"schema_version":"1.0","step_id":"s-mcp-discover","type":"tool_use","thinking":"Load the selected MCP schema.","tool_name":"runtime.mcp_discovery","parameters":{"query":"select:mcp.echo","max_results":1,"include_schemas":true},"requires_followup":true}"#)
    }
    return luminaRuntimeCString(###"{"schema_version":"1.0","step_id":"s-final","type":"result","thinking":"MCP schema loaded.","content":"## MCP discovery done","completed":true,"requires_followup":false}"###)
}

private let luminaContextCallback: LuminaAgentContextCallback = { contextRequest, _ in
    let request = contextRequest.map { String(cString: $0) } ?? ""
    if request.contains(#""request_more_context":true"#) {
        return luminaRuntimeCString(#"[{"id":"deep","title":"Deep context","summary":"更深层上下文","priority":10,"disclosure_level":1}]"#)
    }
    return luminaRuntimeCString(#"[{"id":"initial","title":"Initial context","summary":"首轮摘要","priority":100,"disclosure_level":0}]"#)
}

private let luminaContextLoadingPluginCallback: LuminaAgentContextLoadingPluginCallback = { request, _ in
    let json = request.map { String(cString: $0) } ?? "{}"
    LuminaRuntimeCaptureStore.shared.appendContextLoadingRequest(json)
    if json.contains(#""action":"catalog""#) {
        return luminaRuntimeCString(#"{"status":"ok","items":[{"id":"memory.index","source":"memory","title":"Memory index","summary":"可搜索记忆目录","token_estimate":12}],"sections":[{"id":"memory.seed","source":"memory","title":"Seed context","summary":"轻量首轮上下文","priority":100,"disclosure_level":0,"token_estimate":18}]}"#)
    }
    if json.contains(#""action":"search""#) {
        return luminaRuntimeCString(#"{"status":"ok","items":[{"id":"memory.deep","source":"memory","title":"Deep memory","summary":"命中的深层记忆","token_estimate":24}]}"#)
    }
    if json.contains(#""action":"load""#) {
        return luminaRuntimeCString(#"{"status":"ok","sections":[{"id":"memory.deep","source":"memory","title":"Deep memory","summary":"插件加载的更深层上下文","hash":"h1","priority":10,"disclosure_level":1,"token_estimate":24}]}"#)
    }
    return luminaRuntimeCString(#"{"status":"skipped"}"#)
}

private let luminaLargeContextCallback: LuminaAgentContextCallback = { _, _ in
    luminaRuntimeCString(#"[{"id":"large","title":"Large","summary":""# + String(repeating: "large context ", count: 240) + #""}]"#)
}

private let luminaManyLargeSectionsContextCallback: LuminaAgentContextCallback = { _, _ in
    let oldLarge = String(repeating: "old tool result ", count: 220)
    let recent = String(repeating: "recent context ", count: 8)
    return luminaRuntimeCString("""
    [
      {"id":"old-1","title":"Old tool result","tool_name":"file.read","status":"succeeded","content":"\(oldLarge)"},
      {"id":"old-2","title":"Old secret result","tool_name":"web.fetch","status":"succeeded","content":"Bearer sk-test-secret-token-1234567890 \(oldLarge)","api_key":"sk-test-secret-token-1234567890"},
      {"id":"recent-1","title":"Recent","summary":"\(recent)"},
      {"id":"recent-2","title":"Recent 2","summary":"\(recent)"},
      {"id":"recent-3","title":"Recent 3","summary":"\(recent)"},
      {"id":"recent-4","title":"Recent 4","summary":"\(recent)"}
    ]
    """)
}

private let luminaStreamingModelCallback: LuminaAgentStreamingModelCallback = { plannerInput, emit, emitContext, _ in
    if let plannerInput {
        LuminaRuntimeCaptureStore.shared.appendPlannerInput(String(cString: plannerInput))
    }
    _ = emit?(#"{"delta":"<think>done</think>","tokenCount":3}"#, emitContext)
    _ = emit?(#"{"delta":"done","tokenCount":1}"#, emitContext)
    return luminaRuntimeCString(#"<think>done</think>done"#)
}

private let luminaEventCallback: LuminaAgentEventCallback = { event, _ in
    if let event {
        LuminaRuntimeCaptureStore.shared.appendEvent(String(cString: event))
    }
}

private let luminaRetryProviderCallback: LuminaAgentRetryProviderCallback = { request, _ in
    if let request {
        LuminaRuntimeCaptureStore.shared.appendRetryRequest(String(cString: request))
    }
    return luminaRuntimeCString(#"{"action":"retry","delay_ms":0,"reason":"test retry","max_attempts_override":3}"#)
}

private let luminaCompactionProviderCallback: LuminaAgentCompactionProviderCallback = { request, _ in
    if let request {
        LuminaRuntimeCaptureStore.shared.appendCompactionRequest(String(cString: request))
    }
    return luminaRuntimeCString(#"{"status":"compacted","compacted_context":{"sections":[],"compact_summary":"custom compacted context"},"tokens_saved_estimate":321,"boundary":{"type":"compact_boundary","trigger":"auto","strategy":"summarizing_compact"}}"#)
}

private let luminaSkippingCompactionProviderCallback: LuminaAgentCompactionProviderCallback = { request, _ in
    if let request {
        LuminaRuntimeCaptureStore.shared.appendCompactionRequest(String(cString: request))
    }
    return luminaRuntimeCString(#"{"status":"skipped"}"#)
}

private let luminaToolLoadingPluginCallback: LuminaAgentToolLoadingPluginCallback = { request, _ in
    let text = request.map { String(cString: $0) } ?? ""
    if !text.isEmpty {
        LuminaRuntimeCaptureStore.shared.appendToolLoadingRequest(text)
    }
    if text.contains(#""action":"search""#) {
        return luminaRuntimeCString(#"{"matches":[{"name":"plugin.lazy","description":"Plugin loaded tool.","category":"plugin","aliases":["lazy plugin"],"searchHint":"plugin lazy search","sideEffect":"readOnly","sensitivity":"normal","parameterNames":["query"]}]}"#)
    }
    if text.contains(#""action":"load""#) {
        return luminaRuntimeCString(#"{"schemas":[{"name":"plugin.lazy","description":"Plugin loaded tool.","category":"plugin","aliases":["lazy plugin"],"searchHint":"plugin lazy search","sideEffect":"readOnly","readOnly":true,"concurrencySafe":true,"parameters":[{"name":"query","type":"string","required":true}]}],"loaded":["plugin.lazy"],"failed":[]}"#)
    }
    return luminaRuntimeCString("{}")
}

private let luminaToolCallback: LuminaAgentToolCallback = { _, _ in
    LuminaRuntimeCaptureStore.shared.incrementToolCallCount()
    return luminaRuntimeCString(#"{"status":"succeeded","content":"should not run"}"#)
}

private let luminaAllowPermissionCallback: LuminaAgentPermissionCallback = { _, _ in
    luminaRuntimeCString(#"{"decision":"allowed"}"#)
}

private let luminaConfirmingCallback: LuminaAgentConfirmationCallback = { _, _ in
    luminaRuntimeCString(#"{"confirmed":true}"#)
}

private let luminaLargeToolResultCallback: LuminaAgentToolCallback = { call, _ in
    if let call {
        LuminaRuntimeCaptureStore.shared.appendToolCall(String(cString: call))
    }
    return luminaRuntimeCString(#"{"status":"succeeded","content":""# + String(repeating: "large tool output ", count: 260) + #""}"#)
}

private let luminaRecordingToolCallback: LuminaAgentToolCallback = { call, _ in
    if let call {
        LuminaRuntimeCaptureStore.shared.appendToolCall(String(cString: call))
    }
    return luminaRuntimeCString(#"{"status":"succeeded","content":"rewritten tool ran"}"#)
}

private let luminaFailOnceThenSuccessToolCallback: LuminaAgentToolCallback = { call, _ in
    let count: Int
    if let call {
        count = LuminaRuntimeCaptureStore.shared.appendToolCallAndReturnCount(String(cString: call))
    } else {
        LuminaRuntimeCaptureStore.shared.incrementToolCallCount()
        count = LuminaRuntimeCaptureStore.shared.snapshot().toolCallCount
    }
    if count == 1 {
        return luminaRuntimeCString(#"{"status":"failed","content":"","errorMessage":"temporary timeout","retryable":true,"errorCode":"timeout","errorCategory":"network"}"#)
    }
    return luminaRuntimeCString(#"{"status":"succeeded","content":"retried tool succeeded"}"#)
}

private let luminaRetryableFailingToolCallback: LuminaAgentToolCallback = { call, _ in
    if let call {
        LuminaRuntimeCaptureStore.shared.appendToolCall(String(cString: call))
    } else {
        LuminaRuntimeCaptureStore.shared.incrementToolCallCount()
    }
    return luminaRuntimeCString(#"{"status":"failed","content":"","errorMessage":"temporary timeout","retryable":true,"errorCode":"timeout","errorCategory":"network"}"#)
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

    func testCanonicalContractRejectsFinalAnswerType() {
        let unsupportedStep = #"{"type":"final_answer","content":"done"}"#
        let result = unsupportedStep.withCString { LuminaReActValidateStepJSON($0) }
        defer { LuminaAgentRuntimeReleaseString(result) }
        let text = result.map { String(cString: $0) } ?? ""
        XCTAssertTrue(text.contains(#""ok":false"#))
        XCTAssertTrue(text.contains("unknown ReAct step type"))
    }

    func testMiniCPMV46DialectExtractsResultAndToolUse() {
        let resultOutput = "<think>done</think>完成"
        let normalizedResult = resultOutput.withCString { text in
            "minicpm_v46_tool_calls".withCString { dialect in
                LuminaReActNormalizeStepText(text, dialect)
            }
        }
        defer { LuminaAgentRuntimeReleaseString(normalizedResult) }
        let resultText = normalizedResult.map { String(cString: $0) } ?? ""
        XCTAssertTrue(resultText.contains(#""ok":true"#))
        XCTAssertTrue(resultText.contains(#"\"type\":\"result\""#))

        let toolOutput = """
        <think>need time</think>
        <tool_call>
        <function=device.current_time>
        </function>
        </tool_call>
        """
        let normalizedTool = toolOutput.withCString { text in
            "minicpm_v46_tool_calls".withCString { dialect in
                LuminaReActNormalizeStepText(text, dialect)
            }
        }
        defer { LuminaAgentRuntimeReleaseString(normalizedTool) }
        let toolText = normalizedTool.map { String(cString: $0) } ?? ""
        XCTAssertTrue(toolText.contains(#""ok":true"#))
        XCTAssertTrue(toolText.contains(#"\"type\":\"tool_use\""#))
        XCTAssertTrue(toolText.contains(#"\"tool_name\":\"device.current_time\""#))
        XCTAssertTrue(toolText.contains(#"\"parameters\":{}"#))

        let sideEffectToolOutput = """
        <think>create it</think>
        <tool_call>
        <function=calendar.create>
        <parameter=startDateISO>
        2026-05-31T12:00:00+08:00
        </parameter>
        <parameter=title>
        Demo
        </parameter>
        </function>
        </tool_call>
        """
        let normalizedSideEffectTool = sideEffectToolOutput.withCString { text in
            "minicpm_v46_tool_calls".withCString { dialect in
                LuminaReActNormalizeStepText(text, dialect)
            }
        }
        defer { LuminaAgentRuntimeReleaseString(normalizedSideEffectTool) }
        let sideEffectToolText = normalizedSideEffectTool.map { String(cString: $0) } ?? ""
        XCTAssertTrue(sideEffectToolText.contains(#""ok":true"#))
        XCTAssertTrue(sideEffectToolText.contains(#"\"title\":\"Demo\""#))
        XCTAssertTrue(sideEffectToolText.contains(#"\"startDateISO\":\"2026-05-31T12:00:00+08:00\""#))

        let askUserOutput = """
        <think>need preference</think>
        <tool_call>
        <function=ask_user>
        <parameter=reason>
        缺少偏好
        </parameter>
        <parameter=questions>
        [{"id":"p","question":"选哪个？"}]
        </parameter>
        <parameter=sensitivity>
        normal
        </parameter>
        <parameter=timeout_seconds>
        120
        </parameter>
        <parameter=allow_custom_answer>
        true
        </parameter>
        </function>
        </tool_call>
        """
        let normalizedAskUser = askUserOutput.withCString { text in
            "minicpm_v46_tool_calls".withCString { dialect in
                LuminaReActNormalizeStepText(text, dialect)
            }
        }
        defer { LuminaAgentRuntimeReleaseString(normalizedAskUser) }
        let askUserText = normalizedAskUser.map { String(cString: $0) } ?? ""
        XCTAssertTrue(askUserText.contains(#""ok":true"#))
        XCTAssertTrue(askUserText.contains(#"\"type\":\"ask_user\""#))
    }

    func testMiniCPMV46DialectDoesNotParseLegacyToolUseAsAction() {
        let legacyToolOutput = #"<thought>search first</thought><tool_use name="calendar.search" requires_confirmation="false">{"query":"LuminaTest"}</tool_use>"#
        let normalizedTool = legacyToolOutput.withCString { text in
            "minicpm_v46_tool_calls".withCString { dialect in
                LuminaReActNormalizeStepText(text, dialect)
            }
        }
        defer { LuminaAgentRuntimeReleaseString(normalizedTool) }
        let toolText = normalizedTool.map { String(cString: $0) } ?? ""
        XCTAssertTrue(toolText.contains(#""ok":true"#))
        XCTAssertTrue(toolText.contains(#"\"type\":\"result\""#))
        XCTAssertFalse(toolText.contains(#"\"tool_name\":\"calendar.search\""#))
    }

    func testXMLTagDialectIsNotSupported() {
        let output = #"<thought>bad</thought><tool_use name="calendar.search">{"query":"Project"}</tool_use>"#
        let normalizedTool = output.withCString { text in
            "xml_tags".withCString { dialect in
                LuminaReActNormalizeStepText(text, dialect)
            }
        }
        defer { LuminaAgentRuntimeReleaseString(normalizedTool) }
        let toolText = normalizedTool.map { String(cString: $0) } ?? ""
        XCTAssertTrue(toolText.contains(#""ok":false"#))
        XCTAssertTrue(toolText.contains("xml_tags is no longer a supported model-facing dialect"))
        XCTAssertFalse(toolText.contains(#"\"tool_name\":\"calendar.search\""#))
    }

    func testCanonicalJSONDialectIsNotModelFacing() {
        let output = #"{"type":"tool_use","tool_name":"calendar.search","parameters":{"query":"Project"}}"#
        let normalizedTool = output.withCString { text in
            "canonical_json".withCString { dialect in
                LuminaReActNormalizeStepText(text, dialect)
            }
        }
        defer { LuminaAgentRuntimeReleaseString(normalizedTool) }
        let toolText = normalizedTool.map { String(cString: $0) } ?? ""
        XCTAssertTrue(toolText.contains(#""ok":false"#))
        XCTAssertTrue(toolText.contains("canonical_json is not a model-facing dialect"))
        XCTAssertFalse(toolText.contains(#"\"tool_name\":\"calendar.search\""#))
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

    func testSessionHistoryCallbackReceivesLifecycleEventsAndRedactsSecrets() throws {
        guard let runtime = LuminaAgentRuntimeCreate(luminaKernelRuntimeConfigurationJSON(maxIterations: 1)) else {
            XCTFail("Failed to create runtime")
            return
        }
        defer { LuminaAgentRuntimeDestroy(runtime) }
        LuminaAgentRuntimeSetModelCallback(runtime, luminaFinalModelCallback, nil)
        LuminaAgentRuntimeSetSessionHistoryCallback(runtime, luminaHistoryCallback, nil)

        let request = #"{"text":"history test","api_key":"sk-test-secret","nested":{"token":"bearer-token","password":"pw"}}"#
        let result = request.withCString { LuminaAgentRuntimeRun(runtime, $0) }
        if let result { LuminaAgentRuntimeReleaseString(result) }

        let history = LuminaRuntimeCaptureStore.shared.snapshot().historyEvents
        let eventNames = history.compactMap { event -> String? in
            guard let object = try? JSONSerialization.jsonObject(with: Data(event.utf8)) as? [String: Any] else { return nil }
            XCTAssertNotNil(object["session_id"])
            XCTAssertNotNil(object["run_id"])
            XCTAssertNotNil(object["sequence"])
            XCTAssertNotNil(object["timestamp"])
            return object["event"] as? String
        }
        XCTAssertTrue(eventNames.contains("run_started"))
        XCTAssertTrue(eventNames.contains("step_recorded"))
        XCTAssertTrue(eventNames.contains("run_finished"))
        let joined = history.joined(separator: "\n")
        XCTAssertFalse(joined.contains("sk-test-secret"))
        XCTAssertFalse(joined.contains("bearer-token"))
        XCTAssertFalse(joined.contains(#""password":"pw""#))
        XCTAssertTrue(joined.contains(#""api_key":"[redacted]""#))
        XCTAssertTrue(joined.contains(#""token":"[redacted]""#))
    }

    func testSessionHistoryRecordsObservationCreated() throws {
        guard let runtime = LuminaAgentRuntimeCreate(luminaKernelRuntimeConfigurationJSON(maxIterations: 2)) else {
            XCTFail("Failed to create runtime")
            return
        }
        defer { LuminaAgentRuntimeDestroy(runtime) }
        LuminaAgentRuntimeSetModelCallback(runtime, luminaAskUserModelCallback, nil)
        LuminaAgentRuntimeSetSessionHistoryCallback(runtime, luminaHistoryCallback, nil)

        let result = "{}".withCString { LuminaAgentRuntimeRun(runtime, $0) }
        if let result { LuminaAgentRuntimeReleaseString(result) }

        let history = LuminaRuntimeCaptureStore.shared.snapshot().historyEvents
        XCTAssertTrue(history.contains { $0.contains(#""event":"observation_created""#) })
        XCTAssertTrue(history.contains { $0.contains(#""toolName":"ask_user""#) || $0.contains(#""tool_name":"ask_user""#) })
    }

    func testCheckpointExportWithHistoryIsExplicit() throws {
        guard let runtime = LuminaAgentRuntimeCreate(luminaKernelRuntimeConfigurationJSON(maxIterations: 1)) else {
            XCTFail("Failed to create runtime")
            return
        }
        defer { LuminaAgentRuntimeDestroy(runtime) }
        LuminaAgentRuntimeSetSessionHistoryCallback(runtime, luminaHistoryCallback, nil)

        guard let session = "{}".withCString({ LuminaAgentRuntimeCreateSession(runtime, $0) }) else {
            XCTFail("Failed to create session")
            return
        }
        defer { LuminaAgentRuntimeDestroySession(session) }

        let oldExport = LuminaAgentRuntimeExportSessionCheckpoint(session)
        if let oldExport { LuminaAgentRuntimeReleaseString(oldExport) }
        XCTAssertTrue(LuminaRuntimeCaptureStore.shared.snapshot().historyEvents.isEmpty)

        let newExport = LuminaAgentRuntimeExportSessionCheckpointWithHistory(runtime, session)
        if let newExport { LuminaAgentRuntimeReleaseString(newExport) }
        let history = LuminaRuntimeCaptureStore.shared.snapshot().historyEvents
        XCTAssertEqual(history.count, 1)
        XCTAssertTrue(history[0].contains(#""event":"checkpoint_exported""#))
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
        XCTAssertTrue(input.contains(#""dialect":"minicpm_v46_tool_calls""#))
        XCTAssertTrue(input.contains(#"<think>"#))
        XCTAssertTrue(input.contains(#"<tool_call>"#))
        XCTAssertTrue(input.contains(#""observation_token_budget":"#))
        XCTAssertFalse(input.contains(#"tool_response"#))
        XCTAssertFalse(input.contains(#"tool_result_token_budget"#))
        XCTAssertFalse(input.contains(#"provider-native"#))
        XCTAssertFalse(input.contains(#"OpenAI-style"#))
        XCTAssertFalse(input.contains(#"role/content"#))
        XCTAssertFalse(input.contains(#"canonical ReAct step JSON"#))
        XCTAssertFalse(input.contains(#""raw_request":"#))
    }

    func testTaskEnvelopeUsesLuminaCodeStyleDefaultSystemPromptWhenCallerOmitsOne() throws {
        guard let runtime = LuminaAgentRuntimeCreate(luminaKernelRuntimeConfigurationJSON(maxIterations: 1)) else {
            XCTFail("Failed to create runtime")
            return
        }
        defer { LuminaAgentRuntimeDestroy(runtime) }
        LuminaAgentRuntimeSetModelCallback(runtime, luminaFinalModelCallback, nil)

        let result = LuminaAgentRuntimeRun(runtime, #"{"id":"default-system","text":"hello","content":[{"modality":"text","text":"hello"}]}"#)
        if let result {
            LuminaAgentRuntimeReleaseString(result)
        }

        let input = LuminaRuntimeCaptureStore.shared.snapshot().plannerInputs.first ?? ""
        XCTAssertTrue(input.contains(#""system_prompt_source":"lumina_code_default""#))
        XCTAssertTrue(input.contains("[SECTION: instruction-priority]"))
        XCTAssertTrue(input.contains("[SECTION: trust-and-external-context]"))
        XCTAssertTrue(input.contains("permission_and_confirmation_are_not_tools"))
        XCTAssertTrue(input.contains("skill_policy"))
        XCTAssertTrue(input.contains("Runtime observations are authoritative evidence"))
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
        XCTAssertTrue(events.contains(#""core_extracted_special_token_step":true"#))
        XCTAssertTrue(events.contains(#""model_stream_contains_special_tokens":true"#))
        XCTAssertFalse(events.contains(#""host_returned_canonical_step":true"#))
        XCTAssertTrue(events.contains(#""canonical_step_excerpt":"#))
        XCTAssertFalse(events.contains(#""raw_output_excerpt":"#))
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

    func testContextLoadingPluginProgressivelyLoadsAndCheckpointsWorkingSet() throws {
        guard let runtime = LuminaAgentRuntimeCreate(luminaKernelRuntimeConfigurationJSON(maxIterations: 3)) else {
            XCTFail("Failed to create runtime")
            return
        }
        defer { LuminaAgentRuntimeDestroy(runtime) }
        LuminaAgentRuntimeSetModelCallback(runtime, luminaNeedsContextThenFinalModelCallback, nil)
        LuminaAgentRuntimeSetContextLoadingPluginCallback(runtime, luminaContextLoadingPluginCallback, nil)

        guard let session = LuminaAgentRuntimeCreateSession(
            runtime,
            #"{"id":"context-plugin","text":"需要记忆上下文","content":[{"modality":"text","text":"需要记忆上下文"}]}"#
        ) else {
            XCTFail("Failed to create session")
            return
        }
        defer { LuminaAgentRuntimeDestroySession(session) }

        let result = LuminaAgentRuntimeRunSession(runtime, session)
        if let result {
            LuminaAgentRuntimeReleaseString(result)
        }
        let checkpointPointer = LuminaAgentRuntimeExportSessionCheckpoint(session)
        let checkpoint = checkpointPointer.map { String(cString: $0) } ?? "{}"
        if let checkpointPointer {
            LuminaAgentRuntimeReleaseString(checkpointPointer)
        }

        let snapshot = LuminaRuntimeCaptureStore.shared.snapshot()
        XCTAssertEqual(snapshot.plannerInputs.count, 2)
        XCTAssertTrue(snapshot.plannerInputs[0].contains("Memory index"))
        XCTAssertTrue(snapshot.plannerInputs[0].contains("轻量首轮上下文"))
        XCTAssertTrue(snapshot.plannerInputs[1].contains("插件加载的更深层上下文"))
        XCTAssertTrue(snapshot.contextLoadingRequests.contains { $0.contains(#""action":"catalog""#) })
        XCTAssertTrue(snapshot.contextLoadingRequests.contains { $0.contains(#""action":"search""#) })
        XCTAssertTrue(snapshot.contextLoadingRequests.contains { $0.contains(#""action":"load""#) })
        XCTAssertTrue(checkpoint.contains(#""loaded_context_set""#))
        XCTAssertTrue(checkpoint.contains("memory.deep"))
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
        XCTAssertTrue(result.contains(#""status":"succeeded""#), result)
        XCTAssertEqual(snapshot.toolCallCount, 0)
        XCTAssertTrue(snapshot.plannerInputs.first?.contains(#""mode":"direct""#) == true)
        XCTAssertTrue(snapshot.plannerInputs.first?.contains("All callable tools are already listed") == true)
        XCTAssertTrue(snapshot.plannerInputs.first?.contains(#""focused_schemas":[{"name":"calendar.search""#) == true)
        XCTAssertTrue(snapshot.plannerInputs.first?.contains("Choose an exact listed tool_name") == true)
        XCTAssertTrue(snapshot.plannerInputs.dropFirst().joined(separator: "\n").contains(#""calendar.search""#))
    }

    func testSkillDiscoveryUsesLuminaCodeListingAndDoesNotExposePermissionAsTool() throws {
        guard let runtime = LuminaAgentRuntimeCreate(luminaKernelRuntimeConfigurationJSON(maxIterations: 3)) else {
            XCTFail("Failed to create runtime")
            return
        }
        defer { LuminaAgentRuntimeDestroy(runtime) }
        LuminaAgentRuntimeSetModelCallback(runtime, luminaSkillDiscoveryThenFinalModelCallback, nil)
        LuminaAgentRuntimeSetEventCallback(runtime, luminaEventCallback, nil)

        let skillPointer = LuminaAgentRuntimeRegisterSkillMetadata(
            runtime,
            #"{"canonicalName":"build-ios","description":"Build and run iOS apps with the local Xcode simulator.","whenToUse":"Use when an iOS app needs to be built, launched, tested, or inspected.","source":"project","directory":"/tmp/project","skillFile":"/tmp/project/SKILL.md"}"#
        )
        let skillResult = skillPointer.map { String(cString: $0) } ?? "{}"
        if let skillPointer { LuminaAgentRuntimeReleaseString(skillPointer) }
        XCTAssertTrue(skillResult.contains(#""ok":true"#), skillResult)

        let directPointer = LuminaAgentRuntimeDiscoverSkills(runtime, #"{"query":"ios","max_results":2}"#)
        let directDiscovery = directPointer.map { String(cString: $0) } ?? "{}"
        if let directPointer { LuminaAgentRuntimeReleaseString(directPointer) }
        XCTAssertTrue(directDiscovery.contains("<system-reminder>"))
        XCTAssertTrue(directDiscovery.contains("The following skills are available through the Skill tool"))
        XCTAssertTrue(directDiscovery.contains("build-ios"))
        XCTAssertTrue(directDiscovery.contains(#""when_to_use":"#))

        let resultPointer = LuminaAgentRuntimeRun(runtime, #"{"id":"skill-discovery","text":"帮我构建 iOS app","content":[{"modality":"text","text":"帮我构建 iOS app"}]}"#)
        let result = resultPointer.map { String(cString: $0) } ?? "{}"
        if let resultPointer { LuminaAgentRuntimeReleaseString(resultPointer) }

        let snapshot = LuminaRuntimeCaptureStore.shared.snapshot()
        let firstInput = snapshot.plannerInputs.first ?? ""
        XCTAssertTrue(result.contains(#""status":"succeeded""#), result)
        XCTAssertEqual(snapshot.toolCallCount, 0)
        XCTAssertTrue(firstInput.contains(#""skills""#))
        XCTAssertTrue(firstInput.contains(#""discovery_tool":"runtime.skill_discovery""#))
        XCTAssertTrue(firstInput.contains(#""execution_tool":"Skill""#))
        XCTAssertTrue(firstInput.contains("<system-reminder>"))
        XCTAssertTrue(firstInput.contains(#""name":"Skill""#))
        XCTAssertTrue(firstInput.contains(#""side_effect":"readOnly""#))
        XCTAssertTrue(firstInput.contains(#""read_only":true"#))
        XCTAssertTrue(firstInput.contains(#""name":"runtime.skill_discovery""#))
        XCTAssertFalse(firstInput.contains(#""name":"permission_request""#))
        XCTAssertFalse(firstInput.contains(#""name":"confirmation_request""#))
        XCTAssertTrue(snapshot.events.joined(separator: "\n").contains("skill_discovery_completed"))
    }

    func testMCPDiscoveryFindsProviderToolsAndLoadsDeferredSchema() throws {
        let config = """
        {"maxIterations":3,"maxToolCalls":8,"contextWindowTokens":12000,"maxContextTokens":12000,"maxOutputTokens":4096,"reservedOutputTokens":256,"maxObservationCharacters":1500,"toolResultTokenBudget":1024,"compactThresholdTokens":1800,"maxCompactFailures":3,"maxReasoningSteps":3,"maxReplayObservations":2,"stopOnToolFailure":false,"toolLoadingMode":"enabled"}
        """
        guard let runtime = LuminaAgentRuntimeCreate(config) else {
            XCTFail("Failed to create runtime")
            return
        }
        defer { LuminaAgentRuntimeDestroy(runtime) }
        LuminaAgentRuntimeSetModelCallback(runtime, luminaMCPDiscoveryThenFinalModelCallback, nil)
        LuminaAgentRuntimeSetEventCallback(runtime, luminaEventCallback, nil)

        let providerPointer = LuminaAgentRuntimeRegisterExternalToolProvider(
            runtime,
            #"{"provider_id":"mcp-test","namespace":"mcp","allowed_tools":["echo"],"schemas":[{"name":"echo","description":"Echo input from an MCP server.","category":"mcp","sideEffect":"readOnly","readOnly":true,"deferByDefault":true,"parameters":[{"name":"text","type":"string","required":true}],"sensitivity":"normal"}]}"#
        )
        let providerResult = providerPointer.map { String(cString: $0) } ?? "{}"
        if let providerPointer { LuminaAgentRuntimeReleaseString(providerPointer) }
        XCTAssertTrue(providerResult.contains(#""registered_tools":1"#), providerResult)

        let directPointer = LuminaAgentRuntimeDiscoverMCPTools(runtime, #"{"query":"echo","include_schemas":true,"max_results":2}"#)
        let directDiscovery = directPointer.map { String(cString: $0) } ?? "{}"
        if let directPointer { LuminaAgentRuntimeReleaseString(directPointer) }
        XCTAssertTrue(directDiscovery.contains(#""mcp.echo""#))
        XCTAssertTrue(directDiscovery.contains("Echo input"))

        let resultPointer = LuminaAgentRuntimeRun(runtime, #"{"id":"mcp-discovery","text":"找 MCP echo 工具","content":[{"modality":"text","text":"找 MCP echo 工具"}]}"#)
        let result = resultPointer.map { String(cString: $0) } ?? "{}"
        if let resultPointer { LuminaAgentRuntimeReleaseString(resultPointer) }

        let snapshot = LuminaRuntimeCaptureStore.shared.snapshot()
        XCTAssertTrue(result.contains(#""status":"succeeded""#), result)
        XCTAssertEqual(snapshot.toolCallCount, 0)
        XCTAssertTrue((snapshot.plannerInputs.first ?? "").contains(#""mcp_tools""#))
        XCTAssertTrue((snapshot.plannerInputs.first ?? "").contains(#""discovery_tool":"runtime.mcp_discovery""#))
        XCTAssertTrue((snapshot.plannerInputs.first ?? "").contains(#""name":"runtime.mcp_discovery""#))
        XCTAssertTrue(snapshot.plannerInputs.dropFirst().joined(separator: "\n").contains(#""loaded_tool_set":["mcp.echo"]"#))
        XCTAssertTrue(snapshot.events.joined(separator: "\n").contains("mcp_discovery_completed"))
    }

    func testDeferredToolIsListedButNotCallableUntilLoaded() throws {
        let config = """
        {"maxIterations":2,"maxToolCalls":8,"contextWindowTokens":12000,"maxContextTokens":12000,"maxOutputTokens":4096,"reservedOutputTokens":256,"maxObservationCharacters":1500,"toolResultTokenBudget":1024,"compactThresholdTokens":1800,"maxCompactFailures":3,"maxReasoningSteps":3,"maxReplayObservations":2,"stopOnToolFailure":false,"toolLoadingMode":"enabled"}
        """
        guard let runtime = LuminaAgentRuntimeCreate(config) else {
            XCTFail("Failed to create runtime")
            return
        }
        defer { LuminaAgentRuntimeDestroy(runtime) }
        LuminaAgentRuntimeSetModelCallback(runtime, luminaDeferredToolDirectThenFinalModelCallback, nil)
        LuminaAgentRuntimeSetToolCallback(runtime, luminaToolCallback, nil)
        let schemaPointer = LuminaAgentRuntimeRegisterToolSchema(
            runtime,
            #"{"name":"deferred.search","description":"Search deferred data.","category":"search","aliases":["lazy search"],"searchHint":"deferred lazy search","sideEffect":"readOnly","readOnly":true,"concurrencySafe":true,"deferByDefault":true,"parameters":[{"name":"query","type":"string","required":true}]}"#
        )
        if let schemaPointer { LuminaAgentRuntimeReleaseString(schemaPointer) }

        let resultPointer = LuminaAgentRuntimeRun(runtime, #"{"id":"deferred-direct","text":"直接调用 deferred tool","content":[{"modality":"text","text":"直接调用 deferred tool"}]}"#)
        let result = resultPointer.map { String(cString: $0) } ?? "{}"
        if let resultPointer { LuminaAgentRuntimeReleaseString(resultPointer) }

        let snapshot = LuminaRuntimeCaptureStore.shared.snapshot()
        XCTAssertTrue(result.contains("tool is deferred") || snapshot.plannerInputs.dropFirst().joined(separator: "\n").contains("tool is deferred"))
        XCTAssertEqual(snapshot.toolCallCount, 0)
        XCTAssertTrue(snapshot.plannerInputs.first?.contains(#""deferred_catalog""#) == true)
        XCTAssertTrue(snapshot.plannerInputs.first?.contains(#""deferred.search""#) == true)
        XCTAssertTrue(snapshot.plannerInputs.first?.contains(#""focused_schemas":[]"#) == true)
        XCTAssertTrue(snapshot.plannerInputs.dropFirst().joined(separator: "\n").contains("tool is deferred"))
    }

    func testToolDiscoveryLoadsDeferredSchemaForNextPlannerTurn() throws {
        let config = """
        {"maxIterations":4,"maxToolCalls":8,"contextWindowTokens":12000,"maxContextTokens":12000,"maxOutputTokens":4096,"reservedOutputTokens":256,"maxObservationCharacters":1500,"toolResultTokenBudget":1024,"compactThresholdTokens":1800,"maxCompactFailures":3,"maxReasoningSteps":3,"maxReplayObservations":2,"stopOnToolFailure":false,"toolLoadingMode":"enabled"}
        """
        guard let runtime = LuminaAgentRuntimeCreate(config) else {
            XCTFail("Failed to create runtime")
            return
        }
        defer { LuminaAgentRuntimeDestroy(runtime) }
        LuminaAgentRuntimeSetModelCallback(runtime, luminaDeferredDiscoveryUseThenFinalModelCallback, nil)
        LuminaAgentRuntimeSetToolCallback(runtime, luminaToolCallback, nil)
        let schemaPointer = LuminaAgentRuntimeRegisterToolSchema(
            runtime,
            #"{"name":"deferred.search","description":"Search deferred data.","category":"search","aliases":["lazy search"],"searchHint":"deferred lazy search","sideEffect":"readOnly","readOnly":true,"concurrencySafe":true,"deferByDefault":true,"parameters":[{"name":"query","type":"string","required":true}]}"#
        )
        if let schemaPointer { LuminaAgentRuntimeReleaseString(schemaPointer) }

        let resultPointer = LuminaAgentRuntimeRun(runtime, #"{"id":"deferred-load","text":"发现后调用 deferred tool","content":[{"modality":"text","text":"发现后调用 deferred tool"}]}"#)
        let result = resultPointer.map { String(cString: $0) } ?? "{}"
        if let resultPointer { LuminaAgentRuntimeReleaseString(resultPointer) }

        let snapshot = LuminaRuntimeCaptureStore.shared.snapshot()
        XCTAssertTrue(result.contains(#""status":"succeeded""#))
        XCTAssertEqual(snapshot.toolCallCount, 1)
        XCTAssertTrue(snapshot.plannerInputs.first?.contains(#""focused_schemas":[]"#) == true)
        XCTAssertTrue(snapshot.plannerInputs.dropFirst().joined(separator: "\n").contains(#""loaded_tool_set":["deferred.search"]"#))
        XCTAssertTrue(snapshot.plannerInputs.dropFirst().joined(separator: "\n").contains(#""deferred.search""#))
    }

    func testCustomToolLoadingPluginCanProvideDeferredSchema() throws {
        let config = """
        {"maxIterations":3,"maxToolCalls":8,"contextWindowTokens":12000,"maxContextTokens":12000,"maxOutputTokens":4096,"reservedOutputTokens":256,"maxObservationCharacters":1500,"toolResultTokenBudget":1024,"compactThresholdTokens":1800,"maxCompactFailures":3,"maxReasoningSteps":3,"maxReplayObservations":2,"stopOnToolFailure":false,"toolLoadingMode":"enabled"}
        """
        guard let runtime = LuminaAgentRuntimeCreate(config) else {
            XCTFail("Failed to create runtime")
            return
        }
        defer { LuminaAgentRuntimeDestroy(runtime) }
        LuminaAgentRuntimeSetModelCallback(runtime, luminaPluginDeferredDiscoveryThenFinalModelCallback, nil)
        LuminaAgentRuntimeSetToolLoadingPluginCallback(runtime, luminaToolLoadingPluginCallback, nil)
        let metadataPointer = LuminaAgentRuntimeRegisterDeferredToolMetadata(
            runtime,
            #"{"name":"plugin.lazy","description":"Plugin deferred tool.","category":"plugin","aliases":["lazy plugin"],"searchHint":"plugin lazy search","sideEffect":"readOnly","sensitivity":"normal","parameterNames":["query"],"deferByDefault":true}"#
        )
        if let metadataPointer { LuminaAgentRuntimeReleaseString(metadataPointer) }

        guard let session = LuminaAgentRuntimeCreateSession(runtime, #"{"id":"plugin-load","text":"加载 plugin tool","content":[{"modality":"text","text":"加载 plugin tool"}]}"#) else {
            XCTFail("Failed to create session")
            return
        }
        defer { LuminaAgentRuntimeDestroySession(session) }

        let runPointer = LuminaAgentRuntimeRunSession(runtime, session)
        let result = runPointer.map { String(cString: $0) } ?? "{}"
        if let runPointer { LuminaAgentRuntimeReleaseString(runPointer) }

        let loadedPointer = LuminaAgentRuntimeExportLoadedToolSet(session)
        let loaded = loadedPointer.map { String(cString: $0) } ?? "[]"
        if let loadedPointer { LuminaAgentRuntimeReleaseString(loadedPointer) }

        let snapshot = LuminaRuntimeCaptureStore.shared.snapshot()
        XCTAssertTrue(result.contains(#""status":"succeeded""#))
        XCTAssertTrue(snapshot.toolLoadingRequests.contains { $0.contains(#""action":"search""#) })
        XCTAssertTrue(snapshot.toolLoadingRequests.contains { $0.contains(#""action":"load""#) })
        XCTAssertTrue(loaded.contains("plugin.lazy"))
        XCTAssertTrue(snapshot.plannerInputs.dropFirst().joined(separator: "\n").contains(#""loaded_tool_set":["plugin.lazy"]"#))
    }

    func testValidationReportsRequiredTypeAndEnumErrorsTogetherToNextModelStep() throws {
        let runtime = try XCTUnwrap(LuminaAgentRuntimeCreate(luminaKernelRuntimeConfigurationJSON(maxIterations: 4)))
        defer { LuminaAgentRuntimeDestroy(runtime) }
        LuminaAgentRuntimeSetModelCallback(runtime, luminaRepeatedIdenticalToolThenFinalModelCallback, nil)
        LuminaAgentRuntimeSetToolCallback(runtime, luminaToolCallback, nil)
        let schemaPointer = LuminaAgentRuntimeRegisterToolSchema(
            runtime,
            #"{"name":"external.open","description":"Test all validation constraints.","sideEffect":"readOnly","parameters":[{"name":"target","type":"string","required":true,"enum":["allowed-only"]},{"name":"payload","type":"number","required":true},{"name":"id","type":"string","required":true}]}"#
        )
        if let schemaPointer { LuminaAgentRuntimeReleaseString(schemaPointer) }
        if let result = LuminaAgentRuntimeRun(runtime, #"{"text":"Validate the supplied fields."}"#) {
            LuminaAgentRuntimeReleaseString(result)
        }
        let capture = LuminaRuntimeCaptureStore.shared.snapshot()
        let nextInput = try XCTUnwrap(capture.plannerInputs.dropFirst().first)
        XCTAssertEqual(capture.toolCallCount, 0)
        XCTAssertTrue(nextInput.contains("parameter target is not in the allowed enum"))
        XCTAssertTrue(nextInput.contains("parameter payload has invalid type"))
        XCTAssertTrue(nextInput.contains("missing required parameter id"))
        for name in ["target", "payload", "id"] {
            XCTAssertTrue(nextInput.contains("\"field\":\"\(name)\""), "Missing field-level correction for \(name)")
        }
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

    func testCoreCompactionProviderReceivesDynamicContextBudget() throws {
        let config = """
        {"maxIterations":2,"maxToolCalls":1,"contextWindowTokens":12000,"maxContextTokens":640,"maxOutputTokens":256,"reservedOutputTokens":40,"autoCompactBufferTokens":100,"warningBufferTokens":100,"maxObservationCharacters":500,"toolResultTokenBudget":256,"compactThresholdTokens":100,"maxCompactFailures":3,"maxReasoningSteps":2,"maxReplayObservations":2,"stopOnToolFailure":false}
        """
        guard let runtime = LuminaAgentRuntimeCreate(config) else {
            XCTFail("Failed to create runtime")
            return
        }
        defer { LuminaAgentRuntimeDestroy(runtime) }
        LuminaAgentRuntimeSetModelCallback(runtime, luminaFinalModelCallback, nil)
        LuminaAgentRuntimeSetContextCallback(runtime, luminaLargeContextCallback, nil)
        LuminaAgentRuntimeSetCompactionProviderCallback(runtime, luminaCompactionProviderCallback, nil)

        let pointer = LuminaAgentRuntimeRun(runtime, #"{"id":"compact","text":"compact"}"#)
        if let pointer { LuminaAgentRuntimeReleaseString(pointer) }

        let snapshot = LuminaRuntimeCaptureStore.shared.snapshot()
        XCTAssertFalse(snapshot.compactionRequests.isEmpty)
        XCTAssertTrue(snapshot.compactionRequests.first?.contains(#""max_context_tokens":640"#) == true)
        XCTAssertTrue(snapshot.compactionRequests.first?.contains(#""effective_context_window":600"#) == true)
        XCTAssertTrue(snapshot.plannerInputs.last?.contains("custom compacted context") == true)
    }

    func testCoreModelMetadataOverridesConfiguredContextWindowForCompaction() throws {
        let config = """
        {"maxIterations":2,"maxToolCalls":1,"contextWindowTokens":12000,"maxOutputTokens":256,"reservedOutputTokens":40,"autoCompactBufferTokens":100,"warningBufferTokens":100,"maxObservationCharacters":500,"toolResultTokenBudget":256,"compactThresholdTokens":100,"maxCompactFailures":3,"maxReasoningSteps":2,"maxReplayObservations":2,"stopOnToolFailure":false}
        """
        guard let runtime = LuminaAgentRuntimeCreate(config) else {
            XCTFail("Failed to create runtime")
            return
        }
        defer { LuminaAgentRuntimeDestroy(runtime) }
        LuminaAgentRuntimeSetModelMetadataCallback(runtime, luminaProviderMetadataCallback, nil)
        LuminaAgentRuntimeSetModelCallback(runtime, luminaFinalModelCallback, nil)
        LuminaAgentRuntimeSetContextCallback(runtime, luminaLargeContextCallback, nil)
        LuminaAgentRuntimeSetCompactionProviderCallback(runtime, luminaCompactionProviderCallback, nil)

        let pointer = LuminaAgentRuntimeRun(runtime, #"{"id":"metadata-compact","text":"compact"}"#)
        if let pointer { LuminaAgentRuntimeReleaseString(pointer) }

        let snapshot = LuminaRuntimeCaptureStore.shared.snapshot()
        XCTAssertTrue(snapshot.compactionRequests.first?.contains(#""model_id":"test-dynamic-window""#) == true)
        XCTAssertTrue(snapshot.compactionRequests.first?.contains(#""max_context_tokens":640"#) == true)
        XCTAssertTrue(snapshot.compactionRequests.first?.contains(#""provider_native_context_management":true"#) == true)
    }

    func testCoreCompactionDoesNotTriggerWhenProviderContextWindowHasRoom() throws {
        let config = """
        {"maxIterations":2,"maxToolCalls":1,"contextWindowTokens":12000,"maxContextTokens":12000,"maxOutputTokens":256,"reservedOutputTokens":40,"autoCompactBufferTokens":100,"warningBufferTokens":100,"maxObservationCharacters":500,"toolResultTokenBudget":256,"compactThresholdTokens":100,"maxCompactFailures":3,"maxReasoningSteps":2,"maxReplayObservations":2,"stopOnToolFailure":false}
        """
        guard let runtime = LuminaAgentRuntimeCreate(config) else {
            XCTFail("Failed to create runtime")
            return
        }
        defer { LuminaAgentRuntimeDestroy(runtime) }
        LuminaAgentRuntimeSetModelCallback(runtime, luminaFinalModelCallback, nil)
        LuminaAgentRuntimeSetContextCallback(runtime, luminaLargeContextCallback, nil)
        LuminaAgentRuntimeSetCompactionProviderCallback(runtime, luminaCompactionProviderCallback, nil)

        let pointer = LuminaAgentRuntimeRun(runtime, #"{"id":"no-compact","text":"no compact"}"#)
        if let pointer { LuminaAgentRuntimeReleaseString(pointer) }

        let snapshot = LuminaRuntimeCaptureStore.shared.snapshot()
        XCTAssertTrue(snapshot.compactionRequests.isEmpty)
        XCTAssertFalse(snapshot.plannerInputs.last?.contains("custom compacted context") == true)
    }

    func testCoreCompactionFallsBackWhenProviderSkips() throws {
        let config = """
        {"maxIterations":2,"maxToolCalls":1,"contextWindowTokens":12000,"maxContextTokens":640,"maxOutputTokens":256,"reservedOutputTokens":40,"autoCompactBufferTokens":100,"warningBufferTokens":100,"maxObservationCharacters":500,"toolResultTokenBudget":256,"compactThresholdTokens":100,"maxCompactFailures":3,"maxReasoningSteps":2,"maxReplayObservations":2,"stopOnToolFailure":false}
        """
        guard let runtime = LuminaAgentRuntimeCreate(config) else {
            XCTFail("Failed to create runtime")
            return
        }
        defer { LuminaAgentRuntimeDestroy(runtime) }
        LuminaAgentRuntimeSetModelCallback(runtime, luminaFinalModelCallback, nil)
        LuminaAgentRuntimeSetContextCallback(runtime, luminaLargeContextCallback, nil)
        LuminaAgentRuntimeSetCompactionProviderCallback(runtime, luminaSkippingCompactionProviderCallback, nil)

        let pointer = LuminaAgentRuntimeRun(runtime, #"{"id":"fallback-compact","text":"fallback compact"}"#)
        if let pointer { LuminaAgentRuntimeReleaseString(pointer) }

        let snapshot = LuminaRuntimeCaptureStore.shared.snapshot()
        XCTAssertFalse(snapshot.compactionRequests.isEmpty)
        XCTAssertTrue(snapshot.plannerInputs.last?.contains("context compacted because execution budget is near the provider context window") == true)
    }

    func testCoreBuiltInMicrocompactRunsWhenProviderSkips() throws {
        let config = """
        {"maxIterations":2,"maxToolCalls":1,"contextWindowTokens":2000,"maxContextTokens":2000,"maxOutputTokens":256,"reservedOutputTokens":40,"autoCompactBufferTokens":800,"warningBufferTokens":800,"maxObservationCharacters":500,"toolResultTokenBudget":128,"compactThresholdTokens":800,"maxCompactFailures":3,"maxReasoningSteps":2,"maxReplayObservations":2,"stopOnToolFailure":false}
        """
        guard let runtime = LuminaAgentRuntimeCreate(config) else {
            XCTFail("Failed to create runtime")
            return
        }
        defer { LuminaAgentRuntimeDestroy(runtime) }
        LuminaAgentRuntimeSetModelCallback(runtime, luminaFinalModelCallback, nil)
        LuminaAgentRuntimeSetContextCallback(runtime, luminaManyLargeSectionsContextCallback, nil)
        LuminaAgentRuntimeSetCompactionProviderCallback(runtime, luminaSkippingCompactionProviderCallback, nil)

        let pointer = LuminaAgentRuntimeRun(runtime, #"{"id":"microcompact","text":"micro compact"}"#)
        if let pointer { LuminaAgentRuntimeReleaseString(pointer) }

        let snapshot = LuminaRuntimeCaptureStore.shared.snapshot()
        XCTAssertTrue(snapshot.plannerInputs.last?.contains(#""microcompacted":true"#) == true)
        XCTAssertFalse(snapshot.plannerInputs.last?.contains("context compacted because execution budget is near the provider context window") == true)
        XCTAssertFalse(snapshot.plannerInputs.last?.contains("sk-test-secret-token") == true)
    }

    func testCoreCompactionPayloadRedactsSecrets() throws {
        let config = """
        {"maxIterations":2,"maxToolCalls":1,"contextWindowTokens":2000,"maxContextTokens":900,"maxOutputTokens":256,"reservedOutputTokens":40,"autoCompactBufferTokens":200,"warningBufferTokens":200,"maxObservationCharacters":500,"toolResultTokenBudget":128,"compactThresholdTokens":200,"maxCompactFailures":3,"maxReasoningSteps":2,"maxReplayObservations":2,"stopOnToolFailure":false}
        """
        guard let runtime = LuminaAgentRuntimeCreate(config) else {
            XCTFail("Failed to create runtime")
            return
        }
        defer { LuminaAgentRuntimeDestroy(runtime) }
        LuminaAgentRuntimeSetModelCallback(runtime, luminaFinalModelCallback, nil)
        LuminaAgentRuntimeSetContextCallback(runtime, luminaManyLargeSectionsContextCallback, nil)
        LuminaAgentRuntimeSetCompactionProviderCallback(runtime, luminaSkippingCompactionProviderCallback, nil)

        let pointer = LuminaAgentRuntimeRun(runtime, #"{"id":"redact","text":"redact"}"#)
        if let pointer { LuminaAgentRuntimeReleaseString(pointer) }

        let payload = LuminaRuntimeCaptureStore.shared.snapshot().compactionRequests.joined(separator: "\n")
        XCTAssertFalse(payload.contains("sk-test-secret-token"))
        XCTAssertFalse(payload.contains("Bearer sk-"))
        XCTAssertTrue(payload.contains("[REDACTED]"))
    }

    func testPromptTooLongTriggersReactiveCompactionAndRetriesModel() throws {
        let config = """
        {"maxIterations":2,"maxToolCalls":1,"contextWindowTokens":12000,"maxContextTokens":12000,"maxOutputTokens":256,"reservedOutputTokens":40,"autoCompactBufferTokens":100,"warningBufferTokens":100,"maxObservationCharacters":500,"toolResultTokenBudget":256,"compactThresholdTokens":100,"maxCompactFailures":3,"maxReasoningSteps":2,"maxReplayObservations":2,"stopOnToolFailure":false}
        """
        guard let runtime = LuminaAgentRuntimeCreate(config) else {
            XCTFail("Failed to create runtime")
            return
        }
        defer { LuminaAgentRuntimeDestroy(runtime) }
        LuminaAgentRuntimeSetModelCallback(runtime, luminaPromptTooLongThenFinalModelCallback, nil)
        LuminaAgentRuntimeSetContextCallback(runtime, luminaLargeContextCallback, nil)
        LuminaAgentRuntimeSetEventCallback(runtime, luminaEventCallback, nil)

        let pointer = LuminaAgentRuntimeRun(runtime, #"{"id":"reactive","text":"recover"}"#)
        let result = pointer.map { String(cString: $0) } ?? "{}"
        if let pointer { LuminaAgentRuntimeReleaseString(pointer) }

        let snapshot = LuminaRuntimeCaptureStore.shared.snapshot()
        XCTAssertEqual(snapshot.modelCallCount, 2)
        XCTAssertTrue(snapshot.events.contains(where: { $0.contains("prompt_too_long_recovered") }))
        XCTAssertTrue(snapshot.plannerInputs.last?.contains("context compacted because execution budget is near the provider context window") == true)
        XCTAssertTrue(result.contains("succeeded"))
    }

    func testCompactionRequestIncludesToolResultCandidates() throws {
        let config = """
        {"maxIterations":3,"maxToolCalls":2,"contextWindowTokens":12000,"maxContextTokens":450,"maxOutputTokens":128,"reservedOutputTokens":40,"autoCompactBufferTokens":200,"warningBufferTokens":200,"maxObservationCharacters":500,"toolResultTokenBudget":128,"compactThresholdTokens":200,"maxCompactFailures":3,"maxReasoningSteps":2,"maxReplayObservations":2,"stopOnToolFailure":false}
        """
        guard let runtime = LuminaAgentRuntimeCreate(config) else {
            XCTFail("Failed to create runtime")
            return
        }
        defer { LuminaAgentRuntimeDestroy(runtime) }
        let schema = #"{"name":"status.read","description":"Read status","parameters":[{"name":"scope","type":"string","required":true}],"sideEffect":"readOnly","readOnly":true,"idempotencyPolicy":"replay_identical"}"#
        let schemaPointer = LuminaAgentRuntimeRegisterToolSchema(runtime, schema)
        if let schemaPointer { LuminaAgentRuntimeReleaseString(schemaPointer) }
        LuminaAgentRuntimeSetModelCallback(runtime, luminaReadToolThenFinalModelCallback, nil)
        LuminaAgentRuntimeSetToolCallback(runtime, luminaLargeToolResultCallback, nil)
        LuminaAgentRuntimeSetCompactionProviderCallback(runtime, luminaSkippingCompactionProviderCallback, nil)

        let pointer = LuminaAgentRuntimeRun(runtime, #"{"id":"tool-candidates","text":"read"}"#)
        if let pointer { LuminaAgentRuntimeReleaseString(pointer) }

        let payload = LuminaRuntimeCaptureStore.shared.snapshot().compactionRequests.joined(separator: "\n")
        XCTAssertTrue(payload.contains(#""tool_result_candidates":["#))
        XCTAssertTrue(payload.contains(#""tool_name":"status.read""#))
        XCTAssertTrue(payload.contains("raw_result_characters"))
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

    func testCoreReplayRunsModelAndToolObservationsWithoutLiveCallbacks() throws {
        guard let runtime = LuminaAgentRuntimeCreate(luminaKernelRuntimeConfigurationJSON(maxIterations: 4)) else {
            XCTFail("Failed to create runtime")
            return
        }
        defer { LuminaAgentRuntimeDestroy(runtime) }
        LuminaAgentRuntimeSetEventCallback(runtime, luminaEventCallback, nil)
        let schemaPointer = LuminaAgentRuntimeRegisterToolSchema(
            runtime,
            #"{"name":"data.lookup","description":"Lookup data.","category":"data","sideEffect":"readOnly","parameters":[{"name":"query","type":"string","required":true}]}"#
        )
        if let schemaPointer { LuminaAgentRuntimeReleaseString(schemaPointer) }

        let replay = #"""
        {
          "mode":"all",
          "model_outputs":[
            {"step":{"schema_version":"1.0","step_id":"s-tool","type":"tool_use","thinking":"Replay lookup.","tool_name":"data.lookup","parameters":{"query":"A"},"requires_followup":true}},
            {"step":{"schema_version":"1.0","step_id":"s-result","type":"result","thinking":"Done.","content":"## Replay complete","completed":true,"requires_followup":false}}
          ],
          "tool_observations":[
            {"tool_name":"data.lookup","parameters":{"query":"A"},"result":{"status":"succeeded","content":"from replay"}}
          ]
        }
        """#
        let resultPointer = LuminaAgentRuntimeRunReplay(runtime, #"{"id":"replay","text":"replay"}"#, replay)
        let result = resultPointer.map { String(cString: $0) } ?? "{}"
        if let resultPointer { LuminaAgentRuntimeReleaseString(resultPointer) }

        let snapshot = LuminaRuntimeCaptureStore.shared.snapshot()
        XCTAssertEqual(snapshot.toolCallCount, 0)
        XCTAssertTrue(result.contains("Replay complete"))
        XCTAssertTrue(snapshot.events.joined(separator: "\n").contains("model_output_replayed"))
        XCTAssertTrue(snapshot.events.joined(separator: "\n").contains("tool_observation_replayed"))
    }

    func testNormalRunDoesNotTriggerExternalReplay() throws {
        guard let runtime = LuminaAgentRuntimeCreate(luminaKernelRuntimeConfigurationJSON(maxIterations: 1)) else {
            XCTFail("Failed to create runtime")
            return
        }
        defer { LuminaAgentRuntimeDestroy(runtime) }
        LuminaAgentRuntimeSetModelCallback(runtime, luminaFinalModelCallback, nil)
        LuminaAgentRuntimeSetEventCallback(runtime, luminaEventCallback, nil)

        let resultPointer = LuminaAgentRuntimeRun(runtime, #"{"id":"normal","text":"normal"}"#)
        if let resultPointer { LuminaAgentRuntimeReleaseString(resultPointer) }

        let events = LuminaRuntimeCaptureStore.shared.snapshot().events.joined(separator: "\n")
        XCTAssertFalse(events.contains("replay_started"))
        XCTAssertFalse(events.contains("model_output_replayed"))
        XCTAssertFalse(events.contains("tool_observation_replayed"))
    }

    func testStrictReplayMissingToolObservationFailsWithoutLiveTool() throws {
        guard let runtime = LuminaAgentRuntimeCreate(luminaKernelRuntimeConfigurationJSON(maxIterations: 4)) else {
            XCTFail("Failed to create runtime")
            return
        }
        defer { LuminaAgentRuntimeDestroy(runtime) }
        LuminaAgentRuntimeSetEventCallback(runtime, luminaEventCallback, nil)
        LuminaAgentRuntimeSetToolCallback(runtime, luminaToolCallback, nil)
        let schemaPointer = LuminaAgentRuntimeRegisterToolSchema(
            runtime,
            #"{"name":"data.lookup","description":"Lookup data.","category":"data","sideEffect":"readOnly","readOnly":true,"parameters":[{"name":"query","type":"string","required":true}]}"#
        )
        if let schemaPointer { LuminaAgentRuntimeReleaseString(schemaPointer) }

        let replay = #"""
        {
          "mode":"replay_strict",
          "model_outputs":[
            {"step":{"schema_version":"1.0","step_id":"s-tool","type":"tool_use","thinking":"Replay lookup.","tool_name":"data.lookup","parameters":{"query":"missing"},"requires_followup":true}},
            {"step":{"schema_version":"1.0","step_id":"s-result","type":"result","thinking":"Done.","content":"## Should not reach","completed":true,"requires_followup":false}}
          ],
          "tool_observations":[]
        }
        """#
        let resultPointer = LuminaAgentRuntimeRunReplay(runtime, #"{"id":"strict","text":"strict"}"#, replay)
        let result = resultPointer.map { String(cString: $0) } ?? "{}"
        if let resultPointer { LuminaAgentRuntimeReleaseString(resultPointer) }

        let snapshot = LuminaRuntimeCaptureStore.shared.snapshot()
        XCTAssertEqual(snapshot.toolCallCount, 0)
        XCTAssertTrue(result.contains("replay script did not provide a matching tool observation"))
        XCTAssertTrue(snapshot.events.joined(separator: "\n").contains("replay_missing_entry"))
    }

    func testMixedReplayMissingReadOnlyObservationCanFallbackLive() throws {
        guard let runtime = LuminaAgentRuntimeCreate(luminaKernelRuntimeConfigurationJSON(maxIterations: 4)) else {
            XCTFail("Failed to create runtime")
            return
        }
        defer { LuminaAgentRuntimeDestroy(runtime) }
        LuminaAgentRuntimeSetEventCallback(runtime, luminaEventCallback, nil)
        LuminaAgentRuntimeSetToolCallback(runtime, luminaToolCallback, nil)
        let schemaPointer = LuminaAgentRuntimeRegisterToolSchema(
            runtime,
            #"{"name":"data.lookup","description":"Lookup data.","category":"data","sideEffect":"readOnly","readOnly":true,"parameters":[{"name":"query","type":"string","required":true}]}"#
        )
        if let schemaPointer { LuminaAgentRuntimeReleaseString(schemaPointer) }

        let artifact = #"""
        {
          "artifact_type":"lumina_replay_artifact",
          "request":{"id":"mixed","text":"mixed"},
          "model_outputs":[
            {"step":{"schema_version":"1.0","step_id":"s-tool","type":"tool_use","thinking":"Replay lookup.","tool_name":"data.lookup","parameters":{"query":"live"},"requires_followup":true}},
            {"step":{"schema_version":"1.0","step_id":"s-result","type":"result","thinking":"Done.","content":"## Mixed replay complete","completed":true,"requires_followup":false}}
          ],
          "tool_observations":[]
        }
        """#
        let resultPointer = LuminaAgentRuntimeRunReplayArtifact(
            runtime,
            artifact,
            #"{"mode":"replay_mixed","allow_live_readonly_tool":true}"#
        )
        let result = resultPointer.map { String(cString: $0) } ?? "{}"
        if let resultPointer { LuminaAgentRuntimeReleaseString(resultPointer) }

        let snapshot = LuminaRuntimeCaptureStore.shared.snapshot()
        XCTAssertEqual(snapshot.toolCallCount, 1)
        XCTAssertTrue(result.contains("Mixed replay complete"))
        XCTAssertTrue(snapshot.events.joined(separator: "\n").contains("replay_live_fallback"))
    }

    func testSideEffectReplayFallbackRequiresConfirmationBeforeLiveTool() throws {
        guard let runtime = LuminaAgentRuntimeCreate(luminaKernelRuntimeConfigurationJSON(maxIterations: 4)) else {
            XCTFail("Failed to create runtime")
            return
        }
        defer { LuminaAgentRuntimeDestroy(runtime) }
        LuminaAgentRuntimeSetEventCallback(runtime, luminaEventCallback, nil)
        LuminaAgentRuntimeSetToolCallback(runtime, luminaToolCallback, nil)
        LuminaAgentRuntimeSetPermissionCallback(runtime, luminaAllowPermissionCallback, nil)
        LuminaAgentRuntimeSetConfirmationCallback(runtime, luminaConfirmingCallback, nil)
        let schemaPointer = LuminaAgentRuntimeRegisterToolSchema(
            runtime,
            #"{"name":"unsafe.write","description":"Write data.","category":"data","sideEffect":"appLocalWrite","readOnly":false,"parameters":[{"name":"query","type":"string","required":true}]}"#
        )
        if let schemaPointer { LuminaAgentRuntimeReleaseString(schemaPointer) }

        let artifact = #"""
        {
          "artifact_type":"lumina_replay_artifact",
          "request":{"id":"write","text":"write"},
          "model_outputs":[
            {"step":{"schema_version":"1.0","step_id":"s-tool","type":"tool_use","thinking":"Write.","tool_name":"unsafe.write","parameters":{"query":"create"},"requires_followup":true}},
            {"step":{"schema_version":"1.0","step_id":"s-result","type":"result","thinking":"Done.","content":"## Write replay complete","completed":true,"requires_followup":false}}
          ],
          "tool_observations":[]
        }
        """#
        let resultPointer = LuminaAgentRuntimeRunReplayArtifact(
            runtime,
            artifact,
            #"{"mode":"replay_mixed","allow_live_side_effect_tool_after_confirmation":true}"#
        )
        let result = resultPointer.map { String(cString: $0) } ?? "{}"
        if let resultPointer { LuminaAgentRuntimeReleaseString(resultPointer) }

        let snapshot = LuminaRuntimeCaptureStore.shared.snapshot()
        XCTAssertEqual(snapshot.toolCallCount, 1)
        XCTAssertTrue(result.contains("Write replay complete"))
        XCTAssertTrue(snapshot.events.joined(separator: "\n").contains(#""requires_confirmation":true"#))
    }

    func testReplayArtifactExportForkAndDiffThroughCABI() throws {
        guard let runtime = LuminaAgentRuntimeCreate(luminaKernelRuntimeConfigurationJSON(maxIterations: 2)) else {
            XCTFail("Failed to create runtime")
            return
        }
        defer { LuminaAgentRuntimeDestroy(runtime) }
        guard let session = LuminaAgentRuntimeCreateSession(runtime, #"{"id":"artifact","text":"artifact"}"#) else {
            XCTFail("Failed to create session")
            return
        }
        defer { LuminaAgentRuntimeDestroySession(session) }
        let setPointer = LuminaAgentRuntimeSessionSetState(runtime, session, "session", "topic", #"{"value":"replay"}"#)
        if let setPointer { LuminaAgentRuntimeReleaseString(setPointer) }

        let artifactPointer = LuminaAgentRuntimeExportReplayArtifact(session, #"{"redaction_level":"summary"}"#)
        let artifact = artifactPointer.map { String(cString: $0) } ?? "{}"
        if let artifactPointer { LuminaAgentRuntimeReleaseString(artifactPointer) }
        XCTAssertTrue(artifact.contains("lumina_replay_artifact"))
        XCTAssertTrue(artifact.contains("runtime_checkpoint"))
        XCTAssertTrue(artifact.contains("state_snapshot"))

        guard let forked = LuminaAgentRuntimeCreateSessionFromReplayArtifact(
            runtime,
            artifact,
            #"{"overrides":{"request":{"id":"fork","text":"forked"}}}"#
        ) else {
            XCTFail("Failed to fork from replay artifact")
            return
        }
        defer { LuminaAgentRuntimeDestroySession(forked) }
        let snapshotPointer = LuminaAgentRuntimeSnapshotSession(forked)
        let snapshot = snapshotPointer.map { String(cString: $0) } ?? "{}"
        if let snapshotPointer { LuminaAgentRuntimeReleaseString(snapshotPointer) }
        XCTAssertTrue(snapshot.contains("forked"))

        let diffSamePointer = LuminaAgentRuntimeDiffReplayArtifacts(artifact, artifact, "{}")
        let diffSame = diffSamePointer.map { String(cString: $0) } ?? "{}"
        if let diffSamePointer { LuminaAgentRuntimeReleaseString(diffSamePointer) }
        XCTAssertTrue(diffSame.contains(#""exact_match":true"#))

        let changed = artifact.replacingOccurrences(of: #""tool_observations":[]"#, with: #""tool_observations":[{"tool_name":"x","result":{"status":"succeeded","content":"changed"}}]"#)
        let diffChangedPointer = LuminaAgentRuntimeDiffReplayArtifacts(artifact, changed, "{}")
        let diffChanged = diffChangedPointer.map { String(cString: $0) } ?? "{}"
        if let diffChangedPointer { LuminaAgentRuntimeReleaseString(diffChangedPointer) }
        XCTAssertTrue(diffChanged.contains(#""tool_drift":true"#))
    }

    func testCheckpointPolicyEmitsCoreCheckpointEvent() throws {
        let configuration = luminaKernelRuntimeConfigurationJSON(maxIterations: 2)
            .replacingOccurrences(of: #"stopOnToolFailure":false"#, with: #"stopOnToolFailure":false,"checkpointPolicy":"onStep""#)
        guard let runtime = LuminaAgentRuntimeCreate(configuration) else {
            XCTFail("Failed to create runtime")
            return
        }
        defer { LuminaAgentRuntimeDestroy(runtime) }
        LuminaAgentRuntimeSetModelCallback(runtime, luminaFinalModelCallback, nil)
        LuminaAgentRuntimeSetEventCallback(runtime, luminaEventCallback, nil)

        let resultPointer = LuminaAgentRuntimeRun(runtime, #"{"id":"checkpoint","text":"checkpoint"}"#)
        if let resultPointer { LuminaAgentRuntimeReleaseString(resultPointer) }

        let events = LuminaRuntimeCaptureStore.shared.snapshot().events.joined(separator: "\n")
        XCTAssertTrue(events.contains("checkpoint_created"))
        XCTAssertTrue(events.contains("runtime_checkpoint"))
        XCTAssertTrue(events.contains(#""policy":"on_step""#))
    }

    func testSpanSinkReceivesCorrelationAndSpanIds() throws {
        guard let runtime = LuminaAgentRuntimeCreate(luminaKernelRuntimeConfigurationJSON(maxIterations: 1)) else {
            XCTFail("Failed to create runtime")
            return
        }
        defer { LuminaAgentRuntimeDestroy(runtime) }
        LuminaAgentRuntimeSetModelCallback(runtime, luminaFinalModelCallback, nil)
        LuminaAgentRuntimeSetSpanCallback(runtime, luminaSpanCallback, nil)

        let resultPointer = LuminaAgentRuntimeRun(runtime, #"{"id":"span","text":"span"}"#)
        if let resultPointer { LuminaAgentRuntimeReleaseString(resultPointer) }

        let spans = LuminaRuntimeCaptureStore.shared.snapshot().spans.joined(separator: "\n")
        XCTAssertTrue(spans.contains(#""name":"runtime.run""#))
        XCTAssertTrue(spans.contains(#""span_id":"#))
        XCTAssertTrue(spans.contains(#""parent_span_id":"#))
        XCTAssertTrue(spans.contains(#""session_id":"session-"#))
        XCTAssertTrue(spans.contains(#""run_id":"run-"#))
    }

    func testExternalToolProviderRegistersNamespacedSchemaThroughCABI() throws {
        guard let runtime = LuminaAgentRuntimeCreate(luminaKernelRuntimeConfigurationJSON(maxIterations: 3)) else {
            XCTFail("Failed to create runtime")
            return
        }
        defer { LuminaAgentRuntimeDestroy(runtime) }
        LuminaAgentRuntimeSetModelCallback(runtime, luminaExternalProviderThenFinalModelCallback, nil)
        LuminaAgentRuntimeSetToolCallback(runtime, luminaRecordingToolCallback, nil)

        let providerPointer = LuminaAgentRuntimeRegisterExternalToolProvider(
            runtime,
            #"{"provider_id":"mcp-test","namespace":"mcp","allowed_tools":["echo"],"schemas":[{"name":"echo","description":"Echo input.","category":"external","sideEffect":"readOnly","parameters":[{"name":"text","type":"string","required":true,"sensitive":true}],"sensitivity":"normal"}],"api_token":"must-not-leak"}"#
        )
        let providerResult = providerPointer.map { String(cString: $0) } ?? "{}"
        if let providerPointer { LuminaAgentRuntimeReleaseString(providerPointer) }
        XCTAssertTrue(providerResult.contains(#""registered_tools":1"#))
        XCTAssertFalse(providerResult.contains("must-not-leak"))

        let resultPointer = LuminaAgentRuntimeRun(runtime, #"{"id":"provider","text":"provider"}"#)
        if let resultPointer { LuminaAgentRuntimeReleaseString(resultPointer) }
        let snapshot = LuminaRuntimeCaptureStore.shared.snapshot()
        XCTAssertEqual(snapshot.toolCallCount, 1)
        XCTAssertTrue(snapshot.toolCalls.first?.contains(#""tool_name":"mcp.echo""#) == true)
        XCTAssertTrue(snapshot.toolCalls.first?.contains(#""text":"hello""#) == true)
    }

    func testExternalToolProviderTrustRequestRequiresYoloOrTrustedProvider() throws {
        let providerJSON = #"{"provider_id":"mcp-trust","namespace":"mcp","requiresTrust":true,"trustRequest":{"reason":"local MCP provider asks for host trust"},"allowed_tools":["echo"],"schemas":[{"name":"echo","description":"Echo input.","category":"external","sideEffect":"readOnly","parameters":[{"name":"text","type":"string","required":true}],"sensitivity":"normal"}],"api_token":"must-not-leak"}"#

        guard let normalRuntime = LuminaAgentRuntimeCreate(luminaKernelRuntimeConfigurationJSON(maxIterations: 1)) else {
            XCTFail("Failed to create runtime")
            return
        }
        defer { LuminaAgentRuntimeDestroy(normalRuntime) }
        LuminaAgentRuntimeSetEventCallback(normalRuntime, luminaEventCallback, nil)
        let deniedPointer = LuminaAgentRuntimeRegisterExternalToolProvider(normalRuntime, providerJSON)
        let deniedResult = deniedPointer.map { String(cString: $0) } ?? "{}"
        if let deniedPointer { LuminaAgentRuntimeReleaseString(deniedPointer) }
        XCTAssertTrue(deniedResult.contains(#""ok":false"#))
        XCTAssertTrue(deniedResult.contains("external provider trust required"))
        XCTAssertFalse(deniedResult.contains("must-not-leak"))

        guard let yoloRuntime = LuminaAgentRuntimeCreate(luminaKernelRuntimeConfigurationJSON(maxIterations: 1, yoloMode: true)) else {
            XCTFail("Failed to create runtime")
            return
        }
        defer { LuminaAgentRuntimeDestroy(yoloRuntime) }
        LuminaAgentRuntimeSetEventCallback(yoloRuntime, luminaEventCallback, nil)
        LuminaRuntimeCaptureStore.shared.reset()
        let allowedPointer = LuminaAgentRuntimeRegisterExternalToolProvider(yoloRuntime, providerJSON)
        let allowedResult = allowedPointer.map { String(cString: $0) } ?? "{}"
        if let allowedPointer { LuminaAgentRuntimeReleaseString(allowedPointer) }
        XCTAssertTrue(allowedResult.contains(#""ok":true"#))
        XCTAssertTrue(allowedResult.contains(#""registered_tools":1"#))
        XCTAssertTrue(allowedResult.contains(#""trusted_by_yolo":true"#))
        XCTAssertFalse(allowedResult.contains("must-not-leak"))
        let events = LuminaRuntimeCaptureStore.shared.snapshot().events.joined(separator: "\n")
        XCTAssertTrue(events.contains("external_tool_provider_trust_yolo_allowed"))
    }

    func testCoreRetryProviderCanControlModelGenerationRetry() throws {
        guard let runtime = LuminaAgentRuntimeCreate(luminaKernelRuntimeConfigurationJSON(maxIterations: 1)) else {
            XCTFail("Failed to create runtime")
            return
        }
        defer { LuminaAgentRuntimeDestroy(runtime) }
        LuminaAgentRuntimeSetModelCallback(runtime, luminaEmptyThenFinalModelCallback, nil)
        LuminaAgentRuntimeSetRetryProviderCallback(runtime, luminaRetryProviderCallback, nil)
        LuminaAgentRuntimeSetEventCallback(runtime, luminaEventCallback, nil)

        let resultPointer = LuminaAgentRuntimeRun(runtime, #"{"id":"retry-model","text":"retry model"}"#)
        let result = resultPointer.map { String(cString: $0) } ?? "{}"
        if let resultPointer { LuminaAgentRuntimeReleaseString(resultPointer) }

        let snapshot = LuminaRuntimeCaptureStore.shared.snapshot()
        XCTAssertTrue(result.contains(#""status":"succeeded""#))
        XCTAssertEqual(snapshot.modelCallCount, 2)
        XCTAssertTrue(snapshot.retryRequests.joined(separator: "\n").contains(#""stage":"model_generation""#))
        XCTAssertTrue(snapshot.events.joined(separator: "\n").contains("runtime.retry.scheduled"))
        XCTAssertTrue(snapshot.events.joined(separator: "\n").contains("runtime.retry.succeeded"))
    }

    func testDefaultRetryPolicyRetriesStepNormalizationOnce() throws {
        guard let runtime = LuminaAgentRuntimeCreate(luminaKernelRuntimeConfigurationJSON(maxIterations: 1)) else {
            XCTFail("Failed to create runtime")
            return
        }
        defer { LuminaAgentRuntimeDestroy(runtime) }
        LuminaAgentRuntimeSetModelCallback(runtime, luminaInvalidThenFinalModelCallback, nil)
        LuminaAgentRuntimeSetEventCallback(runtime, luminaEventCallback, nil)

        let resultPointer = LuminaAgentRuntimeRun(runtime, #"{"id":"retry-normalize","text":"retry normalization"}"#)
        let result = resultPointer.map { String(cString: $0) } ?? "{}"
        if let resultPointer { LuminaAgentRuntimeReleaseString(resultPointer) }

        let snapshot = LuminaRuntimeCaptureStore.shared.snapshot()
        XCTAssertTrue(result.contains(#""status":"succeeded""#))
        XCTAssertEqual(snapshot.modelCallCount, 2)
        XCTAssertTrue(snapshot.events.joined(separator: "\n").contains(#""stage":"step_normalization""#))
        XCTAssertTrue(snapshot.events.joined(separator: "\n").contains("runtime.retry.scheduled"))
    }

    func testDefaultRetryPolicyRetriesReadOnlyToolExecution() throws {
        guard let runtime = LuminaAgentRuntimeCreate(luminaKernelRuntimeConfigurationJSON(maxIterations: 3)) else {
            XCTFail("Failed to create runtime")
            return
        }
        defer { LuminaAgentRuntimeDestroy(runtime) }
        LuminaAgentRuntimeSetModelCallback(runtime, luminaReadToolThenFinalModelCallback, nil)
        LuminaAgentRuntimeSetToolCallback(runtime, luminaFailOnceThenSuccessToolCallback, nil)
        LuminaAgentRuntimeSetEventCallback(runtime, luminaEventCallback, nil)
        let schemaPointer = LuminaAgentRuntimeRegisterToolSchema(
            runtime,
            #"{"name":"status.read","description":"Read retryable status.","category":"system","sideEffect":"readOnly","readOnly":true,"idempotencyPolicy":"always_execute","parameters":[{"name":"scope","type":"string","required":true}]}"#
        )
        if let schemaPointer { LuminaAgentRuntimeReleaseString(schemaPointer) }

        let resultPointer = LuminaAgentRuntimeRun(runtime, #"{"id":"retry-tool","text":"retry read tool"}"#)
        let result = resultPointer.map { String(cString: $0) } ?? "{}"
        if let resultPointer { LuminaAgentRuntimeReleaseString(resultPointer) }

        let snapshot = LuminaRuntimeCaptureStore.shared.snapshot()
        XCTAssertTrue(result.contains(#""status":"succeeded""#))
        XCTAssertEqual(snapshot.toolCallCount, 2)
        XCTAssertTrue(snapshot.events.joined(separator: "\n").contains(#""stage":"tool_execution""#))
        XCTAssertTrue(snapshot.events.joined(separator: "\n").contains("runtime.retry.succeeded"))
    }

    func testDefaultRetryPolicyDoesNotRetryWriteToolWithoutIdempotencyKey() throws {
        guard let runtime = LuminaAgentRuntimeCreate(luminaKernelRuntimeConfigurationJSON(maxIterations: 3)) else {
            XCTFail("Failed to create runtime")
            return
        }
        defer { LuminaAgentRuntimeDestroy(runtime) }
        LuminaAgentRuntimeSetModelCallback(runtime, luminaUnsafeToolThenFinalModelCallback, nil)
        LuminaAgentRuntimeSetToolCallback(runtime, luminaRetryableFailingToolCallback, nil)
        LuminaAgentRuntimeSetEventCallback(runtime, luminaEventCallback, nil)
        let schemaPointer = LuminaAgentRuntimeRegisterToolSchema(
            runtime,
            #"{"name":"unsafe.write","description":"Write without caller idempotency key.","category":"test","sideEffect":"appLocalWrite","readOnly":false,"idempotencyPolicy":"caller_keyed","parameters":[{"name":"query","type":"string","required":true}]}"#
        )
        if let schemaPointer { LuminaAgentRuntimeReleaseString(schemaPointer) }

        let resultPointer = LuminaAgentRuntimeRun(runtime, #"{"id":"no-write-retry","text":"do not retry write"}"#)
        if let resultPointer { LuminaAgentRuntimeReleaseString(resultPointer) }

        let snapshot = LuminaRuntimeCaptureStore.shared.snapshot()
        XCTAssertEqual(snapshot.toolCallCount, 1)
        XCTAssertTrue(snapshot.events.joined(separator: "\n").contains(#""action":"fail""#))
        XCTAssertFalse(snapshot.events.joined(separator: "\n").contains("runtime.retry.scheduled"))
        XCTAssertTrue(snapshot.events.joined(separator: "\n").contains("runtime.retry.failed"))
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
        XCTAssertTrue(json.contains("cannot_complete"))
        XCTAssertTrue(json.contains("guardrail_decision"))
        XCTAssertTrue(json.contains("retry_request"))
        XCTAssertTrue(json.contains("retry_decision"))
        XCTAssertTrue(json.contains("runtime_checkpoint"))
        XCTAssertTrue(json.contains("runtime_replay"))
        XCTAssertTrue(json.contains("external_tool_provider"))
        XCTAssertTrue(json.contains("tool_loading_plugin"))
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
