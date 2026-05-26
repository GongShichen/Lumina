import Foundation

public struct LuminaTextOnlyStructuredModelAdapter: LuminaLocalStreamingMultimodalStructuredInferenceModel {
    private let model: any LuminaLocalStructuredInferenceModel

    public init(_ model: any LuminaLocalStructuredInferenceModel) {
        self.model = model
    }

    public func generateJSON(input: LuminaStructuredStepGenerationInput) async throws -> String {
        if let dynamic = model as? any LuminaLocalDynamicOutputStructuredInferenceModel {
            return try await dynamic.generateJSON(prompt: input.prompt, maxOutputTokens: input.maxOutputTokensHint)
        }
        return try await model.generateJSON(prompt: input.prompt)
    }

    public func generateJSON(
        input: LuminaStructuredStepGenerationInput,
        progress: @escaping @Sendable (LuminaStructuredInferenceProgress) -> Void
    ) async throws -> String {
        if let dynamicStreaming = model as? any LuminaLocalDynamicOutputStreamingStructuredInferenceModel {
            return try await dynamicStreaming.generateJSON(
                prompt: input.prompt,
                maxOutputTokens: input.maxOutputTokensHint,
                progress: progress
            )
        }
        if let dynamic = model as? any LuminaLocalDynamicOutputStructuredInferenceModel {
            return try await dynamic.generateJSON(prompt: input.prompt, maxOutputTokens: input.maxOutputTokensHint)
        }
        if let streaming = model as? any LuminaLocalStreamingStructuredInferenceModel {
            return try await streaming.generateJSON(prompt: input.prompt, progress: progress)
        }
        return try await model.generateJSON(prompt: input.prompt)
    }
}
