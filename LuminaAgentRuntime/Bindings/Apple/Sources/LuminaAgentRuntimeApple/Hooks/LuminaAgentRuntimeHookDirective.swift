import Foundation

public enum LuminaAgentRuntimeHookDirective: Sendable {
    case proceed
    case appendContextSection(LuminaRuntimeContextSection)
    case mergeRequestMetadata([String: LuminaJSONValue])
    case rewriteToolCall(LuminaToolCall)
    case rejectToolCall(reason: String)
    /// Rejects before execution and supplies model-visible correction details.
    case rejectToolCallForValidation(reason: String, failure: [String: LuminaJSONValue])
    case requireConfirmation(reason: String)
    case pause(kind: String, payload: LuminaJSONValue, reason: String)
    case fail(markdown: String, reason: String)
    case terminate(markdown: String, reason: String)
    case annotate(key: String, value: LuminaJSONValue)
}
