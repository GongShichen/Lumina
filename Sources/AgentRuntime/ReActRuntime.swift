import Foundation

public enum ReActStepKind: String, Codable, Hashable, Sendable {
    case thought
    case action
    case observation
    case final
}

public struct ReActObservation: Codable, Hashable, Sendable {
    public var toolName: String
    public var status: ToolResultStatus
    public var summary: String
    public var errorMessage: String?

    public init(toolName: String, status: ToolResultStatus, summary: String, errorMessage: String? = nil) {
        self.toolName = toolName
        self.status = status
        self.summary = summary
        self.errorMessage = errorMessage
    }
}

public struct ReActStep: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var kind: ReActStepKind
    public var thought: String?
    public var action: ToolCall?
    public var observation: ReActObservation?
    public var finalMarkdown: String?
    public var elapsedMilliseconds: Double

    public init(
        id: UUID = UUID(),
        kind: ReActStepKind,
        thought: String? = nil,
        action: ToolCall? = nil,
        observation: ReActObservation? = nil,
        finalMarkdown: String? = nil,
        elapsedMilliseconds: Double = 0
    ) {
        self.id = id
        self.kind = kind
        self.thought = thought
        self.action = action
        self.observation = observation
        self.finalMarkdown = finalMarkdown
        self.elapsedMilliseconds = elapsedMilliseconds
    }

    public static func thought(_ value: String, elapsedMilliseconds: Double = 0) -> ReActStep {
        ReActStep(kind: .thought, thought: value, elapsedMilliseconds: elapsedMilliseconds)
    }

    public static func action(thought: String, call: ToolCall, elapsedMilliseconds: Double = 0) -> ReActStep {
        ReActStep(kind: .action, thought: thought, action: call, elapsedMilliseconds: elapsedMilliseconds)
    }

    public static func observation(_ value: ReActObservation, elapsedMilliseconds: Double = 0) -> ReActStep {
        ReActStep(kind: .observation, observation: value, elapsedMilliseconds: elapsedMilliseconds)
    }

    public static func final(_ markdown: String, thought: String? = nil, elapsedMilliseconds: Double = 0) -> ReActStep {
        ReActStep(kind: .final, thought: thought, finalMarkdown: markdown, elapsedMilliseconds: elapsedMilliseconds)
    }
}

public struct ReActTrace: Codable, Hashable, Sendable {
    public var steps: [ReActStep]
    public var terminationReason: String?

    public init(steps: [ReActStep] = [], terminationReason: String? = nil) {
        self.steps = steps
        self.terminationReason = terminationReason
    }

    public var actionCount: Int {
        steps.filter { $0.kind == .action }.count
    }

    public var observations: [ReActObservation] {
        steps.compactMap(\.observation)
    }
}

public struct ReActPlannerContext: Sendable {
    public var request: AgentRequest
    public var availableTools: [ToolSchema]
    public var trace: ReActTrace
    public var iteration: Int
    public var remainingToolCalls: Int
    public var maximumObservationCharacters: Int

    public init(
        request: AgentRequest,
        availableTools: [ToolSchema],
        trace: ReActTrace,
        iteration: Int,
        remainingToolCalls: Int,
        maximumObservationCharacters: Int
    ) {
        self.request = request
        self.availableTools = availableTools
        self.trace = trace
        self.iteration = iteration
        self.remainingToolCalls = remainingToolCalls
        self.maximumObservationCharacters = maximumObservationCharacters
    }
}

public protocol ReActPlanner: Sendable {
    func nextStep(context: ReActPlannerContext) async throws -> ReActStep
}

public struct PlanBasedReActPlanner: ReActPlanner {
    private let planner: any Planner

    public init(planner: any Planner = FoundationModelsPlanner()) {
        self.planner = planner
    }

    public func nextStep(context: ReActPlannerContext) async throws -> ReActStep {
        try Task.checkCancellation()
        let plan = try await planner.makePlan(for: context.request, availableTools: context.availableTools)
        let calls = Array(plan.toolCalls.prefix(context.remainingToolCalls + context.trace.actionCount))
        let nextIndex = context.trace.actionCount
        guard nextIndex < calls.count else {
            return .final(Self.finalMarkdown(from: context.trace), thought: "All planned actions have been observed.")
        }
        return .action(thought: plan.summary, call: calls[nextIndex])
    }

    private static func finalMarkdown(from trace: ReActTrace) -> String {
        let observations = trace.observations
        guard !observations.isEmpty else { return "### 完成\n\n没有需要调用的工具。" }
        return "### 执行结果\n\n" + observations.map { "- **\($0.toolName)**: \($0.summary)" }.joined(separator: "\n")
    }
}

