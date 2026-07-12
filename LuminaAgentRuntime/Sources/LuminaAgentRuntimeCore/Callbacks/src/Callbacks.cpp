#include "Callbacks.hpp"

#include <algorithm>
#include <chrono>
#include <iterator>
#include <sstream>
#include <set>
#include <cctype>

#include "Json.hpp"

namespace LuminaAgent {

static long long timestampMilliseconds() {
    const auto now = std::chrono::system_clock::now().time_since_epoch();
    return std::chrono::duration_cast<std::chrono::milliseconds>(now).count();
}

static bool isSensitiveHistoryKey(const std::string &key) {
    const std::string normalized = lowercased(key);
    return normalized == "api_key" ||
        normalized == "apikey" ||
        normalized == "token" ||
        normalized == "secret" ||
        normalized == "password" ||
        normalized == "authorization" ||
        normalized.find("api_key") != std::string::npos ||
        normalized.find("apikey") != std::string::npos ||
        normalized.find("token") != std::string::npos ||
        normalized.find("secret") != std::string::npos ||
        normalized.find("password") != std::string::npos ||
        normalized.find("authorization") != std::string::npos;
}

static std::vector<std::string> splitTopLevelArrayValues(const std::string &arrayJson) {
    std::vector<std::string> values;
    const std::string text = trim(arrayJson);
    if (text.size() < 2 || text.front() != '[' || text.back() != ']') {
        return values;
    }
    size_t start = 1;
    int objectDepth = 0;
    int arrayDepth = 0;
    bool insideString = false;
    bool escaped = false;
    for (size_t index = 1; index + 1 < text.size(); index++) {
        const char c = text[index];
        if (insideString) {
            if (escaped) {
                escaped = false;
            } else if (c == '\\') {
                escaped = true;
            } else if (c == '"') {
                insideString = false;
            }
            continue;
        }
        if (c == '"') {
            insideString = true;
            continue;
        }
        if (c == '{') {
            objectDepth++;
        } else if (c == '}') {
            objectDepth--;
        } else if (c == '[') {
            arrayDepth++;
        } else if (c == ']') {
            arrayDepth--;
        } else if (c == ',' && objectDepth == 0 && arrayDepth == 0) {
            values.push_back(text.substr(start, index - start));
            start = index + 1;
        }
    }
    const std::string tail = trim(text.substr(start, text.size() - start - 1));
    if (!tail.empty()) {
        values.push_back(tail);
    }
    return values;
}

static std::string redactHistoryJsonValue(const std::string &json);

static std::string redactHistoryObject(const std::map<std::string, JsonField> &fields) {
    std::string output = "{";
    bool first = true;
    for (const auto &entry : fields) {
        if (!first) {
            output += ",";
        }
        first = false;
        output += jsonString(entry.first) + ":";
        output += isSensitiveHistoryKey(entry.first)
            ? jsonString("[redacted]")
            : redactHistoryJsonValue(entry.second.raw);
    }
    output += "}";
    return output;
}

static std::string redactHistoryJsonValue(const std::string &json) {
    const std::string text = trim(json);
    if (text.empty()) {
        return "{}";
    }
    if (text.front() == '{') {
        std::map<std::string, JsonField> fields;
        if (parseFieldsOrEmpty(text, fields)) {
            return redactHistoryObject(fields);
        }
        return "{}";
    }
    if (text.front() == '[') {
        const std::vector<std::string> values = splitTopLevelArrayValues(text);
        std::string output = "[";
        for (size_t index = 0; index < values.size(); index++) {
            if (index > 0) {
                output += ",";
            }
            output += redactHistoryJsonValue(values[index]);
        }
        output += "]";
        return output;
    }
    return text;
}

void RuntimeCallbacks::setModel(LuminaAgentModelCallback callback, void *context) {
    model_ = {reinterpret_cast<void *>(callback), context};
}

void RuntimeCallbacks::setStreamingModel(LuminaAgentStreamingModelCallback callback, void *context) {
    streamingModel_ = {reinterpret_cast<void *>(callback), context};
}

void RuntimeCallbacks::setModelMetadata(LuminaAgentModelMetadataCallback callback, void *context) {
    modelMetadata_ = {reinterpret_cast<void *>(callback), context};
}

void RuntimeCallbacks::setTool(LuminaAgentToolCallback callback, void *context) {
    tool_ = {reinterpret_cast<void *>(callback), context};
}

void RuntimeCallbacks::setContext(LuminaAgentContextCallback callback, void *context) {
    context_ = {reinterpret_cast<void *>(callback), context};
}

void RuntimeCallbacks::setContextLoadingPlugin(LuminaAgentContextLoadingPluginCallback callback, void *context) {
    contextLoadingPlugin_ = {reinterpret_cast<void *>(callback), context};
}

void RuntimeCallbacks::setPermission(LuminaAgentPermissionCallback callback, void *context) {
    permission_ = {reinterpret_cast<void *>(callback), context};
}

void RuntimeCallbacks::setConfirmation(LuminaAgentConfirmationCallback callback, void *context) {
    confirmation_ = {reinterpret_cast<void *>(callback), context};
}

void RuntimeCallbacks::setGuardrail(LuminaAgentGuardrailCallback callback, void *context) {
    guardrail_ = {reinterpret_cast<void *>(callback), context};
}

void RuntimeCallbacks::setRetryProvider(LuminaAgentRetryProviderCallback callback, void *context) {
    retryProvider_ = {reinterpret_cast<void *>(callback), context};
}

void RuntimeCallbacks::setCompactionProvider(LuminaAgentCompactionProviderCallback callback, void *context) {
    compactionProvider_ = {reinterpret_cast<void *>(callback), context};
}

void RuntimeCallbacks::setToolLoadingPlugin(LuminaAgentToolLoadingPluginCallback callback, void *context) {
    toolLoadingPlugin_ = {reinterpret_cast<void *>(callback), context};
}

void RuntimeCallbacks::setAudit(LuminaAgentAuditCallback callback, void *context) {
    audit_ = {reinterpret_cast<void *>(callback), context};
}

void RuntimeCallbacks::setTrace(LuminaAgentTraceCallback callback, void *context) {
    trace_ = {reinterpret_cast<void *>(callback), context};
}

void RuntimeCallbacks::setMetrics(LuminaAgentMetricsCallback callback, void *context) {
    metrics_ = {reinterpret_cast<void *>(callback), context};
}

void RuntimeCallbacks::setSpan(LuminaAgentSpanCallback callback, void *context) {
    span_ = {reinterpret_cast<void *>(callback), context};
}

void RuntimeCallbacks::setSessionHistory(LuminaAgentSessionHistoryCallback callback, void *context) {
    sessionHistory_ = {reinterpret_cast<void *>(callback), context};
}

void RuntimeCallbacks::setRollback(LuminaAgentRollbackCallback callback, void *context) {
    rollback_ = {reinterpret_cast<void *>(callback), context};
}

void RuntimeCallbacks::setEvent(LuminaAgentEventCallback callback, void *context) {
    event_ = {reinterpret_cast<void *>(callback), context};
}

void RuntimeCallbacks::setHook(LuminaAgentHookCallback callback, void *context) {
    hook_ = {reinterpret_cast<void *>(callback), context};
}

void RuntimeCallbacks::setCorrelationContext(const std::string &sessionId, const std::string &runId) {
    currentSessionId_ = sessionId;
    currentRunId_ = runId;
    telemetrySequence_ = 0;
    historySequence_ = 0;
    spanStack_.clear();
}

void RuntimeCallbacks::clearCorrelationContext() {
    currentSessionId_.clear();
    currentRunId_.clear();
    telemetrySequence_ = 0;
    spanStack_.clear();
}

bool RuntimeCallbacks::hasModel() const { return model_.function != nullptr; }
bool RuntimeCallbacks::hasStreamingModel() const { return streamingModel_.function != nullptr; }
bool RuntimeCallbacks::hasModelMetadata() const { return modelMetadata_.function != nullptr; }
bool RuntimeCallbacks::hasTool() const { return tool_.function != nullptr; }
bool RuntimeCallbacks::hasContext() const { return context_.function != nullptr; }
bool RuntimeCallbacks::hasContextLoadingPlugin() const { return contextLoadingPlugin_.function != nullptr; }
bool RuntimeCallbacks::hasPermission() const { return permission_.function != nullptr; }
bool RuntimeCallbacks::hasConfirmation() const { return confirmation_.function != nullptr; }
bool RuntimeCallbacks::hasGuardrail() const { return guardrail_.function != nullptr; }
bool RuntimeCallbacks::hasRetryProvider() const { return retryProvider_.function != nullptr; }
bool RuntimeCallbacks::hasCompactionProvider() const { return compactionProvider_.function != nullptr; }
bool RuntimeCallbacks::hasToolLoadingPlugin() const { return toolLoadingPlugin_.function != nullptr; }
bool RuntimeCallbacks::hasHook() const { return hook_.function != nullptr; }
bool RuntimeCallbacks::hasTrace() const { return trace_.function != nullptr; }
bool RuntimeCallbacks::hasMetrics() const { return metrics_.function != nullptr; }
bool RuntimeCallbacks::hasSpan() const { return span_.function != nullptr; }
bool RuntimeCallbacks::hasSessionHistory() const { return sessionHistory_.function != nullptr; }

std::string RuntimeCallbacks::callModel(const std::string &plannerInput) const {
    auto callback = reinterpret_cast<LuminaAgentModelCallback>(model_.function);
    return callback == nullptr ? "" : consumeCString(callback(plannerInput.c_str(), model_.context));
}

std::string RuntimeCallbacks::loadModelMetadata(const std::string &metadataRequestJson) const {
    auto callback = reinterpret_cast<LuminaAgentModelMetadataCallback>(modelMetadata_.function);
    return callback == nullptr ? "" : consumeCString(callback((trim(metadataRequestJson).empty() ? "{}" : metadataRequestJson).c_str(), modelMetadata_.context));
}

struct StreamingEmissionState {
    const RuntimeCallbacks *callbacks = nullptr;
    std::chrono::steady_clock::time_point startedAt;
    bool sawFirstToken = false;
    int outputTokenCount = 0;
    long long timeToFirstTokenMilliseconds = -1;
    long long chunkCount = 0;
    bool streamContainsSpecialTokens = false;
};

static bool emitStreamingModelChunk(const char *chunkJson, void *context) {
    auto state = static_cast<StreamingEmissionState *>(context);
    if (state != nullptr && state->callbacks != nullptr && chunkJson != nullptr) {
        state->chunkCount += 1;
        const std::string chunkText(chunkJson);
        if (chunkText.find("<think") != std::string::npos || chunkText.find("<tool_call") != std::string::npos || chunkText.find("<function=") != std::string::npos) {
            state->streamContainsSpecialTokens = true;
        }
        std::map<std::string, JsonField> fields;
        if (parseFieldsOrEmpty(chunkText, fields)) {
            if (fields.find("tokenCount") != fields.end()) {
                state->outputTokenCount += std::max(0, intField(fields, "tokenCount", 0));
            } else if (fields.find("outputTokens") != fields.end()) {
                state->outputTokenCount = std::max(state->outputTokenCount, intField(fields, "outputTokens", 0));
            }
        }
        if (!state->sawFirstToken) {
            state->sawFirstToken = true;
            state->timeToFirstTokenMilliseconds = std::chrono::duration_cast<std::chrono::milliseconds>(
                std::chrono::steady_clock::now() - state->startedAt
            ).count();
        }
        state->callbacks->emitEvent("model_generation_delta", chunkJson);
    }
    return true;
}

std::string RuntimeCallbacks::callStreamingModel(const std::string &plannerInput) const {
    return callStreamingModelWithMetrics(plannerInput).text;
}

StreamingModelResult RuntimeCallbacks::callStreamingModelWithMetrics(const std::string &plannerInput) const {
    auto callback = reinterpret_cast<LuminaAgentStreamingModelCallback>(streamingModel_.function);
    if (callback == nullptr) {
        const std::string text = callModel(plannerInput);
        return StreamingModelResult{
            text,
            static_cast<int>(std::max<size_t>(1, text.size() / 4)),
            -1,
            text.empty() ? 0 : 1,
            text.find("<think") != std::string::npos || text.find("<tool_call") != std::string::npos || text.find("<function=") != std::string::npos
        };
    }
    StreamingEmissionState state{
        this,
        std::chrono::steady_clock::now(),
        false,
        0,
        -1,
        0,
        false
    };
    const std::string text = consumeCString(callback(
        plannerInput.c_str(),
        emitStreamingModelChunk,
        &state,
        streamingModel_.context
    ));
    return StreamingModelResult{
        text,
        state.outputTokenCount > 0 ? state.outputTokenCount : static_cast<int>(std::max<size_t>(1, text.size() / 4)),
        state.timeToFirstTokenMilliseconds,
        state.chunkCount,
        state.streamContainsSpecialTokens || text.find("<think") != std::string::npos || text.find("<tool_call") != std::string::npos || text.find("<function=") != std::string::npos
    };
}

std::string RuntimeCallbacks::callTool(const std::string &toolCall) const {
    auto callback = reinterpret_cast<LuminaAgentToolCallback>(tool_.function);
    return callback == nullptr ? "" : consumeCString(callback(toolCall.c_str(), tool_.context));
}

std::string RuntimeCallbacks::loadContext(const std::string &contextRequest) const {
    auto callback = reinterpret_cast<LuminaAgentContextCallback>(context_.function);
    return callback == nullptr ? "" : consumeCString(callback(contextRequest.c_str(), context_.context));
}

std::string RuntimeCallbacks::callContextLoadingPlugin(const std::string &requestJson) const {
    auto callback = reinterpret_cast<LuminaAgentContextLoadingPluginCallback>(contextLoadingPlugin_.function);
    return callback == nullptr ? "" : consumeCString(callback((trim(requestJson).empty() ? "{}" : requestJson).c_str(), contextLoadingPlugin_.context));
}

std::string RuntimeCallbacks::decidePermission(const std::string &permissionRequest) const {
    auto callback = reinterpret_cast<LuminaAgentPermissionCallback>(permission_.function);
    return callback == nullptr ? "" : consumeCString(callback(permissionRequest.c_str(), permission_.context));
}

std::string RuntimeCallbacks::confirm(const std::string &confirmationRequest) const {
    auto callback = reinterpret_cast<LuminaAgentConfirmationCallback>(confirmation_.function);
    return callback == nullptr ? "" : consumeCString(callback(confirmationRequest.c_str(), confirmation_.context));
}

static RuntimeGuardrailDecision parseGuardrailDecision(const std::string &decisionJson) {
    RuntimeGuardrailDecision decision;
    const std::string text = trim(decisionJson);
    if (text.empty() || text == "{}" || text == "null") {
        return decision;
    }
    std::map<std::string, JsonField> fields;
    if (!parseFieldsOrEmpty(text, fields)) {
        decision.decision = "reject";
        decision.message = "guardrail returned invalid JSON";
        return decision;
    }
    decision.decision = lowercased(stringField(fields, "decision", stringField(fields, "type", "allow")));
    if (decision.decision == "allowed") {
        decision.decision = "allow";
    } else if (decision.decision == "denied") {
        decision.decision = "reject";
    } else if (decision.decision == "tripwire" || decision.decision == "fail") {
        decision.decision = "tripwire_failure";
    }
    decision.message = stringField(fields, "message", stringField(fields, "reason"));
    decision.payloadJson = rawField(fields, "payload", rawField(fields, "value", ""));
    return decision;
}

RuntimeGuardrailDecision RuntimeCallbacks::evaluateGuardrail(const std::string &stage, const std::string &payloadJson) const {
    auto callback = reinterpret_cast<LuminaAgentGuardrailCallback>(guardrail_.function);
    if (callback == nullptr) {
        return RuntimeGuardrailDecision{};
    }
    const std::string request = "{\"stage\":" + jsonString(stage) +
        ",\"payload\":" + (trim(payloadJson).empty() ? "{}" : payloadJson) + "}";
    return parseGuardrailDecision(consumeCString(callback(request.c_str(), guardrail_.context)));
}

static bool retryableCode(const std::string &code) {
    const std::string value = lowercased(code);
    return value == "408" ||
        value == "409" ||
        value == "429" ||
        value == "500" ||
        value == "502" ||
        value == "503" ||
        value == "504" ||
        value == "timeout" ||
        value == "timed_out" ||
        value == "network_interruption" ||
        value == "network_connection_lost" ||
        value == "transport";
}

static bool nonRetryableCode(const std::string &code) {
    const std::string value = lowercased(code);
    return value == "400" ||
        value == "401" ||
        value == "403" ||
        value == "404" ||
        value == "configuration" ||
        value == "schema" ||
        value == "validation" ||
        value == "authorization" ||
        value == "authentication";
}

static bool retryableCategory(const std::string &category) {
    const std::string value = lowercased(category);
    return value == "network" ||
        value == "transport" ||
        value == "timeout" ||
        value == "rate_limit" ||
        value == "provider" ||
        value == "transient";
}

static bool nonRetryableCategory(const std::string &category) {
    const std::string value = lowercased(category);
    return value == "auth" ||
        value == "authentication" ||
        value == "authorization" ||
        value == "configuration" ||
        value == "schema" ||
        value == "validation" ||
        value == "permission" ||
        value == "confirmation";
}

static long long defaultRetryDelayMilliseconds(int attempt, double retryAfterSeconds) {
    if (retryAfterSeconds > 0) {
        return static_cast<long long>(std::min(8000.0, retryAfterSeconds * 1000.0));
    }
    const int safeAttempt = std::max(1, attempt);
    const long long base = 1000LL << static_cast<long long>(std::min(2, safeAttempt - 1));
    return std::min(8000LL, base);
}

static bool toolRetryAllowed(const std::map<std::string, JsonField> &fields) {
    if (boolField(fields, "tool_destructive", boolField(fields, "destructive", false))) {
        return false;
    }
    if (boolField(fields, "tool_read_only", boolField(fields, "read_only", false))) {
        return true;
    }
    const std::string policy = lowercased(stringField(fields, "idempotency_policy", stringField(fields, "idempotencyPolicy")));
    if (policy == "replay_identical") {
        return true;
    }
    if (policy == "caller_keyed" && boolField(fields, "has_idempotency_key", false)) {
        return true;
    }
    return false;
}

static RuntimeRetryDecision parseRetryDecision(const std::string &decisionJson, bool &ok) {
    ok = false;
    RuntimeRetryDecision decision;
    const std::string text = trim(decisionJson);
    if (text.empty() || text == "null") {
        return decision;
    }
    std::map<std::string, JsonField> fields;
    if (!parseFieldsOrEmpty(text, fields)) {
        return decision;
    }
    decision.action = lowercased(stringField(fields, "action", stringField(fields, "decision", "fail")));
    if (decision.action == "continue") {
        decision.action = "proceed";
    }
    if (decision.action != "retry" && decision.action != "fallback" && decision.action != "fail" && decision.action != "proceed") {
        decision.action = "fail";
    }
    decision.reason = stringField(fields, "reason", stringField(fields, "message"));
    decision.delayMilliseconds = std::max(0, intField(fields, "delay_ms", intField(fields, "delayMilliseconds", 0)));
    decision.maxAttemptsOverride = std::max(0, intField(fields, "max_attempts_override", intField(fields, "maxAttemptsOverride", 0)));
    ok = true;
    return decision;
}

static RuntimeRetryDecision defaultRetryDecision(const std::string &retryRequestJson) {
    RuntimeRetryDecision decision;
    std::map<std::string, JsonField> fields;
    parseFieldsOrEmpty(trim(retryRequestJson).empty() ? "{}" : retryRequestJson, fields);
    const std::string stage = lowercased(stringField(fields, "stage"));
    const std::string code = stringField(fields, "error_code", stringField(fields, "errorCode"));
    const std::string category = stringField(fields, "error_category", stringField(fields, "errorCategory"));
    const int attempt = std::max(1, intField(fields, "attempt", 1));
    const int configuredMax = intField(fields, "max_attempts", intField(fields, "maxAttempts", 0));
    const int maxAttempts = configuredMax > 0 ? configuredMax : (stage == "step_normalization" ? 2 : 3);
    const bool explicitRecoverable = boolField(fields, "recoverable", false);
    const bool retryable = explicitRecoverable || retryableCode(code) || retryableCategory(category);
    const bool blocked = nonRetryableCode(code) || nonRetryableCategory(category);

    if (attempt >= maxAttempts) {
        decision.reason = "retry attempts exhausted";
        return decision;
    }
    if (blocked || !retryable) {
        decision.reason = blocked ? "error is not retryable" : "error is not marked recoverable";
        return decision;
    }
    if (stage == "permission" || stage == "confirmation") {
        decision.reason = "permission and confirmation are not retried by default";
        return decision;
    }
    if (stage == "tool_execution" && !toolRetryAllowed(fields)) {
        decision.reason = "idempotency policy prevents tool retry";
        return decision;
    }
    decision.action = "retry";
    decision.delayMilliseconds = defaultRetryDelayMilliseconds(attempt, doubleField(fields, "retry_after_seconds", doubleField(fields, "retryAfterSeconds", 0)));
    decision.reason = "default retry policy";
    return decision;
}

static std::string retryDecisionJson(const RuntimeRetryDecision &decision) {
    return "{\"action\":" + jsonString(decision.action) +
        ",\"delay_ms\":" + std::to_string(std::max<long long>(0, decision.delayMilliseconds)) +
        ",\"reason\":" + jsonString(decision.reason) +
        ",\"max_attempts_override\":" + std::to_string(std::max(0, decision.maxAttemptsOverride)) + "}";
}

RuntimeRetryDecision RuntimeCallbacks::decideRetry(const std::string &retryRequestJson) const {
    RuntimeRetryDecision decision;
    bool parsedProviderDecision = false;
    auto callback = reinterpret_cast<LuminaAgentRetryProviderCallback>(retryProvider_.function);
    if (callback != nullptr) {
        decision = parseRetryDecision(
            consumeCString(callback((trim(retryRequestJson).empty() ? "{}" : retryRequestJson).c_str(), retryProvider_.context)),
            parsedProviderDecision
        );
    }
    if (callback == nullptr || !parsedProviderDecision) {
        decision = defaultRetryDecision(retryRequestJson);
    }
    const std::string payload = "{\"request\":" + (trim(retryRequestJson).empty() ? "{}" : retryRequestJson) +
        ",\"decision\":" + retryDecisionJson(decision) +
        ",\"source\":" + jsonString(callback != nullptr && parsedProviderDecision ? "provider" : "default") + "}";
    emitEvent("runtime.retry.decision", payload);
    if (decision.action == "retry") {
        metric("runtime.retry.count", 1, payload);
        metric("runtime.retry.delay_ms", static_cast<double>(decision.delayMilliseconds), payload);
    } else if (decision.action == "fallback") {
        metric("runtime.fallback.count", 1, payload);
    }
    return decision;
}

static RuntimeCompactionDecision parseCompactionDecision(const std::string &decisionJson, bool &ok) {
    ok = false;
    RuntimeCompactionDecision decision;
    const std::string text = trim(decisionJson);
    if (text.empty() || text == "null") {
        return decision;
    }
    std::map<std::string, JsonField> fields;
    if (!parseFieldsOrEmpty(text, fields)) {
        decision.status = "failed";
        decision.failureReason = "compaction provider returned invalid JSON";
        return decision;
    }
    decision.status = lowercased(stringField(fields, "status", stringField(fields, "decision", "skipped")));
    if (decision.status == "skip") {
        decision.status = "skipped";
    }
    if (decision.status != "compacted" && decision.status != "skipped" && decision.status != "failed") {
        decision.status = "skipped";
    }
    decision.compactedContextJson = rawField(fields, "compacted_context", rawField(fields, "compactedContext", ""));
    decision.boundaryJson = rawField(fields, "boundary", "");
    decision.failureReason = stringField(fields, "failure_reason", stringField(fields, "failureReason", stringField(fields, "reason")));
    decision.tokensSavedEstimate = std::max(0, intField(fields, "tokens_saved_estimate", intField(fields, "tokensSavedEstimate", 0)));
    ok = true;
    return decision;
}

static std::string compactionDecisionJson(const RuntimeCompactionDecision &decision) {
    std::string output = "{\"status\":" + jsonString(decision.status) +
        ",\"tokens_saved_estimate\":" + std::to_string(std::max(0, decision.tokensSavedEstimate)) +
        ",\"failure_reason\":" + jsonString(decision.failureReason);
    if (!trim(decision.boundaryJson).empty()) {
        output += ",\"boundary\":" + decision.boundaryJson;
    }
    output += "}";
    return output;
}

RuntimeCompactionDecision RuntimeCallbacks::compactContext(const std::string &compactionRequestJson) const {
    RuntimeCompactionDecision decision;
    bool parsedProviderDecision = false;
    auto callback = reinterpret_cast<LuminaAgentCompactionProviderCallback>(compactionProvider_.function);
    if (callback != nullptr) {
        decision = parseCompactionDecision(
            consumeCString(callback((trim(compactionRequestJson).empty() ? "{}" : compactionRequestJson).c_str(), compactionProvider_.context)),
            parsedProviderDecision
        );
    }
    const std::string source = callback != nullptr && parsedProviderDecision ? "provider" : "default";
    emitEvent(
        "runtime.context.compaction.provider_decision",
        "{\"request\":" + (trim(compactionRequestJson).empty() ? "{}" : compactionRequestJson) +
            ",\"decision\":" + compactionDecisionJson(decision) +
            ",\"source\":" + jsonString(source) + "}"
    );
    return decision;
}

std::string RuntimeCallbacks::callToolLoadingPlugin(const std::string &requestJson) const {
    auto callback = reinterpret_cast<LuminaAgentToolLoadingPluginCallback>(toolLoadingPlugin_.function);
    return callback == nullptr ? "" : consumeCString(callback((trim(requestJson).empty() ? "{}" : requestJson).c_str(), toolLoadingPlugin_.context));
}

std::string RuntimeCallbacks::dispatchHook(const std::string &hookEvent) const {
    auto callback = reinterpret_cast<LuminaAgentHookCallback>(hook_.function);
    return callback == nullptr ? "" : consumeCString(callback(hookEvent.c_str(), hook_.context));
}

static std::vector<std::string> stringArrayField(const std::map<std::string, JsonField> &fields, const std::string &key) {
    const std::string raw = rawField(fields, key, "");
    std::vector<std::string> values;
    if (raw.empty()) {
        return values;
    }
    size_t index = 0;
    while (index < raw.size()) {
        while (index < raw.size() && raw[index] != '"') {
            index++;
        }
        if (index >= raw.size()) {
            break;
        }
        index++;
        std::string value;
        bool escaped = false;
        while (index < raw.size()) {
            const char c = raw[index++];
            if (escaped) {
                switch (c) {
                case '"':
                case '\\':
                case '/':
                    value += c;
                    break;
                case 'n': value += '\n'; break;
                case 'r': value += '\r'; break;
                case 't': value += '\t'; break;
                default: value += c; break;
                }
                escaped = false;
            } else if (c == '\\') {
                escaped = true;
            } else if (c == '"') {
                values.push_back(value);
                break;
            } else {
                value += c;
            }
        }
    }
    return values;
}

static bool containsValue(const std::vector<std::string> &values, const std::string &candidate) {
    if (values.empty()) {
        return true;
    }
    const std::string normalized = lowercased(candidate);
    for (const std::string &value : values) {
        if (lowercased(value) == normalized) {
            return true;
        }
    }
    return false;
}

static bool patternMatches(const std::string &pattern, const std::string &value) {
    if (pattern == "*") {
        return true;
    }
    if (!pattern.empty() && pattern.back() == '*') {
        return value.rfind(pattern.substr(0, pattern.size() - 1), 0) == 0;
    }
    return pattern == value;
}

static bool matchesAnyPattern(const std::vector<std::string> &patterns, const std::string &value) {
    if (patterns.empty()) {
        return true;
    }
    for (const std::string &pattern : patterns) {
        if (patternMatches(pattern, value)) {
            return true;
        }
    }
    return false;
}

static std::string nestedStringField(const std::map<std::string, JsonField> &fields, const std::string &objectKey, const std::string &nestedKey) {
    std::map<std::string, JsonField> nestedFields;
    if (!parseFieldsOrEmpty(rawField(fields, objectKey, ""), nestedFields)) {
        return "";
    }
    return stringField(nestedFields, nestedKey, stringField(nestedFields, nestedKey == "tool_name" ? "toolName" : nestedKey));
}

std::vector<std::string> RuntimeCallbacks::matchingHookRouteIds(const std::string &lifecycle, const std::string &payloadJson) const {
    std::vector<std::string> matched;
    if (hookRoutes_.empty()) {
        return matched;
    }
    std::map<std::string, JsonField> fields;
    parseFieldsOrEmpty(payloadJson.empty() ? "{}" : payloadJson, fields);
    const std::string toolName = stringField(fields, "tool_name",
        stringField(fields, "toolName", nestedStringField(fields, "call", "tool_name")));
    const std::string sensitivity = stringField(fields, "sensitivity",
        nestedStringField(fields, "call", "sensitivity"));
    const std::string sideEffect = stringField(fields, "side_effect",
        stringField(fields, "sideEffect", nestedStringField(fields, "call", "side_effect")));

    for (const RuntimeHookRoute &route : hookRoutes_) {
        if (!containsValue(route.events, lifecycle)) {
            continue;
        }
        if (!route.toolNamePatterns.empty() && !matchesAnyPattern(route.toolNamePatterns, toolName)) {
            continue;
        }
        if (!route.sensitivities.empty() && !containsValue(route.sensitivities, sensitivity)) {
            continue;
        }
        if (!route.sideEffects.empty() && !containsValue(route.sideEffects, sideEffect)) {
            continue;
        }
        matched.push_back(route.id);
    }
    return matched;
}

std::string RuntimeCallbacks::registerHookRoute(const std::string &routeJson) {
    std::map<std::string, JsonField> fields;
    if (!parseFieldsOrEmpty(routeJson, fields)) {
        return "{\"ok\":false,\"error\":\"hook route must be a JSON object\"}";
    }
    RuntimeHookRoute route;
    route.id = stringField(fields, "id", stringField(fields, "route_id"));
    if (route.id.empty()) {
        route.id = "route-" + std::to_string(hookRoutes_.size() + 1);
    }
    route.events = stringArrayField(fields, "events");
    route.toolNamePatterns = stringArrayField(fields, "tool_name_patterns");
    if (route.toolNamePatterns.empty()) {
        route.toolNamePatterns = stringArrayField(fields, "toolNamePatterns");
    }
    route.sensitivities = stringArrayField(fields, "sensitivities");
    route.sideEffects = stringArrayField(fields, "side_effects");
    if (route.sideEffects.empty()) {
        route.sideEffects = stringArrayField(fields, "sideEffects");
    }
    hookRoutes_.push_back(route);
    return "{\"ok\":true,\"route_id\":" + jsonString(route.id) + "}";
}

void RuntimeCallbacks::clearHookRoutes() {
    hookRoutes_.clear();
}

void RuntimeCallbacks::emitEvent(const std::string &type, const std::string &payload) const {
    if (type == "observation_created") {
        recordHistory("observation_created", payload);
    }
    auto callback = reinterpret_cast<LuminaAgentEventCallback>(event_.function);
    if (callback == nullptr) {
        return;
    }
    const long long sequence = ++telemetrySequence_;
    const std::string event = "{\"type\":" + jsonString(type) +
        ",\"sequence\":" + std::to_string(sequence) +
        ",\"timestamp\":" + std::to_string(timestampMilliseconds()) +
        ",\"session_id\":" + jsonString(currentSessionId_) +
        ",\"run_id\":" + jsonString(currentRunId_) +
        ",\"payload\":" + payload + "}";
    callback(event.c_str(), event_.context);
}

void RuntimeCallbacks::audit(const std::string &type, const std::string &payload) const {
    auto callback = reinterpret_cast<LuminaAgentAuditCallback>(audit_.function);
    if (callback == nullptr) {
        return;
    }
    const long long sequence = ++telemetrySequence_;
    const std::string record = "{\"type\":" + jsonString(type) +
        ",\"sequence\":" + std::to_string(sequence) +
        ",\"timestamp\":" + std::to_string(timestampMilliseconds()) +
        ",\"session_id\":" + jsonString(currentSessionId_) +
        ",\"run_id\":" + jsonString(currentRunId_) +
        ",\"payload\":" + payload + "}";
    callback(record.c_str(), audit_.context);
}

void RuntimeCallbacks::trace(const std::string &type, const std::string &payload) const {
    auto callback = reinterpret_cast<LuminaAgentTraceCallback>(trace_.function);
    if (callback == nullptr) {
        return;
    }
    const long long sequence = ++telemetrySequence_;
    const std::string record = "{\"type\":" + jsonString(type) +
        ",\"sequence\":" + std::to_string(sequence) +
        ",\"timestamp\":" + std::to_string(timestampMilliseconds()) +
        ",\"session_id\":" + jsonString(currentSessionId_) +
        ",\"run_id\":" + jsonString(currentRunId_) +
        ",\"payload\":" + payload + "}";
    callback(record.c_str(), trace_.context);
}

void RuntimeCallbacks::metric(const std::string &name, double value, const std::string &payload) const {
    auto callback = reinterpret_cast<LuminaAgentMetricsCallback>(metrics_.function);
    if (callback == nullptr) {
        return;
    }
    const long long sequence = ++telemetrySequence_;
    std::ostringstream output;
    output << "{\"name\":" << jsonString(name)
           << ",\"value\":" << value
           << ",\"sequence\":" << sequence
           << ",\"timestamp\":" << timestampMilliseconds()
           << ",\"session_id\":" << jsonString(currentSessionId_)
           << ",\"run_id\":" << jsonString(currentRunId_)
           << ",\"payload\":" << (trim(payload).empty() ? "{}" : payload)
           << "}";
    const std::string record = output.str();
    callback(record.c_str(), metrics_.context);
}

void RuntimeCallbacks::span(const std::string &phase, const std::string &name, const std::string &payload) const {
    auto callback = reinterpret_cast<LuminaAgentSpanCallback>(span_.function);
    if (callback == nullptr) {
        return;
    }
    const long long sequence = ++telemetrySequence_;
    auto makeSpanId = [&](const std::string &spanName) {
        std::string normalized;
        for (char c : spanName) {
            normalized += std::isalnum(static_cast<unsigned char>(c)) ? c : '-';
        }
        return normalized + "-" + std::to_string(sequence);
    };
    std::string spanId = makeSpanId(name);
    std::string parentSpanId = spanStack_.empty() ? "" : spanStack_.back().second;
    if (phase == "end") {
        for (auto it = spanStack_.rbegin(); it != spanStack_.rend(); ++it) {
            if (it->first == name) {
                spanId = it->second;
                auto base = it.base();
                auto eraseIt = base;
                --eraseIt;
                parentSpanId = eraseIt == spanStack_.begin() ? "" : std::prev(eraseIt)->second;
                spanStack_.erase(eraseIt);
                break;
            }
        }
    } else if (phase == "start") {
        spanStack_.push_back({name, spanId});
    }
    const std::string record = "{\"phase\":" + jsonString(phase) +
        ",\"name\":" + jsonString(name) +
        ",\"span_id\":" + jsonString(spanId) +
        ",\"parent_span_id\":" + jsonString(parentSpanId) +
        ",\"sequence\":" + std::to_string(sequence) +
        ",\"timestamp\":" + std::to_string(timestampMilliseconds()) +
        ",\"session_id\":" + jsonString(currentSessionId_) +
        ",\"run_id\":" + jsonString(currentRunId_) +
        ",\"payload\":" + (trim(payload).empty() ? "{}" : payload) + "}";
    callback(record.c_str(), span_.context);
}

void RuntimeCallbacks::recordHistory(const std::string &event, const std::string &payload) const {
    recordHistoryFor(currentSessionId_, currentRunId_, event, payload);
}

void RuntimeCallbacks::recordHistoryFor(
    const std::string &sessionId,
    const std::string &runId,
    const std::string &event,
    const std::string &payload
) const {
    auto callback = reinterpret_cast<LuminaAgentSessionHistoryCallback>(sessionHistory_.function);
    if (callback == nullptr) {
        return;
    }
    const long long sequence = ++historySequence_;
    const std::string redactedPayload = redactHistoryJsonValue(trim(payload).empty() ? "{}" : payload);
    const std::string record = "{\"event\":" + jsonString(event) +
        ",\"session_id\":" + jsonString(sessionId) +
        ",\"run_id\":" + jsonString(runId) +
        ",\"sequence\":" + std::to_string(sequence) +
        ",\"timestamp\":" + std::to_string(timestampMilliseconds()) +
        ",\"payload\":" + redactedPayload + "}";
    callback(record.c_str(), sessionHistory_.context);
}

} // namespace LuminaAgent
