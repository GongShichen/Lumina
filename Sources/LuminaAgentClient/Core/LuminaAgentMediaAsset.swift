import Foundation

public struct LuminaAgentMediaAsset: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var location: LuminaAgentMediaLocation
    public var mimeType: String
    public var filename: String?
    public var byteCount: Int?
    public var durationSeconds: Double?
    public var width: Int?
    public var height: Int?
    public var transcript: String?
    public var summary: String?
    public var metadata: [String: LuminaJSONValue]

    public init(
        id: UUID = UUID(),
        location: LuminaAgentMediaLocation,
        mimeType: String,
        filename: String? = nil,
        byteCount: Int? = nil,
        durationSeconds: Double? = nil,
        width: Int? = nil,
        height: Int? = nil,
        transcript: String? = nil,
        summary: String? = nil,
        metadata: [String: LuminaJSONValue] = [:]
    ) {
        self.id = id
        self.location = location
        self.mimeType = mimeType
        self.filename = filename
        self.byteCount = byteCount
        self.durationSeconds = durationSeconds
        self.width = width
        self.height = height
        self.transcript = transcript
        self.summary = summary
        self.metadata = metadata
    }
}
