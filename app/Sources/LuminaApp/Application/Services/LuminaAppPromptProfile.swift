import Foundation

enum LuminaAppPromptProfile: String, Sendable {
    case taskExecution = "task.execution"
    case homePersonalization = "home.personalization"

    static let metadataKey = "lumina.promptProfile"
}
