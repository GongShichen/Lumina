import Foundation

public struct LuminaReActPlannerContext: Sendable {
    public var request: LuminaAgentRequest
    public var availableTools: [LuminaToolSchema]
    public var trace: LuminaReActTrace
    public var loadedContext: LuminaRuntimeContext
    public var iteration: Int
    public var remainingToolCalls: Int
    public var maximumObservationCharacters: Int

    public init(
        request: LuminaAgentRequest,
        availableTools: [LuminaToolSchema],
        trace: LuminaReActTrace,
        loadedContext: LuminaRuntimeContext = .empty,
        iteration: Int,
        remainingToolCalls: Int,
        maximumObservationCharacters: Int
    ) {
        self.request = request
        self.availableTools = availableTools
        self.trace = trace
        self.loadedContext = loadedContext
        self.iteration = iteration
        self.remainingToolCalls = remainingToolCalls
        self.maximumObservationCharacters = maximumObservationCharacters
    }
}
