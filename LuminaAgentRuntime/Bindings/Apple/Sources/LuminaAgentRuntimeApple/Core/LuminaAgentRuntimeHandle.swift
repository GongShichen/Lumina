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
        LuminaAgentRuntimeSetModelMetadataCallback(handle, luminaAgentSwiftAdapterModelMetadataCallback, context)
        LuminaAgentRuntimeSetToolCallback(handle, luminaAgentSwiftAdapterToolCallback, context)
        LuminaAgentRuntimeSetContextCallback(handle, luminaAgentSwiftAdapterContextCallback, context)
        LuminaAgentRuntimeSetPermissionCallback(handle, luminaAgentSwiftAdapterPermissionCallback, context)
        LuminaAgentRuntimeSetConfirmationCallback(handle, luminaAgentSwiftAdapterConfirmationCallback, context)
        LuminaAgentRuntimeSetGuardrailCallback(handle, luminaAgentSwiftAdapterGuardrailCallback, context)
        LuminaAgentRuntimeSetRetryProviderCallback(handle, luminaAgentSwiftAdapterRetryProviderCallback, context)
        LuminaAgentRuntimeSetCompactionProviderCallback(handle, luminaAgentSwiftAdapterCompactionProviderCallback, context)
        LuminaAgentRuntimeSetAuditCallback(handle, luminaAgentSwiftAdapterAuditCallback, context)
        LuminaAgentRuntimeSetTraceCallback(handle, luminaAgentSwiftAdapterTraceCallback, context)
        LuminaAgentRuntimeSetMetricsCallback(handle, luminaAgentSwiftAdapterMetricsCallback, context)
        LuminaAgentRuntimeSetSpanCallback(handle, luminaAgentSwiftAdapterSpanCallback, context)
        LuminaAgentRuntimeSetSessionHistoryCallback(handle, luminaAgentSwiftAdapterSessionHistoryCallback, context)
        LuminaAgentRuntimeSetRollbackCallback(handle, luminaAgentSwiftAdapterRollbackCallback, context)
        LuminaAgentRuntimeSetEventCallback(handle, luminaAgentSwiftAdapterEventCallback, context)
        LuminaAgentRuntimeSetHookCallback(handle, luminaAgentSwiftAdapterHookCallback, context)
    }

    func registerHookRoute(_ routeJSON: String) -> String {
        guard let handle = currentHandle() else {
            return #"{"ok":false,"error":"runtime handle unavailable"}"#
        }
        return routeJSON.withCString { routePointer in
            consumeRuntimeString(LuminaAgentRuntimeRegisterHookRoute(handle, routePointer))
        }
    }

    func registerToolSchema(_ schemaJSON: String) -> String {
        guard let handle = currentHandle() else {
            return #"{"ok":false,"error":"runtime handle unavailable"}"#
        }
        return schemaJSON.withCString { schemaPointer in
            consumeRuntimeString(LuminaAgentRuntimeRegisterToolSchema(handle, schemaPointer))
        }
    }

    func registerExternalToolProvider(_ providerJSON: String) -> String {
        guard let handle = currentHandle() else {
            return #"{"ok":false,"error":"runtime handle unavailable"}"#
        }
        return providerJSON.withCString { providerPointer in
            consumeRuntimeString(LuminaAgentRuntimeRegisterExternalToolProvider(handle, providerPointer))
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

    func runReplay(requestJSON: String, replayJSON: String) -> String {
        guard let handle = currentHandle() else {
            return "{\"ok\":false,\"status\":\"failed\",\"resultMarkdown\":\"### Runtime unavailable\"}"
        }
        return requestJSON.withCString { requestPointer in
            replayJSON.withCString { replayPointer in
                consumeRuntimeString(LuminaAgentRuntimeRunReplay(handle, requestPointer, replayPointer))
            }
        }
    }

    func runReplayArtifact(artifactJSON: String, optionsJSON: String) -> String {
        guard let handle = currentHandle() else {
            return "{\"ok\":false,\"status\":\"failed\",\"resultMarkdown\":\"### Runtime unavailable\"}"
        }
        return artifactJSON.withCString { artifactPointer in
            optionsJSON.withCString { optionsPointer in
                consumeRuntimeString(LuminaAgentRuntimeRunReplayArtifact(handle, artifactPointer, optionsPointer))
            }
        }
    }

    func createSession(requestJSON: String) -> LuminaAgentRuntimeSessionHandle? {
        guard let handle = currentHandle() else { return nil }
        return requestJSON.withCString { requestPointer in
            guard let session = LuminaAgentRuntimeCreateSession(handle, requestPointer) else { return nil }
            return LuminaAgentRuntimeSessionHandle(runtime: self, session: session)
        }
    }

    func createSession(checkpointJSON: String) -> LuminaAgentRuntimeSessionHandle? {
        guard let handle = currentHandle() else { return nil }
        return checkpointJSON.withCString { checkpointPointer in
            guard let session = LuminaAgentRuntimeCreateSessionFromCheckpoint(handle, checkpointPointer) else { return nil }
            return LuminaAgentRuntimeSessionHandle(runtime: self, session: session)
        }
    }

    func createSession(replayArtifactJSON: String, forkOptionsJSON: String) -> LuminaAgentRuntimeSessionHandle? {
        guard let handle = currentHandle() else { return nil }
        return replayArtifactJSON.withCString { artifactPointer in
            forkOptionsJSON.withCString { optionsPointer in
                guard let session = LuminaAgentRuntimeCreateSessionFromReplayArtifact(handle, artifactPointer, optionsPointer) else { return nil }
                return LuminaAgentRuntimeSessionHandle(runtime: self, session: session)
            }
        }
    }

    func run(session: OpaquePointer) -> String {
        guard let handle = currentHandle() else {
            return "{\"ok\":false,\"status\":\"failed\",\"resultMarkdown\":\"### Runtime unavailable\"}"
        }
        return consumeRuntimeString(LuminaAgentRuntimeRunSession(handle, session))
    }

    func run(session: OpaquePointer, replayJSON: String) -> String {
        guard let handle = currentHandle() else {
            return "{\"ok\":false,\"status\":\"failed\",\"resultMarkdown\":\"### Runtime unavailable\"}"
        }
        return replayJSON.withCString { replayPointer in
            consumeRuntimeString(LuminaAgentRuntimeRunSessionReplay(handle, session, replayPointer))
        }
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

    func exportCheckpoint(session: OpaquePointer) -> String {
        guard let handle = currentHandle() else {
            return consumeRuntimeString(LuminaAgentRuntimeExportSessionCheckpoint(session))
        }
        return consumeRuntimeString(LuminaAgentRuntimeExportSessionCheckpointWithHistory(handle, session))
    }

    func exportReplayArtifact(session: OpaquePointer, optionsJSON: String) -> String {
        optionsJSON.withCString { optionsPointer in
            consumeRuntimeString(LuminaAgentRuntimeExportReplayArtifact(session, optionsPointer))
        }
    }

    func stateSnapshot(session: OpaquePointer) -> String {
        consumeRuntimeString(LuminaAgentRuntimeSessionStateSnapshot(session))
    }

    func setState(session: OpaquePointer, scope: String, key: String, valueJSON: String) -> String {
        guard let handle = currentHandle() else {
            return #"{"ok":false,"error":"runtime handle unavailable"}"#
        }
        return scope.withCString { scopePointer in
            key.withCString { keyPointer in
                valueJSON.withCString { valuePointer in
                    consumeRuntimeString(LuminaAgentRuntimeSessionSetState(handle, session, scopePointer, keyPointer, valuePointer))
                }
            }
        }
    }

    func getState(session: OpaquePointer, scope: String, key: String) -> String {
        scope.withCString { scopePointer in
            key.withCString { keyPointer in
                consumeRuntimeString(LuminaAgentRuntimeSessionGetState(session, scopePointer, keyPointer))
            }
        }
    }

    func deleteState(session: OpaquePointer, scope: String, key: String) -> String {
        guard let handle = currentHandle() else {
            return #"{"ok":false,"error":"runtime handle unavailable"}"#
        }
        return scope.withCString { scopePointer in
            key.withCString { keyPointer in
                consumeRuntimeString(LuminaAgentRuntimeSessionDeleteState(handle, session, scopePointer, keyPointer))
            }
        }
    }

    func exportTrace(session: OpaquePointer, format: String) -> String {
        format.withCString { formatPointer in
            consumeRuntimeString(LuminaAgentRuntimeExportSessionTrace(session, formatPointer))
        }
    }

    static func diffReplayArtifacts(expectedJSON: String, actualJSON: String, optionsJSON: String) -> String {
        expectedJSON.withCString { expectedPointer in
            actualJSON.withCString { actualPointer in
                optionsJSON.withCString { optionsPointer in
                    consumeRuntimeString(LuminaAgentRuntimeDiffReplayArtifacts(expectedPointer, actualPointer, optionsPointer))
                }
            }
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

    public func run(replayJSON: String) async -> String {
        handle.run(replayJSON: replayJSON)
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

    public func exportCheckpoint() -> String {
        handle.exportCheckpoint()
    }

    public func exportReplayArtifact(optionsJSON: String = "{}") -> String {
        handle.exportReplayArtifact(optionsJSON: optionsJSON)
    }

    public func stateSnapshot() -> String {
        handle.stateSnapshot()
    }

    public func setState(scope: String, key: String, valueJSON: String) -> String {
        handle.setState(scope: scope, key: key, valueJSON: valueJSON)
    }

    public func getState(scope: String, key: String) -> String {
        handle.getState(scope: scope, key: key)
    }

    public func deleteState(scope: String, key: String) -> String {
        handle.deleteState(scope: scope, key: key)
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

    func run(replayJSON: String) -> String {
        guard let session = currentSession() else { return #"{"ok":false,"error":"session unavailable"}"# }
        return runtime.run(session: session, replayJSON: replayJSON)
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

    func exportCheckpoint() -> String {
        guard let session = currentSession() else { return #"{"ok":false,"error":"session unavailable"}"# }
        return runtime.exportCheckpoint(session: session)
    }

    func exportReplayArtifact(optionsJSON: String) -> String {
        guard let session = currentSession() else { return #"{"ok":false,"error":"session unavailable"}"# }
        return runtime.exportReplayArtifact(session: session, optionsJSON: optionsJSON)
    }

    func stateSnapshot() -> String {
        guard let session = currentSession() else { return "{}" }
        return runtime.stateSnapshot(session: session)
    }

    func setState(scope: String, key: String, valueJSON: String) -> String {
        guard let session = currentSession() else { return #"{"ok":false,"error":"session unavailable"}"# }
        return runtime.setState(session: session, scope: scope, key: key, valueJSON: valueJSON)
    }

    func getState(scope: String, key: String) -> String {
        guard let session = currentSession() else { return #"{"ok":false,"error":"session unavailable"}"# }
        return runtime.getState(session: session, scope: scope, key: key)
    }

    func deleteState(scope: String, key: String) -> String {
        guard let session = currentSession() else { return #"{"ok":false,"error":"session unavailable"}"# }
        return runtime.deleteState(session: session, scope: scope, key: key)
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
