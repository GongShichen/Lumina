import Foundation

public enum LuminaAgentRunEvent: Sendable {
    case planningStarted(UUID)
    case planCreated(LuminaAgentPlan)
    case thoughtGenerated(LuminaReActStep)
    case actionProposed(LuminaToolCall)
    case observationCreated(LuminaReActObservation)
    case finalGenerated(String)
    case permissionChecked(LuminaToolCall, LuminaPermissionDecision)
    case confirmationRequired(LuminaToolCall)
    case confirmationResolved(LuminaToolCall, Bool)
    case toolStarted(LuminaToolCall)
    case toolFinished(LuminaToolResult)
    case rollbackStarted(LuminaToolCall)
    case rollbackFinished(LuminaToolCall, Bool)
    case finished(LuminaAgentRunResult)
}
