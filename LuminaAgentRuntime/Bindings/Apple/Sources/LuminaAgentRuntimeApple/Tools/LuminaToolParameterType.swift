import Foundation

public enum LuminaToolParameterType: String, Codable, Sendable {
    case string
    case number
    case bool
    case dateISO8601
    case object
    case array
}
