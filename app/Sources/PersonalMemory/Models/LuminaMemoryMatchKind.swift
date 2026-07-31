import Foundation

public enum LuminaMemoryMatchKind: String, Codable, Sendable {
    case vector
    case bm25
    case hybrid
    case keyword
    case metadata
}
