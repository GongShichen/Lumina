import Foundation

public struct LuminaAgentRunResult: Codable, Hashable, Sendable {
    public var requestID: UUID
    public var plan: LuminaAgentPlan
    public var toolResults: [LuminaToolResult]
    public var status: LuminaAgentRunStatus
    public var timing: LuminaRuntimeTiming
    public var reactTrace: LuminaReActTrace?

    public init(
        requestID: UUID,
        plan: LuminaAgentPlan,
        toolResults: [LuminaToolResult],
        status: LuminaAgentRunStatus,
        timing: LuminaRuntimeTiming = LuminaRuntimeTiming(),
        reactTrace: LuminaReActTrace? = nil
    ) {
        self.requestID = requestID
        self.plan = plan
        self.toolResults = toolResults
        self.status = status
        self.timing = timing
        self.reactTrace = reactTrace
    }
}
