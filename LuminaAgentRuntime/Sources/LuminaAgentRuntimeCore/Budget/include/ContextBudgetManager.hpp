#pragma once

#include <string>

#include "RuntimeSessionConfig.hpp"

namespace LuminaAgent {

struct ContextBudgetSnapshot {
    int usedTokens = 0;
    int remainingTokens = 0;
    bool shouldCompact = false;
    bool overWindow = false;
};

class ContextBudgetManager {
public:
    explicit ContextBudgetManager(RuntimeSessionConfig config);

    int estimateTokens(const std::string &text) const;
    ContextBudgetSnapshot snapshotFor(
        const std::string &requestJson,
        const std::string &contextJson,
        const std::string &progressJson,
        const std::string &lastObservationJson
    ) const;
    bool canAttemptCompact(int consecutiveFailures) const;

private:
    RuntimeSessionConfig config_;
};

} // namespace LuminaAgent
