import Foundation
import LuminaAgentRuntimeCore

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
        hooks: [any LuminaAgentRuntimeHook] = []
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
            hooks: hooks
        )
        self.runtimeHandle = LuminaAgentRuntimeHandle(configurationJSON: configuration.runtimeJSON)
        configureRuntime()
    }

    public func availableToolSchemas() async -> [LuminaToolSchema] {
        box.tools.map(\.schema)
    }

    public func run(request: LuminaAgentRequest) async -> LuminaAgentRunResult {
        await withTaskCancellationHandler {
            await run(request: request, eventSink: nil)
        } onCancel: {
            self.cancelCurrentRun()
        }
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
        box.hookContextSections = []
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

    private nonisolated func cancelCurrentRun() {
        box.requestCancellation()
        runtimeHandle?.cancelCurrentRun()
    }

    private func configureRuntime() {
        guard let runtimeHandle else { return }
        let context = Unmanaged.passUnretained(box).toOpaque()
        runtimeHandle.installCallbacks(context: context)

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
        cancellationValue: { #"{"type":"cannot_complete","thought":"cancelled","reason":"cancelled"}"# }
    ) {
        await box.generateStepJSON(plannerInputJSON: input)
    }
    return retainedCString(response)
}

let luminaAgentSwiftAdapterStreamingModelCallback: LuminaAgentStreamingModelCallback = { plannerInput, emit, emitContext, context in
    guard let box = box(from: context), let plannerInput else {
        return retainedCString(#"{"type":"cannot_complete","thought":"missing model callback context","reason":"missing model callback context"}"#)
    }
    let input = String(cString: plannerInput)
    let safeEmitContext = LuminaAgentUnsafeEmitContext(rawValue: emitContext)
    let response = blockOn(
        isCancelled: { box.isCancellationRequested() },
        cancellationValue: { #"{"type":"cannot_complete","thought":"cancelled","reason":"cancelled"}"# }
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

let luminaAgentSwiftAdapterAuditCallback: LuminaAgentAuditCallback = { auditJSON, context in
    guard let box = box(from: context), let auditJSON else { return }
    let input = String(cString: auditJSON)
    Task { await box.writeAudit(auditJSON: input) }
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
