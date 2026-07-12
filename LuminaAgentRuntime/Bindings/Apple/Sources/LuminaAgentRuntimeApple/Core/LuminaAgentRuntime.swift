import Foundation
import LuminaAgentRuntimeCore

public protocol LuminaSessionHistoryStore: Sendable {
    func record(historyEventJSON: String)
}

public final class LuminaAgentRuntime: @unchecked Sendable {
    private let box: LuminaAgentRuntimeAdapterBox
    private let runtimeHandle: LuminaAgentRuntimeHandle?

    public init(
        tools: [AnyLuminaAgentTool],
        stepGenerator: any LuminaReActStepGenerator = LuminaUnavailableReActStepGenerator(),
        contextProvider: any LuminaRuntimeContextProvider = LuminaEmptyRuntimeContextProvider(),
        contextCompactor: any LuminaReActContextCompactor = LuminaSummarizingReActContextCompactor(),
        configuration: LuminaAgentRuntimeConfiguration,
        permissionGate: any LuminaPermissionGate = LuminaDefaultPermissionGate(),
        confirmationCoordinator: any LuminaConfirmationCoordinator = LuminaAlwaysConfirmCoordinator(),
        auditLogger: any LuminaAuditLogger = LuminaInMemoryAuditLogger(),
        hooks: [any LuminaAgentRuntimeHook] = [],
        observabilitySinks: LuminaRuntimeObservabilitySinks = .disabled,
        guardrails: LuminaRuntimeGuardrails = .empty,
        retryProvider: (any LuminaRuntimeRetryProvider)? = nil,
        contextLoadingPlugin: (any LuminaContextLoadingPlugin)? = nil,
        toolLoadingPlugin: (any LuminaToolLoadingPlugin)? = nil,
        sessionHistoryStore: (any LuminaSessionHistoryStore)? = nil
    ) {
        self.box = LuminaAgentRuntimeAdapterBox(
            tools: tools,
            stepGenerator: stepGenerator,
            contextProvider: contextProvider,
            contextCompactor: contextCompactor,
            configuration: configuration,
            permissionGate: permissionGate,
            confirmationCoordinator: confirmationCoordinator,
            auditLogger: auditLogger,
            hooks: hooks,
            observabilitySinks: observabilitySinks,
            guardrails: guardrails,
            retryProvider: retryProvider,
            contextLoadingPlugin: contextLoadingPlugin,
            toolLoadingPlugin: toolLoadingPlugin,
            sessionHistoryStore: sessionHistoryStore
        )
        self.runtimeHandle = LuminaAgentRuntimeHandle(configurationJSON: configuration.runtimeJSON)
        configureRuntime()
    }

    public func availableToolSchemas() async -> [LuminaToolSchema] {
        box.modelVisibleToolSchemas()
    }

    @discardableResult
    public func setYoloMode(_ enabled: Bool) -> String {
        runtimeHandle?.setYoloMode(enabled) ?? #"{"ok":false,"error":"runtime handle unavailable"}"#
    }

    public func yoloModeStatus() -> String {
        runtimeHandle?.yoloModeStatus() ?? #"{"ok":false,"error":"runtime handle unavailable"}"#
    }

    @discardableResult
    public func registerExternalToolProvider(providerJSON: String) -> String {
        runtimeHandle?.registerExternalToolProvider(providerJSON) ?? #"{"ok":false,"error":"runtime handle unavailable"}"#
    }

    public func createSession(request: LuminaAgentRequest) -> LuminaAgentRuntimeSession? {
        guard let runtimeHandle else { return nil }
        let requestJSON = (try? String(data: JSONEncoder().encode(request), encoding: .utf8)) ?? "{}"
        guard let handle = runtimeHandle.createSession(requestJSON: requestJSON) else { return nil }
        return LuminaAgentRuntimeSession(handle: handle)
    }

    @discardableResult
    public func registerDeferredToolMetadata(metadataJSON: String) -> String {
        runtimeHandle?.registerDeferredToolMetadata(metadataJSON) ?? #"{"ok":false,"error":"runtime handle unavailable"}"#
    }

