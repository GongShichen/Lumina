import Foundation

public struct LuminaReActStepContext: Sendable {
    public var request: LuminaAgentRequest
    public var availableTools: [LuminaToolSchema]
    public var trace: LuminaReActTrace
    public var loadedContext: LuminaRuntimeContext
    public var iteration: Int
    public var remainingToolCalls: Int
    public var maximumObservationCharacters: Int
    public var progressSink: (@Sendable (LuminaStepGenerationProgress) -> Void)?

    public init(
        request: LuminaAgentRequest,
        availableTools: [LuminaToolSchema],
        trace: LuminaReActTrace,
        loadedContext: LuminaRuntimeContext = .empty,
        iteration: Int,
        remainingToolCalls: Int,
        maximumObservationCharacters: Int,
        progressSink: (@Sendable (LuminaStepGenerationProgress) -> Void)? = nil
    ) {
        self.request = request
        self.availableTools = availableTools
        self.trace = trace
        self.loadedContext = loadedContext
        self.iteration = iteration
        self.remainingToolCalls = remainingToolCalls
        self.maximumObservationCharacters = maximumObservationCharacters
        self.progressSink = progressSink
    }
}
