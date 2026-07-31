import Foundation
import PersonalMemory

#if canImport(CoreML)
import CoreML

public final class LuminaCoreMLEmbeddingProvider: LuminaEmbeddingProvider, @unchecked Sendable {
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
            computeUnits: MLComputeUnits = .cpuAndNeuralEngine,
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
        let mlConfiguration = LuminaCoreMLModelConfigurationFactory.make(
            computeUnits: configuration.computeUnits
        )
        self.model = try MLModel(contentsOf: configuration.modelURL, configuration: mlConfiguration)
    }

    public func embed(_ text: String) async throws -> [Float] {
        try Task.checkCancellation()
        let input = try MLDictionaryFeatureProvider(dictionary: [
            configuration.textInputName: MLFeatureValue(string: text)
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

    private static func floatValues(from array: MLMultiArray) -> [Float] {
        switch array.dataType {
        case .float32:
            let pointer = array.dataPointer.bindMemory(to: Float.self, capacity: array.count)
            return Array(UnsafeBufferPointer(start: pointer, count: array.count))
        case .float16:
            let pointer = array.dataPointer.bindMemory(to: UInt16.self, capacity: array.count)
            return UnsafeBufferPointer(start: pointer, count: array.count).map(halfPrecisionFloat)
        default:
            return (0..<array.count).map { Float(truncating: array[$0]) }
        }
    }

    private static func halfPrecisionFloat(_ bits: UInt16) -> Float {
        let sign = UInt32(bits & 0x8000) << 16
        let exponent = UInt32((bits >> 10) & 0x001f)
        var mantissa = UInt32(bits & 0x03ff)
        let floatBits: UInt32
        switch exponent {
        case 0 where mantissa == 0:
            floatBits = sign
        case 0:
            var normalizedExponent: Int32 = -14
            while mantissa & 0x0400 == 0 {
                mantissa <<= 1
                normalizedExponent -= 1
            }
            mantissa &= 0x03ff
            floatBits = sign
                | (UInt32(normalizedExponent + 127) << 23)
                | (mantissa << 13)
        case 0x1f:
            floatBits = sign | 0x7f80_0000 | (mantissa << 13)
        default:
            floatBits = sign | ((exponent + 112) << 23) | (mantissa << 13)
        }
        return Float(bitPattern: floatBits)
    }
}

#endif
