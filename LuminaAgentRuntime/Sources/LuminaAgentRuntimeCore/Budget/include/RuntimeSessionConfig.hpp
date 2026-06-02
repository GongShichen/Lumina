#pragma once

#include <string>

namespace LuminaAgent {

// Immutable execution limits copied into each task session at creation time.
struct RuntimeSessionConfig {
    // True only after the caller supplied every required runtime budget.
    bool isConfigured = false;

    // Human-readable configuration error when `isConfigured` is false.
    std::string configurationError;

    // Maximum model-produced ReAct steps before the runtime stops the session.
    int maximumReActIterations = 0;

    // Maximum tool, ask_user, or multi_tool_use actions allowed in one session.
    int maximumToolCalls = 0;

    // Approximate context window available to task envelope construction.
    int contextWindowTokens = 0;

    // Provider/model-declared maximum context window. Falls back to
    // contextWindowTokens when the caller cannot expose model metadata.
    int maxContextTokens = 0;

    // Provider/model identity and native context-management support. These are
    // optional metadata supplied by the host model provider at run time.
    std::string modelId;
    bool providerNativeContextManagement = false;

    // Maximum model output tokens allowed by the caller/model adapter.
    int maxOutputTokens = 0;

    // Tokens reserved for protocol overhead and result headroom.
    int reservedOutputTokens = 0;

    // Remaining headroom kept before proactive automatic compaction.
    int autoCompactBufferTokens = 0;

    // Remaining headroom used for warning/error observability.
    int warningBufferTokens = 0;

    // Maximum characters retained from each runtime-owned observation summary.
    int maximumObservationCharacters = 0;

    // Approximate token budget for tool results before truncation.
    int toolResultTokenBudget = 0;

    // Remaining-token threshold that triggers compaction.
    int compactThresholdTokens = 0;

    // Maximum consecutive compaction failures before disabling auto compact.
    int maximumCompactFailures = 0;

    // Maximum consecutive pure reasoning steps before the runtime stops empty loops.
    int maximumConsecutiveReasoningSteps = 0;

    // Maximum consecutive identical replay observations before the runtime stops an action loop.
    int maximumConsecutiveReplayObservations = 0;

    // When true, the first non-success tool result terminates the session.
    bool stopOnToolFailure = false;

    // Tool schema disclosure profile for model-facing planner input:
    // full, compact, or name-only.
    std::string toolSchemaProfile = "compact";

    // Core checkpoint emission policy. The core never persists checkpoints;
    // callers receive checkpoint_created events and decide where to store them.
    // Supported values: none, on_pause, on_step, on_exit.
    std::string checkpointPolicy = "none";
};

} // namespace LuminaAgent
