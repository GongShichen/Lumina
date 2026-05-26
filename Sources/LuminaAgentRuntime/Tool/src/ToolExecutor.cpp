#include "ToolExecutor.hpp"

#include <map>
#include <sstream>

#include "Hooks.hpp"
#include "Json.hpp"

namespace LuminaAgent {

ToolExecutor::ToolExecutor(const ToolRegistry &tools, const RuntimeCallbacks &callbacks)
    : tools_(tools), callbacks_(callbacks) {}

std::string ToolExecutor::runToolCall(
    RuntimeSession &session,
    const std::string &toolName,
    const std::string &parameters,
    bool requiresConfirmation
) const {
    if (!tools_.contains(toolName)) {
        const std::string result = "{\"status\":\"failed\",\"content\":\"\",\"errorMessage\":\"tool is not registered\"}";
        const std::string observation = session.recordObservation(toolName, "failed", "", "tool is not registered", false, false);
        callbacks_.emitEvent("observation_created", observation);
        return result;
    }
    const std::string validation = tools_.validateCallJson(toolName, parameters);
    std::map<std::string, JsonField> validationFields;
    if (parseFieldsOrEmpty(validation, validationFields) && !boolField(validationFields, "ok", false)) {
        const std::string error = stringField(validationFields, "error", "tool parameters failed validation");
        const std::string result = "{\"status\":\"failed\",\"content\":\"\",\"errorMessage\":" + jsonString(error) + "}";
        const std::string observation = session.recordObservation(toolName, "failed", "", error, false, false);
        callbacks_.emitEvent("observation_created", observation);
        return result;
    }

    const std::string callJson = "{\"tool_name\":" + jsonString(toolName) +
        ",\"parameters\":" + parameters +
        ",\"requires_confirmation\":" + jsonBool(requiresConfirmation) + "}";
    const std::string redactedCallJson = "{\"tool_name\":" + jsonString(toolName) +
        ",\"parameters\":" + tools_.redactedParametersJson(toolName, parameters) +
        ",\"requires_confirmation\":" + jsonBool(requiresConfirmation) + "}";

    bool confirmationRequired = requiresConfirmation;
    if (callbacks_.hasPermission()) {
        const std::string permissionJson = callbacks_.decidePermission(callJson);
        std::map<std::string, JsonField> permissionFields;
        if (parseFieldsOrEmpty(permissionJson, permissionFields)) {
            const std::string decision = lowercased(stringField(permissionFields, "decision"));
            if (decision == "denied") {
                const std::string error = stringField(permissionFields, "reason", "permission denied");
                const std::string result = "{\"status\":\"denied\",\"content\":\"\",\"errorMessage\":" + jsonString(error) + "}";
                const std::string observation = session.recordObservation(toolName, "denied", "", error, false, false);
                callbacks_.emitEvent("observation_created", observation);
                return result;
            }
            confirmationRequired = confirmationRequired || decision == "requires_confirmation";
        }
    }

    bool confirmed = !confirmationRequired;
    if (confirmationRequired) {
        if (!callbacks_.hasConfirmation()) {
            const std::string error = "confirmation callback is not registered";
            const std::string result = "{\"status\":\"denied\",\"content\":\"\",\"errorMessage\":\"confirmation callback is not registered\"}";
            const std::string observation = session.recordObservation(toolName, "denied", "", error, true, false);
            callbacks_.emitEvent("observation_created", observation);
            return result;
        }
        const std::string confirmationJson = callbacks_.confirm(callJson);
        std::map<std::string, JsonField> confirmationFields;
        if (parseFieldsOrEmpty(confirmationJson, confirmationFields)) {
            confirmed = boolField(confirmationFields, "confirmed", false);
        }
        if (!confirmed) {
            const std::string result = "{\"status\":\"denied\",\"content\":\"\",\"errorMessage\":\"user did not confirm\"}";
            const std::string observation = session.recordObservation(toolName, "denied", "", "user did not confirm", true, false);
            callbacks_.emitEvent("observation_created", observation);
            return result;
        }
    }

    if (!callbacks_.hasTool()) {
        const std::string result = "{\"status\":\"failed\",\"content\":\"\",\"errorMessage\":\"tool callback is not registered\"}";
        const std::string observation = session.recordObservation(toolName, "failed", "", "tool callback is not registered", confirmationRequired, confirmed);
        callbacks_.emitEvent("observation_created", observation);
        return result;
    }
    callbacks_.emitEvent("tool_will_execute", redactedCallJson);
    HookDispatcher(callbacks_).dispatch("tool_will_execute", redactedCallJson);
    std::string result = callbacks_.callTool(callJson);
    if (trim(result).empty()) {
        result = "{\"status\":\"failed\",\"content\":\"\",\"errorMessage\":\"tool returned an empty result\"}";
    }
    callbacks_.audit("tool_did_execute", "{\"call\":" + redactedCallJson + ",\"result\":" + result + "}");
    HookDispatcher(callbacks_).dispatch("tool_did_execute", "{\"call\":" + redactedCallJson + ",\"result\":" + result + "}");

    std::map<std::string, JsonField> resultFields;
    const bool parsed = parseFieldsOrEmpty(result, resultFields);
    const std::string status = parsed ? stringField(resultFields, "status", "succeeded") : "succeeded";
    const std::string content = parsed ? stringField(resultFields, "content", result) : result;
    const std::string error = parsed ? stringField(resultFields, "errorMessage", "") : "";
    const std::string observation = session.recordObservation(
        toolName,
        status,
        content,
        error,
        confirmationRequired,
        confirmed
    );
    callbacks_.emitEvent("observation_created", observation);
    HookDispatcher(callbacks_).dispatch("observation_created", observation);
    return result;
}

std::string ToolExecutor::runMultiToolCall(RuntimeSession &session, const std::string &toolCallsJson) const {
    const std::vector<std::string> calls = extractObjectArrayItems(toolCallsJson);
    if (calls.empty()) {
        return "{\"status\":\"failed\",\"content\":\"\",\"errorMessage\":\"multi_tool_use contained no tool calls\"}";
    }

    std::ostringstream observations;
    observations << "[";
    for (size_t index = 0; index < calls.size(); index++) {
        std::map<std::string, JsonField> fields;
        if (!parseFieldsOrEmpty(calls[index], fields)) {
            return "{\"status\":\"failed\",\"content\":\"\",\"errorMessage\":\"multi_tool_use contains an invalid tool call object\"}";
        }
        const std::string toolName = stringField(fields, "tool_name");
        const std::string parameters = rawField(fields, "parameters", "{}");
        if (toolName.empty() || !tools_.contains(toolName)) {
            return "{\"status\":\"failed\",\"content\":\"\",\"errorMessage\":\"multi_tool_use contains an unregistered tool\"}";
        }
        if (!tools_.isReadOnly(toolName)) {
            return "{\"status\":\"failed\",\"content\":\"\",\"errorMessage\":\"multi_tool_use may only execute read-only tools\"}";
        }
        if (index > 0) {
            observations << ",";
        }
        observations << runToolCall(session, toolName, parameters, false);
        if (session.hasFinal()) {
            break;
        }
    }
    observations << "]";
    return observations.str();
}

} // namespace LuminaAgent
