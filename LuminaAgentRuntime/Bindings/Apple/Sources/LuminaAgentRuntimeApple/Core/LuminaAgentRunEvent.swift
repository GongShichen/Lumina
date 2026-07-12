import Foundation

public enum LuminaAgentRunEvent: Sendable {
    case stepGenerationStarted(UUID)
    case stepGenerationProgress(LuminaStepGenerationProgress)
    case thoughtGenerated(LuminaReActStep)
    case actionProposed(LuminaToolCall)
    case multiActionProposed([LuminaToolCall])
    case observationCreated(LuminaReActObservation)
    case resultGenerated(String)
    case hookAnnotated(String, LuminaJSONValue)
    case contextUpdated(LuminaRuntimeContext)
    case permissionChecked(LuminaToolCall, LuminaPermissionDecision)
    case confirmationRequired(LuminaToolCall)
    case confirmationResolved(LuminaToolCall, Bool)
    case toolStarted(LuminaToolCall)
    case toolFinished(LuminaToolResult)
    case rollbackStarted(LuminaToolCall)
    case rollbackFinished(LuminaToolCall, Bool)
    case finished(LuminaAgentRunResult)
}
