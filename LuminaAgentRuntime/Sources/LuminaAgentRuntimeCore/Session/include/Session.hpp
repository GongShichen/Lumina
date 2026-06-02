#pragma once

#include <map>
#include <string>
#include <vector>

#include "RunStatus.hpp"
#include "RuntimeSessionConfig.hpp"
#include "TraceRecorder.hpp"

namespace LuminaAgent {

struct ToolCallLedgerEntry {
    std::string callId;
    std::string toolName;
    std::string dedupKey;
    std::string canonicalParameters;
    std::string status;
    std::string summary;
    std::string rawResultJson;
    std::string timestamp;
    bool replayable = false;
};

class RuntimeSession {
public:
    // Creates a per-task state container. Sessions are intentionally not shared across tasks.
    explicit RuntimeSession(RuntimeSessionConfig config);

    // Stable correlation identifiers included in observable payloads.
    const std::string &sessionId() const;
    const std::string &runId() const;

    // Returns true while iteration, tool, pause, and final-state budgets allow more work.
    bool canContinue() const;

    // Returns a compact JSON snapshot suitable for public C ABI responses.
    std::string snapshotJson() const;
    std::string checkpointJson() const;
    bool restoreFromCheckpointJson(const std::string &checkpointJson, std::string &error);
    std::string canContinueJson() const;
    std::string statusJson() const;

    // Validates and records one model-produced ReAct step.
    std::string recordStep(const std::string &stepJson);

    // Records a runtime-owned observation generated from tool/environment output.
    std::string recordObservation(
        const std::string &toolName,
        const std::string &status,
        const std::string &content,
        const std::string &errorMessage,
        bool confirmationRequired,
        bool confirmed
    );

    // Records a Markdown result and marks the session as complete.
    std::string recordResult(const std::string &markdown);
    void rewriteResult(const std::string &markdown);

    // Produces a final result if the model did not explicitly produce one.
    std::string finishIfNeeded();

    // Appends one normalized trace event for observability/export.
    void appendTrace(const std::string &phase, const std::string &payloadJson);
    std::string traceJson() const;
    std::string traceJsonl() const;

    // Summarizes recent steps for the next model-facing task envelope.
    std::string stepsSummaryJson() const;

    // Stores immutable request/context inputs for the lifetime of this task session.
    void setRequestJson(const std::string &requestJson);
    const std::string &requestJson() const;
    void setContextJson(const std::string &contextJson);
    const std::string &contextJson() const;

    // Tracks the latest observation so the next ReAct turn can focus on it.
    void setLastObservationJson(const std::string &observationJson);
    const std::string &lastObservationJson() const;

    // Runtime-managed scoped state. Persistence is caller-owned through checkpoints.
    std::string setStateJson(const std::string &scope, const std::string &key, const std::string &valueJson);
    std::string getStateJson(const std::string &scope, const std::string &key) const;
    std::string deleteStateJson(const std::string &scope, const std::string &key);
    std::string stateSnapshotJson(const std::string &scope = "") const;

    // Pauses/resumes a session for external user input, confirmation, or context.
    void pause(const std::string &kind, const std::string &payloadJson);
    void resumeWithObservation(const std::string &observationJson);
    bool isPaused() const;
    std::string pendingJson() const;

    // Budget and status accessors used by envelope construction and execution guards.
    RunStatus status() const;
    int stepCount() const;
    int actionCount() const;
    int maximumReActIterations() const;
    int maximumToolCalls() const;
    int maxContextTokens() const;
    int maxOutputTokens() const;
    int reservedOutputTokens() const;
    int autoCompactBufferTokens() const;
    int warningBufferTokens() const;
    int contextWindowTokens() const;
    int compactThresholdTokens() const;
    int maximumCompactFailures() const;
    int maximumObservationCharacters() const;
    int toolResultTokenBudget() const;
    std::string toolSchemaProfile() const;
    std::string modelId() const;
    bool providerNativeContextManagement() const;
    void applyModelMetadata(int providerMaxContextTokens, const std::string &modelId, bool providerNativeContextManagement);
    int remainingContextTokensEstimate() const;
    bool hasResult() const;
    bool isTerminated() const;
    int consecutiveReasoningCount() const;
    int maximumConsecutiveReasoningSteps() const;
    int maximumConsecutiveReplayObservations() const;
    int compactFailureCount() const;
    void setContextTokenUsageEstimate(int usedTokens);
    void recordCompactFailure();
    void resetCompactFailures();

    // Tracks real tool executions inside this session for idempotent replay.
    std::string nextToolCallId();
    const ToolCallLedgerEntry *findReplayableToolCall(const std::string &dedupKey) const;
    void recordToolCallLedgerEntry(const ToolCallLedgerEntry &entry);
    std::string toolResultCandidatesJson(int maxItems, int minCharacters) const;
    std::string toolReplayObservationsJson() const;
    std::string recordReplayObservation(const std::string &toolName, const ToolCallLedgerEntry &entry);

    // Terminal state helpers for cancellation and unrecoverable failures.
    void cancel();
    void failWithResult(const std::string &reason, const std::string &markdown);

private:
    RuntimeSessionConfig config_;
    std::string sessionId_;
    std::string runId_;
    int stepCount_ = 0;
    int actionCount_ = 0;
    int reasoningCount_ = 0;
    int consecutiveReasoningCount_ = 0;
    int observationCount_ = 0;
    int toolCallSequence_ = 0;
    int contextTokenUsageEstimate_ = 0;
    int compactFailureCount_ = 0;
    bool hasResult_ = false;
    bool cancelled_ = false;
    bool hasSucceededTool_ = false;
    bool hasFailedTool_ = false;
    bool hasCancelledTool_ = false;
    bool paused_ = false;
    std::string requestJson_;
    std::string contextJson_;
    std::string lastObservationJson_;
    std::string pendingKind_;
    std::string pendingPayloadJson_;
    std::string terminationReason_;
    std::string resultMarkdown_;
    std::string lastReplayDedupKey_;
    int consecutiveReplayObservationCount_ = 0;
    std::vector<std::string> observations_;
    std::map<std::string, ToolCallLedgerEntry> toolCallLedger_;
    std::map<std::string, std::map<std::string, std::string>> state_;
    TraceRecorder trace_;
};

} // namespace LuminaAgent
