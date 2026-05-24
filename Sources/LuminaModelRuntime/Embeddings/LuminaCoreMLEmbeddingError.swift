import Foundation
import PersonalMemory

#if canImport(CoreML)
import CoreML

public enum LuminaCoreMLEmbeddingError: LocalizedError {
    case missingEmbeddingOutput(String)
    case dimensionMismatch(expected: Int, actual: Int)
    case invalidTokenizer(String)
    case tokenizerNotFound(URL)

    public var errorDescription: String? {
        switch self {
        case let .missingEmbeddingOutput(name):
            return "Core ML embedding output '\(name)' was missing or was not an MLMultiArray."
        case let .dimensionMismatch(expected, actual):
            return "Core ML embedding dimension mismatch. Expected \(expected), got \(actual)."
        case let .invalidTokenizer(reason):
            return "BGE tokenizer is invalid: \(reason)"
        case let .tokenizerNotFound(url):
            return "BGE tokenizer was not found at \(url.path)."
        }
    }
}

#endif
