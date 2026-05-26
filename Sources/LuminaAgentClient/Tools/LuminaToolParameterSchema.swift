import Foundation

public struct LuminaToolParameterSchema: Codable, Hashable, Sendable {
    public var name: String
    public var type: LuminaToolParameterType
    public var description: String
    public var required: Bool
    public var sensitive: Bool

    public init(
        name: String,
        type: LuminaToolParameterType,
        description: String,
        required: Bool = true,
        sensitive: Bool = false
    ) {
        self.name = name
        self.type = type
        self.description = description
        self.required = required
        self.sensitive = sensitive
    }
}
