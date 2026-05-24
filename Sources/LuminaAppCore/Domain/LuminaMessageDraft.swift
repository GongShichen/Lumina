import Foundation

public struct LuminaMessageDraft: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var recipients: [String]
    public var body: String

    public init(id: UUID = UUID(), recipients: [String], body: String) {
        self.id = id
        self.recipients = recipients
        self.body = body
    }
}
