import LuminaAgentClient
import Foundation

#if canImport(CoreML)
import CoreML

public enum LuminaCoreMLStepModelError: LocalizedError {
    case missingStringOutput(String)

    public var errorDescription: String? {
        switch self {
        case let .missingStringOutput(name):
            return "Core ML model output '\(name)' was missing or was not a String."
        }
    }
}

#endif
