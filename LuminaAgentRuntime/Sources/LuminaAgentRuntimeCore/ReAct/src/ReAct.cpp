#include "ReAct.hpp"

#include <sstream>
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
                "structured_content", "artifacts", "recoverable_actions"
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

    if (type == "result") {
        if (!hasAllowedKeys(fields, {"schema_version", "step_id", "type", "thought", "requires_followup", "content", "structured_content", "artifacts", "citations", "completed"}, error)) {
            error = "result may only contain schema_version, step_id, type, thought, requires_followup, content, structured_content, artifacts, citations, and completed.";
            return false;
        }
        if (fields.find("content") == fields.end() || fields["content"].kind != JsonKind::string) {
            error = "result requires a string content field.";
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

static std::string tagValue(const std::string &text, const std::string &tag) {
    const std::string open = "<" + tag + ">";
    const std::string close = "</" + tag + ">";
    const size_t start = text.find(open);
    if (start == std::string::npos) {
        return "";
    }
    const size_t valueStart = start + open.size();
    const size_t end = text.find(close, valueStart);
    if (end == std::string::npos) {
        return "";
    }
    return trim(text.substr(valueStart, end - valueStart));
}

static std::string xmlAttributeValue(const std::string &header, const std::string &name) {
    const std::string key = name + "=\"";
    const size_t start = header.find(key);
    if (start == std::string::npos) {
        return "";
    }
    const size_t valueStart = start + key.size();
    const size_t valueEnd = header.find("\"", valueStart);
    if (valueEnd == std::string::npos) {
        return "";
    }
    return header.substr(valueStart, valueEnd - valueStart);
}

static bool toolUseTagValue(
    const std::string &text,
    std::string &toolName,
    bool &requiresConfirmation,
    bool &hasRequiresConfirmation,
    std::string &value,
    std::string &error
) {
    const std::string open = "<tool_use";
    const size_t start = text.find(open);
    if (start == std::string::npos) {
        return false;
    }
    const size_t openEnd = text.find(">", start);
    if (openEnd == std::string::npos) {
        error = "tool_use tag is missing closing '>'.";
        return false;
    }
    const std::string header = text.substr(start, openEnd - start + 1);
    toolName = xmlAttributeValue(header, "name");
    if (toolName.empty()) {
        error = "tool_use tag requires a name attribute.";
        return false;
    }
    std::string confirmation = lowercased(xmlAttributeValue(header, "requires_confirmation"));
    if (confirmation.empty()) {
        confirmation = lowercased(xmlAttributeValue(header, "requires-confirmation"));
    }
    if (!confirmation.empty()) {
        hasRequiresConfirmation = true;
        requiresConfirmation = confirmation == "true" || confirmation == "1" || confirmation == "yes";
    }
    const std::string close = "</tool_use>";
    const size_t valueStart = openEnd + 1;
    const size_t end = text.find(close, valueStart);
    if (end == std::string::npos) {
        error = "tool_use tag is missing closing </tool_use>.";
        return false;
    }
    value = trim(text.substr(valueStart, end - valueStart));
    if (value.empty()) {
        error = "tool_use tag content must be an explicit JSON object; use {} for no parameters.";
        return false;
    }
    return true;
}

static bool startsWith(const std::string &text, const std::string &prefix) {
    return text.size() >= prefix.size() && text.compare(0, prefix.size(), prefix) == 0;
}

static std::string stripLeadingThinkBlock(const std::string &text, std::string &error) {
    std::string normalized = trim(text);
    if (!startsWith(normalized, "<think")) {
        if (normalized.find("<think") != std::string::npos || normalized.find("</think>") != std::string::npos) {
            error = "model output may not contain <think> tags.";
            return "";
        }
        return normalized;
    }
    const size_t openEnd = normalized.find(">");
    if (openEnd == std::string::npos) {
        error = "leading <think> tag is missing closing '>'.";
        return "";
    }
    const size_t close = normalized.find("</think>", openEnd + 1);
    if (close == std::string::npos) {
        error = "leading <think> tag is missing closing </think>.";
        return "";
    }
    normalized = trim(normalized.substr(close + std::string("</think>").size()));
    if (normalized.find("<think") != std::string::npos || normalized.find("</think>") != std::string::npos) {
        error = "model output may not contain nested or repeated <think> tags.";
        return "";
    }
    return normalized;
}

static std::string normalizeXmlTags(const std::string &text, std::string &error) {
    const std::string normalizedText = stripLeadingThinkBlock(text, error);
    if (!error.empty()) {
        return "";
    }
    if (normalizedText.find("<observation") != std::string::npos || normalizedText.find("<tool_result") != std::string::npos) {
        error = "model output may not contain runtime-owned observation/tool_result tags.";
        return "";
    }
    const std::string thought = tagValue(normalizedText, "thought");
    std::string toolName;
    bool requiresConfirmation = false;
    bool hasRequiresConfirmation = false;
    std::string toolParameters;
    const bool hasToolUse = toolUseTagValue(
        normalizedText,
        toolName,
        requiresConfirmation,
        hasRequiresConfirmation,
        toolParameters,
        error
    );
    if (!error.empty()) {
        return "";
    }
    if (hasToolUse) {
        std::map<std::string, JsonField> fields;
        if (!parseFieldsOrEmpty(toolParameters, fields)) {
            error = "tool_use tag content must be a JSON object.";
            return "";
        }
        return "{\"type\":\"tool_use\",\"thought\":" + jsonString(thought) +
            ",\"tool_name\":" + jsonString(toolName) +
            ",\"parameters\":" + toolParameters +
            (hasRequiresConfirmation ? ",\"requires_confirmation\":" + jsonBool(requiresConfirmation) : "") +
            "}";
    }
    const std::string askUser = tagValue(normalizedText, "ask_user");
    if (!askUser.empty()) {
        std::map<std::string, JsonField> fields;
        if (!parseFieldsOrEmpty(askUser, fields)) {
            error = "ask_user tag content must be a JSON object.";
            return "";
        }
        return "{\"type\":\"ask_user\",\"thought\":" + jsonString(thought) +
            ",\"questions\":" + rawField(fields, "questions", "[]") +
            ",\"reason\":" + jsonString(stringField(fields, "reason")) +
            ",\"sensitivity\":" + jsonString(stringField(fields, "sensitivity", "normal")) +
            ",\"timeout_seconds\":" + rawField(fields, "timeout_seconds", rawField(fields, "timeoutSeconds", "0")) +
            ",\"allow_custom_answer\":" + rawField(fields, "allow_custom_answer", "true") +
            "}";
    }
    const std::string result = tagValue(normalizedText, "result");
    if (!result.empty()) {
        return "{\"type\":\"result\",\"thought\":" + jsonString(thought) +
            ",\"content\":" + jsonString(result) +
            ",\"completed\":true}";
    }
    const std::string cannotComplete = tagValue(normalizedText, "cannot_complete");
    if (!cannotComplete.empty()) {
        return "{\"type\":\"cannot_complete\",\"thought\":" + jsonString(thought) +
            ",\"reason\":" + jsonString(cannotComplete) + "}";
    }
    if (!thought.empty()) {
        return "{\"type\":\"reasoning\",\"thought\":" + jsonString(thought) + ",\"requires_followup\":true}";
    }
    error = "no supported XML ReAct tag found.";
    return "";
}

std::string normalizeReActStepText(const std::string &text, const std::string &dialect, std::string &error) {
    const std::string normalizedDialect = lowercased(trim(dialect).empty() ? "canonical_json" : dialect);
    if (normalizedDialect == "canonical_json") {
        const std::string object = firstValidReActStepObject(text);
        if (object.empty()) {
            error = "no canonical ReAct JSON object found.";
        }
        return object;
    }
    if (normalizedDialect == "xml_tags") {
        std::string object = normalizeXmlTags(text, error);
        if (object.empty()) {
            return "";
        }
        std::string validationError;
        if (!validateReActStepObject(object, true, validationError)) {
            error = validationError;
            return "";
        }
        return object;
    }
    if (normalizedDialect == "provider_native_tool_call" || normalizedDialect == "custom_adapter") {
        error = "dialect requires caller-side adapter before runtime normalization.";
        return "";
    }
    error = "unsupported ReAct dialect: " + normalizedDialect;
    return "";
}

} // namespace LuminaAgent
