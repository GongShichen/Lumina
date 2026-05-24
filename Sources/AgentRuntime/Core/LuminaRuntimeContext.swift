import Foundation

public struct LuminaRuntimeContext: Codable, Hashable, Sendable {
    public var sections: [LuminaRuntimeContextSection]

    public init(sections: [LuminaRuntimeContextSection] = []) {
        self.sections = sections
    }

    public static let empty = LuminaRuntimeContext()
}
