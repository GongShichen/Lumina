import Foundation

public struct LuminaStructuredPlannerModelInput: Sendable {
    public var prompt: String
    public var content: [LuminaAgentContentPart]
    public var availableTools: [LuminaToolSchema]

    public init(prompt: String, content: [LuminaAgentContentPart], availableTools: [LuminaToolSchema]) {
        self.prompt = prompt
        self.content = content
        self.availableTools = availableTools
    }
}
