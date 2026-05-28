#include "ReAct.hpp"

#include <string>
#include <vector>

namespace LuminaAgent {

static bool hasAllowedKeys(
    const std::map<std::string, JsonField> &fields,
    std::initializer_list<const char *> allowed,
    std::string &error
) {
    std::vector<std::string> keys;
    for (const char *key : allowed) {
        keys.emplace_back(key);
    }
    return hasOnlyKeys(fields, keys, error);
}

std::string reactStepType(const std::map<std::string, JsonField> &fields) {
    return lowercased(stringField(fields, "type"));
}

bool validateReActStepObject(const std::string &json, bool requireKnownType, std::string &error) {
    std::map<std::string, JsonField> fields;
    if (!parseTopLevelObject(json, fields, error)) {
        return false;
    }

    auto typeIt = fields.find("type");
    if (typeIt == fields.end() || typeIt->second.kind != JsonKind::string) {
        error = "missing string field type.";
        return false;
    }

    if (!hasAllowedKeys(
            fields,
            {
                "schema_version", "step_id", "type", "thought", "requires_followup",
                "confidence", "needs_more_context", "tool_name", "parameters",
                "expected_observation", "requires_confirmation", "tool_calls",
                "query", "category", "max_results", "include_schemas",
                "questions", "reason", "sensitivity", "timeout_seconds",
                "allow_custom_answer", "content", "citations", "completed",
                "recoverable_actions"
            },
            error
        )) {
        return false;
    }

    const std::string type = lowercased(typeIt->second.stringValue);
    if (type == "reasoning") {
        if (!hasAllowedKeys(fields, {"schema_version", "step_id", "type", "thought", "requires_followup", "confidence", "needs_more_context"}, error)) {
            error = "reasoning may only contain schema_version, step_id, type, thought, requires_followup, confidence, and needs_more_context.";
            return false;
        }
        if (fields.find("thought") == fields.end() || fields["thought"].kind != JsonKind::string) {
            error = "reasoning requires a string thought field.";
            return false;
        }
        return true;
    }

    if (type == "tool_use") {
        if (!hasAllowedKeys(fields, {"schema_version", "step_id", "type", "thought", "requires_followup", "tool_name", "parameters", "expected_observation", "requires_confirmation"}, error)) {
            error = "tool_use may only contain schema_version, step_id, type, thought, requires_followup, tool_name, parameters, expected_observation, and requires_confirmation.";
            return false;
        }
        if (fields.find("tool_name") == fields.end() || fields["tool_name"].kind != JsonKind::string) {
            error = "tool_use requires a string tool_name field.";
            return false;
        }
        auto parametersIt = fields.find("parameters");
        if (parametersIt != fields.end() && parametersIt->second.kind != JsonKind::object) {
            error = "parameters must be an object when present.";
            return false;
        }
        return true;
    }

    if (type == "multi_tool_use") {
        if (!hasAllowedKeys(fields, {"schema_version", "step_id", "type", "thought", "requires_followup", "tool_calls", "expected_observation"}, error)) {
            error = "multi_tool_use may only contain schema_version, step_id, type, thought, requires_followup, tool_calls, and expected_observation.";
            return false;
        }
        auto callsIt = fields.find("tool_calls");
        if (callsIt == fields.end() || callsIt->second.kind != JsonKind::array) {
            error = "multi_tool_use requires an array tool_calls field.";
            return false;
        }
        return true;
    }

    if (type == "tool_discovery") {
        if (!hasAllowedKeys(fields, {"schema_version", "step_id", "type", "thought", "requires_followup", "query", "category", "max_results", "include_schemas"}, error)) {
            error = "tool_discovery may only contain schema_version, step_id, type, thought, requires_followup, query, category, max_results, and include_schemas.";
            return false;
        }
        return true;
    }

    if (type == "ask_user") {
        if (!hasAllowedKeys(fields, {"schema_version", "step_id", "type", "thought", "requires_followup", "questions", "reason", "sensitivity", "timeout_seconds", "allow_custom_answer"}, error)) {
            error = "ask_user may only contain schema_version, step_id, type, thought, requires_followup, questions, reason, sensitivity, timeout_seconds, and allow_custom_answer.";
            return false;
        }
        auto questionsIt = fields.find("questions");
        if (questionsIt == fields.end() || questionsIt->second.kind != JsonKind::array) {
            error = "ask_user requires an array questions field.";
            return false;
        }
        return true;
    }

    if (type == "final_answer") {
        if (!hasAllowedKeys(fields, {"schema_version", "step_id", "type", "thought", "requires_followup", "content", "citations", "completed"}, error)) {
            error = "final_answer may only contain schema_version, step_id, type, thought, requires_followup, content, citations, and completed.";
            return false;
        }
        if (fields.find("content") == fields.end() || fields["content"].kind != JsonKind::string) {
            error = "final_answer requires a string content field.";
            return false;
        }
        return true;
    }

    if (type == "cannot_complete") {
        if (!hasAllowedKeys(fields, {"schema_version", "step_id", "type", "thought", "requires_followup", "reason", "recoverable_actions"}, error)) {
            error = "cannot_complete may only contain schema_version, step_id, type, thought, requires_followup, reason, and recoverable_actions.";
            return false;
        }
        if (fields.find("reason") == fields.end() || fields["reason"].kind != JsonKind::string) {
            error = "cannot_complete requires a string reason field.";
            return false;
        }
        return true;
    }

    (void) requireKnownType;
    error = "unknown ReAct step type.";
    return false;
}

std::string firstValidReActStepObject(const std::string &text) {
    for (const std::string &object : extractBalancedObjects(text)) {
        std::string error;
        if (validateReActStepObject(object, true, error)) {
            return object;
        }
    }
    return "";
}

} // namespace LuminaAgent
