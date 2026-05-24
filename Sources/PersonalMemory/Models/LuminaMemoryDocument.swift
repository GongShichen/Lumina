import Foundation

public struct LuminaMemoryDocument: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var source: LuminaMemorySource
    public var title: String
    public var body: String
    public var createdAt: Date
    public var updatedAt: Date
    public var sensitivity: LuminaMemorySensitivity
    public var metadata: [String: String]

    public init(
        id: UUID = UUID(),
        source: LuminaMemorySource,
        title: String,
        body: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        sensitivity: LuminaMemorySensitivity = .normal,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.source = source
        self.title = title
        self.body = body
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.sensitivity = sensitivity
        self.metadata = metadata
    }
}
