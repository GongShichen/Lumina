import Foundation

public struct LuminaMemoryChunk: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var documentID: UUID
    public var source: LuminaMemorySource
    public var title: String
    public var text: String
    public var summary: String
    public var createdAt: Date
    public var sensitivity: LuminaMemorySensitivity
    public var metadata: [String: String]
    public var embedding: [Float]?

    public init(
        id: UUID = UUID(),
        documentID: UUID,
        source: LuminaMemorySource,
        title: String,
        text: String,
        summary: String,
        createdAt: Date,
        sensitivity: LuminaMemorySensitivity,
        metadata: [String: String],
        embedding: [Float]? = nil
    ) {
        self.id = id
        self.documentID = documentID
        self.source = source
        self.title = title
        self.text = text
        self.summary = summary
        self.createdAt = createdAt
        self.sensitivity = sensitivity
        self.metadata = metadata
        self.embedding = embedding
    }
}
