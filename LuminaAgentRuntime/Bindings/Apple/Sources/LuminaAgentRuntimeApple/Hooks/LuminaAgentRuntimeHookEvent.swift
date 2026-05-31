import Foundation

public enum LuminaAgentRuntimeHookEvent: String, Codable, Hashable, Sendable {
    case runStarted
    case sessionStarted
    case contextLoaded
    case contextUpdated
    case stepContextReady
    case beforeModel
    case afterModel
    case beforeNormalization
    case afterNormalization
    case stepProduced
    case beforeTool
    case toolWillExecute
    case toolDidExecute
    case afterTool
    case beforePermission
    case afterPermission
    case beforeConfirmation
    case afterConfirmation
    case beforeCompaction
    case observationCreated
    case resultGenerated
    case runEnded
    case sessionEnded
    case paused
    case cancelled
    case failed
}
