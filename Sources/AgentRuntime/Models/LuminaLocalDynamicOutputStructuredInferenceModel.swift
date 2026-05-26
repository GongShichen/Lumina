import Foundation

public protocol LuminaLocalDynamicOutputStructuredInferenceModel: LuminaLocalStructuredInferenceModel {
    func generateJSON(prompt: String, maxOutputTokens: Int?) async throws -> String
}
