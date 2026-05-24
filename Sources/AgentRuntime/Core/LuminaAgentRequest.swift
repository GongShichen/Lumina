import Foundation

public struct LuminaAgentRequest: Codable, Hashable, Sendable {
    public var id: UUID
    public var text: String
    public var content: [LuminaAgentContentPart]
    public var localeIdentifier: String
    public var metadata: [String: LuminaJSONValue]

    public init(
        id: UUID = UUID(),
        text: String,
        localeIdentifier: String = Locale.current.identifier,
        metadata: [String: LuminaJSONValue] = [:]
    ) {
        self.id = id
        self.text = text
        self.content = [.text(text)]
        self.localeIdentifier = localeIdentifier
        self.metadata = metadata
    }

    public init(
        id: UUID = UUID(),
        content: [LuminaAgentContentPart],
        localeIdentifier: String = Locale.current.identifier,
        metadata: [String: LuminaJSONValue] = [:]
    ) {
        self.id = id
        self.content = content
        self.text = content.textForPlanning
        self.localeIdentifier = localeIdentifier
        self.metadata = metadata
    }
}
