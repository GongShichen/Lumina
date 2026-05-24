import Foundation

public enum LuminaMemorySourceKind: String, Codable, Sendable {
    case appNote
    case calendar
    case reminder
    case ledger
    case subscription
    case imported
}
