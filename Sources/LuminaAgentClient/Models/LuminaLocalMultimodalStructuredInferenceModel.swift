import Foundation

public protocol LuminaLocalMultimodalStructuredInferenceModel: Sendable {
    func generateJSON(input: LuminaStructuredStepGenerationInput) async throws -> String
}
