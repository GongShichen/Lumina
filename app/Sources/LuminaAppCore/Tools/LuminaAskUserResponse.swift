import Foundation

public struct LuminaAskUserResponse: Codable, Hashable, Sendable {
    public var requestID: UUID
    public var answers: [LuminaAskUserAnswer]
    public var cancelled: Bool
    public var answeredAt: Date

    public init(requestID: UUID, answers: [LuminaAskUserAnswer], cancelled: Bool = false, answeredAt: Date = Date()) {
        self.requestID = requestID
        self.answers = answers
        self.cancelled = cancelled
        self.answeredAt = answeredAt
    }
}
