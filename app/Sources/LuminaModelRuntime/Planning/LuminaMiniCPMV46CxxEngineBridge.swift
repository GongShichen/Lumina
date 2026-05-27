import Foundation

@_silgen_name("LuminaMiniCPMV46BackendCapabilities")
private func LuminaMiniCPMV46BackendCapabilitiesC() -> UnsafeMutablePointer<CChar>?

@_silgen_name("LuminaMiniCPMV46GenerateReActJSON")
private func LuminaMiniCPMV46GenerateReActJSONC(
    _ modelDirectory: UnsafePointer<CChar>,
    _ backendPreference: UnsafePointer<CChar>,
    _ prompt: UnsafePointer<CChar>,
    _ contextLength: Int32,
    _ maxOutputTokens: Int32,
    _ safetyMarginTokens: Int32
) -> UnsafeMutablePointer<CChar>?

@_silgen_name("LuminaModelRuntimeFreeCString")
private func LuminaModelRuntimeFreeCStringC(_ value: UnsafeMutablePointer<CChar>?)

enum LuminaMiniCPMV46CxxEngineBridge {
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
    ) throws -> LuminaMiniCPMV46EngineResponse {
        let response = try modelDirectory.path.withCString { modelPath in
            try backendPreference.rawValue.withCString { backend in
                try prompt.withCString { promptCString in
                    guard let pointer = LuminaMiniCPMV46GenerateReActJSONC(
                        modelPath,
                        backend,
                        promptCString,
                        Int32(contextLength),
                        Int32(maxOutputTokens),
                        Int32(safetyMarginTokens)
                    ) else {
                        throw LuminaMiniCPMV46ReActModelError.engineUnavailable("MiniCPM-V 4.6 native engine returned no response.")
                    }
                    defer { LuminaModelRuntimeFreeCStringC(pointer) }
                    return String(cString: pointer)
                }
            }
        }
        return try LuminaMiniCPMV46EngineResponse.decode(response)
    }
}
