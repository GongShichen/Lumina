import Foundation

public enum LuminaReActStepKind: String, Codable, Hashable, Sendable {
    case thought
    case action
    case multiAction
    case observation
    case result
}
