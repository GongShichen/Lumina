import Foundation

public protocol LuminaLocalMultimodalStructuredInferenceModel: Sendable {
    func generateJSON(input: LuminaStructuredPlannerModelInput) async throws -> String
}
