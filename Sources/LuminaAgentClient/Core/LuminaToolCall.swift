import Foundation

public struct LuminaToolCall: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var toolName: String
    public var arguments: [String: LuminaJSONValue]
    public var requiresConfirmation: Bool

    public init(
        id: UUID = UUID(),
        toolName: String,
        arguments: [String: LuminaJSONValue],
        requiresConfirmation: Bool = false
    ) {
        self.id = id
        self.toolName = toolName
        self.arguments = arguments
        self.requiresConfirmation = requiresConfirmation
    }
}
