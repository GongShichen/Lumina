import Foundation
import LuminaAgentRuntime

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
        LuminaAgentRuntimeSetModelCallback(handle, luminaAgentClientModelCallback, context)
        LuminaAgentRuntimeSetStreamingModelCallback(handle, luminaAgentClientStreamingModelCallback, context)
        LuminaAgentRuntimeSetToolCallback(handle, luminaAgentClientToolCallback, context)
        LuminaAgentRuntimeSetContextCallback(handle, luminaAgentClientContextCallback, context)
        LuminaAgentRuntimeSetPermissionCallback(handle, luminaAgentClientPermissionCallback, context)
        LuminaAgentRuntimeSetConfirmationCallback(handle, luminaAgentClientConfirmationCallback, context)
        LuminaAgentRuntimeSetAuditCallback(handle, luminaAgentClientAuditCallback, context)
        LuminaAgentRuntimeSetRollbackCallback(handle, luminaAgentClientRollbackCallback, context)
        LuminaAgentRuntimeSetEventCallback(handle, luminaAgentClientEventCallback, context)
        LuminaAgentRuntimeSetHookCallback(handle, luminaAgentClientHookCallback, context)
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
            return "{\"ok\":false,\"status\":\"failed\",\"finalMarkdown\":\"### Runtime unavailable\"}"
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
