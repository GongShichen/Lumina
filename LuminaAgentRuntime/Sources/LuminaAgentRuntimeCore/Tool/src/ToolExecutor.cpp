#include "ToolExecutor.hpp"

#include <chrono>
#include <map>
#include <sstream>

#include "Hooks.hpp"
#include "Json.hpp"

namespace LuminaAgent {

static std::string timestampMilliseconds() {
    const auto now = std::chrono::system_clock::now().time_since_epoch();
    const auto millis = std::chrono::duration_cast<std::chrono::milliseconds>(now).count();
    return std::to_string(millis);
}

static std::string excerpt(const std::string &text, size_t limit) {
    if (text.size() <= limit) {
        return text;
    }
    return text.substr(0, limit) + "...";
}

static bool shouldRecordForReplay(const std::string &policy, const std::map<std::string, JsonField> &resultFields) {
    if (policy == "always_execute") {
        return false;
    }
    if (boolField(resultFields, "retryable", false)) {
        return false;
    }
    const std::string status = lowercased(stringField(resultFields, "status", "succeeded"));
    return status != "cancelled";
}

static std::string callerProvidedIdempotencyKey(const std::string &parameters) {
    std::map<std::string, JsonField> fields;
    if (!parseFieldsOrEmpty(parameters.empty() ? "{}" : parameters, fields)) {
        return "";
    }
    for (const std::string &field : {"idempotency_key", "instance_id", "client_request_id"}) {
        const std::string value = stringField(fields, field);
        if (!value.empty()) {
            return value;
        }
    }
    return "";
}

static std::string makeDedupKey(
    const std::string &toolName,
    const std::string &canonicalParameters,
    const std::string &idempotencyPolicy,
    const std::string &parameters
) {
    if (idempotencyPolicy == "caller_keyed") {
        const std::string callerKey = callerProvidedIdempotencyKey(parameters);
        if (!callerKey.empty()) {
            return toolName + "\ncaller_key:" + callerKey;
        }
    }
    return toolName + "\n" + canonicalParameters;
}

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

    const std::string callId = session.nextToolCallId();
    const std::string canonicalParameters = canonicalizeJsonObject(parameters.empty() ? "{}" : parameters);
    const std::string idempotencyPolicy = tools_.idempotencyPolicy(toolName);
    const std::string dedupKey = makeDedupKey(toolName, canonicalParameters, idempotencyPolicy, parameters);
    callbacks_.emitEvent(
        "tool_call_resolved",
        "{\"tool_name\":" + jsonString(toolName) +
            ",\"call_id\":" + jsonString(callId) +
            ",\"idempotency_policy\":" + jsonString(idempotencyPolicy) +
            ",\"dedup_key\":" + jsonString(dedupKey) +
            ",\"canonical_parameters\":" + jsonString(excerpt(canonicalParameters, 800)) + "}"
    );
    if (idempotencyPolicy != "always_execute") {
        if (const ToolCallLedgerEntry *entry = session.findReplayableToolCall(dedupKey)) {
            const std::string observation = session.recordReplayObservation(toolName, *entry);
            callbacks_.emitEvent("observation_created", observation);
            callbacks_.emitEvent(
                "tool_call_replayed",
                "{\"tool_name\":" + jsonString(toolName) +
                    ",\"call_id\":" + jsonString(callId) +
                    ",\"duplicate_of\":" + jsonString(entry->callId) +
                    ",\"dedup_key\":" + jsonString(dedupKey) +
                    ",\"previous_status\":" + jsonString(entry->status) +
                    ",\"previous_summary\":" + jsonString(excerpt(entry->summary, 800)) + "}"
            );
            callbacks_.audit(
                "tool_replayed",
                "{\"tool_name\":" + jsonString(toolName) +
                    ",\"call_id\":" + jsonString(callId) +
                    ",\"duplicate_of\":" + jsonString(entry->callId) +
                    ",\"dedup_key\":" + jsonString(dedupKey) + "}"
            );
            HookDispatcher(callbacks_).dispatch("observation_created", observation);
            return "{\"status\":" + jsonString(entry->status) +
                ",\"content\":" + jsonString(entry->summary) +
                ",\"replayed\":true," +
                "\"duplicate_of\":" + jsonString(entry->callId) + "}";
        }
    }

    const std::string validation = tools_.validateCallJson(toolName, parameters);
    std::map<std::string, JsonField> validationFields;
    if (parseFieldsOrEmpty(validation, validationFields) && !boolField(validationFields, "ok", false)) {
        const std::string error = stringField(validationFields, "error", "tool parameters failed validation");
        const std::string result = "{\"status\":\"failed\",\"content\":\"\",\"errorMessage\":" + jsonString(error) + "}";
        const std::string observation = session.recordObservation(toolName, "failed", "", error, false, false);
        callbacks_.emitEvent(
            "tool_parameter_validation_failed",
            "{\"tool_name\":" + jsonString(toolName) +
                ",\"call_id\":" + jsonString(callId) +
                ",\"error\":" + jsonString(error) +
                ",\"parameters\":" + jsonString(excerpt(parameters, 800)) + "}"
        );
        std::map<std::string, JsonField> observationFields;
        parseFieldsOrEmpty(observation, observationFields);
        if (idempotencyPolicy != "always_execute") {
            ToolCallLedgerEntry entry;
            entry.callId = callId;
            entry.toolName = toolName;
            entry.dedupKey = dedupKey;
            entry.canonicalParameters = canonicalParameters;
            entry.status = "failed";
            entry.summary = stringField(observationFields, "summary", error);
            entry.rawResultJson = result;
            entry.timestamp = timestampMilliseconds();
            entry.replayable = true;
            session.recordToolCallLedgerEntry(entry);
        }
        callbacks_.emitEvent("observation_created", observation);
        return result;
    }

