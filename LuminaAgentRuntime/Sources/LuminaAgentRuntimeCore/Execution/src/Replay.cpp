#include "Replay.hpp"

#include <algorithm>
#include <sstream>

#include "Json.hpp"

namespace LuminaAgent {

static bool hasField(const std::map<std::string, JsonField> &fields, const std::string &key) {
    return fields.find(key) != fields.end();
}

static std::string normalizeReplayMode(const std::string &value, const std::string &fallback = "replay_strict") {
    std::string mode = lowercased(value.empty() ? fallback : value);
    if (mode == "model_outputs") {
        return "model";
    }
    if (mode == "tool_observations") {
        return "tools";
    }
    if (mode == "strict" || mode == "all") {
        return "replay_strict";
    }
    if (mode == "mixed") {
        return "replay_mixed";
    }
    if (mode != "replay_strict" &&
        mode != "replay_mixed" &&
        mode != "model" &&
        mode != "tools" &&
        mode != "live" &&
        mode != "record" &&
        mode != "fork_from_checkpoint" &&
        mode != "recover_from_checkpoint") {
        return fallback;
    }
    return mode;
}

static bool modeAllowsModelFallbackByDefault(const std::string &mode) {
    return mode == "replay_mixed" || mode == "record" || mode == "fork_from_checkpoint" || mode == "recover_from_checkpoint" || mode == "tools" || mode == "live";
}

static bool modeAllowsToolFallbackByDefault(const std::string &mode) {
    return mode == "replay_mixed" || mode == "record" || mode == "fork_from_checkpoint" || mode == "recover_from_checkpoint" || mode == "model" || mode == "live";
}

static std::string stepJsonFromReplayItem(const std::string &item) {
    std::map<std::string, JsonField> fields;
    if (!parseFieldsOrEmpty(item, fields)) {
        return "";
    }
    const std::string step = rawField(fields, "step", rawField(fields, "output", rawField(fields, "model_output", "")));
    if (!step.empty()) {
        return trim(step);
    }
    if (!stringField(fields, "type").empty()) {
        return trim(item);
    }
    return "";
}

static std::string resultJsonFromReplayItem(const std::string &item) {
    std::map<std::string, JsonField> fields;
    if (!parseFieldsOrEmpty(item, fields)) {
        return "";
    }
    const std::string explicitResult = rawField(fields, "result", rawField(fields, "tool_result", ""));
    if (!explicitResult.empty()) {
        return trim(explicitResult);
    }
    const std::string status = stringField(fields, "status", "succeeded");
    const std::string content = stringField(fields, "content", "");
    const std::string error = stringField(fields, "errorMessage", stringField(fields, "error_message", ""));
    return "{\"status\":" + jsonString(status) +
        ",\"content\":" + jsonString(content) +
        ",\"errorMessage\":" + jsonString(error) + "}";
}

RuntimeReplayOptions RuntimeReplayController::optionsFromJson(const std::string &optionsJson, const std::string &modeFallback) {
    RuntimeReplayOptions options;
    std::map<std::string, JsonField> fields;
    parseFieldsOrEmpty(trim(optionsJson).empty() ? "{}" : optionsJson, fields);
    options.mode = normalizeReplayMode(stringField(fields, "mode"), normalizeReplayMode(modeFallback));
    const bool modelDefault = modeAllowsModelFallbackByDefault(options.mode);
    const bool toolDefault = modeAllowsToolFallbackByDefault(options.mode);
    options.allowLiveModel = boolField(fields, "allow_live_model", boolField(fields, "allowLiveModel", modelDefault));
    options.allowLiveReadOnlyTool = boolField(fields, "allow_live_readonly_tool", boolField(fields, "allowLiveReadOnlyTool", toolDefault));
    options.allowLiveSideEffectToolAfterConfirmation = boolField(
        fields,
        "allow_live_side_effect_tool_after_confirmation",
        boolField(fields, "allowLiveSideEffectToolAfterConfirmation", true)
    );
    options.failOnMissingObservation = boolField(fields, "fail_on_missing_observation", boolField(fields, "failOnMissingObservation", true));
    options.startSequence = std::max(0, intField(fields, "start_sequence", intField(fields, "startSequence", 0)));
    options.endSequence = intField(fields, "end_sequence", intField(fields, "endSequence", -1));
    options.redactionLevel = stringField(fields, "redaction_level", stringField(fields, "redactionLevel", "summary"));
    if (options.redactionLevel != "minimal" && options.redactionLevel != "summary" && options.redactionLevel != "debug") {
        options.redactionLevel = "summary";
    }
    return options;
}

RuntimeReplayController RuntimeReplayController::fromJson(const std::string &replayJson) {
    RuntimeReplayController controller;
    const std::string text = trim(replayJson);
    if (text.empty() || text == "{}" || text == "null") {
        controller.options_.mode = "live";
        return controller;
    }

    std::map<std::string, JsonField> fields;
    if (!parseFieldsOrEmpty(text, fields)) {
        controller.options_.mode = "live";
        return controller;
    }
    controller.configured_ = true;
    controller.options_ = optionsFromJson(text, stringField(fields, "mode", "replay_strict"));

    for (const std::string &item : extractObjectArrayItems(rawField(fields, "model_outputs", rawField(fields, "modelSteps", "[]")))) {
        const std::string step = stepJsonFromReplayItem(item);
        if (!step.empty()) {
            controller.modelSteps_.push_back(step);
        }
    }

    const std::string toolArray = rawField(fields, "tool_observations", rawField(fields, "toolResults", "[]"));
    for (const std::string &item : extractObjectArrayItems(toolArray)) {
        std::map<std::string, JsonField> itemFields;
        if (!parseFieldsOrEmpty(item, itemFields)) {
            continue;
        }
        RuntimeReplayToolObservation observation;
        observation.toolName = stringField(itemFields, "tool_name", stringField(itemFields, "toolName"));
        const std::string canonical = stringField(itemFields, "canonical_parameters", stringField(itemFields, "canonicalParameters"));
        observation.canonicalParameters = canonical.empty()
            ? canonicalizeJsonObject(rawField(itemFields, "parameters", rawField(itemFields, "arguments", "{}")))
            : canonical;
        observation.resultJson = resultJsonFromReplayItem(item);
        if (!observation.toolName.empty() && !observation.resultJson.empty()) {
            controller.toolObservations_.push_back(observation);
        }
    }
    return controller;
}

RuntimeReplayController RuntimeReplayController::fromArtifact(const std::string &artifactJson, const std::string &optionsJson) {
    return fromJson(replayScriptFromArtifact(artifactJson, optionsJson));
}

bool RuntimeReplayController::isConfigured() const {
    return configured_ && options_.mode != "live";
}

bool RuntimeReplayController::hasModelReplay() const {
    return modelIndex_ < modelSteps_.size();
}

bool RuntimeReplayController::shouldReplayTools() const {
    return isConfigured() &&
        (options_.mode == "replay_mixed" ||
         options_.mode == "replay_strict" ||
         options_.mode == "tools" ||
         options_.mode == "record" ||
         options_.mode == "fork_from_checkpoint" ||
         options_.mode == "recover_from_checkpoint");
}

bool RuntimeReplayController::allowsLiveModel() const {
    return options_.allowLiveModel || options_.mode == "live";
}

bool RuntimeReplayController::allowsLiveTool(bool toolReadOnly, bool toolDestructive) const {
    if (options_.mode == "live" || options_.mode == "record") {
        return true;
    }
    if (toolReadOnly && options_.allowLiveReadOnlyTool) {
        return true;
    }
    return !toolReadOnly && !toolDestructive && options_.allowLiveSideEffectToolAfterConfirmation;
}

bool RuntimeReplayController::requiresConfirmationForLiveSideEffect(bool toolReadOnly, bool toolDestructive) const {
    return !toolReadOnly && (toolDestructive || options_.allowLiveSideEffectToolAfterConfirmation);
}

bool RuntimeReplayController::failOnMissingObservation() const {
    return options_.failOnMissingObservation;
}

std::string RuntimeReplayController::nextModelStep() {
    if (!hasModelReplay()) {
        return "";
    }
    return modelSteps_[modelIndex_++];
}

std::string RuntimeReplayController::consumeToolResult(const std::string &toolName, const std::string &canonicalParameters) {
    if (!shouldReplayTools()) {
        return "";
    }
    for (RuntimeReplayToolObservation &observation : toolObservations_) {
        if (observation.consumed) {
            continue;
        }
        if (observation.toolName != toolName) {
            continue;
        }
        if (!observation.canonicalParameters.empty() && observation.canonicalParameters != canonicalParameters) {
            continue;
        }
        observation.consumed = true;
        return observation.resultJson;
    }
    return "";
}

std::string RuntimeReplayController::summaryJson() const {
    size_t consumedTools = 0;
    for (const RuntimeReplayToolObservation &observation : toolObservations_) {
        if (observation.consumed) {
            consumedTools += 1;
        }
    }
    std::ostringstream output;
    output << "{"
           << "\"mode\":" << jsonString(options_.mode) << ","
           << "\"model_outputs\":" << modelSteps_.size() << ","
           << "\"model_outputs_consumed\":" << modelIndex_ << ","
           << "\"tool_observations\":" << toolObservations_.size() << ","
           << "\"tool_observations_consumed\":" << consumedTools
           << "}";
    return output.str();
}

std::string RuntimeReplayController::optionsJson() const {
    std::ostringstream output;
    output << "{"
           << "\"mode\":" << jsonString(options_.mode) << ","
           << "\"allow_live_model\":" << jsonBool(options_.allowLiveModel) << ","
           << "\"allow_live_readonly_tool\":" << jsonBool(options_.allowLiveReadOnlyTool) << ","
           << "\"allow_live_side_effect_tool_after_confirmation\":" << jsonBool(options_.allowLiveSideEffectToolAfterConfirmation) << ","
           << "\"fail_on_missing_observation\":" << jsonBool(options_.failOnMissingObservation) << ","
           << "\"start_sequence\":" << options_.startSequence << ","
           << "\"end_sequence\":" << options_.endSequence << ","
           << "\"redaction_level\":" << jsonString(options_.redactionLevel)
           << "}";
    return output.str();
}

std::string RuntimeReplayController::requestFromArtifact(const std::string &artifactJson) {
    std::map<std::string, JsonField> fields;
    if (!parseFieldsOrEmpty(trim(artifactJson).empty() ? "{}" : artifactJson, fields)) {
        return "{}";
    }
    const std::string request = rawField(fields, "request", "{}");
    return trim(request).empty() || request == "null" ? "{}" : request;
}

std::string RuntimeReplayController::checkpointFromArtifact(const std::string &artifactJson) {
    std::map<std::string, JsonField> fields;
    if (!parseFieldsOrEmpty(trim(artifactJson).empty() ? "{}" : artifactJson, fields)) {
        return "";
    }
    const std::string checkpoint = rawField(fields, "checkpoint", "");
    return checkpoint == "null" ? "" : checkpoint;
}

std::string RuntimeReplayController::replayScriptFromArtifact(const std::string &artifactJson, const std::string &optionsJson) {
    std::map<std::string, JsonField> artifactFields;
    if (!parseFieldsOrEmpty(trim(artifactJson).empty() ? "{}" : artifactJson, artifactFields)) {
        return "{\"mode\":\"replay_strict\"}";
    }
    std::map<std::string, JsonField> optionFields;
    parseFieldsOrEmpty(trim(optionsJson).empty() ? "{}" : optionsJson, optionFields);
    const std::string mode = hasField(optionFields, "mode")
        ? stringField(optionFields, "mode")
        : stringField(artifactFields, "mode", stringField(artifactFields, "replay_mode", "replay_strict"));
    const RuntimeReplayOptions options = optionsFromJson(optionsJson, mode);
    std::ostringstream output;
    output << "{"
           << "\"mode\":" << jsonString(options.mode) << ","
           << "\"allow_live_model\":" << jsonBool(options.allowLiveModel) << ","
           << "\"allow_live_readonly_tool\":" << jsonBool(options.allowLiveReadOnlyTool) << ","
           << "\"allow_live_side_effect_tool_after_confirmation\":" << jsonBool(options.allowLiveSideEffectToolAfterConfirmation) << ","
           << "\"fail_on_missing_observation\":" << jsonBool(options.failOnMissingObservation) << ","
           << "\"start_sequence\":" << options.startSequence << ","
           << "\"end_sequence\":" << options.endSequence << ","
           << "\"redaction_level\":" << jsonString(options.redactionLevel) << ","
           << "\"model_outputs\":" << rawField(artifactFields, "model_outputs", rawField(artifactFields, "modelSteps", "[]")) << ","
           << "\"tool_observations\":" << rawField(artifactFields, "tool_observations", rawField(artifactFields, "toolResults", "[]"))
           << "}";
    return output.str();
}

std::string RuntimeReplayController::artifactFromSession(
    const std::string &checkpointJson,
    const std::string &traceJson,
    const std::string &toolObservationsJson,
    const std::string &stateSnapshotJson,
    const std::string &optionsJson
) {
    std::map<std::string, JsonField> checkpointFields;
    parseFieldsOrEmpty(trim(checkpointJson).empty() ? "{}" : checkpointJson, checkpointFields);
    RuntimeReplayOptions options = optionsFromJson(optionsJson, "record");
    std::ostringstream output;
    output << "{"
           << "\"artifact_type\":\"lumina_replay_artifact\","
           << "\"schema_version\":\"1.0\","
           << "\"session_id\":" << jsonString(stringField(checkpointFields, "session_id")) << ","
           << "\"run_id\":" << jsonString(stringField(checkpointFields, "run_id")) << ","
           << "\"request\":" << rawField(checkpointFields, "request", "{}") << ","
           << "\"runtime_config\":" << rawField(checkpointFields, "budget", "{}") << ","
           << "\"checkpoint\":" << (trim(checkpointJson).empty() ? "{}" : checkpointJson) << ","
           << "\"trace\":" << (trim(traceJson).empty() ? "[]" : traceJson) << ","
           << "\"model_outputs\":[],"
           << "\"tool_observations\":" << (trim(toolObservationsJson).empty() ? "[]" : toolObservationsJson) << ","
           << "\"state_snapshot\":" << (trim(stateSnapshotJson).empty() ? "{}" : stateSnapshotJson) << ","
           << "\"compaction_boundaries\":[],"
           << "\"retry_events\":[],"
           << "\"redaction_policy\":" << jsonString(options.redactionLevel)
           << "}";
    return output.str();
}

static bool containsDifferentRaw(const std::map<std::string, JsonField> &lhs, const std::map<std::string, JsonField> &rhs, const std::string &key) {
    return trim(rawField(lhs, key, "null")) != trim(rawField(rhs, key, "null"));
}

std::string RuntimeReplayController::diffArtifacts(const std::string &expectedJson, const std::string &actualJson, const std::string &optionsJson) {
    (void) optionsJson;
    std::map<std::string, JsonField> expected;
    std::map<std::string, JsonField> actual;
    const bool expectedOk = parseFieldsOrEmpty(trim(expectedJson).empty() ? "{}" : expectedJson, expected);
    const bool actualOk = parseFieldsOrEmpty(trim(actualJson).empty() ? "{}" : actualJson, actual);
    if (!expectedOk || !actualOk) {
        return "{\"ok\":false,\"error\":\"expected and actual replay artifacts must be JSON objects\"}";
    }
    const bool modelDrift = containsDifferentRaw(expected, actual, "model_outputs");
    const bool toolDrift = containsDifferentRaw(expected, actual, "tool_observations");
    const bool stateDrift = containsDifferentRaw(expected, actual, "state_snapshot");
    bool resultDrift = false;
    std::map<std::string, JsonField> expectedCheckpoint;
    std::map<std::string, JsonField> actualCheckpoint;
    if (parseFieldsOrEmpty(rawField(expected, "checkpoint", "{}"), expectedCheckpoint) &&
        parseFieldsOrEmpty(rawField(actual, "checkpoint", "{}"), actualCheckpoint)) {
        resultDrift = containsDifferentRaw(expectedCheckpoint, actualCheckpoint, "resultMarkdown");
    }
    const bool exactMatch = trim(expectedJson) == trim(actualJson);
    const bool semanticMatch = !modelDrift && !toolDrift && !stateDrift && !resultDrift;
    std::ostringstream output;
    output << "{"
           << "\"ok\":true,"
           << "\"exact_match\":" << jsonBool(exactMatch) << ","
           << "\"semantic_runtime_match\":" << jsonBool(semanticMatch) << ","
           << "\"model_drift\":" << jsonBool(modelDrift) << ","
           << "\"tool_drift\":" << jsonBool(toolDrift) << ","
           << "\"state_drift\":" << jsonBool(stateDrift || resultDrift) << ","
           << "\"side_effect_risk\":" << jsonBool(toolDrift) << "}";
    return output.str();
}

} // namespace LuminaAgent
