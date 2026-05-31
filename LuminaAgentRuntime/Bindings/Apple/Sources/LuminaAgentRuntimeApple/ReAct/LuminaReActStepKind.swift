import Foundation

public enum LuminaReActStepKind: String, Codable, Hashable, Sendable {
    case thought
    case action
    case observation
    case result
}