    const std::string callJson = "{\"tool_name\":" + jsonString(toolName) +
        ",\"call_id\":" + jsonString(callId) +
        ",\"parameters\":" + parameters +
        ",\"requires_confirmation\":" + jsonBool(requiresConfirmation) + "}";
    const std::string redactedCallJson = "{\"tool_name\":" + jsonString(toolName) +
        ",\"call_id\":" + jsonString(callId) +
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

    std::map<std::string, JsonField> resultFields;
    std::string resultValidation = tools_.validateResultJson(toolName, result);
    std::map<std::string, JsonField> resultValidationFields;
    bool parsed = parseFieldsOrEmpty(result, resultFields);
    if (parseFieldsOrEmpty(resultValidation, resultValidationFields) && !boolField(resultValidationFields, "ok", false)) {
        const std::string error = stringField(resultValidationFields, "error", "tool result failed validation");
        result = "{\"status\":\"failed\",\"content\":\"\",\"errorMessage\":" + jsonString(error) + "}";
        resultFields.clear();
        parsed = parseFieldsOrEmpty(result, resultFields);
    }
    callbacks_.audit("tool_did_execute", "{\"call\":" + redactedCallJson + ",\"result\":" + result + "}");
    HookDispatcher(callbacks_).dispatch("tool_did_execute", "{\"call\":" + redactedCallJson + ",\"result\":" + result + "}");
    callbacks_.emitEvent(
        "tool_callback_returned",
        "{\"tool_name\":" + jsonString(toolName) +
            ",\"call_id\":" + jsonString(callId) +
            ",\"raw_result_excerpt\":" + jsonString(excerpt(result, 1200)) + "}"
    );

    const std::string status = parsed ? stringField(resultFields, "status", "succeeded") : "succeeded";
    const std::string content = tools_.truncateResultContent(toolName, parsed ? stringField(resultFields, "content", result) : result);
    const std::string error = parsed ? stringField(resultFields, "errorMessage", "") : "";
    const std::string observation = session.recordObservation(
        toolName,
        status,
        content,
        error,
        confirmationRequired,
        confirmed
    );
    std::map<std::string, JsonField> observationFields;
    parseFieldsOrEmpty(observation, observationFields);
    if (parsed && shouldRecordForReplay(idempotencyPolicy, resultFields)) {
        ToolCallLedgerEntry entry;
        entry.callId = callId;
        entry.toolName = toolName;
        entry.dedupKey = dedupKey;
        entry.canonicalParameters = canonicalParameters;
        entry.status = lowercased(status.empty() ? "succeeded" : status);
        entry.summary = stringField(observationFields, "summary", content);
        entry.rawResultJson = result;
        entry.timestamp = timestampMilliseconds();
        entry.replayable = true;
        session.recordToolCallLedgerEntry(entry);
    }
    callbacks_.emitEvent("observation_created", observation);
    HookDispatcher(callbacks_).dispatch("observation_created", observation);
    return result;
}

std::string ToolExecutor::runMultiToolCall(RuntimeSession &session, const std::string &toolCallsJson) const {
    const std::vector<std::string> calls = extractObjectArrayItems(toolCallsJson);
    if (calls.empty()) {
        const std::string result = "{\"status\":\"failed\",\"content\":\"\",\"errorMessage\":\"multi_tool_use contained no tool calls\"}";
        session.recordObservation("multi_tool_use", "failed", "", "multi_tool_use contained no tool calls", false, false);
        return result;
    }

    std::ostringstream observations;
    observations << "[";
    for (size_t index = 0; index < calls.size(); index++) {
        std::map<std::string, JsonField> fields;
        if (!parseFieldsOrEmpty(calls[index], fields)) {
            const std::string result = "{\"status\":\"failed\",\"content\":\"\",\"errorMessage\":\"multi_tool_use contains an invalid tool call object\"}";
            session.recordObservation("multi_tool_use", "failed", "", "multi_tool_use contains an invalid tool call object", false, false);
            return result;
        }
        const std::string toolName = stringField(fields, "tool_name");
        const std::string parameters = rawField(fields, "parameters", "{}");
        if (toolName.empty() || !tools_.contains(toolName)) {
            const std::string result = "{\"status\":\"failed\",\"content\":\"\",\"errorMessage\":\"multi_tool_use contains an unregistered tool\"}";
            session.recordObservation("multi_tool_use", "failed", "", "multi_tool_use contains an unregistered tool", false, false);
            return result;
        }
        if (!tools_.isReadOnly(toolName)) {
            const std::string result = "{\"status\":\"failed\",\"content\":\"\",\"errorMessage\":\"multi_tool_use may only execute read-only tools\"}";
            session.recordObservation("multi_tool_use", "failed", "", "multi_tool_use may only execute read-only tools", false, false);
            return result;
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
