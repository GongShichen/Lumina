#include "ExecutionContext.hpp"

namespace LuminaAgent {

ExecutionContext::ExecutionContext(
    RuntimeSession &session,
    const RuntimeSessionConfig &config,
    const ToolRegistry &tools,
    const RuntimeCallbacks &callbacks,
    RuntimeEventQueue &events
)
    : session_(session),
      config_(config),
      tools_(tools),
      callbacks_(callbacks),
      events_(events) {}

RuntimeSession &ExecutionContext::session() const { return session_; }
const RuntimeSessionConfig &ExecutionContext::config() const { return config_; }
const ToolRegistry &ExecutionContext::tools() const { return tools_; }
const RuntimeCallbacks &ExecutionContext::callbacks() const { return callbacks_; }
RuntimeEventQueue &ExecutionContext::events() const { return events_; }
ContextBudgetManager ExecutionContext::budgetManager() const { return ContextBudgetManager(config_); }

void ExecutionContext::setRequestJson(const std::string &requestJson) {
    requestJson_ = requestJson;
    session_.setRequestJson(requestJson);
}

const std::string &ExecutionContext::requestJson() const { return requestJson_; }

void ExecutionContext::setContextJson(const std::string &contextJson) {
    contextJson_ = contextJson;
    session_.setContextJson(contextJson);
}

const std::string &ExecutionContext::contextJson() const { return contextJson_; }

void ExecutionContext::setLastObservationJson(const std::string &observationJson) {
    lastObservationJson_ = observationJson;
    session_.setLastObservationJson(observationJson);
}

const std::string &ExecutionContext::lastObservationJson() const { return lastObservationJson_; }

} // namespace LuminaAgent
