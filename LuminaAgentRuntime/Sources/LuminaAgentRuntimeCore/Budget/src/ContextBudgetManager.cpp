#include "ContextBudgetManager.hpp"

#include <algorithm>

namespace LuminaAgent {

ContextBudgetManager::ContextBudgetManager(RuntimeSessionConfig config)
    : config_(config) {}

int ContextBudgetManager::estimateTokens(const std::string &text) const {
    if (text.empty()) {
        return 0;
    }
    return std::max(1, static_cast<int>((text.size() + 3) / 4));
}

ContextBudgetSnapshot ContextBudgetManager::snapshotFor(
    const std::string &requestJson,
    const std::string &contextJson,
    const std::string &progressJson,
    const std::string &lastObservationJson
) const {
    ContextBudgetSnapshot snapshot;
    snapshot.usedTokens =
        estimateTokens(requestJson) +
        estimateTokens(contextJson) +
        estimateTokens(progressJson) +
        estimateTokens(lastObservationJson) +
        std::max(0, config_.reservedOutputTokens);
    snapshot.remainingTokens = std::max(0, config_.contextWindowTokens - snapshot.usedTokens);
    snapshot.shouldCompact = snapshot.remainingTokens <= std::max(0, config_.compactThresholdTokens);
    snapshot.overWindow = snapshot.usedTokens >= config_.contextWindowTokens;
    return snapshot;
}

bool ContextBudgetManager::canAttemptCompact(int consecutiveFailures) const {
    return config_.maximumCompactFailures <= 0 || consecutiveFailures < config_.maximumCompactFailures;
}

} // namespace LuminaAgent
