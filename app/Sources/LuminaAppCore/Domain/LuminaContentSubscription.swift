import Foundation

public struct LuminaContentSubscription: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var source: String
    public var createdAt: Date

    public init(id: UUID = UUID(), source: String, createdAt: Date = Date()) {
        self.id = id
        self.source = source
        self.createdAt = createdAt
    }
}
