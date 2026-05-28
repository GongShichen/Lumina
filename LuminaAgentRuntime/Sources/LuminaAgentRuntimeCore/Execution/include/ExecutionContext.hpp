#pragma once

#include <string>

#include "Callbacks.hpp"
#include "ContextBudgetManager.hpp"
#include "RuntimeEventQueue.hpp"
#include "RuntimeSessionConfig.hpp"
#include "Session.hpp"
#include "ToolRegistry.hpp"

namespace LuminaAgent {

class ExecutionContext {
public:
    ExecutionContext(
        RuntimeSession &session,
        const RuntimeSessionConfig &config,
        const ToolRegistry &tools,
        const RuntimeCallbacks &callbacks,
        RuntimeEventQueue &events
    );

    RuntimeSession &session() const;
    const RuntimeSessionConfig &config() const;
    const ToolRegistry &tools() const;
    const RuntimeCallbacks &callbacks() const;
    RuntimeEventQueue &events() const;
    ContextBudgetManager budgetManager() const;

    void setRequestJson(const std::string &requestJson);
    const std::string &requestJson() const;
    void setContextJson(const std::string &contextJson);
    const std::string &contextJson() const;
    void setLastObservationJson(const std::string &observationJson);
    const std::string &lastObservationJson() const;

private:
    RuntimeSession &session_;
    const RuntimeSessionConfig &config_;
    const ToolRegistry &tools_;
    const RuntimeCallbacks &callbacks_;
    RuntimeEventQueue &events_;
    std::string requestJson_;
    std::string contextJson_ = "null";
    std::string lastObservationJson_;
};

} // namespace LuminaAgent
