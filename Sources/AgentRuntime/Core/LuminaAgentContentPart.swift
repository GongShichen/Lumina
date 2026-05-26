import Foundation

public enum LuminaAgentContentPart: Codable, Hashable, Identifiable, Sendable {
    case text(id: UUID, String)
    case markdown(id: UUID, String)
    case image(LuminaAgentMediaAsset)
    case audio(LuminaAgentMediaAsset)
    case video(LuminaAgentMediaAsset)
    case file(LuminaAgentMediaAsset)
    case structuredData(id: UUID, LuminaJSONValue)

    public var id: UUID {
        switch self {
        case let .text(id, _), let .markdown(id, _):
            return id
        case let .image(asset), let .audio(asset), let .video(asset), let .file(asset):
            return asset.id
        case let .structuredData(id, _):
            return id
        }
    }

    public var modality: LuminaAgentModality {
        switch self {
        case .text, .markdown:
            return .text
        case .image:
            return .image
        case .audio:
            return .audio
        case .video:
            return .video
        case .file:
            return .file
        case .structuredData:
            return .structuredData
        }
    }

    public static func text(_ value: String, id: UUID = UUID()) -> LuminaAgentContentPart {
        .text(id: id, value)
    }

    public static func markdown(_ value: String, id: UUID = UUID()) -> LuminaAgentContentPart {
        .markdown(id: id, value)
    }

    public static func json(_ value: LuminaJSONValue, id: UUID = UUID()) -> LuminaAgentContentPart {
        .structuredData(id: id, value)
    }

    public var textForModelInput: String? {
        switch self {
        case let .text(_, value), let .markdown(_, value):
            return value
        case let .image(asset):
            return asset.summary.map { "[image: \($0)]" }
        case let .audio(asset):
            return asset.transcript ?? asset.summary.map { "[audio: \($0)]" }
        case let .video(asset):
            return asset.transcript ?? asset.summary.map { "[video: \($0)]" }
        case let .file(asset):
            return asset.summary.map { "[file: \($0)]" }
        case let .structuredData(_, value):
            return "[structuredData: \(value)]"
        }
    }

    private enum CodingKeys: String, CodingKey {
        case modality
        case id
        case text
        case format
        case asset
        case value
    }

    private enum TextFormat: String, Codable {
        case plain
        case markdown
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let modality = try container.decode(LuminaAgentModality.self, forKey: .modality)
        switch modality {
        case .text:
            let id = try container.decode(UUID.self, forKey: .id)
            let text = try container.decode(String.self, forKey: .text)
            let format = try container.decodeIfPresent(TextFormat.self, forKey: .format) ?? .plain
            self = format == .markdown ? .markdown(id: id, text) : .text(id: id, text)
        case .image:
            self = .image(try container.decode(LuminaAgentMediaAsset.self, forKey: .asset))
        case .audio:
            self = .audio(try container.decode(LuminaAgentMediaAsset.self, forKey: .asset))
        case .video:
            self = .video(try container.decode(LuminaAgentMediaAsset.self, forKey: .asset))
        case .file:
            self = .file(try container.decode(LuminaAgentMediaAsset.self, forKey: .asset))
        case .structuredData:
            self = .structuredData(
                id: try container.decode(UUID.self, forKey: .id),
                try container.decode(LuminaJSONValue.self, forKey: .value)
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(modality, forKey: .modality)
        switch self {
        case let .text(id, value):
            try container.encode(id, forKey: .id)
            try container.encode(value, forKey: .text)
            try container.encode(TextFormat.plain, forKey: .format)
        case let .markdown(id, value):
            try container.encode(id, forKey: .id)
            try container.encode(value, forKey: .text)
            try container.encode(TextFormat.markdown, forKey: .format)
        case let .image(asset), let .audio(asset), let .video(asset), let .file(asset):
            try container.encode(asset, forKey: .asset)
        case let .structuredData(id, value):
            try container.encode(id, forKey: .id)
            try container.encode(value, forKey: .value)
        }
    }
}
