#include "Session.hpp"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <map>
#include <sstream>

#include "Json.hpp"
#include "ObservationBuilder.hpp"
#include "ReAct.hpp"

namespace LuminaAgent {

static std::string makeSessionIdentifier(const std::string &prefix) {
    static std::atomic<unsigned long long> counter{0};
    const auto now = std::chrono::system_clock::now().time_since_epoch();
    const auto millis = std::chrono::duration_cast<std::chrono::milliseconds>(now).count();
    return prefix + "-" + std::to_string(millis) + "-" + std::to_string(counter.fetch_add(1) + 1);
}

RuntimeSession::RuntimeSession(RuntimeSessionConfig config)
    : config_(config),
      sessionId_(makeSessionIdentifier("session")),
      runId_(makeSessionIdentifier("run")) {}

const std::string &RuntimeSession::sessionId() const {
    return sessionId_;
}

const std::string &RuntimeSession::runId() const {
    return runId_;
}

bool RuntimeSession::canContinue() const {
    return !paused_ && !hasResult_ && terminationReason_.empty() && stepCount_ < config_.maximumReActIterations;
}

RunStatus RuntimeSession::status() const {
    if (cancelled_ || hasCancelledTool_) {
        return RunStatus::cancelled;
    }
    if (terminationReason_ == "cannot-complete" ||
        terminationReason_ == "reasoning-budget" ||
        terminationReason_ == "replay-loop" ||
        terminationReason_ == "model-empty-output" ||
        terminationReason_ == "invalid-model-output") {
        return RunStatus::failed;
    }
    if (!hasResult_ && terminationReason_.empty()) {
        return RunStatus::running;
    }
    if (hasFailedTool_) {
        return hasSucceededTool_ ? RunStatus::partiallySucceeded : RunStatus::failed;
    }
    return RunStatus::succeeded;
}

std::string RuntimeSession::snapshotJson() const {
    std::ostringstream output;
    output << "{"
           << "\"ok\":true,"
           << "\"session_id\":" << jsonString(sessionId_) << ","
           << "\"run_id\":" << jsonString(runId_) << ","
           << "\"status\":" << jsonString(runStatusName(status())) << ","
           << "\"canContinue\":" << jsonBool(canContinue()) << ","
           << "\"paused\":" << jsonBool(paused_) << ","
           << "\"request\":" << (trim(requestJson_).empty() ? "{}" : requestJson_) << ","
           << "\"context\":" << (trim(contextJson_).empty() ? "null" : contextJson_) << ","
           << "\"pending\":" << pendingJson() << ","
           << "\"stepCount\":" << stepCount_ << ","
           << "\"actionCount\":" << actionCount_ << ","
           << "\"reasoningCount\":" << reasoningCount_ << ","
           << "\"observationCount\":" << observationCount_ << ","
           << "\"remainingToolCalls\":" << std::max(0, config_.maximumToolCalls - actionCount_) << ","
           << "\"remainingContextTokensEstimate\":" << remainingContextTokensEstimate() << ","
           << "\"terminationReason\":" << jsonString(terminationReason_) << ","
           << "\"resultMarkdown\":" << jsonString(resultMarkdown_)
           << "}";
    return output.str();
}

static std::string ledgerJson(const std::map<std::string, ToolCallLedgerEntry> &ledger) {
    std::ostringstream output;
    output << "[";
    size_t index = 0;
    for (const auto &entry : ledger) {
        if (index++ > 0) {
            output << ",";
        }
        output << "{"
               << "\"call_id\":" << jsonString(entry.second.callId) << ","
               << "\"tool_name\":" << jsonString(entry.second.toolName) << ","
               << "\"dedup_key\":" << jsonString(entry.second.dedupKey) << ","
               << "\"canonical_parameters\":" << jsonString(entry.second.canonicalParameters) << ","
               << "\"status\":" << jsonString(entry.second.status) << ","
               << "\"summary\":" << jsonString(entry.second.summary) << ","
               << "\"raw_result\":" << (trim(entry.second.rawResultJson).empty() ? "null" : entry.second.rawResultJson) << ","
               << "\"timestamp\":" << jsonString(entry.second.timestamp) << ","
               << "\"replayable\":" << jsonBool(entry.second.replayable)
               << "}";
    }
    output << "]";
    return output.str();
}

std::string RuntimeSession::checkpointJson() const {
    std::ostringstream output;
    output << "{"
           << "\"contract\":\"runtime_checkpoint\","
           << "\"session_id\":" << jsonString(sessionId_) << ","
           << "\"run_id\":" << jsonString(runId_) << ","
           << "\"status\":" << jsonString(runStatusName(status())) << ","
           << "\"request\":" << (trim(requestJson_).empty() ? "{}" : requestJson_) << ","
           << "\"context\":" << (trim(contextJson_).empty() ? "null" : contextJson_) << ","
           << "\"step_index\":" << stepCount_ << ","
           << "\"stepCount\":" << stepCount_ << ","
           << "\"actionCount\":" << actionCount_ << ","
           << "\"reasoningCount\":" << reasoningCount_ << ","
           << "\"observationCount\":" << observationCount_ << ","
           << "\"pending\":" << pendingJson() << ","
           << "\"budget\":{"
                << "\"maximumReActIterations\":" << config_.maximumReActIterations << ","
                << "\"maximumToolCalls\":" << config_.maximumToolCalls << ","
                << "\"remainingToolCalls\":" << std::max(0, config_.maximumToolCalls - actionCount_) << ","
                << "\"remainingContextTokensEstimate\":" << remainingContextTokensEstimate()
           << "},"
           << "\"last_observation\":" << (trim(lastObservationJson_).empty() ? "null" : lastObservationJson_) << ","
           << "\"runtime_state\":" << stateSnapshotJson() << ","
           << "\"tool_replay_ledger\":" << ledgerJson(toolCallLedger_) << ","
           << "\"trace_summary\":" << trace_.summaryJson(12) << ","
           << "\"trace\":" << trace_.json() << ","
           << "\"terminationReason\":" << jsonString(terminationReason_) << ","
           << "\"resultMarkdown\":" << jsonString(resultMarkdown_) << ","
           << "\"paused\":" << jsonBool(paused_) << ","
           << "\"hasResult\":" << jsonBool(hasResult_)
           << "}";
    return output.str();
}

static bool restoreStateObject(
    const std::string &stateJson,
    std::map<std::string, std::map<std::string, std::string>> &state
) {
    std::map<std::string, JsonField> scopes;
    if (!parseFieldsOrEmpty(stateJson, scopes)) {
        return false;
    }
    state.clear();
    for (const std::string &scope : {"temp", "session", "user", "app"}) {
        std::map<std::string, JsonField> values;
        if (!parseFieldsOrEmpty(rawField(scopes, scope, "{}"), values)) {
            continue;
        }
        for (const auto &entry : values) {
            state[scope][entry.first] = trim(entry.second.raw.empty() ? "null" : entry.second.raw);
        }
    }
    return true;
}

bool RuntimeSession::restoreFromCheckpointJson(const std::string &checkpointJson, std::string &error) {
    std::map<std::string, JsonField> fields;
    if (!parseTopLevelObject(checkpointJson, fields, error)) {
        return false;
    }
    sessionId_ = stringField(fields, "session_id", sessionId_);
    runId_ = stringField(fields, "run_id", runId_);
    stepCount_ = intField(fields, "stepCount", intField(fields, "step_index", stepCount_));
    actionCount_ = intField(fields, "actionCount", actionCount_);
    reasoningCount_ = intField(fields, "reasoningCount", reasoningCount_);
    observationCount_ = intField(fields, "observationCount", observationCount_);
    requestJson_ = rawField(fields, "request", requestJson_.empty() ? "{}" : requestJson_);
    contextJson_ = rawField(fields, "context", contextJson_);
    lastObservationJson_ = rawField(fields, "last_observation", lastObservationJson_);
    terminationReason_ = stringField(fields, "terminationReason", terminationReason_);
    resultMarkdown_ = stringField(fields, "resultMarkdown", resultMarkdown_);
    hasResult_ = boolField(fields, "hasResult", !resultMarkdown_.empty());
    paused_ = boolField(fields, "paused", false);
    if (paused_) {
        std::map<std::string, JsonField> pendingFields;
        parseFieldsOrEmpty(rawField(fields, "pending", "{}"), pendingFields);
        pendingKind_ = stringField(pendingFields, "kind", pendingKind_);
        pendingPayloadJson_ = rawField(pendingFields, "payload", pendingPayloadJson_.empty() ? "{}" : pendingPayloadJson_);
    }
    restoreStateObject(rawField(fields, "runtime_state", "{}"), state_);
    for (const std::string &item : extractObjectArrayItems(rawField(fields, "tool_replay_ledger", "[]"))) {
        std::map<std::string, JsonField> itemFields;
        if (!parseFieldsOrEmpty(item, itemFields)) {
            continue;
        }
        ToolCallLedgerEntry entry;
        entry.callId = stringField(itemFields, "call_id");
        entry.toolName = stringField(itemFields, "tool_name");
        entry.dedupKey = stringField(itemFields, "dedup_key");
        entry.canonicalParameters = stringField(itemFields, "canonical_parameters");
        entry.status = stringField(itemFields, "status");
        entry.summary = stringField(itemFields, "summary");
        entry.rawResultJson = rawField(itemFields, "raw_result", "{}");
        entry.timestamp = stringField(itemFields, "timestamp");
        entry.replayable = boolField(itemFields, "replayable", false);
        if (!entry.dedupKey.empty()) {
            toolCallLedger_[entry.dedupKey] = entry;
        }
    }
    appendTrace("checkpoint_restored", "{\"session_id\":" + jsonString(sessionId_) + ",\"run_id\":" + jsonString(runId_) + "}");
    return true;
}

std::string RuntimeSession::canContinueJson() const {
    std::ostringstream output;
    output << "{\"ok\":true,"
           << "\"canContinue\":" << jsonBool(canContinue()) << ","
           << "\"paused\":" << jsonBool(paused_) << ","
           << "\"iteration\":" << stepCount_ << ","
           << "\"remainingToolCalls\":" << std::max(0, config_.maximumToolCalls - actionCount_)
           << "}";
    return output.str();
}

std::string RuntimeSession::statusJson() const {
    return "{\"ok\":true,\"status\":" + jsonString(runStatusName(status())) + "}";
}

std::string RuntimeSession::recordStep(const std::string &stepJson) {
    if (hasResult_ || !terminationReason_.empty()) {
        return "{\"ok\":false,\"error\":\"runtime session has already terminated.\"}";
    }
    if (stepCount_ >= config_.maximumReActIterations) {
        terminationReason_ = "iteration-budget";
        return "{\"ok\":false,\"error\":\"maximum ReAct iteration budget reached.\"}";
    }

    std::string error;
    std::map<std::string, JsonField> fields;
    if (!parseTopLevelObject(stepJson, fields, error) || !validateReActStepObject(stepJson, true, error)) {
        return "{\"ok\":false,\"error\":" + jsonString(error) + "}";
    }

    const std::string type = reactStepType(fields);
    stepCount_ += 1;

    if (type == "reasoning") {
        reasoningCount_ += 1;
        consecutiveReasoningCount_ += 1;
    } else {
        consecutiveReasoningCount_ = 0;
        if (type != "tool_use" && type != "ask_user" && type != "multi_tool_use") {
            lastReplayDedupKey_.clear();
            consecutiveReplayObservationCount_ = 0;
        }
    }

    if (type == "tool_use" || type == "ask_user" || type == "multi_tool_use") {
        if (actionCount_ >= config_.maximumToolCalls) {
            terminationReason_ = "tool-budget";
            return "{\"ok\":false,\"error\":\"maximum tool call budget reached.\"}";
        }
        actionCount_ += 1;
    } else if (type == "result") {
        hasResult_ = true;
        terminationReason_ = "result";
        resultMarkdown_ = fields["content"].stringValue;
    } else if (type == "cannot_complete") {
        hasFailedTool_ = true;
        hasResult_ = true;
        terminationReason_ = "cannot-complete";
        resultMarkdown_ = "### 无法完成\n\n" + fields["reason"].stringValue;
    }
    appendTrace("step_recorded", stepJson);

    std::ostringstream output;
    output << "{\"ok\":true,"
           << "\"type\":" << jsonString(type) << ","
           << "\"stepCount\":" << stepCount_ << ","
           << "\"actionCount\":" << actionCount_ << ","
           << "\"remainingToolCalls\":" << std::max(0, config_.maximumToolCalls - actionCount_) << ","
           << "\"consecutiveReasoningCount\":" << consecutiveReasoningCount_ << ","
           << "\"resultMarkdown\":" << jsonString(resultMarkdown_) << ","
           << "\"terminationReason\":" << jsonString(terminationReason_)
           << "}";
    return output.str();
}

std::string RuntimeSession::recordObservation(
    const std::string &toolName,
    const std::string &status,
    const std::string &content,
    const std::string &errorMessage,
    bool confirmationRequired,
    bool confirmed
) {
    const std::string resultStatus = lowercased(status.empty() ? "failed" : status);
    if (resultStatus == "succeeded") {
        hasSucceededTool_ = true;
    } else if (resultStatus == "cancelled") {
        hasCancelledTool_ = true;
    } else {
        hasFailedTool_ = true;
    }

    const std::string summary = ObservationBuilder().buildSummary({
        resultStatus,
        content,
        errorMessage,
        confirmationRequired,
        confirmed,
        config_.maximumObservationCharacters
    });

    observationCount_ += 1;
    observations_.push_back(summary);
    appendTrace("observation_created", "{\"toolName\":" + jsonString(toolName) + ",\"status\":" + jsonString(resultStatus) + ",\"summary\":" + jsonString(summary) + "}");
    if (config_.stopOnToolFailure && resultStatus != "succeeded") {
        hasResult_ = true;
        terminationReason_ = "tool-failure";
        resultMarkdown_ = "### 执行中止\n\n" + summary;
    }

    std::ostringstream output;
    output << "{\"ok\":true,"
           << "\"toolName\":" << jsonString(toolName) << ","
           << "\"status\":" << jsonString(resultStatus) << ","
           << "\"summary\":" << jsonString(summary) << ","
           << "\"errorMessage\":" << jsonString(errorMessage) << ","
           << "\"terminationReason\":" << jsonString(terminationReason_) << ","
           << "\"resultMarkdown\":" << jsonString(resultMarkdown_)
           << "}";
    lastObservationJson_ = output.str();
    return lastObservationJson_;
}

std::string RuntimeSession::recordResult(const std::string &markdown) {
    hasResult_ = true;
    terminationReason_ = "result";
    resultMarkdown_ = markdown;
    appendTrace("result_recorded", "{\"markdown\":" + jsonString(markdown) + "}");
    return snapshotJson();
}

void RuntimeSession::rewriteResult(const std::string &markdown) {
    hasResult_ = true;
    terminationReason_ = "result";
    resultMarkdown_ = markdown;
    appendTrace("result_rewritten", "{\"markdown\":" + jsonString(markdown) + "}");
}

std::string RuntimeSession::finishIfNeeded() {
    if (!hasResult_) {
        if (terminationReason_.empty()) {
            terminationReason_ = stepCount_ >= config_.maximumReActIterations ? "budget" : "stopped";
        }
        hasResult_ = true;
        if (resultMarkdown_.empty()) {
            resultMarkdown_ = terminationReason_ == "budget"
                ? "### 已达到执行预算\n\nAgent 已停止继续调用工具。"
                : "### 执行结束\n\n本次任务没有生成result。";
        }
    }
    return snapshotJson();
}

void RuntimeSession::appendTrace(const std::string &phase, const std::string &payloadJson) {
    trace_.append(phase, payloadJson);
}

std::string RuntimeSession::traceJson() const {
    return trace_.json();
}

std::string RuntimeSession::traceJsonl() const {
    return trace_.jsonl();
}

std::string RuntimeSession::stepsSummaryJson() const {
    return trace_.summaryJson(8);
}

void RuntimeSession::setRequestJson(const std::string &requestJson) {
    requestJson_ = requestJson;
}

const std::string &RuntimeSession::requestJson() const {
    return requestJson_;
}

void RuntimeSession::setContextJson(const std::string &contextJson) {
    contextJson_ = contextJson;
}

const std::string &RuntimeSession::contextJson() const {
    return contextJson_;
}

void RuntimeSession::setLastObservationJson(const std::string &observationJson) {
    lastObservationJson_ = observationJson;
}

const std::string &RuntimeSession::lastObservationJson() const {
    return lastObservationJson_;
}

static bool isAllowedStateScope(const std::string &scope) {
    return scope == "temp" || scope == "session" || scope == "user" || scope == "app";
}

static std::string normalizedStateValue(const std::string &valueJson) {
    const std::string value = trim(valueJson);
    return value.empty() ? "null" : value;
}

std::string RuntimeSession::setStateJson(const std::string &scope, const std::string &key, const std::string &valueJson) {
    if (!isAllowedStateScope(scope)) {
        return "{\"ok\":false,\"error\":\"invalid state scope\"}";
    }
    if (trim(key).empty()) {
        return "{\"ok\":false,\"error\":\"state key is required\"}";
    }
    state_[scope][key] = normalizedStateValue(valueJson);
    appendTrace(
        "state_mutated",
        "{\"operation\":\"set\",\"scope\":" + jsonString(scope) +
            ",\"key\":" + jsonString(key) +
            ",\"value\":" + state_[scope][key] + "}"
    );
    return "{\"ok\":true,\"scope\":" + jsonString(scope) + ",\"key\":" + jsonString(key) + ",\"value\":" + state_[scope][key] + "}";
}

std::string RuntimeSession::getStateJson(const std::string &scope, const std::string &key) const {
    auto scopeIt = state_.find(scope);
    if (!isAllowedStateScope(scope) || scopeIt == state_.end()) {
        return "{\"ok\":false,\"error\":\"state value not found\"}";
    }
    auto valueIt = scopeIt->second.find(key);
    if (valueIt == scopeIt->second.end()) {
        return "{\"ok\":false,\"error\":\"state value not found\"}";
    }
    return "{\"ok\":true,\"scope\":" + jsonString(scope) + ",\"key\":" + jsonString(key) + ",\"value\":" + valueIt->second + "}";
}

std::string RuntimeSession::deleteStateJson(const std::string &scope, const std::string &key) {
    if (!isAllowedStateScope(scope)) {
        return "{\"ok\":false,\"error\":\"invalid state scope\"}";
    }
    auto scopeIt = state_.find(scope);
    if (scopeIt != state_.end()) {
        scopeIt->second.erase(key);
    }
    appendTrace(
        "state_mutated",
        "{\"operation\":\"delete\",\"scope\":" + jsonString(scope) +
            ",\"key\":" + jsonString(key) + "}"
    );
    return "{\"ok\":true,\"scope\":" + jsonString(scope) + ",\"key\":" + jsonString(key) + "}";
}

std::string RuntimeSession::stateSnapshotJson(const std::string &scope) const {
    auto writeScope = [&](std::ostringstream &output, const std::string &name) {
        output << jsonString(name) << ":{";
        auto scopeIt = state_.find(name);
        size_t index = 0;
        if (scopeIt != state_.end()) {
            for (const auto &entry : scopeIt->second) {
                if (index++ > 0) {
                    output << ",";
                }
                output << jsonString(entry.first) << ":" << normalizedStateValue(entry.second);
            }
        }
        output << "}";
    };
    std::ostringstream output;
    output << "{";
    if (!scope.empty() && isAllowedStateScope(scope)) {
        writeScope(output, scope);
    } else {
        size_t index = 0;
        for (const std::string &name : {"temp", "session", "user", "app"}) {
            if (index++ > 0) {
                output << ",";
            }
            writeScope(output, name);
        }
    }
    output << "}";
    return output.str();
}

void RuntimeSession::pause(const std::string &kind, const std::string &payloadJson) {
    paused_ = true;
    pendingKind_ = kind;
    pendingPayloadJson_ = payloadJson;
    appendTrace("session_paused", "{\"kind\":" + jsonString(kind) + ",\"payload\":" + (trim(payloadJson).empty() ? "{}" : payloadJson) + "}");
}

void RuntimeSession::resumeWithObservation(const std::string &observationJson) {
    paused_ = false;
    pendingKind_.clear();
    pendingPayloadJson_.clear();
    lastObservationJson_ = observationJson;
    appendTrace("session_resumed", "{\"observation\":" + (trim(observationJson).empty() ? "null" : observationJson) + "}");
}

bool RuntimeSession::isPaused() const {
    return paused_;
}

std::string RuntimeSession::pendingJson() const {
    if (!paused_) {
        return "null";
    }
    return "{\"kind\":" + jsonString(pendingKind_) + ",\"payload\":" + (trim(pendingPayloadJson_).empty() ? "{}" : pendingPayloadJson_) + "}";
}

int RuntimeSession::stepCount() const { return stepCount_; }
int RuntimeSession::actionCount() const { return actionCount_; }
int RuntimeSession::maximumReActIterations() const { return config_.maximumReActIterations; }
int RuntimeSession::maximumToolCalls() const { return config_.maximumToolCalls; }
int RuntimeSession::maxContextTokens() const { return config_.maxContextTokens > 0 ? config_.maxContextTokens : config_.contextWindowTokens; }
int RuntimeSession::maxOutputTokens() const { return config_.maxOutputTokens; }
int RuntimeSession::reservedOutputTokens() const { return config_.reservedOutputTokens; }
int RuntimeSession::autoCompactBufferTokens() const { return config_.autoCompactBufferTokens; }
int RuntimeSession::warningBufferTokens() const { return config_.warningBufferTokens; }
int RuntimeSession::contextWindowTokens() const { return config_.contextWindowTokens; }
int RuntimeSession::compactThresholdTokens() const { return config_.compactThresholdTokens; }
int RuntimeSession::maximumCompactFailures() const { return config_.maximumCompactFailures; }
int RuntimeSession::maximumObservationCharacters() const { return config_.maximumObservationCharacters; }
int RuntimeSession::toolResultTokenBudget() const { return config_.toolResultTokenBudget; }
std::string RuntimeSession::toolSchemaProfile() const { return config_.toolSchemaProfile; }
std::string RuntimeSession::modelId() const { return config_.modelId; }
bool RuntimeSession::providerNativeContextManagement() const { return config_.providerNativeContextManagement; }

void RuntimeSession::applyModelMetadata(int providerMaxContextTokens, const std::string &modelId, bool providerNativeContextManagement) {
    if (providerMaxContextTokens > 0) {
        config_.maxContextTokens = providerMaxContextTokens;
    }
    if (!trim(modelId).empty()) {
        config_.modelId = modelId;
    }
    config_.providerNativeContextManagement = config_.providerNativeContextManagement || providerNativeContextManagement;
    appendTrace(
        "model_metadata_applied",
        "{\"model_id\":" + jsonString(config_.modelId) +
            ",\"max_context_tokens\":" + std::to_string(config_.maxContextTokens > 0 ? config_.maxContextTokens : config_.contextWindowTokens) +
            ",\"provider_native_context_management\":" + jsonBool(config_.providerNativeContextManagement) + "}"
    );
}

int RuntimeSession::remainingContextTokensEstimate() const {
    const int maxContext = config_.maxContextTokens > 0 ? config_.maxContextTokens : config_.contextWindowTokens;
    return std::max(0, std::max(1, maxContext - config_.reservedOutputTokens) - contextTokenUsageEstimate_);
}
bool RuntimeSession::hasResult() const { return hasResult_; }
bool RuntimeSession::isTerminated() const { return hasResult_ || !terminationReason_.empty(); }
int RuntimeSession::consecutiveReasoningCount() const { return consecutiveReasoningCount_; }
int RuntimeSession::maximumConsecutiveReasoningSteps() const { return config_.maximumConsecutiveReasoningSteps; }
int RuntimeSession::maximumConsecutiveReplayObservations() const { return config_.maximumConsecutiveReplayObservations; }
int RuntimeSession::compactFailureCount() const { return compactFailureCount_; }

void RuntimeSession::setContextTokenUsageEstimate(int usedTokens) {
    contextTokenUsageEstimate_ = std::max(0, usedTokens);
}

void RuntimeSession::recordCompactFailure() {
    compactFailureCount_ += 1;
}

void RuntimeSession::resetCompactFailures() {
    compactFailureCount_ = 0;
}

std::string RuntimeSession::nextToolCallId() {
    toolCallSequence_ += 1;
    return "tool-call-" + std::to_string(toolCallSequence_);
}

const ToolCallLedgerEntry *RuntimeSession::findReplayableToolCall(const std::string &dedupKey) const {
    auto it = toolCallLedger_.find(dedupKey);
    if (it == toolCallLedger_.end() || !it->second.replayable) {
        return nullptr;
    }
    return &it->second;
}

void RuntimeSession::recordToolCallLedgerEntry(const ToolCallLedgerEntry &entry) {
    if (!entry.dedupKey.empty()) {
        toolCallLedger_[entry.dedupKey] = entry;
    }
}

std::string RuntimeSession::toolResultCandidatesJson(int maxItems, int minCharacters) const {
    std::vector<const ToolCallLedgerEntry *> entries;
    for (const auto &entry : toolCallLedger_) {
        const int rawSize = static_cast<int>(entry.second.rawResultJson.size());
        if (rawSize >= std::max(0, minCharacters)) {
            entries.push_back(&entry.second);
        }
    }
    std::sort(entries.begin(), entries.end(), [](const ToolCallLedgerEntry *lhs, const ToolCallLedgerEntry *rhs) {
        return lhs->timestamp > rhs->timestamp;
    });
    const int limit = maxItems <= 0 ? static_cast<int>(entries.size()) : std::min(maxItems, static_cast<int>(entries.size()));
    std::ostringstream output;
    output << "[";
    for (int index = 0; index < limit; index++) {
        if (index > 0) {
            output << ",";
        }
        const ToolCallLedgerEntry &entry = *entries[static_cast<size_t>(index)];
        output << "{"
               << "\"call_id\":" << jsonString(entry.callId) << ","
               << "\"tool_name\":" << jsonString(entry.toolName) << ","
               << "\"status\":" << jsonString(entry.status) << ","
               << "\"summary\":" << jsonString(truncateToCharacters(entry.summary, config_.maximumObservationCharacters)) << ","
               << "\"raw_result_characters\":" << entry.rawResultJson.size() << ","
               << "\"raw_result_excerpt\":" << jsonString(truncateToCharacters(entry.rawResultJson, config_.maximumObservationCharacters)) << ","
               << "\"timestamp\":" << jsonString(entry.timestamp) << ","
               << "\"replayable\":" << jsonBool(entry.replayable)
               << "}";
    }
    output << "]";
    return output.str();
}

std::string RuntimeSession::toolReplayObservationsJson() const {
    std::vector<const ToolCallLedgerEntry *> entries;
    for (const auto &entry : toolCallLedger_) {
        if (entry.second.replayable) {
            entries.push_back(&entry.second);
        }
    }
    std::sort(entries.begin(), entries.end(), [](const ToolCallLedgerEntry *lhs, const ToolCallLedgerEntry *rhs) {
        return lhs->timestamp < rhs->timestamp;
    });
    std::ostringstream output;
    output << "[";
    for (size_t index = 0; index < entries.size(); index++) {
        if (index > 0) {
            output << ",";
        }
        const ToolCallLedgerEntry &entry = *entries[index];
        output << "{"
               << "\"tool_name\":" << jsonString(entry.toolName) << ","
               << "\"call_id\":" << jsonString(entry.callId) << ","
               << "\"canonical_parameters\":" << jsonString(entry.canonicalParameters) << ","
               << "\"result\":" << (trim(entry.rawResultJson).empty() ? "{}" : entry.rawResultJson) << ","
               << "\"status\":" << jsonString(entry.status) << ","
               << "\"summary\":" << jsonString(truncateToCharacters(entry.summary, config_.maximumObservationCharacters)) << ","
               << "\"timestamp\":" << jsonString(entry.timestamp) << ","
               << "\"replayable\":" << jsonBool(entry.replayable)
               << "}";
    }
    output << "]";
    return output.str();
}

std::string RuntimeSession::recordReplayObservation(const std::string &toolName, const ToolCallLedgerEntry &entry) {
    const std::string resultStatus = lowercased(entry.status.empty() ? "succeeded" : entry.status);
    if (resultStatus == "succeeded") {
        hasSucceededTool_ = true;
    } else if (resultStatus == "cancelled") {
        hasCancelledTool_ = true;
    } else {
        hasFailedTool_ = true;
    }

    const std::string summary =
        "Runtime 已检测到同一个 tool_name + parameters 在本 session 中执行过，因此没有再次执行工具。"
        "请基于上一轮结果继续；如果任务已经完成，请输出 result；不要再次调用相同参数。"
        "上一轮状态：" + resultStatus + "。上一轮摘要：" + entry.summary;
    observationCount_ += 1;
    observations_.push_back(summary);
    if (entry.dedupKey == lastReplayDedupKey_) {
        consecutiveReplayObservationCount_ += 1;
    } else {
        lastReplayDedupKey_ = entry.dedupKey;
        consecutiveReplayObservationCount_ = 1;
    }
    if (config_.maximumConsecutiveReplayObservations > 0 &&
        consecutiveReplayObservationCount_ >= config_.maximumConsecutiveReplayObservations) {
        hasResult_ = true;
        terminationReason_ = "replay-loop";
        resultMarkdown_ = "### 无法继续执行\n\n模型连续重复同一个 tool call，runtime 已复用上一轮 observation 并停止重复执行。请根据上一轮 observation 选择下一步工具或输出result。";
    }
    appendTrace(
        "observation_created",
        "{\"toolName\":" + jsonString(toolName) +
            ",\"status\":" + jsonString(resultStatus) +
            ",\"summary\":" + jsonString(summary) +
            ",\"replayed\":true," +
            "\"replay_count\":" + std::to_string(consecutiveReplayObservationCount_) + "," +
            "\"duplicate_of\":" + jsonString(entry.callId) + "}"
    );

    std::ostringstream output;
    output << "{\"ok\":true,"
           << "\"toolName\":" << jsonString(toolName) << ","
           << "\"status\":" << jsonString(resultStatus) << ","
           << "\"summary\":" << jsonString(summary) << ","
           << "\"errorMessage\":\"\","
           << "\"replayed\":true,"
           << "\"replay_count\":" << consecutiveReplayObservationCount_ << ","
           << "\"duplicate_of\":" << jsonString(entry.callId) << ","
           << "\"terminationReason\":" << jsonString(terminationReason_) << ","
           << "\"resultMarkdown\":" << jsonString(resultMarkdown_)
           << "}";
    lastObservationJson_ = output.str();
    return lastObservationJson_;
}

void RuntimeSession::cancel() {
    cancelled_ = true;
    hasResult_ = true;
    terminationReason_ = "cancelled";
    resultMarkdown_ = "### 已取消\n\n本次任务已取消。";
}

void RuntimeSession::failWithResult(const std::string &reason, const std::string &markdown) {
    hasFailedTool_ = true;
    hasResult_ = true;
    terminationReason_ = reason;
    resultMarkdown_ = markdown;
}

} // namespace LuminaAgent
