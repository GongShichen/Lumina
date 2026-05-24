import Foundation

public enum LuminaAgentMediaLocation: Codable, Hashable, Sendable {
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
