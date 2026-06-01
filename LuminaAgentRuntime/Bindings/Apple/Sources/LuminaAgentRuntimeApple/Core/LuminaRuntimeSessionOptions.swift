import Foundation

public enum LuminaRuntimeCheckpointPolicy: String, Codable, Hashable, Sendable {
    case none
    case onPause
    case onStep
    case onExit
}
