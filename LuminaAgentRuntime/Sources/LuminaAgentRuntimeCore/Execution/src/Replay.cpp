#include "Replay.hpp"

#include <sstream>

#include "Json.hpp"

namespace LuminaAgent {

static std::string replayMode(const std::map<std::string, JsonField> &fields) {
    std::string mode = lowercased(stringField(fields, "mode", "mixed"));
    if (mode == "model_outputs") {
        return "model";
    }
    if (mode == "tool_observations") {
        return "tools";
    }
    if (mode != "mixed" && mode != "model" && mode != "tools" && mode != "all" && mode != "live") {
        return "mixed";
    }
    return mode;
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

RuntimeReplayController RuntimeReplayController::fromJson(const std::string &replayJson) {
    RuntimeReplayController controller;
    const std::string text = trim(replayJson);
    if (text.empty() || text == "{}" || text == "null") {
        controller.mode_ = "live";
        return controller;
    }

    std::map<std::string, JsonField> fields;
    if (!parseFieldsOrEmpty(text, fields)) {
        controller.mode_ = "live";
        return controller;
    }
    controller.mode_ = replayMode(fields);

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

bool RuntimeReplayController::isConfigured() const {
    return mode_ != "live" && (!modelSteps_.empty() || !toolObservations_.empty());
}

bool RuntimeReplayController::hasModelReplay() const {
    return modelIndex_ < modelSteps_.size();
}

bool RuntimeReplayController::shouldReplayTools() const {
    return !toolObservations_.empty() && (mode_ == "mixed" || mode_ == "tools" || mode_ == "all");
}

bool RuntimeReplayController::allowsLiveModel() const {
    return mode_ != "model" && mode_ != "all";
}

bool RuntimeReplayController::allowsLiveTool() const {
    return mode_ != "tools" && mode_ != "all";
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
           << "\"mode\":" << jsonString(mode_) << ","
           << "\"model_outputs\":" << modelSteps_.size() << ","
           << "\"model_outputs_consumed\":" << modelIndex_ << ","
           << "\"tool_observations\":" << toolObservations_.size() << ","
           << "\"tool_observations_consumed\":" << consumedTools
           << "}";
    return output.str();
}

} // namespace LuminaAgent
