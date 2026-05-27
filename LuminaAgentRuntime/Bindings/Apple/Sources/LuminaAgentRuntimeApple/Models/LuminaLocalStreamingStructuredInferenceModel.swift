import Foundation

public protocol LuminaLocalStreamingStructuredInferenceModel: LuminaLocalStructuredInferenceModel {
    func generateJSON(
        prompt: String,
        progress: @escaping @Sendable (LuminaStructuredInferenceProgress) -> Void
    ) async throws -> String
}
