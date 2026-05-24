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
        case "thought":
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
        case "final_answer":
            guard let finalAnswer = dto.finalAnswer else {
                throw LuminaReActParserError.invalidSchema("final_answer steps require a final_answer string.")
            }
            return .final(finalAnswer, thought: thought)
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
        let allowedTopLevelKeys = Set(["type", "thought", "tool_name", "parameters", "requires_confirmation", "final_answer"])
        let unknownTopLevelKeys = topLevelKeys.subtracting(allowedTopLevelKeys)
        guard unknownTopLevelKeys.isEmpty else {
            throw LuminaReActParserError.invalidSchema("unknown top-level keys: \(unknownTopLevelKeys.sorted().joined(separator: ", ")).")
        }

        switch type.lowercased() {
        case "thought":
            guard topLevelKeys.isSubset(of: Set(["type", "thought"])) else {
                throw LuminaReActParserError.invalidSchema("thought may only contain type and thought.")
            }
            guard object["thought"] is String else {
                throw LuminaReActParserError.invalidSchema("thought requires a string thought field.")
            }
        case "tool_use":
            guard topLevelKeys.isSubset(of: Set(["type", "thought", "tool_name", "parameters", "requires_confirmation"])) else {
                throw LuminaReActParserError.invalidSchema("tool_use may only contain type, optional thought, tool_name, parameters, and requires_confirmation.")
            }
            guard object["tool_name"] is String else {
                throw LuminaReActParserError.invalidSchema("tool_use requires a string tool_name field.")
            }
            if let parameters = object["parameters"], !(parameters is [String: Any]) {
                throw LuminaReActParserError.invalidSchema("parameters must be an object when present.")
            }
            if let value = object["requires_confirmation"], !(value is Bool) {
                throw LuminaReActParserError.invalidSchema("requires_confirmation must be a boolean when present.")
            }
        case "final_answer":
            guard topLevelKeys.isSubset(of: Set(["type", "thought", "final_answer"])) else {
                throw LuminaReActParserError.invalidSchema("final_answer may only contain type, optional thought, and final_answer.")
            }
            guard object["final_answer"] is String else {
                throw LuminaReActParserError.invalidSchema("final_answer requires a string final_answer field.")
            }
        default:
            return
        }
    }
}
