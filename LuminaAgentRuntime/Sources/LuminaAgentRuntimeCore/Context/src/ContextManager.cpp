#include "ContextManager.hpp"

#include <algorithm>
#include <chrono>
#include <regex>
#include <sstream>

#include "Callbacks.hpp"
#include "Json.hpp"

namespace LuminaAgent {

ContextManager::ContextManager(RuntimeSession &session)
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

static std::string contextLoadingBudgetJson(const RuntimeSession &session) {
    return "{\"remaining_tokens_estimate\":" + std::to_string(session.remainingContextTokensEstimate()) +
        ",\"max_context_tokens\":" + std::to_string(session.maxContextTokens()) +
        ",\"reserved_output_tokens\":" + std::to_string(session.reservedOutputTokens()) +
        ",\"auto_compact_buffer_tokens\":" + std::to_string(session.autoCompactBufferTokens()) + "}";
}

static std::string requestTextForQuery(const std::string &requestJson) {
    std::map<std::string, JsonField> fields;
    if (!parseFieldsOrEmpty(requestJson, fields)) {
        return "";
    }
    return stringField(fields, "text", truncateToCharacters(requestJson, 800));
}

static std::string contextLoadingRequestJson(
    const RuntimeSession &session,
    const std::string &action,
    const std::string &requestJson,
    const std::string &query,
    const std::string &reasoningStepJson,
    const std::string &itemsJson = "[]"
) {
    return "{\"action\":" + jsonString(action) +
        ",\"session_id\":" + jsonString(session.sessionId()) +
        ",\"run_id\":" + jsonString(session.runId()) +
        ",\"request\":" + (trim(requestJson).empty() ? "{}" : requestJson) +
        ",\"query\":" + jsonString(query) +
        ",\"reasoning_step\":" + (trim(reasoningStepJson).empty() ? "null" : reasoningStepJson) +
        ",\"context_budget\":" + contextLoadingBudgetJson(session) +
        ",\"loaded_context_set\":" + session.loadedContextSetJson() +
        ",\"context_catalog_summary\":" + (trim(session.contextCatalogSummaryJson()).empty() ? "null" : session.contextCatalogSummaryJson()) +
        ",\"items\":" + (trim(itemsJson).empty() ? "[]" : itemsJson) +
        "}";
}

static bool parseContextLoadingResponse(const std::string &responseJson, std::map<std::string, JsonField> &fields) {
    if (!parseFieldsOrEmpty(responseJson, fields)) {
        return false;
    }
    const std::string status = lowercased(stringField(fields, "status", "ok"));
    return status.empty() || status == "ok" || status == "skipped";
}

static bool shouldFallbackContextLoadingResponse(const std::string &responseJson, const std::map<std::string, JsonField> &fields) {
    const std::string text = trim(responseJson);
    const std::string status = lowercased(stringField(fields, "status", ""));
    return text.empty() || text == "{}" || text == "null" || status == "skipped" || status == "failed";
}

static int recordContextSections(RuntimeSession &session, const std::string &sectionsJson) {
    int count = 0;
    for (const std::string &section : extractObjectArrayItems(sectionsJson)) {
        session.recordLoadedContextSection(section);
        count += 1;
    }
    return count;
}

static std::string contextContainerJson(
    RuntimeSession &session,
    const std::string &sectionsJson,
    int disclosureLevel
) {
    const std::string sections = trim(sectionsJson).empty() ? "[]" : sectionsJson;
    return "{\"sections\":" + sections +
        ",\"disclosure_level\":" + std::to_string(disclosureLevel) +
        ",\"loaded_context_set\":" + session.loadedContextSetJson() +
        ",\"context_catalog_summary\":" + (trim(session.contextCatalogSummaryJson()).empty() ? "null" : session.contextCatalogSummaryJson()) +
        "}";
}

static void emitContextLoadingEvent(
    RuntimeCallbacks &callbacks,
    const std::string &type,
    const RuntimeSession &session,
    const std::string &source,
    int loadedCount,
    const std::string &payloadJson
) {
    callbacks.emitEvent(
        type,
        "{\"source\":" + jsonString(source) +
            ",\"loaded_count\":" + std::to_string(std::max(0, loadedCount)) +
            ",\"tokens_estimate\":" + std::to_string(static_cast<int>(payloadJson.size() / 4)) +
            ",\"budget_snapshot\":" + contextLoadingBudgetJson(session) + "}"
    );
    callbacks.metric("runtime.context_loading.loaded_count", static_cast<double>(std::max(0, loadedCount)), "{\"event\":" + jsonString(type) + ",\"source\":" + jsonString(source) + "}");
}

std::string ContextManager::loadProgressiveInitialContext(const std::string &requestJson, RuntimeCallbacks &callbacks) const {
    const std::string catalogRequest = contextLoadingRequestJson(session_, "catalog", requestJson, requestTextForQuery(requestJson), "");
    const std::string catalogResponse = callbacks.callContextLoadingPlugin(catalogRequest);
    std::map<std::string, JsonField> fields;
    if (!parseContextLoadingResponse(catalogResponse, fields)) {
        callbacks.emitEvent("context_loading.load_failed", "{\"source\":\"context_loading_plugin\",\"action\":\"catalog\",\"reason\":\"invalid response\"}");
        return callbacks.hasContext() ? callbacks.loadContext(initialRequestJson(requestJson)) : "null";
    }
    if (shouldFallbackContextLoadingResponse(catalogResponse, fields)) {
        return callbacks.hasContext() ? callbacks.loadContext(initialRequestJson(requestJson)) : "null";
    }

    const std::string itemsJson = rawField(fields, "items", "[]");
    const std::string sectionsJson = rawField(fields, "sections", "[]");
    session_.setContextCatalogSummaryJson("{\"items\":" + itemsJson +
        ",\"next_cursor\":" + jsonString(stringField(fields, "next_cursor", stringField(fields, "nextCursor"))) + "}");
    const int loaded = recordContextSections(session_, sectionsJson);
    emitContextLoadingEvent(callbacks, "context_loading.catalog_emitted", session_, "context_loading_plugin", loaded, catalogResponse);
    if (loaded == 0) {
        return contextContainerJson(session_, "[]", 0);
    }
    return contextContainerJson(session_, sectionsJson, 0);
}

std::string ContextManager::loadProgressiveFollowUpContext(
    const std::string &requestJson,
    const std::string &reasoningStepJson,
    const std::string &currentContextJson,
    RuntimeCallbacks &callbacks
) const {
    std::map<std::string, JsonField> reasoningFields;
    parseFieldsOrEmpty(reasoningStepJson, reasoningFields);
    const std::string query = stringField(reasoningFields, "thinking", requestTextForQuery(requestJson));
    const std::string searchRequest = contextLoadingRequestJson(session_, "search", requestJson, query, reasoningStepJson);
    const std::string searchResponse = callbacks.callContextLoadingPlugin(searchRequest);
    std::map<std::string, JsonField> searchFields;
    if (!parseContextLoadingResponse(searchResponse, searchFields)) {
        callbacks.emitEvent("context_loading.load_failed", "{\"source\":\"context_loading_plugin\",\"action\":\"search\",\"reason\":\"invalid response\"}");
        return callbacks.hasContext() ? callbacks.loadContext(followUpRequestJson(requestJson, reasoningStepJson)) : "null";
    }
    if (shouldFallbackContextLoadingResponse(searchResponse, searchFields)) {
        return callbacks.hasContext() ? callbacks.loadContext(followUpRequestJson(requestJson, reasoningStepJson)) : "null";
    }

    emitContextLoadingEvent(callbacks, "context_loading.search", session_, "context_loading_plugin", 0, searchResponse);
    std::string sectionsJson = rawField(searchFields, "sections", "[]");
    int loaded = recordContextSections(session_, sectionsJson);
    if (loaded == 0) {
        const std::string itemsJson = rawField(searchFields, "items", "[]");
        if (!extractObjectArrayItems(itemsJson).empty()) {
            const std::string loadRequest = contextLoadingRequestJson(session_, "load", requestJson, query, reasoningStepJson, itemsJson);
            const std::string loadResponse = callbacks.callContextLoadingPlugin(loadRequest);
            std::map<std::string, JsonField> loadFields;
            if (parseContextLoadingResponse(loadResponse, loadFields)) {
                sectionsJson = rawField(loadFields, "sections", "[]");
                loaded = recordContextSections(session_, sectionsJson);
                emitContextLoadingEvent(callbacks, "context_loading.loaded", session_, "context_loading_plugin", loaded, loadResponse);
            } else {
                callbacks.emitEvent("context_loading.load_failed", "{\"source\":\"context_loading_plugin\",\"action\":\"load\",\"reason\":\"invalid response\"}");
            }
        }
    } else {
        emitContextLoadingEvent(callbacks, "context_loading.loaded", session_, "context_loading_plugin", loaded, searchResponse);
    }

    if (loaded == 0) {
        return callbacks.hasContext() ? callbacks.loadContext(followUpRequestJson(requestJson, reasoningStepJson)) : "null";
    }
    return mergeContextJson(currentContextJson, contextContainerJson(session_, sectionsJson, 1));
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

std::string ContextManager::compactIfNeeded(const std::string &contextJson, RuntimeCallbacks *callbacks, const std::string &trigger) const {
    return compactIfNeeded(session_.requestJson(), contextJson, session_.stepsSummaryJson(), session_.lastObservationJson(), callbacks, trigger);
}

static std::string budgetSnapshotJson(const ContextBudgetSnapshot &snapshot) {
    std::ostringstream output;
    output << "{"
           << "\"used_tokens\":" << snapshot.usedTokens << ","
           << "\"remaining_tokens\":" << snapshot.remainingTokens << ","
           << "\"max_context_tokens\":" << snapshot.maxContextTokens << ","
           << "\"effective_context_window\":" << snapshot.effectiveContextWindowTokens << ","
           << "\"auto_compact_threshold_tokens\":" << snapshot.autoCompactThresholdTokens << ","
           << "\"auto_compact_buffer_tokens\":" << snapshot.autoCompactBufferTokens << ","
           << "\"warning_buffer_tokens\":" << snapshot.warningBufferTokens << ","
           << "\"should_compact\":" << jsonBool(snapshot.shouldCompact) << ","
           << "\"over_window\":" << jsonBool(snapshot.overWindow) << ","
           << "\"warning\":" << jsonBool(snapshot.warning)
           << "}";
    return output.str();
}

static bool sectionIsSnipped(const std::string &sectionJson) {
    std::map<std::string, JsonField> fields;
    if (!parseFieldsOrEmpty(sectionJson, fields)) {
        return false;
    }
    return boolField(fields, "snipped", false) ||
        boolField(fields, "hidden", false) ||
        boolField(fields, "excluded", false) ||
        boolField(fields, "model_visible", true) == false ||
        boolField(fields, "modelVisible", true) == false;
}

static std::string redactSensitiveText(const std::string &text) {
    std::string redacted = text;
    const std::vector<std::regex> keyPatterns = {
        std::regex(R"REGEX(("(?:api[_-]?key|apikey|secret|token|access[_-]?token|refresh[_-]?token|password|authorization)"\s*:\s*")[^"]*("))REGEX", std::regex::icase),
        std::regex(R"REGEX((Bearer\s+)[A-Za-z0-9._~+/=-]{12,})REGEX", std::regex::icase),
        std::regex(R"REGEX((sk-[A-Za-z0-9_-]{12,}))REGEX", std::regex::icase)
    };
    redacted = std::regex_replace(redacted, keyPatterns[0], "$1[REDACTED]$2");
    redacted = std::regex_replace(redacted, keyPatterns[1], "$1[REDACTED]");
    redacted = std::regex_replace(redacted, keyPatterns[2], "[REDACTED]");
    return redacted;
}

static std::string applySnipProjection(const std::string &contextJson, int &removedCount) {
    removedCount = 0;
    std::map<std::string, JsonField> fields;
    if (!parseFieldsOrEmpty(contextJson, fields)) {
        return contextJson;
    }
    const std::vector<std::string> sections = extractObjectArrayItems(rawField(fields, "sections", "[]"));
    if (sections.empty()) {
        return contextJson;
    }
    std::ostringstream output;
    output << "{\"sections\":[";
    bool wrote = false;
    for (const std::string &section : sections) {
        if (sectionIsSnipped(section)) {
            removedCount += 1;
            continue;
        }
        if (wrote) {
            output << ",";
        }
        output << section;
        wrote = true;
    }
    output << "]";
    const std::string disclosure = rawField(fields, "disclosure_level", "");
    if (!disclosure.empty()) {
        output << ",\"disclosure_level\":" << disclosure;
    }
    output << "}";
    return output.str();
}

static std::string stringFieldOrRawExcerpt(const std::map<std::string, JsonField> &fields, const std::string &key, int limit) {
    const auto it = fields.find(key);
    if (it == fields.end()) {
        return "";
    }
    if (it->second.kind == JsonKind::string) {
        return truncateToCharacters(it->second.stringValue, limit);
    }
    return truncateToCharacters(it->second.raw, limit);
}

static std::string compactSectionSummary(const std::string &sectionJson, int limit) {
    std::map<std::string, JsonField> fields;
    if (!parseFieldsOrEmpty(sectionJson, fields)) {
        return truncateToCharacters(sectionJson, limit);
    }
    for (const std::string &key : {"summary", "content", "text", "result", "observation"}) {
        const std::string value = stringFieldOrRawExcerpt(fields, key, limit);
        if (!value.empty()) {
            return value;
        }
    }
    return truncateToCharacters(sectionJson, limit);
}

static std::string microcompactedSection(const std::string &sectionJson, int summaryLimit) {
    std::map<std::string, JsonField> fields;
    parseFieldsOrEmpty(sectionJson, fields);
    std::ostringstream output;
    output << "{"
           << "\"microcompacted\":true,"
           << "\"original_characters\":" << sectionJson.size() << ","
           << "\"id\":" << jsonString(stringField(fields, "id", stringField(fields, "call_id", stringField(fields, "tool_call_id")))) << ","
           << "\"title\":" << jsonString(stringField(fields, "title", stringField(fields, "tool_name", "Compacted context section"))) << ","
           << "\"type\":" << jsonString(stringField(fields, "type", stringField(fields, "kind", "context_section"))) << ","
           << "\"tool_name\":" << jsonString(stringField(fields, "tool_name", stringField(fields, "toolName"))) << ","
           << "\"status\":" << jsonString(stringField(fields, "status")) << ","
           << "\"summary\":" << jsonString(redactSensitiveText(compactSectionSummary(sectionJson, summaryLimit))) << ","
           << "\"compaction_reason\":\"large historical context section\""
           << "}";
    return output.str();
}

static std::string applyMicrocompact(
    const std::string &contextJson,
    const RuntimeSession &session,
    const ContextBudgetSnapshot &snapshot,
    int &compactedSections,
    int &tokensSavedEstimate
) {
    compactedSections = 0;
    tokensSavedEstimate = 0;
    std::map<std::string, JsonField> fields;
    if (!parseFieldsOrEmpty(contextJson, fields)) {
        return contextJson;
    }
    const std::vector<std::string> sections = extractObjectArrayItems(rawField(fields, "sections", "[]"));
    if (sections.empty()) {
        return contextJson;
    }
    const int preserveTail = 4;
    const int largeSectionCharacters = std::max(800, session.toolResultTokenBudget() * 4);
    const int summaryLimit = std::max(160, session.maximumObservationCharacters() / 2);
    std::ostringstream output;
    output << "{\"sections\":[";
    bool wrote = false;
    bool redactedChanged = false;
    for (size_t index = 0; index < sections.size(); index++) {
        const bool preserveRecent = index + static_cast<size_t>(preserveTail) >= sections.size();
        const std::string redactedSection = redactSensitiveText(sections[index]);
        redactedChanged = redactedChanged || redactedSection != sections[index];
        std::string next = redactedSection;
        if (!preserveRecent && static_cast<int>(sections[index].size()) > largeSectionCharacters) {
            next = microcompactedSection(sections[index], summaryLimit);
            compactedSections += 1;
            tokensSavedEstimate += std::max(0, static_cast<int>((sections[index].size() - next.size()) / 4));
        }
        if (wrote) {
            output << ",";
        }
        output << next;
        wrote = true;
    }
    output << "]";
    const std::string disclosure = rawField(fields, "disclosure_level", "");
    if (!disclosure.empty()) {
        output << ",\"disclosure_level\":" << disclosure;
    }
    const std::string compactSummary = stringField(fields, "compact_summary");
    if (!compactSummary.empty()) {
        output << ",\"compact_summary\":" << jsonString(redactSensitiveText(compactSummary));
    }
    output << "}";
    if (compactedSections == 0 && !redactedChanged) {
        return contextJson;
    }
    return output.str();
}

static std::string compactionRequestJson(
    const RuntimeSession &session,
    const std::string &trigger,
    const std::string &strategy,
    const std::string &requestJson,
    const std::string &contextJson,
    const std::string &progressJson,
    const std::string &lastObservationJson,
    const ContextBudgetSnapshot &snapshot
) {
    return "{\"session_id\":" + jsonString(session.sessionId()) +
        ",\"run_id\":" + jsonString(session.runId()) +
        ",\"trigger\":" + jsonString(trigger) +
        ",\"strategy\":" + jsonString(strategy) +
        ",\"model_id\":" + jsonString(session.modelId()) + "," +
        "\"max_context_tokens\":" + std::to_string(snapshot.maxContextTokens) + "," +
        "\"effective_context_window\":" + std::to_string(snapshot.effectiveContextWindowTokens) + "," +
        "\"budget_snapshot\":" + budgetSnapshotJson(snapshot) + "," +
        "\"provider_native_context_management\":" + jsonBool(session.providerNativeContextManagement()) + "," +
        "\"context_frame\":{\"request\":" + redactSensitiveText(trim(requestJson).empty() ? "{}" : requestJson) +
        ",\"context\":" + redactSensitiveText(trim(contextJson).empty() ? "{}" : contextJson) +
        ",\"trace_summary\":" + redactSensitiveText(trim(progressJson).empty() ? "[]" : progressJson) +
        ",\"last_observation\":" + redactSensitiveText(trim(lastObservationJson).empty() ? "null" : lastObservationJson) + "}," +
        "\"trace_summary\":" + redactSensitiveText(trim(progressJson).empty() ? "[]" : progressJson) + "," +
        "\"tool_result_candidates\":" + redactSensitiveText(session.toolResultCandidatesJson(8, session.toolResultTokenBudget() * 4)) +
        "}";
}

static std::string deterministicSummaryContext(
    const RuntimeSession &session,
    const std::string &normalized,
    const ContextBudgetSnapshot &snapshot
) {
    const int summaryLimit = session.maximumObservationCharacters();
    return "{\"sections\":[],\"compact_summary\":\"context compacted because execution budget is near the provider context window\",\"used_tokens_estimate\":" +
        std::to_string(snapshot.usedTokens) +
        ",\"remaining_tokens_estimate\":" + std::to_string(snapshot.remainingTokens) +
        ",\"max_context_tokens\":" + std::to_string(snapshot.maxContextTokens) +
        ",\"effective_context_window\":" + std::to_string(snapshot.effectiveContextWindowTokens) +
        ",\"auto_compact_threshold_tokens\":" + std::to_string(snapshot.autoCompactThresholdTokens) +
        ",\"source_context\":" + jsonString(redactSensitiveText(truncateToCharacters(normalized, summaryLimit))) + "}";
}

std::string ContextManager::compactIfNeeded(
    const std::string &requestJson,
    const std::string &contextJson,
    const std::string &progressJson,
    const std::string &lastObservationJson,
    RuntimeCallbacks *callbacks,
    const std::string &trigger
) const {
    const auto startedAt = std::chrono::steady_clock::now();
    std::string normalized = normalizeLoadedContext(contextJson);
    RuntimeSessionConfig config;
    config.isConfigured = true;
    config.maximumReActIterations = session_.maximumReActIterations();
    config.maximumToolCalls = session_.maximumToolCalls();
    config.contextWindowTokens = session_.contextWindowTokens();
    config.maxContextTokens = session_.maxContextTokens();
    config.maxOutputTokens = session_.maxOutputTokens();
    config.reservedOutputTokens = session_.reservedOutputTokens();
    config.autoCompactBufferTokens = session_.autoCompactBufferTokens();
    config.warningBufferTokens = session_.warningBufferTokens();
    config.maximumObservationCharacters = session_.maximumObservationCharacters();
    config.toolResultTokenBudget = session_.toolResultTokenBudget();
    config.compactThresholdTokens = session_.compactThresholdTokens();
    config.maximumCompactFailures = session_.maximumCompactFailures();
    config.maximumConsecutiveReasoningSteps = session_.maximumConsecutiveReasoningSteps();
    ContextBudgetSnapshot snapshot = ContextBudgetManager(config).snapshotFor(requestJson, normalized, progressJson, lastObservationJson);

    int snippedSections = 0;
    std::string projected = applySnipProjection(normalized, snippedSections);
    if (snippedSections > 0) {
        normalized = projected;
        snapshot = ContextBudgetManager(config).snapshotFor(requestJson, normalized, progressJson, lastObservationJson);
        if (callbacks != nullptr) {
            callbacks->emitEvent(
                "runtime.context.compaction.completed",
                "{\"trigger\":" + jsonString(trigger) +
                    ",\"strategy\":\"snip_projection\",\"removed_sections\":" + std::to_string(snippedSections) +
                    ",\"budget_snapshot\":" + budgetSnapshotJson(snapshot) + "}"
            );
        }
    }

    const bool reactive = lowercased(trigger) == "reactive";
    if (!reactive && !snapshot.shouldCompact && !snapshot.warning) {
        return normalized;
    }

    const std::vector<std::string> strategies = {
        "microcompact",
        "provider_native",
        (snapshot.shouldCompact || reactive) ? "summarizing_compact" : "partial_summarize"
    };
    for (const std::string &strategy : strategies) {
        if (strategy == "provider_native" && !session_.providerNativeContextManagement()) {
            if (callbacks != nullptr) {
                callbacks->emitEvent(
                    "runtime.context.compaction.skipped",
                    "{\"trigger\":" + jsonString(trigger) +
                        ",\"strategy\":\"provider_native\",\"reason\":\"provider metadata did not declare native context management\"}"
                );
            }
            continue;
        }
        const std::string request = compactionRequestJson(session_, trigger, strategy, requestJson, normalized, progressJson, lastObservationJson, snapshot);
        if (callbacks != nullptr) {
            callbacks->emitEvent("runtime.context.compaction.started", "{\"request\":" + request + "}");
            const RuntimeCompactionDecision decision = callbacks->compactContext(request);
            if (decision.status == "compacted" && !trim(decision.compactedContextJson).empty()) {
                session_.resetCompactFailures();
                session_.appendTrace(
                    "context_compacted",
                    "{\"trigger\":" + jsonString(trigger) +
                        ",\"strategy\":" + jsonString(strategy) +
                        ",\"boundary\":" + (trim(decision.boundaryJson).empty() ? "null" : decision.boundaryJson) +
                        ",\"tokens_saved_estimate\":" + std::to_string(decision.tokensSavedEstimate) + "}"
                );
                const auto elapsedMs = std::chrono::duration_cast<std::chrono::milliseconds>(
                    std::chrono::steady_clock::now() - startedAt
                ).count();
                callbacks->metric(
                    "runtime.context.compaction.duration_ms",
                    static_cast<double>(elapsedMs),
                    "{\"strategy\":" + jsonString(strategy) + ",\"trigger\":" + jsonString(trigger) + "}"
                );
                callbacks->metric(
                    "runtime.context.compaction.tokens_saved_estimate",
                    static_cast<double>(decision.tokensSavedEstimate),
                    "{\"strategy\":" + jsonString(strategy) + ",\"trigger\":" + jsonString(trigger) + "}"
                );
                callbacks->emitEvent(
                    "runtime.context.compaction.completed",
                    "{\"trigger\":" + jsonString(trigger) +
                        ",\"strategy\":" + jsonString(strategy) +
                        ",\"tokens_saved_estimate\":" + std::to_string(decision.tokensSavedEstimate) +
                        ",\"budget_snapshot\":" + budgetSnapshotJson(snapshot) + "}"
                );
                return normalizeLoadedContext(decision.compactedContextJson);
            }
            if (decision.status == "failed") {
                session_.recordCompactFailure();
                callbacks->emitEvent(
                    "runtime.context.compaction.failed",
                    "{\"trigger\":" + jsonString(trigger) +
                        ",\"strategy\":" + jsonString(strategy) +
                        ",\"reason\":" + jsonString(decision.failureReason) + "}"
                );
                if (!ContextBudgetManager(config).canAttemptCompact(session_.compactFailureCount())) {
                    return normalized;
                }
            } else {
                callbacks->emitEvent(
                    "runtime.context.compaction.skipped",
                    "{\"trigger\":" + jsonString(trigger) +
                    ",\"strategy\":" + jsonString(strategy) + "}"
                );
            }
        }
        if (strategy == "microcompact") {
            int compactedSections = 0;
            int tokensSavedEstimate = 0;
            const std::string microcompacted = applyMicrocompact(normalized, session_, snapshot, compactedSections, tokensSavedEstimate);
            if (microcompacted != normalized) {
                normalized = microcompacted;
                snapshot = ContextBudgetManager(config).snapshotFor(requestJson, normalized, progressJson, lastObservationJson);
                session_.appendTrace(
                    "context_compacted",
                    "{\"trigger\":" + jsonString(trigger) +
                        ",\"strategy\":\"microcompact\",\"compacted_sections\":" + std::to_string(compactedSections) +
                        ",\"tokens_saved_estimate\":" + std::to_string(tokensSavedEstimate) + "}"
                );
                if (callbacks != nullptr) {
                    callbacks->metric("runtime.context.compaction.count", 1, "{\"strategy\":\"microcompact\",\"source\":\"default\"}");
                    callbacks->metric("runtime.context.compaction.tokens_saved_estimate", static_cast<double>(tokensSavedEstimate), "{\"strategy\":\"microcompact\",\"source\":\"default\"}");
                    callbacks->emitEvent(
                        "runtime.context.compaction.completed",
                        "{\"trigger\":" + jsonString(trigger) +
                            ",\"strategy\":\"microcompact\",\"source\":\"default\",\"compacted_sections\":" + std::to_string(compactedSections) +
                            ",\"tokens_saved_estimate\":" + std::to_string(tokensSavedEstimate) +
                            ",\"budget_snapshot\":" + budgetSnapshotJson(snapshot) + "}"
                    );
                }
                if (!snapshot.shouldCompact && !snapshot.warning) {
                    return normalized;
                }
            }
        }
    }

    if (!snapshot.shouldCompact && !reactive) {
        return normalized;
    }
    session_.resetCompactFailures();
    const std::string compacted = deterministicSummaryContext(session_, normalized, snapshot);
    if (callbacks != nullptr) {
        callbacks->emitEvent(
            "runtime.context.compaction.completed",
            "{\"trigger\":" + jsonString(trigger) +
                ",\"strategy\":\"summarizing_compact\",\"source\":\"default\",\"budget_snapshot\":" + budgetSnapshotJson(snapshot) + "}"
        );
        callbacks->metric("runtime.context.compaction.count", 1, "{\"strategy\":\"summarizing_compact\",\"source\":\"default\"}");
    }
    session_.appendTrace(
        "context_compacted",
        "{\"trigger\":" + jsonString(trigger) +
            ",\"strategy\":\"summarizing_compact\",\"boundary\":{\"type\":\"compact_boundary\",\"trigger\":" + jsonString(trigger) +
            ",\"pre_tokens\":" + std::to_string(snapshot.usedTokens) + "}}"
    );
    return compacted;
}

} // namespace LuminaAgent
