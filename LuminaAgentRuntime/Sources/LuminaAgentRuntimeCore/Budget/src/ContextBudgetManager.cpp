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

int ContextBudgetManager::maxContextTokens() const {
    return std::max(1, config_.maxContextTokens > 0 ? config_.maxContextTokens : config_.contextWindowTokens);
}

int ContextBudgetManager::effectiveContextWindowTokens() const {
    return std::max(1, maxContextTokens() - std::max(0, config_.reservedOutputTokens));
}

int ContextBudgetManager::autoCompactBufferTokens() const {
    if (config_.autoCompactBufferTokens > 0) {
        return config_.autoCompactBufferTokens;
    }
    return std::max(0, config_.compactThresholdTokens);
}

int ContextBudgetManager::warningBufferTokens() const {
    if (config_.warningBufferTokens > 0) {
        return config_.warningBufferTokens;
    }
    return std::max(autoCompactBufferTokens(), config_.compactThresholdTokens);
}

int ContextBudgetManager::autoCompactThresholdTokens() const {
    return std::max(1, effectiveContextWindowTokens() - autoCompactBufferTokens());
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
        estimateTokens(lastObservationJson);
    snapshot.maxContextTokens = maxContextTokens();
    snapshot.effectiveContextWindowTokens = effectiveContextWindowTokens();
    snapshot.autoCompactBufferTokens = autoCompactBufferTokens();
    snapshot.warningBufferTokens = warningBufferTokens();
    snapshot.autoCompactThresholdTokens = autoCompactThresholdTokens();
    snapshot.remainingTokens = std::max(0, snapshot.effectiveContextWindowTokens - snapshot.usedTokens);
    snapshot.shouldCompact = snapshot.usedTokens >= snapshot.autoCompactThresholdTokens;
    snapshot.overWindow = snapshot.usedTokens >= snapshot.effectiveContextWindowTokens;
    snapshot.warning = snapshot.remainingTokens <= snapshot.warningBufferTokens;
    return snapshot;
}

bool ContextBudgetManager::canAttemptCompact(int consecutiveFailures) const {
    return config_.maximumCompactFailures <= 0 || consecutiveFailures < config_.maximumCompactFailures;
}

} // namespace LuminaAgent