    @discardableResult
    public func registerSkillMetadata(metadataJSON: String) -> String {
        let result = runtimeHandle?.registerSkillMetadata(metadataJSON) ?? #"{"ok":false,"error":"runtime handle unavailable"}"#
        if ((try? JSONSerialization.jsonObject(with: Data(result.utf8))) as? [String: Any])?["ok"] as? Bool == true {
            box.registeredSkillMetadataCount += 1
        }
        return result
    }

    public func discoverSkills(queryJSON: String = "{}") -> String {
        runtimeHandle?.discoverSkills(queryJSON) ?? #"{"ok":false,"error":"runtime handle unavailable"}"#
    }

    public func discoverMCPTools(queryJSON: String = "{}") -> String {
        runtimeHandle?.discoverMCPTools(queryJSON) ?? #"{"ok":false,"error":"runtime handle unavailable"}"#
    }

    @discardableResult
    public func registerDeferredToolMetadata(_ metadata: LuminaDeferredToolMetadata) -> String {
        guard let data = try? JSONEncoder().encode(metadata),
              let json = String(data: data, encoding: .utf8)
        else {
            return #"{"ok":false,"error":"failed to encode deferred tool metadata"}"#
        }
        return registerDeferredToolMetadata(metadataJSON: json)
    }

    public func createSession(checkpointJSON: String) -> LuminaAgentRuntimeSession? {
        guard let runtimeHandle,
              let handle = runtimeHandle.createSession(checkpointJSON: checkpointJSON)
        else { return nil }
        return LuminaAgentRuntimeSession(handle: handle)
    }

    public func createSession(replayArtifactJSON: String, forkOptionsJSON: String = "{}") -> LuminaAgentRuntimeSession? {
        guard let runtimeHandle,
              let handle = runtimeHandle.createSession(replayArtifactJSON: replayArtifactJSON, forkOptionsJSON: forkOptionsJSON)
        else { return nil }
        return LuminaAgentRuntimeSession(handle: handle)
    }

    public func run(request: LuminaAgentRequest) async -> LuminaAgentRunResult {
        await withTaskCancellationHandler {
            await run(request: request, eventSink: nil)
        } onCancel: {
            self.cancelCurrentRun()
        }
    }

    public func runReplay(request: LuminaAgentRequest, replayJSON: String) async -> LuminaAgentRunResult {
        await withTaskCancellationHandler {
            await runReplay(request: request, replayJSON: replayJSON, eventSink: nil)
        } onCancel: {
            self.cancelCurrentRun()
        }
    }

    public func runReplayArtifact(artifactJSON: String, optionsJSON: String = "{}") async -> String {
        guard let runtimeHandle else {
            return "{\"ok\":false,\"status\":\"failed\",\"resultMarkdown\":\"### Runtime unavailable\"}"
        }
        return runtimeHandle.runReplayArtifact(artifactJSON: artifactJSON, optionsJSON: optionsJSON)
    }

    public static func diffReplayArtifacts(expectedJSON: String, actualJSON: String, optionsJSON: String = "{}") -> String {
        LuminaAgentRuntimeHandle.diffReplayArtifacts(expectedJSON: expectedJSON, actualJSON: actualJSON, optionsJSON: optionsJSON)
    }

    public nonisolated func runStream(request: LuminaAgentRequest) -> AsyncStream<LuminaAgentRunEvent> {
        AsyncStream { continuation in
            Task {
                let result = await self.run(request: request) { event in
                    continuation.yield(event)
                }
                continuation.yield(.finished(result))
                continuation.finish()
            }
        }
    }

    private func run(
        request: LuminaAgentRequest,
        eventSink: (@Sendable (LuminaAgentRunEvent) -> Void)?
    ) async -> LuminaAgentRunResult {
        guard let runtimeHandle else {
            return LuminaAgentRunResult(
                requestID: request.id,
                plan: LuminaAgentPlan(summary: "Runtime unavailable.", toolCalls: []),
                toolResults: [],
                status: .failed
            )
        }
        box.currentEventSink = eventSink
        box.currentRequest = request
        box.resetCancellation()
        box.trace = LuminaReActTrace()
        box.toolResults = []
        box.stepGenerationMilliseconds = 0
        box.toolExecutionMilliseconds = 0
        box.timingStartedAt = ContinuousClock.now
        let requestJSON = (try? String(data: JSONEncoder().encode(request), encoding: .utf8)) ?? "{}"
        let resultJSON = runtimeHandle.run(requestJSON: requestJSON)
        let result = box.makeRunResult(fromRuntimeResultJSON: resultJSON, request: request)
        box.currentEventSink = nil
        box.resetCancellation()
        return result
    }

