import Foundation

public struct LuminaReActCompactionRequest: Sendable {
    public var agentRequest: LuminaAgentRequest
    public var trace: LuminaReActTrace
    public var loadedContext: LuminaRuntimeContext
    public var availableTools: [LuminaToolSchema]
    public var estimatedCharacters: Int
    public var characterBudget: Int
    public var preservedStepCount: Int
    public var maximumSummaryCharacters: Int

    public init(
        agentRequest: LuminaAgentRequest,
        trace: LuminaReActTrace,
        loadedContext: LuminaRuntimeContext,
        availableTools: [LuminaToolSchema],
        estimatedCharacters: Int,
        characterBudget: Int,
        preservedStepCount: Int,
        maximumSummaryCharacters: Int
    ) {
        self.agentRequest = agentRequest
        self.trace = trace
        self.loadedContext = loadedContext
        self.availableTools = availableTools
        self.estimatedCharacters = estimatedCharacters
        self.characterBudget = characterBudget
        self.preservedStepCount = preservedStepCount
        self.maximumSummaryCharacters = maximumSummaryCharacters
    }
}
