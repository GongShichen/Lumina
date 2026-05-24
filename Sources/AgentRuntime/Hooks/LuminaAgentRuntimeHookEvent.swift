import Foundation

public enum LuminaAgentRuntimeHookEvent: String, Codable, Hashable, Sendable {
    case runStarted
    case contextLoaded
    case plannerContextReady
    case stepProduced
    case toolWillExecute
    case toolDidExecute
    case observationCreated
    case finalGenerated
    case runEnded
    case cancelled
    case failed
}
