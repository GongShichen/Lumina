import AgentRuntime
import Foundation

struct LuminaAppReActPromptBuilder: Sendable {
    var maximumTraceObservations: Int = 2
    var maximumContextCharacters: Int = 1_200
    var maximumTraceCharacters: Int = 900
    var maximumToolDescriptionCharacters: Int = 80

    func build(context: LuminaReActPlannerContext) async throws -> String {
        try Task.checkCancellation()
        let profile = promptProfile(from: context.request.metadata)
        let toolBlock = compactToolContext(for: context.availableTools)
        let traceBlock = try compactTraceContext(context.trace)
        let contextBlock = loadedContextBlock(context.loadedContext)
        let modalities = context.request.content.modalities.map(\.rawValue).sorted().joined(separator: ", ")

        return """
        \(systemPrompt(for: profile))

        \(LuminaReActSchema.promptContract)

        Rules:
        - Complete the request through tools when action is needed; do not only plan.
        - Use only listed tools and listed input keys.
        - Set requires_confirmation=true for any sideEffect tool.
        - If essential information is missing, use ask_user.
        - Never claim success before an observation confirms it.
        - Keep final_answer concise and do not repeat observations.

        \(profileInstructions(for: profile))

        Request: \(context.request.text)

        Modalities: \(modalities.isEmpty ? "text" : modalities)

        Tools:
        \(toolBlock)

        Context:
        \(contextBlock)

        Recent steps:
        \(traceBlock)

        Budget: iteration=\(context.iteration), remainingTools=\(context.remainingToolCalls), maxObservationChars=\(context.maximumObservationCharacters)

        Return exactly one JSON object now.
        """
    }

    private func promptProfile(from metadata: [String: LuminaJSONValue]) -> LuminaAppPromptProfile {
        metadata.string(LuminaAppPromptProfile.metadataKey)
            .flatMap(LuminaAppPromptProfile.init(rawValue:)) ?? .taskExecution
    }

    private func systemPrompt(for profile: LuminaAppPromptProfile) -> String {
        switch profile {
        case .taskExecution:
            return """
            You are Lumina, a local-first Apple-platform personal assistant. Complete the user's task end-to-end through registered tools while preserving privacy.
            """
        case .homePersonalization:
            return """
            You are Lumina's home personalization agent. Generate a grounded greeting and at most three useful query suggestions from real local status, context, observations, and tool schemas.
            """
        }
    }

    private func profileInstructions(for profile: LuminaAppPromptProfile) -> String {
        switch profile {
        case .taskExecution:
            return """
            Task policy:
            - Decide each step yourself with ReAct.
            - Use device.current_time for relative dates before calendar/reminder/notification actions.
            - Use read tools for memory, calendar, contacts, ledger, clipboard, location, or files when needed.
            - Use ask_user for missing title, time, contact, message body, or planning preference.
            - After a side-effect observation, final_answer states the confirmed result or recovery step.
            """
        case .homePersonalization:
            return """
            Home policy:
            - Do not call tools with side effects, even with confirmation.
            - Suggestions must be grounded in tools or real context and never fabricate people, meetings, bills, memories, places, or subscriptions.
            - Suggestion format, max 3 lines: SUGGESTION|title|query|SF Symbol
            """
        }
    }

    private func compactToolContext(for schemas: [LuminaToolSchema]) -> String {
        schemas.sorted { $0.name < $1.name }.map { schema in
            let params = schema.parameters.map { parameter in
                "\(parameter.name):\(parameter.type.rawValue)\(parameter.required ? "" : "?")"
            }.joined(separator: ", ")
            let input = params.isEmpty ? "{}" : "{\(params)}"
            let sideEffect = schema.sideEffect == .readOnly ? "readOnly" : "sideEffect"
            return "- \(schema.name) \(sideEffect) sens=\(schema.sensitivity.rawValue) input=\(input) desc=\(schema.description.truncated(to: maximumToolDescriptionCharacters))"
        }.joined(separator: "\n")
    }

    private func loadedContextBlock(_ loadedContext: LuminaRuntimeContext) -> String {
        guard !loadedContext.sections.isEmpty else {
            return "none; retrieve with tools if needed"
        }
        let sections = loadedContext.sections.enumerated().map { index, section in
            let content = section.content.isEmpty ? section.summary : section.content
            return "[\(index + 1)] \(section.title) source=\(section.source) sens=\(section.sensitivity.rawValue) summary=\(content.truncated(to: 240))"
        }.joined(separator: "\n")
        return sections.truncated(to: maximumContextCharacters)
    }

    private func compactTraceContext(_ trace: LuminaReActTrace) throws -> String {
        let compactSteps = trace.steps.suffix(maximumTraceObservations * 2)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = String(decoding: try encoder.encode(Array(compactSteps)), as: UTF8.self)
        return json.isEmpty ? "none" : json.truncated(to: maximumTraceCharacters)
    }
}

private extension String {
    func truncated(to limit: Int) -> String {
        guard count > limit else { return self }
        let end = index(startIndex, offsetBy: max(0, limit - 1))
        return String(self[..<end]) + "..."
    }
}
