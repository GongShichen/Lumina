import Foundation

enum LuminaAgentActivityState: String, Sendable {
    case idle
    case running
    case waitingForConfirmation
    case succeeded
    case failed
    case cancelled
}
