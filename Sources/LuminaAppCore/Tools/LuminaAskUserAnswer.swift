import Foundation

public struct LuminaAskUserAnswer: Codable, Hashable, Sendable {
    public var questionID: String
    public var choiceID: String?
    public var value: String
    public var isCustom: Bool

    public init(questionID: String, choiceID: String? = nil, value: String, isCustom: Bool = false) {
        self.questionID = questionID
        self.choiceID = choiceID
        self.value = value
        self.isCustom = isCustom
    }
}
