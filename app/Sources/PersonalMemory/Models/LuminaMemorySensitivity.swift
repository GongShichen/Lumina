import Foundation

public enum LuminaMemorySensitivity: String, Codable, Comparable, Sendable {
    case low
    case normal
    case sensitive
    case privateData

    public static func < (lhs: LuminaMemorySensitivity, rhs: LuminaMemorySensitivity) -> Bool {
        lhs.rank < rhs.rank
    }

    private var rank: Int {
        switch self {
        case .low: 0
        case .normal: 1
        case .sensitive: 2
        case .privateData: 3
        }
    }
}
