import Foundation

public struct LuminaAgentRuntimeHookMatcher: Sendable {
    public var events: Set<LuminaAgentRuntimeHookEvent>
    public var toolNamePatterns: [String]
    public var sensitivities: Set<LuminaToolSensitivity>
    public var sideEffects: Set<LuminaToolSideEffect>

    public init(
        events: Set<LuminaAgentRuntimeHookEvent> = [],
        toolNamePatterns: [String] = [],
        sensitivities: Set<LuminaToolSensitivity> = [],
        sideEffects: Set<LuminaToolSideEffect> = []
    ) {
        self.events = events
        self.toolNamePatterns = toolNamePatterns
        self.sensitivities = sensitivities
        self.sideEffects = sideEffects
    }

    public static let any = LuminaAgentRuntimeHookMatcher()

    public func matches(event: LuminaAgentRuntimeHookEvent, context: LuminaAgentRuntimeHookContext) -> Bool {
        if !events.isEmpty && !events.contains(event) {
            return false
        }
        if !toolNamePatterns.isEmpty {
            guard let toolName = context.toolCall?.toolName ?? context.toolResult?.toolName else {
                return false
            }
            if !toolNamePatterns.contains(where: { Self.matchesPattern($0, value: toolName) }) {
                return false
            }
        }
        if !sensitivities.isEmpty || !sideEffects.isEmpty {
            guard let toolName = context.toolCall?.toolName ?? context.toolResult?.toolName,
                  let schema = context.availableTools.first(where: { $0.name == toolName })
            else { return false }
            if !sensitivities.isEmpty && !sensitivities.contains(schema.sensitivity) {
                return false
            }
            if !sideEffects.isEmpty && !sideEffects.contains(schema.sideEffect) {
                return false
            }
        }
        return true
    }

    private static func matchesPattern(_ pattern: String, value: String) -> Bool {
        if pattern == "*" { return true }
        if pattern.hasSuffix("*") {
            return value.hasPrefix(String(pattern.dropLast()))
        }
        return pattern == value
    }
}

public protocol LuminaMatchingAgentRuntimeHook: LuminaAgentRuntimeHook {
    var matcher: LuminaAgentRuntimeHookMatcher { get }
}
