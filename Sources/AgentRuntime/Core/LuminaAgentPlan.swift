import Foundation

public struct LuminaAgentPlan: Codable, Hashable, Sendable {
    public var id: UUID
    public var summary: String
    public var toolCalls: [LuminaToolCall]

    public init(id: UUID = UUID(), summary: String, toolCalls: [LuminaToolCall]) {
        self.id = id
        self.summary = summary
        self.toolCalls = toolCalls
    }
}
