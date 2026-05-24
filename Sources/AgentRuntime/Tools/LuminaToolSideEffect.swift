import Foundation

public enum LuminaToolSideEffect: String, Codable, Sendable {
    case readOnly
    case appLocalWrite
    case systemWrite
    case externalCommunication
}
