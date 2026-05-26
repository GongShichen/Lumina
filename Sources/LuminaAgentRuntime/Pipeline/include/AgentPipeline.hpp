#pragma once

#include <string>

#include "Session.hpp"
#include "ToolRegistry.hpp"

namespace LuminaAgent {

class Distiller {
public:
    // Produces a compact task/context view before execution. Model inference remains external.
    std::string distill(const std::string &requestJson, const std::string &contextJson) const;
};

class Executor {
public:
    // Builds the next model-facing planner input for the ReAct loop.
    std::string plannerInput(
        const ToolRegistry &tools,
        const RuntimeSession &session,
        const std::string &requestJson,
        const std::string &contextJson,
        const std::string &lastObservationJson
    ) const;
};

class Responder {
public:
    // Converts the terminal session state into user-readable Markdown result JSON.
    std::string finalize(RuntimeSession &session) const;
};

} // namespace LuminaAgent