    private func runReplay(
        request: LuminaAgentRequest,
        replayJSON: String,
        eventSink: (@Sendable (LuminaAgentRunEvent) -> Void)?
    ) async -> LuminaAgentRunResult {
        guard let runtimeHandle else {
            return LuminaAgentRunResult(
                requestID: request.id,
                plan: LuminaAgentPlan(summary: "Runtime unavailable.", toolCalls: []),
                toolResults: [],
                status: .failed
            )
        }
        box.currentEventSink = eventSink
        box.currentRequest = request
        box.resetCancellation()
        box.trace = LuminaReActTrace()
        box.toolResults = []
        box.stepGenerationMilliseconds = 0
        box.toolExecutionMilliseconds = 0
        box.timingStartedAt = ContinuousClock.now
        let requestJSON = (try? String(data: JSONEncoder().encode(request), encoding: .utf8)) ?? "{}"
        let resultJSON = runtimeHandle.runReplay(requestJSON: requestJSON, replayJSON: replayJSON)
        let result = box.makeRunResult(fromRuntimeResultJSON: resultJSON, request: request)
        box.currentEventSink = nil
        box.resetCancellation()
        return result
    }

    private nonisolated func cancelCurrentRun() {
        box.requestCancellation()
        runtimeHandle?.cancelCurrentRun()
    }

    private func configureRuntime() {
        guard let runtimeHandle else { return }
        let context = Unmanaged.passUnretained(box).toOpaque()
        runtimeHandle.installCallbacks(context: context, installContextLoadingPlugin: box.contextLoadingPlugin != nil)
        for index in box.hooks.indices {
            _ = runtimeHandle.registerHookRoute(box.hookRouteJSON(index: index))
        }

        for tool in box.tools {
            guard let schemaJSON = try? String(data: JSONEncoder().encode(tool.schema), encoding: .utf8) else { continue }
            _ = runtimeHandle.registerToolSchema(schemaJSON)
        }
    }
}

private func box(from context: UnsafeMutableRawPointer?) -> LuminaAgentRuntimeAdapterBox? {
    guard let context else { return nil }
    return Unmanaged<LuminaAgentRuntimeAdapterBox>.fromOpaque(context).takeUnretainedValue()
}

private func retainedCString(_ string: String) -> UnsafeMutablePointer<CChar>? {
    strdup(string)
}

private func blockOn<T: Sendable>(
    isCancelled: @escaping @Sendable () -> Bool = { false },
    cancellationValue: @escaping @Sendable () -> T,
    operation: @escaping @Sendable () async -> T
) -> T {
    let semaphore = DispatchSemaphore(value: 0)
    let holder = LuminaAgentBlockingBox()
    let task = Task {
        holder.value = await operation()
        semaphore.signal()
    }
    while semaphore.wait(timeout: .now() + .milliseconds(10)) == .timedOut {
        if isCancelled() || Task.isCancelled {
            task.cancel()
            return cancellationValue()
        }
    }
    return holder.value as! T
}

