import Foundation

public struct LuminaAskUserQuestion: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var header: String
    public var question: String
    public var options: [LuminaAskUserChoice]
    public var allowsCustomAnswer: Bool

    public init(
        id: String,
        header: String,
        question: String,
        options: [LuminaAskUserChoice],
        allowsCustomAnswer: Bool = true
    ) {
        self.id = id
        self.header = header
        self.question = question
        self.options = Array(options.prefix(3))
        self.allowsCustomAnswer = allowsCustomAnswer
    }
}
