import Foundation

public enum LuminaAgentRuntimeHookEvent: String, Codable, Hashable, Sendable {
    case runStarted
    case contextLoaded
    case stepContextReady
    case stepProduced
    case toolWillExecute
    case toolDidExecute
    case observationCreated
    case resultGenerated
    case runEnded
    case cancelled
    case failed
}
