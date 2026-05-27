import Foundation

public enum LuminaAgentModality: String, Codable, Hashable, Sendable {
    case text
    case image
    case audio
    case video
    case file
    case structuredData
}
