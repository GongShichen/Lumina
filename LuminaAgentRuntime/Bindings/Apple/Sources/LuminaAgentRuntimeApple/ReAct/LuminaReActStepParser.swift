import Foundation

public enum LuminaReActStepParser {
    public static func parse(json: String, availableTools: [LuminaToolSchema]) throws -> LuminaReActStep {
        let data = Data(json.utf8)
        try validateStrictReActSchema(data: data)
        let dto = try JSONDecoder().decode(ReActStepDTO.self, from: data)
        let schemasByName = Dictionary(uniqueKeysWithValues: availableTools.map { ($0.name, $0) })
        let stepType = dto.type.lowercased()
        let thought = dto.thought ?? ""

        switch stepType {
        case "thought", "reasoning":
            guard dto.thought != nil else {
                throw LuminaReActParserError.invalidSchema("thought steps require a thought string.")
            }
            return .thought(thought)
        case "tool_use":
            guard let toolName = dto.toolName,
                  !toolName.isEmpty,
                  let schema = schemasByName[toolName]
            else {
                throw LuminaReActParserError.invalidAction
            }
            return .action(
                thought: thought,
                call: LuminaToolCall(
                    toolName: toolName,
                    arguments: dto.parameters ?? [:],
                    requiresConfirmation: (dto.requiresConfirmation ?? false) || schema.sideEffect != .readOnly
                )
            )
        case "result":
            guard let content = dto.content else {
                throw LuminaReActParserError.invalidSchema("result steps require a content string.")
            }
            return .result(content, thought: thought)
        case "ask_user":
            guard schemasByName["ask_user"] != nil else {
                throw LuminaReActParserError.invalidAction
            }
            let questions = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["questions"] ?? []
            let questionData = try JSONSerialization.data(withJSONObject: [
                "questions": questions,
                "reason": (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["reason"] as? String ?? "",
                "sensitivity": (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["sensitivity"] as? String ?? "normal",
                "timeoutSeconds": (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["timeout_seconds"] as? Double ?? 0,
                "allow_custom_answer": (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["allow_custom_answer"] as? Bool ?? true
            ])
            let value = (try? JSONDecoder().decode([String: LuminaJSONValue].self, from: questionData)) ?? [:]
            return .action(thought: thought, call: LuminaToolCall(toolName: "ask_user", arguments: value))
        case "cannot_complete":
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let reason = object?["reason"] as? String ?? "无法完成。"
            return .result("### 无法完成\n\n\(reason)", thought: thought)
        default:
            throw LuminaReActParserError.invalidStepType(stepType)
        }
    }

    private static func validateStrictReActSchema(data: Data) throws {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LuminaReActParserError.invalidSchema("top-level value must be an object.")
        }
        guard let type = object["type"] as? String else {
            throw LuminaReActParserError.invalidSchema("missing string field type.")
        }

        let topLevelKeys = Set(object.keys)
        let allowedTopLevelKeys = Set([
            "schema_version", "step_id", "type", "thought", "requires_followup",
            "confidence", "needs_more_context", "tool_name", "parameters",
            "expected_observation", "requires_confirmation", "tool_calls",
            "query", "category", "max_results", "include_schemas",
            "questions", "reason", "sensitivity", "timeout_seconds",
            "allow_custom_answer", "content", "citations", "completed",
            "structured_content", "artifacts", "recoverable_actions"
        ])
        let unknownTopLevelKeys = topLevelKeys.subtracting(allowedTopLevelKeys)
        guard unknownTopLevelKeys.isEmpty else {
            throw LuminaReActParserError.invalidSchema("unknown top-level keys: \(unknownTopLevelKeys.sorted().joined(separator: ", ")).")
        }

        switch type.lowercased() {
        case "thought", "reasoning":
            guard object["thought"] is String else {
                throw LuminaReActParserError.invalidSchema("thought requires a string thought field.")
            }
        case "tool_use":
            guard object["tool_name"] is String else {
                throw LuminaReActParserError.invalidSchema("tool_use requires a string tool_name field.")
            }
            if let parameters = object["parameters"], !(parameters is [String: Any]) {
                throw LuminaReActParserError.invalidSchema("parameters must be an object when present.")
            }
            if let value = object["requires_confirmation"], !(value is Bool) {
                throw LuminaReActParserError.invalidSchema("requires_confirmation must be a boolean when present.")
            }
        case "result":
            guard object["content"] is String else {
                throw LuminaReActParserError.invalidSchema("result requires a string content field.")
            }
        case "ask_user":
            guard object["questions"] is [Any] else {
                throw LuminaReActParserError.invalidSchema("ask_user requires questions array.")
            }
        case "cannot_complete":
            guard object["reason"] is String else {
                throw LuminaReActParserError.invalidSchema("cannot_complete requires reason string.")
            }
        default:
            return
        }
    }
}
