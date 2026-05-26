import AgentRuntime
import Foundation

#if canImport(CoreML)
import CoreML

public final class LuminaCoreMLJSONStepModel: LuminaLocalStructuredInferenceModel, @unchecked Sendable {
    public struct Configuration: Sendable {
        public var modelURL: URL
        public var promptInputName: String
        public var jsonOutputName: String
        public var computeUnits: MLComputeUnits

        public init(
            modelURL: URL,
            promptInputName: String = "prompt",
            jsonOutputName: String = "json",
            computeUnits: MLComputeUnits = .cpuAndNeuralEngine
        ) {
            self.modelURL = modelURL
            self.promptInputName = promptInputName
            self.jsonOutputName = jsonOutputName
            self.computeUnits = computeUnits
        }
    }

    private let configuration: Configuration
    private let model: MLModel

    public init(configuration: Configuration) throws {
        self.configuration = configuration
        let mlConfiguration = LuminaCoreMLModelConfigurationFactory.make(
            computeUnits: configuration.computeUnits
        )
        self.model = try MLModel(contentsOf: configuration.modelURL, configuration: mlConfiguration)
    }

    public func generateJSON(prompt: String) async throws -> String {
        try Task.checkCancellation()
        let input = try MLDictionaryFeatureProvider(dictionary: [
            configuration.promptInputName: MLFeatureValue(string: prompt)
        ])
        let output = try await model.prediction(from: input, options: MLPredictionOptions())
        guard let value = output.featureValue(for: configuration.jsonOutputName)?.stringValue else {
            throw LuminaCoreMLStepModelError.missingStringOutput(configuration.jsonOutputName)
        }
        return value
    }
}

#endif
