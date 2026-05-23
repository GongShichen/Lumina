import Foundation

#if canImport(CoreML)
import CoreML

public final class CoreMLEmbeddingProvider: EmbeddingProvider, @unchecked Sendable {
    public struct Configuration: Sendable {
        public var modelURL: URL
        public var textInputName: String
        public var embeddingOutputName: String
        public var dimension: Int
        public var computeUnits: MLComputeUnits
        public var normalizeOutput: Bool

        public init(
            modelURL: URL,
            textInputName: String = "text",
            embeddingOutputName: String = "embedding",
            dimension: Int,
            computeUnits: MLComputeUnits = .all,
            normalizeOutput: Bool = true
        ) {
            self.modelURL = modelURL
            self.textInputName = textInputName
            self.embeddingOutputName = embeddingOutputName
            self.dimension = dimension
            self.computeUnits = computeUnits
            self.normalizeOutput = normalizeOutput
        }
    }

    public let dimension: Int
    private let configuration: Configuration
    private let model: MLModel

    public init(configuration: Configuration) throws {
        self.configuration = configuration
        self.dimension = configuration.dimension
        let mlConfiguration = MLModelConfiguration()
        mlConfiguration.computeUnits = configuration.computeUnits
        self.model = try MLModel(contentsOf: configuration.modelURL, configuration: mlConfiguration)
    }

    public func embed(_ text: String) async throws -> [Float] {
        try Task.checkCancellation()
        let input = try MLDictionaryFeatureProvider(dictionary: [
            configuration.textInputName: MLFeatureValue(string: text)
        ])
        let output = try await model.prediction(from: input, options: MLPredictionOptions())
        guard let array = output.featureValue(for: configuration.embeddingOutputName)?.multiArrayValue else {
            throw CoreMLEmbeddingError.missingEmbeddingOutput(configuration.embeddingOutputName)
        }

        var values = (0..<array.count).map { Float(truncating: array[$0]) }
        if values.count != configuration.dimension {
            throw CoreMLEmbeddingError.dimensionMismatch(expected: configuration.dimension, actual: values.count)
        }
        if configuration.normalizeOutput {
            values = VectorMath.normalized(values)
        }
        return values
    }
}

public enum CoreMLEmbeddingError: LocalizedError {
    case missingEmbeddingOutput(String)
    case dimensionMismatch(expected: Int, actual: Int)

    public var errorDescription: String? {
        switch self {
        case let .missingEmbeddingOutput(name):
            return "Core ML embedding output '\(name)' was missing or was not an MLMultiArray."
        case let .dimensionMismatch(expected, actual):
            return "Core ML embedding dimension mismatch. Expected \(expected), got \(actual)."
        }
    }
}
#endif
