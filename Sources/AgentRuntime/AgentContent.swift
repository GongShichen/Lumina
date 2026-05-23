import Foundation

public enum AgentModality: String, Codable, Hashable, Sendable {
    case text
    case image
    case audio
    case video
    case file
    case structuredData
}

public struct AgentMediaAsset: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var location: AgentMediaLocation
    public var mimeType: String
    public var filename: String?
    public var byteCount: Int?
    public var durationSeconds: Double?
    public var width: Int?
    public var height: Int?
    public var transcript: String?
    public var summary: String?
    public var metadata: [String: JSONValue]

    public init(
        id: UUID = UUID(),
        location: AgentMediaLocation,
        mimeType: String,
        filename: String? = nil,
        byteCount: Int? = nil,
        durationSeconds: Double? = nil,
        width: Int? = nil,
        height: Int? = nil,
        transcript: String? = nil,
        summary: String? = nil,
        metadata: [String: JSONValue] = [:]
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

public enum AgentMediaLocation: Codable, Hashable, Sendable {
    case inlineBase64(String)
    case fileURL(String)
    case remoteURL(String)
    case securityScopedBookmarkBase64(String)

    private enum CodingKeys: String, CodingKey {
        case kind
        case value
    }

    private enum Kind: String, Codable {
        case inlineBase64
        case fileURL
        case remoteURL
        case securityScopedBookmarkBase64
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        let value = try container.decode(String.self, forKey: .value)
        switch kind {
        case .inlineBase64:
            self = .inlineBase64(value)
        case .fileURL:
            self = .fileURL(value)
        case .remoteURL:
            self = .remoteURL(value)
        case .securityScopedBookmarkBase64:
            self = .securityScopedBookmarkBase64(value)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .inlineBase64(value):
            try container.encode(Kind.inlineBase64, forKey: .kind)
            try container.encode(value, forKey: .value)
        case let .fileURL(value):
            try container.encode(Kind.fileURL, forKey: .kind)
            try container.encode(value, forKey: .value)
        case let .remoteURL(value):
            try container.encode(Kind.remoteURL, forKey: .kind)
            try container.encode(value, forKey: .value)
        case let .securityScopedBookmarkBase64(value):
            try container.encode(Kind.securityScopedBookmarkBase64, forKey: .kind)
            try container.encode(value, forKey: .value)
        }
    }
}

public enum AgentContentPart: Codable, Hashable, Identifiable, Sendable {
    case text(id: UUID, String)
    case markdown(id: UUID, String)
    case image(AgentMediaAsset)
    case audio(AgentMediaAsset)
    case video(AgentMediaAsset)
    case file(AgentMediaAsset)
    case structuredData(id: UUID, JSONValue)

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

    public var modality: AgentModality {
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

    public static func text(_ value: String, id: UUID = UUID()) -> AgentContentPart {
        .text(id: id, value)
    }

    public static func markdown(_ value: String, id: UUID = UUID()) -> AgentContentPart {
        .markdown(id: id, value)
    }

    public static func json(_ value: JSONValue, id: UUID = UUID()) -> AgentContentPart {
        .structuredData(id: id, value)
    }

    public var textForPlanning: String? {
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
        let modality = try container.decode(AgentModality.self, forKey: .modality)
        switch modality {
        case .text:
            let id = try container.decode(UUID.self, forKey: .id)
            let text = try container.decode(String.self, forKey: .text)
            let format = try container.decodeIfPresent(TextFormat.self, forKey: .format) ?? .plain
            self = format == .markdown ? .markdown(id: id, text) : .text(id: id, text)
        case .image:
            self = .image(try container.decode(AgentMediaAsset.self, forKey: .asset))
        case .audio:
            self = .audio(try container.decode(AgentMediaAsset.self, forKey: .asset))
        case .video:
            self = .video(try container.decode(AgentMediaAsset.self, forKey: .asset))
        case .file:
            self = .file(try container.decode(AgentMediaAsset.self, forKey: .asset))
        case .structuredData:
            self = .structuredData(
                id: try container.decode(UUID.self, forKey: .id),
                try container.decode(JSONValue.self, forKey: .value)
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

public extension Array where Element == AgentContentPart {
    var textForPlanning: String {
        compactMap(\.textForPlanning).joined(separator: "\n")
    }

    var modalities: Set<AgentModality> {
        Set(map(\.modality))
    }
}
