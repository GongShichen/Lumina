import Foundation
import LuminaAgentRuntimeCore

final class LuminaAgentRuntimeHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var handle: OpaquePointer?

    init?(configurationJSON: String) {
        self.handle = configurationJSON.withCString { LuminaAgentRuntimeCreate($0) }
        if handle == nil {
            return nil
        }
    }

    deinit {
        lock.lock()
        let handleToDestroy = handle
        handle = nil
        lock.unlock()
        if let handleToDestroy {
            LuminaAgentRuntimeDestroy(handleToDestroy)
        }
    }

    func installCallbacks(context: UnsafeMutableRawPointer) {
        guard let handle = currentHandle() else { return }
        LuminaAgentRuntimeSetModelCallback(handle, luminaAgentSwiftAdapterModelCallback, context)
        LuminaAgentRuntimeSetStreamingModelCallback(handle, luminaAgentSwiftAdapterStreamingModelCallback, context)
        LuminaAgentRuntimeSetToolCallback(handle, luminaAgentSwiftAdapterToolCallback, context)
        LuminaAgentRuntimeSetContextCallback(handle, luminaAgentSwiftAdapterContextCallback, context)
        LuminaAgentRuntimeSetPermissionCallback(handle, luminaAgentSwiftAdapterPermissionCallback, context)
        LuminaAgentRuntimeSetConfirmationCallback(handle, luminaAgentSwiftAdapterConfirmationCallback, context)
        LuminaAgentRuntimeSetAuditCallback(handle, luminaAgentSwiftAdapterAuditCallback, context)
        LuminaAgentRuntimeSetTraceCallback(handle, luminaAgentSwiftAdapterTraceCallback, context)
        LuminaAgentRuntimeSetMetricsCallback(handle, luminaAgentSwiftAdapterMetricsCallback, context)
        LuminaAgentRuntimeSetSpanCallback(handle, luminaAgentSwiftAdapterSpanCallback, context)
        LuminaAgentRuntimeSetRollbackCallback(handle, luminaAgentSwiftAdapterRollbackCallback, context)
        LuminaAgentRuntimeSetEventCallback(handle, luminaAgentSwiftAdapterEventCallback, context)
        LuminaAgentRuntimeSetHookCallback(handle, luminaAgentSwiftAdapterHookCallback, context)
    }

    func registerToolSchema(_ schemaJSON: String) -> String {
        guard let handle = currentHandle() else {
            return #"{"ok":false,"error":"runtime handle unavailable"}"#
        }
        return schemaJSON.withCString { schemaPointer in
            consumeRuntimeString(LuminaAgentRuntimeRegisterToolSchema(handle, schemaPointer))
        }
    }

    func run(requestJSON: String) -> String {
        guard let handle = currentHandle() else {
            return "{\"ok\":false,\"status\":\"failed\",\"resultMarkdown\":\"### Runtime unavailable\"}"
        }
        return requestJSON.withCString { requestPointer in
            consumeRuntimeString(LuminaAgentRuntimeRun(handle, requestPointer))
        }
    }

    func createSession(requestJSON: String) -> LuminaAgentRuntimeSessionHandle? {
        guard let handle = currentHandle() else { return nil }
        return requestJSON.withCString { requestPointer in
            guard let session = LuminaAgentRuntimeCreateSession(handle, requestPointer) else { return nil }
            return LuminaAgentRuntimeSessionHandle(runtime: self, session: session)
        }
    }

    func run(session: OpaquePointer) -> String {
        guard let handle = currentHandle() else {
            return "{\"ok\":false,\"status\":\"failed\",\"resultMarkdown\":\"### Runtime unavailable\"}"
        }
        return consumeRuntimeString(LuminaAgentRuntimeRunSession(handle, session))
    }

    func resume(session: OpaquePointer, resumeJSON: String) -> String {
        guard let handle = currentHandle() else {
            return "{\"ok\":false,\"status\":\"failed\",\"resultMarkdown\":\"### Runtime unavailable\"}"
        }
        return resumeJSON.withCString { resumePointer in
            consumeRuntimeString(LuminaAgentRuntimeResumeSession(handle, session, resumePointer))
        }
    }

    func cancel(session: OpaquePointer) -> String {
        guard let handle = currentHandle() else {
            return "{\"ok\":false,\"status\":\"failed\",\"resultMarkdown\":\"### Runtime unavailable\"}"
        }
        return consumeRuntimeString(LuminaAgentRuntimeCancelSession(handle, session))
    }

    func snapshot(session: OpaquePointer) -> String {
        consumeRuntimeString(LuminaAgentRuntimeSnapshotSession(session))
    }

    func exportTrace(session: OpaquePointer, format: String) -> String {
        format.withCString { formatPointer in
            consumeRuntimeString(LuminaAgentRuntimeExportSessionTrace(session, formatPointer))
        }
    }

    func destroy(session: OpaquePointer) {
        LuminaAgentRuntimeDestroySession(session)
    }

    func cancelCurrentRun() {
        guard let handle = currentHandle() else { return }
        _ = consumeRuntimeString(LuminaAgentRuntimeCancel(handle, nil))
    }

    private func currentHandle() -> OpaquePointer? {
        lock.lock()
        defer { lock.unlock() }
        return handle
    }
}

public final class LuminaAgentRuntimeSession: @unchecked Sendable {
    private let handle: LuminaAgentRuntimeSessionHandle

    init(handle: LuminaAgentRuntimeSessionHandle) {
        self.handle = handle
    }

    public func run() async -> String {
        handle.run()
    }

    public func resume(observationJSON: String) async -> String {
        handle.resume(observationJSON: observationJSON)
    }

    public func cancel() async -> String {
        handle.cancel()
    }

    public func snapshot() -> String {
        handle.snapshot()
    }

    public func exportTrace(format: String = "json") -> String {
        handle.exportTrace(format: format)
    }
}

final class LuminaAgentRuntimeSessionHandle: @unchecked Sendable {
    private let lock = NSLock()
    private let runtime: LuminaAgentRuntimeHandle
    private var session: OpaquePointer?

    init(runtime: LuminaAgentRuntimeHandle, session: OpaquePointer) {
        self.runtime = runtime
        self.session = session
    }

    deinit {
        lock.lock()
        let sessionToDestroy = session
        session = nil
        lock.unlock()
        if let sessionToDestroy {
            runtime.destroy(session: sessionToDestroy)
        }
    }

    func run() -> String {
        guard let session = currentSession() else { return #"{"ok":false,"error":"session unavailable"}"# }
        return runtime.run(session: session)
    }

    func resume(observationJSON: String) -> String {
        guard let session = currentSession() else { return #"{"ok":false,"error":"session unavailable"}"# }
        return runtime.resume(session: session, resumeJSON: observationJSON)
    }

    func cancel() -> String {
        guard let session = currentSession() else { return #"{"ok":false,"error":"session unavailable"}"# }
        return runtime.cancel(session: session)
    }

    func snapshot() -> String {
        guard let session = currentSession() else { return #"{"ok":false,"error":"session unavailable"}"# }
        return runtime.snapshot(session: session)
    }

    func exportTrace(format: String) -> String {
        guard let session = currentSession() else { return "[]" }
        return runtime.exportTrace(session: session, format: format)
    }

    private func currentSession() -> OpaquePointer? {
        lock.lock()
        defer { lock.unlock() }
        return session
    }
}

func consumeRuntimeString(_ pointer: UnsafeMutablePointer<CChar>?) -> String {
    guard let pointer else { return "{}" }
    defer { LuminaAgentRuntimeReleaseString(pointer) }
    return String(cString: pointer)
}
