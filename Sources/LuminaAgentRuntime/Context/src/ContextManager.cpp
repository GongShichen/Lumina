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

std::string ContextManager::normalizeLoadedContext(const std::string &contextJson) const {
    if (trim(contextJson).empty() || trim(contextJson) == "null") {
        return "{\"sections\":[]}";
    }
    if (trim(contextJson).front() == '[') {
        return "{\"sections\":" + contextJson + "}";
    }
    return contextJson;
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
