import Foundation

public enum LuminaAgentRuntimeHookDirective: Sendable {
    case appendContextSection(LuminaRuntimeContextSection)
    case mergeRequestMetadata([String: LuminaJSONValue])
    case terminate(markdown: String, reason: String)
    case annotate(key: String, value: LuminaJSONValue)
}
