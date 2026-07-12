import Foundation

public struct LuminaReActStep: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var kind: LuminaReActStepKind
    public var thought: String?
    public var action: LuminaToolCall?
    public var toolCalls: [LuminaToolCall]
    public var observation: LuminaReActObservation?
    public var resultMarkdown: String?
    public var elapsedMilliseconds: Double

    public init(
        id: UUID = UUID(),
        kind: LuminaReActStepKind,
        thought: String? = nil,
        action: LuminaToolCall? = nil,
        toolCalls: [LuminaToolCall] = [],
        observation: LuminaReActObservation? = nil,
        resultMarkdown: String? = nil,
        elapsedMilliseconds: Double = 0
    ) {
        self.id = id
        self.kind = kind
        self.thought = thought
        self.action = action
        self.toolCalls = toolCalls
        self.observation = observation
        self.resultMarkdown = resultMarkdown
        self.elapsedMilliseconds = elapsedMilliseconds
    }

    public static func thought(_ value: String, elapsedMilliseconds: Double = 0) -> LuminaReActStep {
        LuminaReActStep(kind: .thought, thought: value, elapsedMilliseconds: elapsedMilliseconds)
    }

    public static func action(thought: String, call: LuminaToolCall, elapsedMilliseconds: Double = 0) -> LuminaReActStep {
        LuminaReActStep(kind: .action, thought: thought, action: call, elapsedMilliseconds: elapsedMilliseconds)
    }

    public static func multiAction(thought: String, calls: [LuminaToolCall], elapsedMilliseconds: Double = 0) -> LuminaReActStep {
        LuminaReActStep(kind: .multiAction, thought: thought, toolCalls: calls, elapsedMilliseconds: elapsedMilliseconds)
    }

    public static func observation(_ value: LuminaReActObservation, elapsedMilliseconds: Double = 0) -> LuminaReActStep {
        LuminaReActStep(kind: .observation, observation: value, elapsedMilliseconds: elapsedMilliseconds)
    }

    public static func result(_ markdown: String, thought: String? = nil, elapsedMilliseconds: Double = 0) -> LuminaReActStep {
        LuminaReActStep(kind: .result, thought: thought, resultMarkdown: markdown, elapsedMilliseconds: elapsedMilliseconds)
    }
}
