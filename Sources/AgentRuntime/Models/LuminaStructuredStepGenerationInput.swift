import Foundation

public struct LuminaStructuredStepGenerationInput: Sendable {
    public var prompt: String
    public var content: [LuminaAgentContentPart]
    public var availableTools: [LuminaToolSchema]
    public var maxOutputTokensHint: Int?

    public init(
        prompt: String,
        content: [LuminaAgentContentPart],
        availableTools: [LuminaToolSchema],
        maxOutputTokensHint: Int? = nil
    ) {
        self.prompt = prompt
        self.content = content
        self.availableTools = availableTools
        self.maxOutputTokensHint = maxOutputTokensHint
    }
}
