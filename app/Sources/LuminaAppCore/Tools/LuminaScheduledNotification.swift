import Foundation

public struct LuminaScheduledNotification: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var body: String
    public var fireDate: Date

    public init(
        id: String = UUID().uuidString,
        title: String,
        body: String,
        fireDate: Date
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.fireDate = fireDate
    }
}
