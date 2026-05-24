import Foundation

public struct LuminaAskUserRequest: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var questions: [LuminaAskUserQuestion]
    public var reason: String
    public var sensitivity: String
    public var timeoutSeconds: TimeInterval?

    public init(
        id: UUID = UUID(),
        questions: [LuminaAskUserQuestion],
        reason: String,
        sensitivity: String = "normal",
        timeoutSeconds: TimeInterval? = nil
    ) {
        self.id = id
        self.questions = Array(questions.prefix(3))
        self.reason = reason
        self.sensitivity = sensitivity
        self.timeoutSeconds = timeoutSeconds
    }
}
