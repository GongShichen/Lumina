import Foundation

public struct LuminaTextOnlyStructuredModelAdapter: LuminaLocalMultimodalStructuredInferenceModel {
    private let model: any LuminaLocalStructuredInferenceModel

    public init(_ model: any LuminaLocalStructuredInferenceModel) {
        self.model = model
    }

    public func generateJSON(input: LuminaStructuredPlannerModelInput) async throws -> String {
        try await model.generateJSON(prompt: input.prompt)
    }
}
