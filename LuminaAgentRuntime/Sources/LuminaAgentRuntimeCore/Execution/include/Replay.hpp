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

struct RuntimeReplayOptions {
    std::string mode = "replay_strict";
    bool allowLiveModel = false;
    bool allowLiveReadOnlyTool = false;
    bool allowLiveSideEffectToolAfterConfirmation = true;
    bool failOnMissingObservation = true;
    int startSequence = 0;
    int endSequence = -1;
    std::string redactionLevel = "summary";
};

class RuntimeReplayController {
public:
    static RuntimeReplayController fromJson(const std::string &replayJson);
    static RuntimeReplayController fromArtifact(const std::string &artifactJson, const std::string &optionsJson);

    bool isConfigured() const;
    bool hasModelReplay() const;
    bool shouldReplayTools() const;
    bool allowsLiveModel() const;
    bool allowsLiveTool(bool toolReadOnly, bool toolDestructive) const;
    bool requiresConfirmationForLiveSideEffect(bool toolReadOnly, bool toolDestructive) const;
    bool failOnMissingObservation() const;
    std::string nextModelStep();
    std::string consumeToolResult(const std::string &toolName, const std::string &canonicalParameters);
    std::string summaryJson() const;
    std::string optionsJson() const;

    static std::string replayScriptFromArtifact(const std::string &artifactJson, const std::string &optionsJson);
    static std::string requestFromArtifact(const std::string &artifactJson);
    static std::string checkpointFromArtifact(const std::string &artifactJson);
    static std::string artifactFromSession(
        const std::string &checkpointJson,
        const std::string &traceJson,
        const std::string &toolObservationsJson,
        const std::string &stateSnapshotJson,
        const std::string &optionsJson
    );
    static std::string diffArtifacts(const std::string &expectedJson, const std::string &actualJson, const std::string &optionsJson);

private:
    static RuntimeReplayOptions optionsFromJson(const std::string &optionsJson, const std::string &modeFallback);

    RuntimeReplayOptions options_;
    bool configured_ = false;
    std::vector<std::string> modelSteps_;
    std::vector<RuntimeReplayToolObservation> toolObservations_;
    size_t modelIndex_ = 0;
};

} // namespace LuminaAgent
