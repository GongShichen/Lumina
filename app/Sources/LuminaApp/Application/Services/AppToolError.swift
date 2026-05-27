import LuminaAgentRuntime
@preconcurrency import EventKit
import Foundation
import PersonalMemory

enum AppToolError: LocalizedError {
    case permissionDenied(String)
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case let .permissionDenied(message):
            return message
        case let .unavailable(message):
            return message
        }
    }
}
