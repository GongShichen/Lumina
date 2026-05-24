import Foundation

public enum LuminaReActParserError: LocalizedError {
    case invalidAction
    case invalidSchema(String)
    case invalidStepType(String)

    public var errorDescription: String? {
        switch self {
        case .invalidAction:
            "ReAct tool_use must reference an available structured tool."
        case let .invalidSchema(message):
            "Invalid ReAct JSON schema: \(message)."
        case let .invalidStepType(type):
            "Unsupported ReAct step type: \(type)."
        }
    }
}
