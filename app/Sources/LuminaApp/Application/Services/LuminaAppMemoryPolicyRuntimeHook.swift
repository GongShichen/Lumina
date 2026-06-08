import LuminaAgentRuntime
import Foundation

struct LuminaAppMemoryPolicyRuntimeHook: LuminaAgentRuntimeHook {
    func handle(
        event: LuminaAgentRuntimeHookEvent,
        context: LuminaAgentRuntimeHookContext
    ) async throws -> [LuminaAgentRuntimeHookDirective] {
        guard event == .stepContextReady,
              context.availableTools.contains(where: { $0.name == "memory.ingest_text" })
        else {
            return []
        }

        return [
            .appendContextSection(LuminaRuntimeContextSection(
                id: "app.memory_policy.agentic_persistence",
                title: "Persistent memory policy",
                summary: "Agent may save durable user memory only when it is useful beyond this task.",
                content: """
                You may call memory.ingest_text only when a fact, preference, durable plan, or user instruction is likely to be useful in future sessions. Do not save transient tool observations, temporary reasoning, one-off task progress, raw sensitive content, or anything the user did not ask you to remember unless it is clearly reusable. Include reason, memoryType, retentionHint, source, and sensitivity in parameters. Use sensitive or privateData for contact, health, location, communication, clipboard, or document-body content.
                """,
                source: "app/policy",
                sensitivity: .normal,
                disclosureLevel: 0
            )),
            .annotate(key: "app.memoryPolicy", value: .string("agentic_persistence_available"))
        ]
    }
}

struct LuminaToolRecoveryRuntimeHook: LuminaMatchingAgentRuntimeHook {
    let matcher = LuminaAgentRuntimeHookMatcher(events: [.stepContextReady])

    func handle(
        event: LuminaAgentRuntimeHookEvent,
        context: LuminaAgentRuntimeHookContext
    ) async throws -> [LuminaAgentRuntimeHookDirective] {
        guard event == .stepContextReady,
              let observation = context.trace.steps.last?.observation,
              observation.status == .failed || observation.status == .denied || observation.status == .cancelled
        else {
            return []
        }

        let failureText = [
            observation.summary,
            observation.errorMessage ?? ""
        ]
            .joined(separator: "\n")
            .lowercased()
        let availableTools = context.availableTools.sorted { $0.name < $1.name }

        if isUnknownToolFailure(failureText) {
            let content = """
            Unknown Tool: \(observation.toolName).
            All available tools:
            \(toolCatalogJSON(for: availableTools))
            You must choose only an exact tool name from the schema above and pass only parameters declared by that tool schema.
            """
            return directives(
                id: "app.tool_recovery.unknown_tool.\(stableIDComponent(observation.toolName))",
                title: "Tool recovery: unknown tool",
                summary: "The previous tool name was invalid; full callable tool catalog is available.",
                content: content,
                annotation: "unknown_tool"
            )
        }

        if isParameterFailure(failureText) {
            let schemaTools: [LuminaToolSchema]
            if let schema = availableTools.first(where: { $0.name == observation.toolName }) {
                schemaTools = [schema]
            } else {
                schemaTools = availableTools
            }
            let content = """
            Value Error. \(observation.toolName) parameters are:
            \(toolCatalogJSON(for: schemaTools))
            Fill missing or invalid parameters from the user request and previous observations, then retry with exactly the parameter names and JSON types shown above. Only output cannot_complete when the needed value cannot be inferred. Do not repeat the invalid parameters.
            """
            return directives(
                id: "app.tool_recovery.value_error.\(stableIDComponent(observation.toolName))",
                title: "Tool recovery: value error",
                summary: "The previous tool parameters failed validation; matching schema is available.",
                content: content,
                annotation: "value_error"
            )
        }

        return []
    }

    private func directives(
        id: String,
        title: String,
        summary: String,
        content: String,
        annotation: String
    ) -> [LuminaAgentRuntimeHookDirective] {
        [
            .appendContextSection(LuminaRuntimeContextSection(
                id: id,
                title: title,
                summary: summary,
                content: content,
                source: "app/tool-recovery",
                sensitivity: .normal,
                disclosureLevel: 0
            )),
            .annotate(key: "app.toolRecovery", value: .string(annotation))
        ]
    }

    private func isUnknownToolFailure(_ text: String) -> Bool {
        text.contains("tool is not registered") ||
            text.contains("unknown tool") ||
            text.contains("unregistered tool") ||
            text.contains("tool is deferred") ||
            text.contains("tool is not callable")
    }

    private func isParameterFailure(_ text: String) -> Bool {
        text.contains("missing required parameter") ||
            text.contains("invalid type") ||
            text.contains("allowed enum") ||
            text.contains("parameters must be a json object") ||
            text.contains("tool parameters must be a json object") ||
            text.contains("failed validation") ||
            text.contains("schema")
    }

    private func toolCatalogJSON(for schemas: [LuminaToolSchema]) -> String {
        let payload = schemas.map(toolSchemaPayload(for:))
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8)
        else {
            return schemas.map { schema in
                "\(schema.name): \(schema.description)"
            }.joined(separator: "\n")
        }
        return json
    }

    private func toolSchemaPayload(for schema: LuminaToolSchema) -> [String: Any] {
        [
            "name": schema.name,
            "description": schema.description,
            "requires_confirmation": schema.sideEffect != .readOnly,
            "side_effect": schema.sideEffect.rawValue,
            "sensitivity": schema.sensitivity.rawValue,
            "parameters": schema.parameters.sorted { $0.name < $1.name }.map { parameter in
                [
                    "name": parameter.name,
                    "type": parameter.type.rawValue,
                    "required": parameter.required,
                    "description": parameter.description,
                    "sensitive": parameter.sensitive
                ] as [String: Any]
            }
        ] as [String: Any]
    }

    private func stableIDComponent(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        let scalars = value.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? Character(scalar) : "_"
        }
        let sanitized = String(scalars)
        return sanitized.isEmpty ? "tool" : sanitized
    }
}
