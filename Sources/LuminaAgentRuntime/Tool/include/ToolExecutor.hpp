#pragma once

#include <string>

#include "Callbacks.hpp"
#include "Session.hpp"
#include "ToolRegistry.hpp"

namespace LuminaAgent {

class ToolExecutor {
public:
    // Binds one execution pass to the immutable tool registry and callback set.
    ToolExecutor(const ToolRegistry &tools, const RuntimeCallbacks &callbacks);

    // Executes one validated tool call, including permission, confirmation, audit, and observation.
    std::string runToolCall(
        RuntimeSession &session,
        const std::string &toolName,
        const std::string &parameters,
        bool requiresConfirmation
    ) const;

    // Executes a model-declared batch after verifying every tool is read-only.
    std::string runMultiToolCall(RuntimeSession &session, const std::string &toolCallsJson) const;

private:
    const ToolRegistry &tools_;
    const RuntimeCallbacks &callbacks_;
};

} // namespace LuminaAgent
