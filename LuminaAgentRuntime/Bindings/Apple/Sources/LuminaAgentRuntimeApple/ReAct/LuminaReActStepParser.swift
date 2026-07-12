import Foundation

public enum LuminaReActStepParser {
    public static func parse(json: String, availableTools: [LuminaToolSchema]) throws -> LuminaReActStep {
        let data = Data(json.utf8)
        try validateStrictReActSchema(data: data)
        let dto = try JSONDecoder().decode(ReActStepDTO.self, from: data)
        let schemasByName = Dictionary(uniqueKeysWithValues: availableTools.map { ($0.name, $0) })
        let stepType = dto.type.lowercased()
        let thinking = dto.thinking ?? ""

        switch stepType {
        case "reasoning":
            guard dto.thinking != nil else {
                throw LuminaReActParserError.invalidSchema("reasoning steps require a thinking string.")
            }
            return .thought(thinking)
        case "tool_use":
            guard let toolName = dto.toolName,
                  !toolName.isEmpty
            else {
                throw LuminaReActParserError.invalidAction
            }
            let schemaRequiresConfirmation = schemasByName[toolName].map { $0.sideEffect != .readOnly } ?? false
            return .action(
                thought: thinking,
                call: LuminaToolCall(
                    toolName: toolName,
                    arguments: dto.parameters ?? [:],
                    requiresConfirmation: (dto.requiresConfirmation ?? false) || schemaRequiresConfirmation
                )
            )
        case "multi_tool_use":
            guard let toolCalls = dto.toolCalls, !toolCalls.isEmpty else {
                throw LuminaReActParserError.invalidSchema("multi_tool_use requires a non-empty tool_calls array.")
            }
            let calls = toolCalls.map { toolCall in
                let schemaRequiresConfirmation = schemasByName[toolCall.toolName].map { $0.sideEffect != .readOnly } ?? false
                return LuminaToolCall(
                    toolName: toolCall.toolName,
                    arguments: toolCall.parameters ?? [:],
                    requiresConfirmation: (toolCall.requiresConfirmation ?? false) || schemaRequiresConfirmation
                )
            }
            return .multiAction(thought: thinking, calls: calls)
        case "result":
            guard let content = dto.content else {
                throw LuminaReActParserError.invalidSchema("result steps require a content string.")
            }
            return .result(content, thought: thinking)
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
            return .action(thought: thinking, call: LuminaToolCall(toolName: "ask_user", arguments: value))
        case "cannot_complete":
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let reason = object?["reason"] as? String ?? "无法完成。"
            return .result("### 无法完成\n\n\(reason)", thought: thinking)
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
            "schema_version", "step_id", "type", "thinking", "requires_followup",
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
        case "reasoning":
            guard object["thinking"] is String else {
                throw LuminaReActParserError.invalidSchema("reasoning requires a string thinking field.")
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
        case "multi_tool_use":
            guard let toolCalls = object["tool_calls"] as? [Any], !toolCalls.isEmpty else {
                throw LuminaReActParserError.invalidSchema("multi_tool_use requires a non-empty tool_calls array.")
            }
            for toolCall in toolCalls {
                guard let object = toolCall as? [String: Any], object["tool_name"] is String else {
                    throw LuminaReActParserError.invalidSchema("multi_tool_use tool_calls require tool_name strings.")
                }
                if let parameters = object["parameters"], !(parameters is [String: Any]) {
                    throw LuminaReActParserError.invalidSchema("multi_tool_use parameters must be objects.")
                }
                if let value = object["requires_confirmation"], !(value is Bool) {
                    throw LuminaReActParserError.invalidSchema("multi_tool_use requires_confirmation must be boolean.")
                }
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
