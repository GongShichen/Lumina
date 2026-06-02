#pragma once

#include <string>

#include "RuntimeSessionConfig.hpp"

namespace LuminaAgent {

struct ContextBudgetSnapshot {
    int usedTokens = 0;
    int remainingTokens = 0;
    int maxContextTokens = 0;
    int effectiveContextWindowTokens = 0;
    int autoCompactThresholdTokens = 0;
    int autoCompactBufferTokens = 0;
    int warningBufferTokens = 0;
    bool shouldCompact = false;
    bool overWindow = false;
    bool warning = false;
};

class ContextBudgetManager {
public:
    explicit ContextBudgetManager(RuntimeSessionConfig config);

    int estimateTokens(const std::string &text) const;
    int maxContextTokens() const;
    int effectiveContextWindowTokens() const;
    int autoCompactThresholdTokens() const;
    int autoCompactBufferTokens() const;
    int warningBufferTokens() const;
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
