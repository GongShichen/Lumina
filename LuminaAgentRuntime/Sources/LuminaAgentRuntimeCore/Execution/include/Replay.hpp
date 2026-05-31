#pragma once

#include <string>
#include <vector>

namespace LuminaAgent {

struct RuntimeReplayToolObservation {
    std::string toolName;
    std::string canonicalParameters;
    std::string resultJson;
    bool consumed = false;
};

class RuntimeReplayController {
public:
    static RuntimeReplayController fromJson(const std::string &replayJson);

    bool isConfigured() const;
    bool hasModelReplay() const;
    bool shouldReplayTools() const;
    bool allowsLiveModel() const;
    bool allowsLiveTool() const;
    std::string nextModelStep();
    std::string consumeToolResult(const std::string &toolName, const std::string &canonicalParameters);
    std::string summaryJson() const;

private:
    std::string mode_ = "mixed";
    std::vector<std::string> modelSteps_;
    std::vector<RuntimeReplayToolObservation> toolObservations_;
    size_t modelIndex_ = 0;
};

} // namespace LuminaAgent
