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

func consumeRuntimeString(_ pointer: UnsafeMutablePointer<CChar>?) -> String {
    guard let pointer else { return "{}" }
    defer { LuminaAgentRuntimeReleaseString(pointer) }
    return String(cString: pointer)
}