public struct ModelBackedReActPlanner: ReActPlanner {
    private let model: any LocalMultimodalStructuredInferenceModel
    private let fallback: any ReActPlanner

    public init(multimodalModel: any LocalMultimodalStructuredInferenceModel, fallback: any ReActPlanner = PlanBasedReActPlanner()) {
        self.model = multimodalModel
        self.fallback = fallback
    }

    public init(model: any LocalStructuredInferenceModel, fallback: any ReActPlanner = PlanBasedReActPlanner()) {
        self.init(multimodalModel: TextOnlyStructuredModelAdapter(model), fallback: fallback)
    }

    public func nextStep(context: ReActPlannerContext) async throws -> ReActStep {
        do {
            try Task.checkCancellation()
            let prompt = try StructuredReActPrompt(context: context).render()
            let json = try await model.generateJSON(input: StructuredPlannerModelInput(
                prompt: prompt,
                content: context.request.content,
                availableTools: context.availableTools
            ))
            return try ReActStepParser.parse(json: json, availableTools: context.availableTools)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return try await fallback.nextStep(context: context)
        }
    }
}

public struct StructuredReActPrompt: Sendable {
    public var context: ReActPlannerContext

    public init(context: ReActPlannerContext) {
        self.context = context
    }

    public func render() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let toolsJSON = String(decoding: try encoder.encode(context.availableTools), as: UTF8.self)
        let traceJSON = String(decoding: try encoder.encode(context.trace), as: UTF8.self)

        return """
        You are the local ReAct planner inside a private iOS agent runtime.
        Return JSON only. Do not add markdown outside JSON.

        User request:
        \(context.request.text)

        Modalities:
        \(context.request.content.modalities.map(\.rawValue).sorted().joined(separator: ", "))

        Available tools:
        \(toolsJSON)

        Current ReAct trace:
        \(traceJSON)

        Required JSON shape:
        {
          "kind": "thought|action|final",
          "thought": "brief reasoning summary",
          "action": {
            "toolName": "one of the available tool names",
            "arguments": {"key": "value"},
            "requiresConfirmation": true
          },
          "finalMarkdown": "markdown answer for the user"
        }

        Rules:
        - Use action only for a structured tool call.
        - Never invent tools.
        - Any non-read-only tool must set requiresConfirmation to true.
        - Keep observations compact; remaining tool calls: \(context.remainingToolCalls).
        - Return final when enough observations exist.
        """
    }
}

public enum ReActStepParser {
    public static func parse(json: String, availableTools: [ToolSchema]) throws -> ReActStep {
        let dto = try JSONDecoder().decode(ReActStepDTO.self, from: Data(json.utf8))
        let schemasByName = Dictionary(uniqueKeysWithValues: availableTools.map { ($0.name, $0) })

        switch dto.kind {
        case .thought:
            return .thought(dto.thought ?? "")
        case .action:
            guard let action = dto.action, let schema = schemasByName[action.toolName] else {
                throw ReActParserError.invalidAction
            }
            return .action(
                thought: dto.thought ?? "",
                call: ToolCall(
                    toolName: action.toolName,
                    arguments: action.arguments,
                    requiresConfirmation: action.requiresConfirmation || schema.sideEffect != .readOnly
                )
            )
        case .observation:
            throw ReActParserError.invalidAction
        case .final:
            return .final(dto.finalMarkdown ?? "", thought: dto.thought)
        }
    }
}

public enum ReActParserError: LocalizedError {
    case invalidAction

    public var errorDescription: String? {
        "ReAct action must reference an available structured tool."
    }
}

private struct ReActStepDTO: Decodable {
    var kind: ReActStepKind
    var thought: String?
    var action: ReActActionDTO?
    var finalMarkdown: String?
}

private struct ReActActionDTO: Decodable {
    var toolName: String
    var arguments: [String: JSONValue]
    var requiresConfirmation: Bool
}

enum ReActObservationCompressor {
    static func observation(from result: ToolResult, maximumCharacters: Int) -> ReActObservation {
        var parts: [String] = []
        if !result.content.isEmpty {
            parts.append(result.content.compactMap(\.textForPlanning).joined(separator: "\n"))
        }
        if !result.output.isEmpty {
            parts.append(result.output.keys.sorted().joined(separator: ", "))
        }
        if let error = result.errorMessage {
            parts.append(error)
        }
        let raw = parts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = String(raw.prefix(maximumCharacters))
        return ReActObservation(
            toolName: result.toolName,
            status: result.status,
            summary: summary.isEmpty ? result.status.rawValue : summary,
            errorMessage: result.errorMessage
        )
    }
}
