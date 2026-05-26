import Foundation

public struct LuminaRuntimeContextRequest: Sendable {
    public var request: LuminaAgentRequest
    public var availableTools: [LuminaToolSchema]
    public var trace: LuminaReActTrace
    public var iteration: Int
    public var remainingToolCalls: Int
    public var maximumCharacters: Int

    public init(
        request: LuminaAgentRequest,
        availableTools: [LuminaToolSchema],
        trace: LuminaReActTrace,
        iteration: Int,
        remainingToolCalls: Int,
        maximumCharacters: Int
    ) {
        self.request = request
        self.availableTools = availableTools
        self.trace = trace
        self.iteration = iteration
        self.remainingToolCalls = remainingToolCalls
        self.maximumCharacters = maximumCharacters
    }
}
