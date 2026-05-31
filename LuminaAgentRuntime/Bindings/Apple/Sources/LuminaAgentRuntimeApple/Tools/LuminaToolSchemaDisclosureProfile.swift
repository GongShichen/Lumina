import Foundation

public enum LuminaToolSchemaDisclosureProfile: String, Codable, Hashable, Sendable {
    case full
    case compact
    case nameOnly = "name-only"
}
