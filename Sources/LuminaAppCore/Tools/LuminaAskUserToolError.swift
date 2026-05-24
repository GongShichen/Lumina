import Foundation

public enum LuminaAskUserToolError: LocalizedError, Sendable {
    case invalidArguments(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidArguments(message):
            message
        }
    }
}
