import Foundation

public enum LuminaAgentRunStatus: String, Codable, Sendable {
    case succeeded
    case partiallySucceeded
    case failed
    case cancelled
}
