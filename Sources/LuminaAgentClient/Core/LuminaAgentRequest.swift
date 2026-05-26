import Foundation

public struct LuminaAgentRequest: Codable, Hashable, Sendable {
    public var id: UUID
    public var systemInstructions: String
    public var text: String
    public var content: [LuminaAgentContentPart]
    public var localeIdentifier: String
    public var metadata: [String: LuminaJSONValue]

    public init(
        id: UUID = UUID(),
        systemInstructions: String = "",
        text: String,
        localeIdentifier: String = Locale.current.identifier,
        metadata: [String: LuminaJSONValue] = [:]
    ) {
        self.id = id
        self.systemInstructions = systemInstructions
        self.text = text
        self.content = [.text(text)]
        self.localeIdentifier = localeIdentifier
        self.metadata = metadata
    }

    public init(
        id: UUID = UUID(),
        systemInstructions: String = "",
        content: [LuminaAgentContentPart],
        localeIdentifier: String = Locale.current.identifier,
        metadata: [String: LuminaJSONValue] = [:]
    ) {
        self.id = id
        self.systemInstructions = systemInstructions
        self.content = content
        self.text = content.textForModelInput
        self.localeIdentifier = localeIdentifier
        self.metadata = metadata
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case systemInstructions
        case text
        case content
        case localeIdentifier
        case metadata
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        systemInstructions = try container.decodeIfPresent(String.self, forKey: .systemInstructions) ?? ""
        text = try container.decode(String.self, forKey: .text)
        content = try container.decode([LuminaAgentContentPart].self, forKey: .content)
        localeIdentifier = try container.decodeIfPresent(String.self, forKey: .localeIdentifier) ?? Locale.current.identifier
        metadata = try container.decodeIfPresent([String: LuminaJSONValue].self, forKey: .metadata) ?? [:]
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(systemInstructions, forKey: .systemInstructions)
        try container.encode(text, forKey: .text)
        try container.encode(content, forKey: .content)
        try container.encode(localeIdentifier, forKey: .localeIdentifier)
        try container.encode(metadata, forKey: .metadata)
    }
}
