#include "ContextManager.hpp"

#include "Json.hpp"

namespace LuminaAgent {

ContextManager::ContextManager(const RuntimeSession &session)
    : session_(session) {}

std::string ContextManager::initialRequestJson(const std::string &requestJson) const {
    return "{\"request\":" + (trim(requestJson).empty() ? "{}" : requestJson) +
        ",\"context_budget\":{\"remaining_tokens_estimate\":" +
        std::to_string(session_.remainingContextTokensEstimate()) +
        ",\"disclosure_level\":0}}";
}

std::string ContextManager::followUpRequestJson(const std::string &requestJson, const std::string &reasoningStepJson) const {
    return "{\"request\":" + (trim(requestJson).empty() ? "{}" : requestJson) +
        ",\"reasoning_step\":" + (trim(reasoningStepJson).empty() ? "{}" : reasoningStepJson) +
        ",\"context_budget\":{\"remaining_tokens_estimate\":" +
        std::to_string(session_.remainingContextTokensEstimate()) +
        ",\"disclosure_level\":1},"
        "\"request_more_context\":true}";
}

std::string ContextManager::normalizeLoadedContext(const std::string &contextJson) const {
    if (trim(contextJson).empty() || trim(contextJson) == "null") {
        return "{\"sections\":[]}";
    }
    if (trim(contextJson).front() == '[') {
        return "{\"sections\":" + contextJson + "}";
    }
    return contextJson;
}

std::string ContextManager::mergeContextJson(const std::string &currentContextJson, const std::string &additionalContextJson) const {
    const std::string current = normalizeLoadedContext(currentContextJson);
    const std::string additional = normalizeLoadedContext(additionalContextJson);

    std::map<std::string, JsonField> currentFields;
    std::map<std::string, JsonField> additionalFields;
    parseFieldsOrEmpty(current, currentFields);
    parseFieldsOrEmpty(additional, additionalFields);

    const std::vector<std::string> currentSections = extractObjectArrayItems(rawField(currentFields, "sections", "[]"));
    const std::vector<std::string> additionalSections = extractObjectArrayItems(rawField(additionalFields, "sections", "[]"));

    std::string sections = "[";
    bool wrote = false;
    for (const std::string &section : currentSections) {
        if (wrote) {
            sections += ",";
        }
        sections += section;
        wrote = true;
    }
    for (const std::string &section : additionalSections) {
        if (wrote) {
            sections += ",";
        }
        sections += section;
        wrote = true;
    }
    sections += "]";
    return "{\"sections\":" + sections + ",\"disclosure_level\":1}";
}

std::string ContextManager::compactIfNeeded(const std::string &contextJson) const {
    if (session_.remainingContextTokensEstimate() > 1200) {
        return normalizeLoadedContext(contextJson);
    }
    const std::string normalized = normalizeLoadedContext(contextJson);
    return "{\"sections\":[],\"compact_summary\":\"context omitted because execution budget is near the context window limit\",\"source_context\":" +
        jsonString(truncateToCharacters(normalized, 1600)) + "}";
}

} // namespace LuminaAgent
