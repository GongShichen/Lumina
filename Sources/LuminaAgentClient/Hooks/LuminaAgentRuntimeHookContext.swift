import Foundation

public struct LuminaAgentRuntimeHookContext: Sendable {
    public var request: LuminaAgentRequest
    public var availableTools: [LuminaToolSchema]
    public var trace: LuminaReActTrace
    public var loadedContext: LuminaRuntimeContext
    public var stepContext: LuminaReActStepContext?
    public var step: LuminaReActStep?
    public var toolCall: LuminaToolCall?
    public var toolResult: LuminaToolResult?
    public var observation: LuminaReActObservation?
    public var finalMarkdown: String?
    public var timing: LuminaRuntimeTiming?
    public var errorMessage: String?

    public init(
        request: LuminaAgentRequest,
        availableTools: [LuminaToolSchema] = [],
        trace: LuminaReActTrace = LuminaReActTrace(),
        loadedContext: LuminaRuntimeContext = .empty,
        stepContext: LuminaReActStepContext? = nil,
        step: LuminaReActStep? = nil,
        toolCall: LuminaToolCall? = nil,
        toolResult: LuminaToolResult? = nil,
        observation: LuminaReActObservation? = nil,
        finalMarkdown: String? = nil,
        timing: LuminaRuntimeTiming? = nil,
        errorMessage: String? = nil
    ) {
        self.request = request
        self.availableTools = availableTools
        self.trace = trace
        self.loadedContext = loadedContext
        self.stepContext = stepContext
        self.step = step
        self.toolCall = toolCall
        self.toolResult = toolResult
        self.observation = observation
        self.finalMarkdown = finalMarkdown
        self.timing = timing
        self.errorMessage = errorMessage
    }
}
