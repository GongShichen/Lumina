import Foundation

public protocol LuminaLocalDynamicOutputStreamingStructuredInferenceModel: LuminaLocalStreamingStructuredInferenceModel {
    func generateJSON(
        prompt: String,
        maxOutputTokens: Int?,
        progress: @escaping @Sendable (LuminaStructuredInferenceProgress) -> Void
    ) async throws -> String
}
