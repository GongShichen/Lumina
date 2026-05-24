import Foundation

public struct LuminaAskUserChoice: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var label: String
    public var description: String
    public var recommended: Bool

    public init(id: String, label: String, description: String, recommended: Bool = false) {
        self.id = id
        self.label = label
        self.description = description
        self.recommended = recommended
    }
}
