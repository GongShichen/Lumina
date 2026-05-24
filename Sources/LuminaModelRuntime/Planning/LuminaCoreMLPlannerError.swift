import AgentRuntime
import Foundation

#if canImport(CoreML)
import CoreML

public enum LuminaCoreMLPlannerError: LocalizedError {
    case missingStringOutput(String)

    public var errorDescription: String? {
        switch self {
        case let .missingStringOutput(name):
            return "Core ML planner output '\(name)' was missing or was not a String."
        }
    }
}

#endif
