import Foundation
import PersonalMemory

#if canImport(CoreML)
import CoreML

public final class LuminaBGECoreMLEmbeddingProvider: LuminaEmbeddingProvider, @unchecked Sendable {
    public struct Configuration: Sendable {
        public var modelURL: URL
        public var tokenizerURL: URL
        public var inputIDsName: String
        public var attentionMaskName: String
        public var embeddingOutputName: String
        public var dimension: Int
        public var sequenceLength: Int
        public var computeUnits: MLComputeUnits
        public var normalizeOutput: Bool

        public init(
            modelURL: URL,
            tokenizerURL: URL,
            inputIDsName: String = "input_ids",
            attentionMaskName: String = "attention_mask",
            embeddingOutputName: String = "pooler_output",
            dimension: Int = 512,
            sequenceLength: Int = 512,
            computeUnits: MLComputeUnits = .cpuAndNeuralEngine,
            normalizeOutput: Bool = true
        ) {
            self.modelURL = modelURL
            self.tokenizerURL = tokenizerURL
            self.inputIDsName = inputIDsName
            self.attentionMaskName = attentionMaskName
            self.embeddingOutputName = embeddingOutputName
            self.dimension = dimension
            self.sequenceLength = sequenceLength
            self.computeUnits = computeUnits
            self.normalizeOutput = normalizeOutput
        }
    }

    public let dimension: Int
    private let configuration: Configuration
    private let model: MLModel
    private let tokenizer: LuminaBGEWordPieceTokenizer

    public init(configuration: Configuration) throws {
        guard FileManager.default.fileExists(atPath: configuration.tokenizerURL.path) else {
            throw LuminaCoreMLEmbeddingError.tokenizerNotFound(configuration.tokenizerURL)
        }

        self.configuration = configuration
        self.dimension = configuration.dimension
        self.tokenizer = try LuminaBGEWordPieceTokenizer(tokenizerURL: configuration.tokenizerURL)

        let mlConfiguration = LuminaCoreMLModelConfigurationFactory.make(
            computeUnits: configuration.computeUnits
        )
        self.model = try MLModel(contentsOf: configuration.modelURL, configuration: mlConfiguration)
    }

    public func embed(_ text: String) async throws -> [Float] {
        try Task.checkCancellation()
        let encoded = tokenizer.encode(text, maxLength: configuration.sequenceLength)
        let inputIDs = try LuminaBGECoreMLEmbeddingProvider.multiArray(encoded.inputIDs)
        let attentionMask = try LuminaBGECoreMLEmbeddingProvider.multiArray(encoded.attentionMask)

        let input = try MLDictionaryFeatureProvider(dictionary: [
            configuration.inputIDsName: MLFeatureValue(multiArray: inputIDs),
            configuration.attentionMaskName: MLFeatureValue(multiArray: attentionMask)
        ])
        let output = try await model.prediction(from: input, options: MLPredictionOptions())
        guard let array = output.featureValue(for: configuration.embeddingOutputName)?.multiArrayValue else {
            throw LuminaCoreMLEmbeddingError.missingEmbeddingOutput(configuration.embeddingOutputName)
        }

        var values = Self.floatValues(from: array)
        if values.count != configuration.dimension {
            throw LuminaCoreMLEmbeddingError.dimensionMismatch(expected: configuration.dimension, actual: values.count)
        }
        if configuration.normalizeOutput {
            values = LuminaVectorMath.normalized(values)
        }
        return values
    }

    private static func multiArray(_ values: [Int32]) throws -> MLMultiArray {
        let array = try MLMultiArray(shape: [1, NSNumber(value: values.count)], dataType: .int32)
        let pointer = array.dataPointer.bindMemory(to: Int32.self, capacity: values.count)
        for (index, value) in values.enumerated() {
            pointer[index] = value
        }
        return array
    }

    private static func floatValues(from array: MLMultiArray) -> [Float] {
        switch array.dataType {
        case .float32:
            let pointer = array.dataPointer.bindMemory(to: Float.self, capacity: array.count)
            return Array(UnsafeBufferPointer(start: pointer, count: array.count))
        case .float16:
            let pointer = array.dataPointer.bindMemory(to: Float16.self, capacity: array.count)
            return UnsafeBufferPointer(start: pointer, count: array.count).map(Float.init)
        default:
            return (0..<array.count).map { Float(truncating: array[$0]) }
        }
    }
}

#endif
