import Foundation

public protocol LuminaLocalStructuredInferenceModel: Sendable {
    func generateJSON(prompt: String) async throws -> String
}
