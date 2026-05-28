#include "ContextManager.hpp"

#include <algorithm>

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
    return compactIfNeeded(session_.requestJson(), contextJson, session_.stepsSummaryJson(), session_.lastObservationJson());
}

std::string ContextManager::compactIfNeeded(
    const std::string &requestJson,
    const std::string &contextJson,
    const std::string &progressJson,
    const std::string &lastObservationJson
) const {
    const std::string normalized = normalizeLoadedContext(contextJson);
    RuntimeSessionConfig config;
    config.isConfigured = true;
    config.maximumReActIterations = session_.maximumReActIterations();
    config.maximumToolCalls = session_.maximumToolCalls();
    config.contextWindowTokens = session_.contextWindowTokens();
    config.maxOutputTokens = session_.maxOutputTokens();
    config.reservedOutputTokens = session_.reservedOutputTokens();
    config.maximumObservationCharacters = session_.maximumObservationCharacters();
    config.toolResultTokenBudget = session_.toolResultTokenBudget();
    config.compactThresholdTokens = session_.compactThresholdTokens();
    config.maximumCompactFailures = session_.maximumCompactFailures();
    config.maximumConsecutiveReasoningSteps = session_.maximumConsecutiveReasoningSteps();
    const ContextBudgetSnapshot snapshot = ContextBudgetManager(config).snapshotFor(requestJson, normalized, progressJson, lastObservationJson);
    if (!snapshot.shouldCompact) {
        return normalized;
    }
    const int summaryLimit = session_.maximumObservationCharacters();
    return "{\"sections\":[],\"compact_summary\":\"context compacted because execution budget is near the configured context window\",\"used_tokens_estimate\":" +
        std::to_string(snapshot.usedTokens) +
        ",\"remaining_tokens_estimate\":" + std::to_string(snapshot.remainingTokens) +
        ",\"source_context\":" + jsonString(truncateToCharacters(normalized, summaryLimit)) + "}";
}

} // namespace LuminaAgent
