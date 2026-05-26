#pragma once

#include <string>

#include "Session.hpp"

namespace LuminaAgent {

class ContextManager {
public:
    // Reads session budgets while preparing context requests and compacted context.
    explicit ContextManager(const RuntimeSession &session);

    // Builds the JSON request sent to the caller's context provider.
    std::string initialRequestJson(const std::string &requestJson) const;

    // Wraps arrays or loose objects into the runtime's `sections` container.
    std::string normalizeLoadedContext(const std::string &contextJson) const;

    // Drops or summarizes low-priority context when the context window is tight.
    std::string compactIfNeeded(const std::string &contextJson) const;

private:
    const RuntimeSession &session_;
};

} // namespace LuminaAgent
