import Foundation

@_silgen_name("LuminaMiniCPMV46BackendCapabilities")
private func LuminaMiniCPMV46BackendCapabilitiesC() -> UnsafeMutablePointer<CChar>?

@_silgen_name("LuminaMiniCPMV46GenerateReActJSONCancellable")
private func LuminaMiniCPMV46GenerateReActJSONCancellableC(
    _ modelDirectory: UnsafePointer<CChar>,
    _ backendPreference: UnsafePointer<CChar>,
    _ prompt: UnsafePointer<CChar>,
    _ contextLength: Int32,
    _ maxOutputTokens: Int32,
    _ safetyMarginTokens: Int32,
    _ isCancelled: @convention(c) (UnsafeMutableRawPointer?) -> Bool,
    _ cancellationContext: UnsafeMutableRawPointer?
) -> UnsafeMutablePointer<CChar>?

@_silgen_name("LuminaModelRuntimeFreeCString")
private func LuminaModelRuntimeFreeCStringC(_ value: UnsafeMutablePointer<CChar>?)

enum LuminaMiniCPMV46CxxEngineBridge {
    private final class CancellationState: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false

        func cancel() {
            lock.withLock { cancelled = true }
        }

        var isCancelled: Bool { lock.withLock { cancelled } }
    }

    static func capabilitiesJSON() -> String? {
        guard let pointer = LuminaMiniCPMV46BackendCapabilitiesC() else {
            return nil
        }
        defer { LuminaModelRuntimeFreeCStringC(pointer) }
        return String(cString: pointer)
    }

    static func generate(
        modelDirectory: URL,
        backendPreference: LuminaMiniCPMV46BackendPreference,
        prompt: String,
        contextLength: Int,
        maxOutputTokens: Int,
        safetyMarginTokens: Int
    ) async throws -> LuminaMiniCPMV46EngineResponse {
        try Task.checkCancellation()
        let cancellation = CancellationState()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let context = Unmanaged.passUnretained(cancellation).toOpaque()
            let response = try modelDirectory.path.withCString { modelPath in
                try backendPreference.rawValue.withCString { backend in
                    try prompt.withCString { promptCString in
                        guard let pointer = LuminaMiniCPMV46GenerateReActJSONCancellableC(
                            modelPath,
                            backend,
                            promptCString,
                            Int32(clamping: contextLength),
                            Int32(clamping: maxOutputTokens),
                            Int32(clamping: safetyMarginTokens),
                            { pointer in
                                guard let pointer else { return false }
                                return Unmanaged<CancellationState>.fromOpaque(pointer).takeUnretainedValue().isCancelled
                            },
                            context
                        ) else {
                            throw LuminaMiniCPMV46ReActModelError.engineUnavailable("MiniCPM-V 4.6 native engine returned no response.")
                        }
                        defer { LuminaModelRuntimeFreeCStringC(pointer) }
                        return String(cString: pointer)
                    }
                }
            }
            // Older external engines may not support interruption. Discard their
            // response after cancellation so it can never trigger a tool action.
            try Task.checkCancellation()
            return try LuminaMiniCPMV46EngineResponse.decode(response)
        } onCancel: {
            cancellation.cancel()
        }
    }
}
