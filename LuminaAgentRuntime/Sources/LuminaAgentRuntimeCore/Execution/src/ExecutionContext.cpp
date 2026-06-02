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
ContextBudgetManager ExecutionContext::budgetManager() const {
    RuntimeSessionConfig config = config_;
    config.contextWindowTokens = session_.contextWindowTokens();
    config.maxContextTokens = session_.maxContextTokens();
    config.maxOutputTokens = session_.maxOutputTokens();
    config.reservedOutputTokens = session_.reservedOutputTokens();
    config.autoCompactBufferTokens = session_.autoCompactBufferTokens();
    config.warningBufferTokens = session_.warningBufferTokens();
    config.compactThresholdTokens = session_.compactThresholdTokens();
    config.toolResultTokenBudget = session_.toolResultTokenBudget();
    config.maximumObservationCharacters = session_.maximumObservationCharacters();
    return ContextBudgetManager(config);
}

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
