#pragma once

namespace LuminaAgent {

// Immutable execution limits copied into each task session at creation time.
struct RuntimeSessionConfig {
    // Maximum model-produced ReAct steps before the runtime stops the session.
    int maximumReActIterations = 12;

    // Maximum tool, ask_user, or multi_tool_use actions allowed in one session.
    int maximumToolCalls = 8;

    // Approximate context window available to task envelope construction.
    int maximumContextTokens = 12000;

    // Maximum characters retained from each runtime-owned observation summary.
    int maximumObservationCharacters = 2400;

    // When true, the first non-success tool result terminates the session.
    bool stopOnToolFailure = false;
};

} // namespace LuminaAgent
