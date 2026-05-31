import Foundation

public enum LuminaAgentRuntimeHookDirective: Sendable {
    case proceed
    case appendContextSection(LuminaRuntimeContextSection)
    case mergeRequestMetadata([String: LuminaJSONValue])
    case rewriteToolCall(LuminaToolCall)
    case rejectToolCall(reason: String)
    case requireConfirmation(reason: String)
    case pause(kind: String, payload: LuminaJSONValue, reason: String)
    case fail(markdown: String, reason: String)
    case terminate(markdown: String, reason: String)
    case annotate(key: String, value: LuminaJSONValue)
}
