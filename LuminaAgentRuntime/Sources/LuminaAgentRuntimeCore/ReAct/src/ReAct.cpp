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
                "schema_version", "step_id", "type", "thinking", "requires_followup",
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
        if (!hasAllowedKeys(fields, {"schema_version", "step_id", "type", "thinking", "requires_followup", "confidence", "needs_more_context"}, error)) {
            error = "reasoning may only contain schema_version, step_id, type, thinking, requires_followup, confidence, and needs_more_context.";
            return false;
        }
        if (fields.find("thinking") == fields.end() || fields["thinking"].kind != JsonKind::string) {
            error = "reasoning requires a string thinking field.";
            return false;
        }
        return true;
    }

    if (type == "tool_use") {
        if (!hasAllowedKeys(fields, {"schema_version", "step_id", "type", "thinking", "requires_followup", "tool_name", "parameters", "expected_observation", "requires_confirmation"}, error)) {
            error = "tool_use may only contain schema_version, step_id, type, thinking, requires_followup, tool_name, parameters, expected_observation, and requires_confirmation.";
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
        if (!hasAllowedKeys(fields, {"schema_version", "step_id", "type", "thinking", "requires_followup", "tool_calls", "expected_observation"}, error)) {
            error = "multi_tool_use may only contain schema_version, step_id, type, thinking, requires_followup, tool_calls, and expected_observation.";
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
        if (!hasAllowedKeys(fields, {"schema_version", "step_id", "type", "thinking", "requires_followup", "query", "category", "max_results", "include_schemas"}, error)) {
            error = "tool_discovery may only contain schema_version, step_id, type, thinking, requires_followup, query, category, max_results, and include_schemas.";
            return false;
        }
        return true;
    }

    if (type == "ask_user") {
        if (!hasAllowedKeys(fields, {"schema_version", "step_id", "type", "thinking", "requires_followup", "questions", "reason", "sensitivity", "timeout_seconds", "allow_custom_answer"}, error)) {
            error = "ask_user may only contain schema_version, step_id, type, thinking, requires_followup, questions, reason, sensitivity, timeout_seconds, and allow_custom_answer.";
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
        if (!hasAllowedKeys(fields, {"schema_version", "step_id", "type", "thinking", "requires_followup", "content", "structured_content", "artifacts", "citations", "completed"}, error)) {
            error = "result may only contain schema_version, step_id, type, thinking, requires_followup, content, structured_content, artifacts, citations, and completed.";
            return false;
        }
        if (fields.find("content") == fields.end() || fields["content"].kind != JsonKind::string) {
            error = "result requires a string content field.";
            return false;
        }
        return true;
    }

    if (type == "cannot_complete") {
        if (!hasAllowedKeys(fields, {"schema_version", "step_id", "type", "thinking", "requires_followup", "reason", "recoverable_actions"}, error)) {
            error = "cannot_complete may only contain schema_version, step_id, type, thinking, requires_followup, reason, and recoverable_actions.";
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

static bool startsWith(const std::string &text, const std::string &prefix) {
    return text.size() >= prefix.size() && text.compare(0, prefix.size(), prefix) == 0;
}

static std::string stripMiniCPMEndTokens(const std::string &text) {
    std::string value = text;
    const std::vector<std::string> endTokens = {"<|im_end|>", "<|endoftext|>"};
    for (const std::string &token : endTokens) {
        const size_t position = value.find(token);
        if (position != std::string::npos) {
            value = value.substr(0, position);
        }
    }
    return trim(value);
}

static std::string removeMiniCPMThinkBlocks(const std::string &text, std::string &thinking) {
    std::string value = text;
    const size_t start = value.find("<think>");
    if (start == std::string::npos) {
        return trim(value);
    }
    const size_t bodyStart = start + std::string("<think>").size();
    const size_t end = value.find("</think>", bodyStart);
    if (end == std::string::npos) {
        thinking = trim(value.substr(bodyStart));
        return "";
    }
    thinking = trim(value.substr(bodyStart, end - bodyStart));
    value.erase(start, (end + std::string("</think>").size()) - start);
    return trim(value);
}

static std::string miniCPMParameterValueJson(const std::string &raw) {
    const std::string value = trim(raw);
    if (value.empty()) {
        return jsonString("");
    }
    std::map<std::string, JsonField> objectFields;
    if ((startsWith(value, "{") && parseFieldsOrEmpty(value, objectFields)) ||
        startsWith(value, "[")) {
        return value;
    }
    const std::string lowered = lowercased(value);
    if (lowered == "true" || lowered == "false" || lowered == "null") {
        return lowered;
    }
    bool numeric = true;
    bool sawDigit = false;
    for (char c : value) {
        if (c >= '0' && c <= '9') {
            sawDigit = true;
            continue;
        }
        if (c == '-' || c == '+' || c == '.' || c == 'e' || c == 'E') {
            continue;
        }
        numeric = false;
        break;
    }
    if (numeric && sawDigit) {
        return value;
    }
    if ((startsWith(value, "\"") && value.size() >= 2 && value.back() == '"')) {
        return value;
    }
    return jsonString(value);
}

static bool appendMiniCPMParameters(
    const std::string &functionBody,
    std::ostringstream &parameters,
    std::string &error
) {
    parameters << "{";
    bool needsComma = false;
    size_t cursor = 0;
    while (true) {
        const size_t start = functionBody.find("<parameter=", cursor);
        if (start == std::string::npos) {
            break;
        }
        const size_t nameStart = start + std::string("<parameter=").size();
        const size_t headerEnd = functionBody.find(">", nameStart);
        if (headerEnd == std::string::npos) {
            error = "MiniCPM tool parameter tag is missing closing '>'.";
            return false;
        }
        const std::string name = trim(functionBody.substr(nameStart, headerEnd - nameStart));
        if (name.empty()) {
            error = "MiniCPM tool parameter tag requires a parameter name.";
            return false;
        }
        const size_t valueStart = headerEnd + 1;
        const size_t valueEnd = functionBody.find("</parameter>", valueStart);
        if (valueEnd == std::string::npos) {
            error = "MiniCPM tool parameter tag is missing </parameter>.";
            return false;
        }
        if (needsComma) {
            parameters << ",";
        }
        needsComma = true;
        parameters << jsonString(name) << ":" << miniCPMParameterValueJson(functionBody.substr(valueStart, valueEnd - valueStart));
        cursor = valueEnd + std::string("</parameter>").size();
    }
    parameters << "}";
    return true;
}

static bool appendMiniCPMToolCall(
    const std::string &toolCallBlock,
    std::ostringstream &calls,
    bool &needsComma,
    int index,
    std::string &error
) {
    const size_t functionStart = toolCallBlock.find("<function=");
    if (functionStart == std::string::npos) {
        error = "MiniCPM tool_call requires an inner <function=name> block.";
        return false;
    }
    const size_t nameStart = functionStart + std::string("<function=").size();
    const size_t headerEnd = toolCallBlock.find(">", nameStart);
    if (headerEnd == std::string::npos) {
        error = "MiniCPM function tag is missing closing '>'.";
        return false;
    }
    const std::string name = trim(toolCallBlock.substr(nameStart, headerEnd - nameStart));
    if (name.empty()) {
        error = "MiniCPM function tag requires a tool name.";
        return false;
    }
    const size_t bodyStart = headerEnd + 1;
    const size_t bodyEnd = toolCallBlock.find("</function>", bodyStart);
    if (bodyEnd == std::string::npos) {
        error = "MiniCPM function tag is missing </function>.";
        return false;
    }
    std::ostringstream parameters;
    if (!appendMiniCPMParameters(toolCallBlock.substr(bodyStart, bodyEnd - bodyStart), parameters, error)) {
        return false;
    }
    if (needsComma) {
        calls << ",";
    }
    needsComma = true;
    calls << "{\"tool_name\":" << jsonString(name)
          << ",\"parameters\":" << parameters.str()
          << ",\"call_id\":" << jsonString("toolu_minicpm_" + std::to_string(index))
          << "}";
    return true;
}

static std::string normalizeMiniCPMV46ToolCalls(const std::string &text, std::string &error) {
    std::string normalized = stripMiniCPMEndTokens(text);
    std::string thinking;
    normalized = removeMiniCPMThinkBlocks(normalized, thinking);
    if (normalized.empty() && !thinking.empty()) {
        return "{\"type\":\"reasoning\",\"thinking\":" + jsonString(thinking) + ",\"requires_followup\":true}";
    }

    std::ostringstream calls;
    calls << "[";
    bool needsComma = false;
    size_t cursor = 0;
    int index = 1;
    size_t firstToolStart = std::string::npos;
    size_t lastToolEnd = std::string::npos;
    while (true) {
        const size_t start = normalized.find("<tool_call>", cursor);
        if (start == std::string::npos) {
            break;
        }
        if (firstToolStart == std::string::npos) {
            firstToolStart = start;
        }
        const size_t bodyStart = start + std::string("<tool_call>").size();
        const size_t end = normalized.find("</tool_call>", bodyStart);
        if (end == std::string::npos) {
            error = "MiniCPM tool_call tag is missing </tool_call>.";
            return "";
        }
        if (!appendMiniCPMToolCall(normalized.substr(bodyStart, end - bodyStart), calls, needsComma, index, error)) {
            return "";
        }
        lastToolEnd = end + std::string("</tool_call>").size();
        cursor = lastToolEnd;
        index += 1;
    }
    calls << "]";

    if (needsComma) {
        std::string preamble;
        if (firstToolStart != std::string::npos) {
            preamble = trim(normalized.substr(0, firstToolStart));
        }
        std::string stepThinking = thinking.empty() ? preamble : thinking;
        if (stepThinking.empty()) {
            stepThinking = "tool call";
        }
        const std::string callsJson = calls.str();
        const std::vector<std::string> callItems = extractObjectArrayItems(callsJson);
        if (callItems.size() == 1) {
            std::map<std::string, JsonField> callFields;
            parseFieldsOrEmpty(callItems[0], callFields);
            const std::string toolName = stringField(callFields, "tool_name");
            const std::string parameters = rawField(callFields, "parameters", "{}");
            if (toolName == "ask_user") {
                std::map<std::string, JsonField> parameterFields;
                if (!parseFieldsOrEmpty(parameters, parameterFields)) {
                    error = "ask_user input must be a JSON object.";
                    return "";
                }
                return "{\"type\":\"ask_user\",\"thinking\":" + jsonString(stepThinking) +
                    ",\"questions\":" + rawField(parameterFields, "questions", "[]") +
                    ",\"reason\":" + jsonString(stringField(parameterFields, "reason")) +
                    ",\"sensitivity\":" + jsonString(stringField(parameterFields, "sensitivity", "normal")) +
                    ",\"timeout_seconds\":" + rawField(parameterFields, "timeout_seconds", rawField(parameterFields, "timeoutSeconds", "0")) +
                    ",\"allow_custom_answer\":" + rawField(parameterFields, "allow_custom_answer", "true") +
                    "}";
            }
            return "{\"type\":\"tool_use\",\"thinking\":" + jsonString(stepThinking) +
                ",\"tool_name\":" + jsonString(toolName) +
                ",\"parameters\":" + parameters +
                ",\"step_id\":" + jsonString(stringField(callFields, "call_id")) +
                "}";
        }
        return "{\"type\":\"multi_tool_use\",\"thinking\":" + jsonString(stepThinking) +
            ",\"tool_calls\":" + callsJson + "}";
    }

    if (!normalized.empty()) {
        return "{\"type\":\"result\",\"thinking\":" + jsonString(thinking.empty() ? "final answer" : thinking) +
            ",\"content\":" + jsonString(normalized) +
            ",\"completed\":true}";
    }

    error = "MiniCPM output is empty.";
    return "";
}

std::string normalizeReActStepText(const std::string &text, const std::string &dialect, std::string &error) {
    const std::string normalizedDialect = lowercased(trim(dialect).empty() ? "minicpm_v46_tool_calls" : dialect);
    if (normalizedDialect == "canonical_json") {
        error = "canonical_json is not a model-facing dialect; use LuminaReActExtractFirstStandardObject only for trusted provider adapters.";
        return "";
    }
    if (normalizedDialect == "lumina_code_content_blocks" || normalizedDialect == "provider_native_content_blocks") {
        error = "provider content blocks are not model-facing dialects; trusted providers must adapt them before runtime step validation.";
        return "";
    }
    if (normalizedDialect == "minicpm_v46_tool_calls" || normalizedDialect == "minicpm_v46_special_tokens") {
        std::string object = normalizeMiniCPMV46ToolCalls(text, error);
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
    if (normalizedDialect == "xml_tags") {
        error = "xml_tags is no longer a supported model-facing dialect; use MiniCPM-V4.6 special-token tool calls.";
        return "";
    }
    if (normalizedDialect == "provider_native_tool_call" || normalizedDialect == "custom_adapter") {
        error = "dialect requires caller-side adapter before runtime normalization.";
        return "";
    }
    error = "unsupported ReAct dialect: " + normalizedDialect;
    return "";
}

} // namespace LuminaAgent
