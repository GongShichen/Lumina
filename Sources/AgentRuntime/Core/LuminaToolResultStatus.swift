import Foundation

public enum LuminaToolResultStatus: String, Codable, Sendable {
    case succeeded
    case failed
    case cancelled
    case denied
}
