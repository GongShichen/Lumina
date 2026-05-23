import Foundation

public struct StructuredPlannerPrompt: Codable, Hashable, Sendable {
    public var request: AgentRequest
    public var availableTools: [ToolSchema]
    public var maximumToolCalls: Int

    public init(request: AgentRequest, availableTools: [ToolSchema], maximumToolCalls: Int = 6) {
        self.request = request
        self.availableTools = availableTools
        self.maximumToolCalls = maximumToolCalls
    }

    public func render() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let toolsData = try encoder.encode(availableTools)
        let toolsJSON = String(decoding: toolsData, as: UTF8.self)

        return """
        You are the local planner inside a private iOS agent runtime.
        Return JSON only. Do not add markdown.

        User request text / extracted modality summaries:
        \(request.text)

        Modalities:
        \(request.content.modalities.map(\.rawValue).sorted().joined(separator: ", "))

        Available tools:
        \(toolsJSON)

        Required JSON shape:
        {
          "summary": "short plan summary",
          "toolCalls": [
            {
              "toolName": "one of the available tool names",
              "arguments": {"key": "value"},
              "requiresConfirmation": true
            }
          ]
        }

        Rules:
        - Use at most \(maximumToolCalls) tool calls.
        - Read-only tools may run without confirmation.
        - Any system write, app-local write, or external communication must set requiresConfirmation to true.
        - Prefer local.search before injecting private context into the prompt.
        """
    }
}

public protocol LocalStructuredInferenceModel: Sendable {
    func generateJSON(prompt: String) async throws -> String
}

public struct StructuredPlannerModelInput: Sendable {
    public var prompt: String
    public var content: [AgentContentPart]
    public var availableTools: [ToolSchema]

    public init(prompt: String, content: [AgentContentPart], availableTools: [ToolSchema]) {
        self.prompt = prompt
        self.content = content
        self.availableTools = availableTools
    }
}

public protocol LocalMultimodalStructuredInferenceModel: Sendable {
    func generateJSON(input: StructuredPlannerModelInput) async throws -> String
}

public struct TextOnlyStructuredModelAdapter: LocalMultimodalStructuredInferenceModel {
    private let model: any LocalStructuredInferenceModel

    public init(_ model: any LocalStructuredInferenceModel) {
        self.model = model
    }

    public func generateJSON(input: StructuredPlannerModelInput) async throws -> String {
        try await model.generateJSON(prompt: input.prompt)
    }
}

public struct ModelBackedPlanner: Planner {
    private let model: any LocalMultimodalStructuredInferenceModel
    private let fallback: any Planner
    private let maximumToolCalls: Int

    public init(
        model: any LocalStructuredInferenceModel,
        fallback: any Planner = RuleBasedPlanner(),
        maximumToolCalls: Int = 6
    ) {
        self.init(
            multimodalModel: TextOnlyStructuredModelAdapter(model),
            fallback: fallback,
            maximumToolCalls: maximumToolCalls
        )
    }

    public init(
        multimodalModel: any LocalMultimodalStructuredInferenceModel,
        fallback: any Planner = RuleBasedPlanner(),
        maximumToolCalls: Int = 6
    ) {
        self.model = multimodalModel
        self.fallback = fallback
        self.maximumToolCalls = maximumToolCalls
    }

    public func makePlan(for request: AgentRequest, availableTools: [ToolSchema]) async throws -> AgentPlan {
        do {
            try Task.checkCancellation()
            let prompt = try StructuredPlannerPrompt(
                request: request,
                availableTools: availableTools,
                maximumToolCalls: maximumToolCalls
            ).render()
            let json = try await model.generateJSON(input: StructuredPlannerModelInput(
                prompt: prompt,
                content: request.content,
                availableTools: availableTools
            ))
            return try GeneratedPlanParser.parse(json: json, availableTools: availableTools, maximumToolCalls: maximumToolCalls)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return try await fallback.makePlan(for: request, availableTools: availableTools)
        }
    }
}

enum GeneratedPlanParser {
    static func parse(json: String, availableTools: [ToolSchema], maximumToolCalls: Int) throws -> AgentPlan {
        let data = Data(json.utf8)
        let dto = try JSONDecoder().decode(GeneratedPlanDTO.self, from: data)
        let schemasByName = Dictionary(uniqueKeysWithValues: availableTools.map { ($0.name, $0) })

        let calls = dto.toolCalls.prefix(maximumToolCalls).compactMap { call -> ToolCall? in
            guard let schema = schemasByName[call.toolName] else { return nil }
            return ToolCall(
                toolName: call.toolName,
                arguments: call.arguments,
                requiresConfirmation: call.requiresConfirmation || schema.sideEffect != .readOnly
            )
        }

        return AgentPlan(summary: dto.summary, toolCalls: calls)
    }
}

private struct GeneratedPlanDTO: Decodable {
    var summary: String
    var toolCalls: [GeneratedToolCallDTO]
}

private struct GeneratedToolCallDTO: Decodable {
    var toolName: String
    var arguments: [String: JSONValue]
    var requiresConfirmation: Bool
}
