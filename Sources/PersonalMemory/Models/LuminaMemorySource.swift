import Foundation

public struct LuminaMemorySource: Codable, Hashable, Sendable {
    public var kind: LuminaMemorySourceKind
    public var identifier: String

    public init(kind: LuminaMemorySourceKind, identifier: String) {
        self.kind = kind
        self.identifier = identifier
    }
}