let luminaAgentSwiftAdapterModelCallback: LuminaAgentModelCallback = { plannerInput, context in
    guard let box = box(from: context), let plannerInput else {
        return retainedCString(#"{"type":"cannot_complete","reason":"missing model callback context"}"#)
    }
    let input = String(cString: plannerInput)
    let response = blockOn(
        isCancelled: { box.isCancellationRequested() },
        cancellationValue: { #"{"type":"cannot_complete","thinking":"cancelled","reason":"cancelled"}"# }
    ) {
        await box.generateStepJSON(plannerInputJSON: input)
    }
    return retainedCString(response)
}

let luminaAgentSwiftAdapterStreamingModelCallback: LuminaAgentStreamingModelCallback = { plannerInput, emit, emitContext, context in
    guard let box = box(from: context), let plannerInput else {
        return retainedCString(#"{"type":"cannot_complete","thinking":"missing model callback context","reason":"missing model callback context"}"#)
    }
    let input = String(cString: plannerInput)
    let safeEmitContext = LuminaAgentUnsafeEmitContext(rawValue: emitContext)
    let response = blockOn(
        isCancelled: { box.isCancellationRequested() },
        cancellationValue: { #"{"type":"cannot_complete","thinking":"cancelled","reason":"cancelled"}"# }
    ) {
        await box.generateStepJSON(plannerInputJSON: input) { progress in
            guard let emit else { return true }
            let payload = LuminaAgentRuntimeAdapterBox.streamingDeltaJSON(from: progress)
            return payload.withCString { emit($0, safeEmitContext.rawValue) }
        }
    }
    return retainedCString(response)
}

let luminaAgentSwiftAdapterToolCallback: LuminaAgentToolCallback = { toolCall, context in
    guard let box = box(from: context), let toolCall else {
        return retainedCString(#"{"status":"failed","content":"","errorMessage":"missing tool callback context"}"#)
    }
    let callJSON = String(cString: toolCall)
    let response = blockOn(
        isCancelled: { box.isCancellationRequested() },
        cancellationValue: { #"{"status":"cancelled","content":"","errorMessage":"cancelled"}"# }
    ) {
        await box.executeTool(callJSON: callJSON)
    }
    return retainedCString(response)
}

let luminaAgentSwiftAdapterContextCallback: LuminaAgentContextCallback = { requestJSON, context in
    guard let box = box(from: context), let requestJSON else {
        return retainedCString("null")
    }
    let input = String(cString: requestJSON)
    let response = blockOn(cancellationValue: { "null" }) {
        await box.loadContext(requestJSON: input)
    }
    return retainedCString(response)
}

let luminaAgentSwiftAdapterContextLoadingPluginCallback: LuminaAgentContextLoadingPluginCallback = { requestJSON, context in
    guard let box = box(from: context), let requestJSON else {
        return retainedCString("{}")
    }
    guard let plugin = box.contextLoadingPlugin else {
        return retainedCString("{}")
    }
    let input = String(cString: requestJSON)
    let response = blockOn(cancellationValue: { "{}" }) {
        await plugin.handleContextLoading(requestJSON: input)
    }
    return retainedCString(response)
}

let luminaAgentSwiftAdapterModelMetadataCallback: LuminaAgentModelMetadataCallback = { _, context in
    guard let box = box(from: context) else {
        return retainedCString("{}")
    }
    let response = """
    {"model_id":"apple-runtime-provider","max_context_tokens":\(box.configuration.contextWindowTokens),"provider_native_context_management":false}
    """
    return retainedCString(response)
}

let luminaAgentSwiftAdapterRetryProviderCallback: LuminaAgentRetryProviderCallback = { retryJSON, context in
    guard let box = box(from: context), let retryJSON else {
        return retainedCString("")
    }
    let input = String(cString: retryJSON)
    let response = blockOn(cancellationValue: { "" }) {
        await box.decideRetry(retryJSON: input)
    }
    return retainedCString(response)
}

let luminaAgentSwiftAdapterCompactionProviderCallback: LuminaAgentCompactionProviderCallback = { compactionJSON, context in
    guard let box = box(from: context), let compactionJSON else {
        return retainedCString(#"{"status":"skipped","reason":"missing compaction callback context"}"#)
    }
    let input = String(cString: compactionJSON)
    let response = blockOn(cancellationValue: { #"{"status":"skipped","reason":"cancelled"}"# }) {
        await box.compactContext(compactionJSON: input)
    }
    return retainedCString(response)
}

let luminaAgentSwiftAdapterToolLoadingPluginCallback: LuminaAgentToolLoadingPluginCallback = { requestJSON, context in
    guard let box = box(from: context), let requestJSON else {
        return retainedCString("{}")
    }
    guard let plugin = box.toolLoadingPlugin else {
        return retainedCString("{}")
    }
    let input = String(cString: requestJSON)
    let response = blockOn(cancellationValue: { "{}" }) {
        await plugin.handleToolLoading(requestJSON: input)
    }
    return retainedCString(response)
}

let luminaAgentSwiftAdapterPermissionCallback: LuminaAgentPermissionCallback = { permissionJSON, context in
    guard let box = box(from: context), let permissionJSON else {
        return retainedCString(#"{"decision":"denied","reason":"missing permission callback context"}"#)
    }
    let input = String(cString: permissionJSON)
    let response = blockOn(cancellationValue: { #"{"decision":"denied","reason":"cancelled"}"# }) {
        await box.decidePermission(permissionJSON: input)
    }
    return retainedCString(response)
}

let luminaAgentSwiftAdapterConfirmationCallback: LuminaAgentConfirmationCallback = { confirmationJSON, context in
    guard let box = box(from: context), let confirmationJSON else {
        return retainedCString(#"{"confirmed":false,"reason":"missing confirmation callback context"}"#)
    }
    let input = String(cString: confirmationJSON)
    let response = blockOn(cancellationValue: { #"{"confirmed":false,"reason":"cancelled"}"# }) {
        await box.confirm(confirmationJSON: input)
    }
    return retainedCString(response)
}

let luminaAgentSwiftAdapterGuardrailCallback: LuminaAgentGuardrailCallback = { guardrailJSON, context in
    guard let box = box(from: context), let guardrailJSON else {
        return retainedCString(#"{"decision":"reject","message":"missing guardrail callback context"}"#)
    }
    let input = String(cString: guardrailJSON)
    let response = blockOn(cancellationValue: { #"{"decision":"tripwire_failure","message":"cancelled"}"# }) {
        await box.evaluateGuardrail(guardrailJSON: input)
    }
    return retainedCString(response)
}

let luminaAgentSwiftAdapterAuditCallback: LuminaAgentAuditCallback = { auditJSON, context in
    guard let box = box(from: context), let auditJSON else { return }
    let input = String(cString: auditJSON)
    Task { await box.writeAudit(auditJSON: input) }
}

let luminaAgentSwiftAdapterTraceCallback: LuminaAgentTraceCallback = { traceJSON, context in
    guard let box = box(from: context), let traceJSON, let sink = box.observabilitySinks.trace else { return }
    let input = String(cString: traceJSON)
    Task { await sink.recordTrace(input) }
}

let luminaAgentSwiftAdapterMetricsCallback: LuminaAgentMetricsCallback = { metricJSON, context in
    guard let box = box(from: context), let metricJSON, let sink = box.observabilitySinks.metrics else { return }
    let input = String(cString: metricJSON)
    Task { await sink.recordMetric(input) }
}

let luminaAgentSwiftAdapterSpanCallback: LuminaAgentSpanCallback = { spanJSON, context in
    guard let box = box(from: context), let spanJSON, let sink = box.observabilitySinks.span else { return }
    let input = String(cString: spanJSON)
    Task { await sink.recordSpan(input) }
}

let luminaAgentSwiftAdapterSessionHistoryCallback: LuminaAgentSessionHistoryCallback = { historyJSON, context in
    guard let box = box(from: context), let historyJSON, let store = box.sessionHistoryStore else { return }
    let input = String(cString: historyJSON)
    store.record(historyEventJSON: input)
}

let luminaAgentSwiftAdapterRollbackCallback: LuminaAgentRollbackCallback = { _, _ in
    retainedCString(#"{"status":"unavailable"}"#)
}

let luminaAgentSwiftAdapterEventCallback: LuminaAgentEventCallback = { eventJSON, context in
    guard let box = box(from: context), let eventJSON else { return }
    box.consumeRuntimeEvent(eventJSON: String(cString: eventJSON))
}

let luminaAgentSwiftAdapterHookCallback: LuminaAgentHookCallback = { hookJSON, context in
    guard let box = box(from: context), let hookJSON else {
        return retainedCString("{}")
    }
    let input = String(cString: hookJSON)
    let response = blockOn(cancellationValue: { "{\"terminate\":true,\"markdown\":\"### 已取消\\n\\nRuntime hook cancelled.\",\"reason\":\"cancelled\"}" }) {
        await box.dispatchHook(hookJSON: input)
    }
    return retainedCString(response)
}
