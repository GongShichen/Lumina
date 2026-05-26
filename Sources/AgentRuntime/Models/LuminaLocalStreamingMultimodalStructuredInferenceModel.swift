import Foundation

public protocol LuminaLocalStreamingMultimodalStructuredInferenceModel: LuminaLocalMultimodalStructuredInferenceModel {
    func generateJSON(
        input: LuminaStructuredStepGenerationInput,
        progress: @escaping @Sendable (LuminaStructuredInferenceProgress) -> Void
    ) async throws -> String
}
