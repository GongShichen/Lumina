import Foundation

public enum LuminaGuardrailDecision<Payload: Sendable>: Sendable {
    case allow
    case reject(message: String)
    case rewrite(Payload)
    case tripwireFailure(message: String)
}

public protocol LuminaInputGuardrail: Sendable {
    func evaluate(request: LuminaAgentRequest) async -> LuminaGuardrailDecision<LuminaAgentRequest>
}

public protocol LuminaToolInputGuardrail: Sendable {
    func evaluate(call: LuminaToolCall, schema: LuminaToolSchema, request: LuminaAgentRequest) async -> LuminaGuardrailDecision<LuminaToolCall>
}

public protocol LuminaToolOutputGuardrail: Sendable {
    func evaluate(result: LuminaToolResult, call: LuminaToolCall, schema: LuminaToolSchema, request: LuminaAgentRequest) async -> LuminaGuardrailDecision<LuminaToolResult>
}

public protocol LuminaResultGuardrail: Sendable {
    func evaluate(markdown: String, request: LuminaAgentRequest) async -> LuminaGuardrailDecision<String>
}

public struct LuminaRuntimeGuardrails: Sendable {
    public var input: [any LuminaInputGuardrail]
    public var toolInput: [any LuminaToolInputGuardrail]
    public var toolOutput: [any LuminaToolOutputGuardrail]
    public var result: [any LuminaResultGuardrail]

    public init(
        input: [any LuminaInputGuardrail] = [],
        toolInput: [any LuminaToolInputGuardrail] = [],
        toolOutput: [any LuminaToolOutputGuardrail] = [],
        result: [any LuminaResultGuardrail] = []
    ) {
        self.input = input
        self.toolInput = toolInput
        self.toolOutput = toolOutput
        self.result = result
    }

    public static let empty = LuminaRuntimeGuardrails()
}

enum LuminaGuardrailFailure: Error, LocalizedError {
    case rejected(String)
    case tripwire(String)

    var errorDescription: String? {
        switch self {
        case let .rejected(message):
            return message
        case let .tripwire(message):
            return message
        }
    }
}
