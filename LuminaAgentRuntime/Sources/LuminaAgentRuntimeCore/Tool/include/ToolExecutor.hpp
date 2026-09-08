#pragma once

#include <string>
#include <atomic>

#include "Callbacks.hpp"
#include "Replay.hpp"
#include "Session.hpp"
#include "ToolRegistry.hpp"

namespace LuminaAgent {

class ToolExecutor {
public:
    // Binds one execution pass to the immutable tool registry and callback set.
    ToolExecutor(const ToolRegistry &tools, const RuntimeCallbacks &callbacks, RuntimeReplayController *replay = nullptr,
                 const std::atomic_bool *cancelled = nullptr);

    // Executes one validated tool call, including permission, confirmation, audit, and observation.
    std::string runToolCall(
        RuntimeSession &session,
        const std::string &toolName,
        const std::string &parameters,
        bool requiresConfirmation
    ) const;

    // Executes a model-declared batch serially. Each call still goes through the
    // normal validation, permission, confirmation, guardrail, and replay path.
    std::string runMultiToolCall(RuntimeSession &session, const std::string &toolCallsJson) const;

private:
    const ToolRegistry &tools_;
    const RuntimeCallbacks &callbacks_;
    RuntimeReplayController *replay_;
    const std::atomic_bool *cancelled_;
    bool cancellationRequested() const;
};

} // namespace LuminaAgent
