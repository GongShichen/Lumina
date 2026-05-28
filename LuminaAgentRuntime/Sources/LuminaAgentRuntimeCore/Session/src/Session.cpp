#include "Session.hpp"

#include <algorithm>
#include <map>
#include <sstream>

#include "Json.hpp"
#include "ObservationBuilder.hpp"
#include "ReAct.hpp"

namespace LuminaAgent {

RuntimeSession::RuntimeSession(RuntimeSessionConfig config)
    : config_(config) {}

bool RuntimeSession::canContinue() const {
    return !paused_ && !hasFinal_ && terminationReason_.empty() && stepCount_ < config_.maximumReActIterations;
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
    if (!hasFinal_ && terminationReason_.empty()) {
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
           << "\"status\":" << jsonString(runStatusName(status())) << ","
           << "\"canContinue\":" << jsonBool(canContinue()) << ","
           << "\"paused\":" << jsonBool(paused_) << ","
           << "\"pending\":" << pendingJson() << ","
           << "\"stepCount\":" << stepCount_ << ","
           << "\"actionCount\":" << actionCount_ << ","
           << "\"reasoningCount\":" << reasoningCount_ << ","
           << "\"observationCount\":" << observationCount_ << ","
           << "\"remainingToolCalls\":" << std::max(0, config_.maximumToolCalls - actionCount_) << ","
           << "\"remainingContextTokensEstimate\":" << remainingContextTokensEstimate() << ","
           << "\"terminationReason\":" << jsonString(terminationReason_) << ","
           << "\"finalMarkdown\":" << jsonString(finalMarkdown_)
           << "}";
    return output.str();
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
    if (hasFinal_ || !terminationReason_.empty()) {
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
    } else if (type == "final_answer") {
        hasFinal_ = true;
        terminationReason_ = "final";
        finalMarkdown_ = fields["content"].stringValue;
    } else if (type == "cannot_complete") {
        hasFailedTool_ = true;
        hasFinal_ = true;
        terminationReason_ = "cannot-complete";
        finalMarkdown_ = "### 无法完成\n\n" + fields["reason"].stringValue;
    }
    appendTrace("step_recorded", stepJson);

    std::ostringstream output;
    output << "{\"ok\":true,"
           << "\"type\":" << jsonString(type) << ","
           << "\"stepCount\":" << stepCount_ << ","
           << "\"actionCount\":" << actionCount_ << ","
           << "\"remainingToolCalls\":" << std::max(0, config_.maximumToolCalls - actionCount_) << ","
           << "\"consecutiveReasoningCount\":" << consecutiveReasoningCount_ << ","
           << "\"finalMarkdown\":" << jsonString(finalMarkdown_) << ","
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
        hasFinal_ = true;
        terminationReason_ = "tool-failure";
        finalMarkdown_ = "### 执行中止\n\n" + summary;
    }

    std::ostringstream output;
    output << "{\"ok\":true,"
           << "\"toolName\":" << jsonString(toolName) << ","
           << "\"status\":" << jsonString(resultStatus) << ","
           << "\"summary\":" << jsonString(summary) << ","
           << "\"errorMessage\":" << jsonString(errorMessage) << ","
           << "\"terminationReason\":" << jsonString(terminationReason_) << ","
           << "\"finalMarkdown\":" << jsonString(finalMarkdown_)
           << "}";
    lastObservationJson_ = output.str();
    return lastObservationJson_;
}

std::string RuntimeSession::recordFinal(const std::string &markdown) {
    hasFinal_ = true;
    terminationReason_ = "final";
    finalMarkdown_ = markdown;
    appendTrace("final_recorded", "{\"markdown\":" + jsonString(markdown) + "}");
    return snapshotJson();
}

std::string RuntimeSession::finishIfNeeded() {
    if (!hasFinal_) {
        if (terminationReason_.empty()) {
            terminationReason_ = stepCount_ >= config_.maximumReActIterations ? "budget" : "stopped";
        }
        hasFinal_ = true;
        if (finalMarkdown_.empty()) {
            finalMarkdown_ = terminationReason_ == "budget"
                ? "### 已达到执行预算\n\nAgent 已停止继续调用工具。"
                : "### 执行结束\n\n本次任务没有生成最终回答。";
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
int RuntimeSession::maxOutputTokens() const { return config_.maxOutputTokens; }
int RuntimeSession::reservedOutputTokens() const { return config_.reservedOutputTokens; }
int RuntimeSession::contextWindowTokens() const { return config_.contextWindowTokens; }
int RuntimeSession::compactThresholdTokens() const { return config_.compactThresholdTokens; }
int RuntimeSession::maximumCompactFailures() const { return config_.maximumCompactFailures; }
int RuntimeSession::maximumObservationCharacters() const { return config_.maximumObservationCharacters; }
int RuntimeSession::toolResultTokenBudget() const { return config_.toolResultTokenBudget; }
int RuntimeSession::remainingContextTokensEstimate() const { return std::max(0, config_.contextWindowTokens - contextTokenUsageEstimate_); }
bool RuntimeSession::hasFinal() const { return hasFinal_; }
bool RuntimeSession::isTerminated() const { return hasFinal_ || !terminationReason_.empty(); }
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
        "请基于上一轮结果继续；如果任务已经完成，请输出 final_answer；不要再次调用相同参数。"
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
        hasFinal_ = true;
        terminationReason_ = "replay-loop";
        finalMarkdown_ = "### 无法继续执行\n\n模型连续重复同一个 tool call，runtime 已复用上一轮 observation 并停止重复执行。请根据上一轮 observation 选择下一步工具或输出最终回答。";
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
           << "\"finalMarkdown\":" << jsonString(finalMarkdown_)
           << "}";
    lastObservationJson_ = output.str();
    return lastObservationJson_;
}

void RuntimeSession::cancel() {
    cancelled_ = true;
    hasFinal_ = true;
    terminationReason_ = "cancelled";
    finalMarkdown_ = "### 已取消\n\n本次任务已取消。";
}

void RuntimeSession::failWithFinal(const std::string &reason, const std::string &markdown) {
    hasFailedTool_ = true;
    hasFinal_ = true;
    terminationReason_ = reason;
    finalMarkdown_ = markdown;
}

} // namespace LuminaAgent
