#include "ToolExecutor.hpp"

#include <chrono>
#include <algorithm>
#include <map>
#include <sstream>
#include <thread>

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
    if (boolField(resultFields, "retryable", false) && policy != "caller_keyed") {
        return false;
    }
    const std::string status = lowercased(stringField(resultFields, "status", "succeeded"));
    return status != "cancelled" || policy == "caller_keyed";
}

static bool allowsCorrectedValidationCall(const ToolCallLedgerEntry &entry, const std::string &canonicalParameters) {
    std::map<std::string, JsonField> fields;
    return entry.status == "failed" && entry.canonicalParameters != canonicalParameters &&
        parseFieldsOrEmpty(entry.rawResultJson, fields) && boolField(fields, "validation_failed", false);
}

static std::string withJsonField(const std::string &object, const std::string &name, const std::string &value) {
    std::map<std::string, JsonField> fields;
    parseFieldsOrEmpty(object, fields);
    std::string result = "{";
    for (const auto &entry : fields) {
        if (entry.first == name) continue;
        result += jsonString(entry.first) + ":" + entry.second.raw + ",";
    }
    return result + jsonString(name) + ":" + value + "}";
}

static bool isIdentifierField(const std::string &name) {
    const std::string lower = lowercased(name);
    const auto endsWith = [&](const std::string &suffix) {
        return name.size() >= suffix.size() && name.compare(name.size() - suffix.size(), suffix.size(), suffix) == 0;
    };
    return lower == "id" || lower == "identifier" || endsWith("Id") || endsWith("ID") || endsWith("_id") ||
        (lower.size() > 10 && lower.compare(lower.size() - 10, 10, "identifier") == 0);
}

static std::string identifierLookupFeedback(
    const ToolRegistry &tools,
    const std::string &toolName,
    const std::map<std::string, JsonField> &arguments,
    const std::map<std::string, JsonField> &validation
) {
    bool missingIdentifier = false;
    for (const std::string &item : extractObjectArrayItems(rawField(validation, "fieldErrors", "[]"))) {
        std::map<std::string, JsonField> fields;
        if (!parseFieldsOrEmpty(item, fields)) continue;
        const std::string field = stringField(fields, "field");
        if (isIdentifierField(field) && arguments.find(field) == arguments.end()) missingIdentifier = true;
    }
    const size_t separator = toolName.rfind('.');
    if (!missingIdentifier || separator == std::string::npos) return "";
    std::string candidates = "[";
    std::string suggestedCall = "null";
    for (const std::string &operation : {"search", "list"}) {
        const std::string candidate = toolName.substr(0, separator + 1) + operation;
        if (!tools.contains(candidate) || !tools.isReadOnly(candidate)) continue;
        const std::string schema = tools.schemaJson(candidate);
        if (candidates != "[") candidates += ",";
        candidates += schema;
        // Only copy fields already supplied under the same names. An update title
        // may be the NEW title, so it must not be invented as a search query.
        std::map<std::string, JsonField> schemaFields;
        parseFieldsOrEmpty(schema, schemaFields);
        // The lightweight validator covers the parameter list only. Do not
        // advertise an executable call when a custom schema may add constraints.
        const std::string customSchema = rawField(schemaFields, "inputSchema", rawField(schemaFields, "input_schema", "null"));
        if (customSchema != "null" && customSchema != "{}") continue;
        const auto parameterList = schemaFields.find("parameters");
        if (parameterList != schemaFields.end() && parameterList->second.kind != JsonKind::array) continue;
        std::string lookupArguments = "{}";
        for (const std::string &parameter : extractObjectArrayItems(rawField(schemaFields, "parameters", "[]"))) {
            std::map<std::string, JsonField> parameterFields;
            parseFieldsOrEmpty(parameter, parameterFields);
            const std::string name = stringField(parameterFields, "name");
            const auto value = arguments.find(name);
            if (value != arguments.end()) lookupArguments = withJsonField(lookupArguments, name, value->second.raw);
        }
        std::map<std::string, JsonField> result;
        parseFieldsOrEmpty(tools.validateCallJson(candidate, lookupArguments), result);
        if (suggestedCall == "null" && boolField(result, "ok", false) && tools.isCallable(candidate, {})) {
            suggestedCall = "{\"toolName\":" + jsonString(candidate) + ",\"arguments\":" + lookupArguments + "}";
        }
    }
    candidates += "]";
    return "{\"availableTools\":" + candidates + ",\"suggestedCall\":" + suggestedCall + "}";
}

static std::string correctionOutput(
    const ToolRegistry &tools,
    const std::string &toolName,
    const std::string &parameters,
    const std::string &code,
    const std::string &reason,
    const std::string &retryPolicy,
    const std::string &validation = "{}"
) {
    std::map<std::string, JsonField> parameterFields, validationFields;
    const bool validParameters = parseFieldsOrEmpty(parameters, parameterFields);
    parseFieldsOrEmpty(validation, validationFields);
    const std::string lookup = retryPolicy == "correct_arguments"
        ? identifierLookupFeedback(tools, toolName, parameterFields, validationFields) : "";
    std::string failure = "{\"code\":" + jsonString(lookup.empty() ? code : "missing_identifier") +
        ",\"reason\":" + jsonString(reason) +
        ",\"toolName\":" + jsonString(toolName) +
        ",\"arguments\":" + (validParameters ? parameters : "null") +
        ",\"fieldErrors\":" + rawField(validationFields, "fieldErrors", "[]") +
        ",\"missingInformation\":" + rawField(validationFields, "missingInformation", "[]") +
        ",\"retryPolicy\":" + jsonString(lookup.empty() ? retryPolicy : "prerequisite") +
        ",\"toolSchema\":" + tools.schemaJson(toolName);
    if (code == "unknown_tool") {
        const size_t separator = toolName.find('.');
        const std::string query = separator == std::string::npos ? toolName : toolName.substr(0, separator);
        failure += ",\"availableTools\":" + tools.discoverToolsJson(query, "", 4, true);
        failure += ",\"guidance\":\"Choose a registered tool from the relevant candidates and follow its schema. Never invent a tool name or arguments.\"";
    } else if (!lookup.empty()) {
        std::map<std::string, JsonField> lookupFields;
        parseFieldsOrEmpty(lookup, lookupFields);
        failure += ",\"availableTools\":" + rawField(lookupFields, "availableTools", "[]") +
            ",\"suggestedCall\":" + rawField(lookupFields, "suggestedCall", "null");
        failure += ",\"guidance\":\"The object identifier is missing. First search or list the corresponding objects using the registered lookup schemas, then use the real returned ID. If suggestedCall is null, obtain the required lookup arguments from the user request or ask the user; never execute an incomplete call or invent an ID. Ask the user if multiple objects match.\"";
    } else if (retryPolicy == "correct_arguments") {
        failure += ",\"guidance\":\"Correct only the invalid fields using this schema and user intent. Obtain missing IDs from a lookup tool and dates from a current-time observation; do not fabricate values.\"";
    } else if (retryPolicy == "request_permission") {
        failure += ",\"guidance\":\"Stop this operation and explain the required permission. Do not retry or switch tools to bypass the denial.\"";
    } else if (retryPolicy == "verify_before_retry") {
        failure += ",\"guidance\":\"The write outcome is uncertain. Do not retry or change identifiers to repeat the write; explain the failure and verify existing state first.\"";
    } else {
        failure += ",\"guidance\":\"Explain this failure and stop this operation unless new user input resolves it.\"";
    }
    if (lookup.empty()) failure += ",\"suggestedCall\":null";
    return "{\"failure\":" + failure + "}}";
}

static std::string failureResult(const std::string &status, const std::string &reason, const std::string &output, bool validationFailed = false) {
    return "{\"status\":" + jsonString(status) + ",\"content\":\"\",\"errorMessage\":" + jsonString(reason) +
        ",\"output\":" + output + (validationFailed ? ",\"validation_failed\":true" : "") + "}";
}

static std::string replayResult(const ToolCallLedgerEntry &entry) {
    return withJsonField(withJsonField(entry.rawResultJson, "replayed", "true"), "duplicate_of", jsonString(entry.callId));
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

static bool isInternalRuntimeTool(const std::string &toolName) {
    return toolName.rfind("runtime.", 0) == 0;
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
        return toolName + "\ncaller_key:implicit";
    }
    return toolName + "\n" + canonicalParameters;
}

static std::string retryRequestJson(
    const RuntimeSession &session,
    const std::string &stage,
    int attempt,
    int maxAttempts,
    const std::string &errorCode,
    const std::string &errorCategory,
    bool recoverable,
    long long elapsedMilliseconds,
    const std::string &toolName,
    const std::string &toolSideEffect,
    const std::string &idempotencyPolicy,
    bool hasIdempotencyKey,
    bool toolReadOnly,
    bool toolDestructive
) {
    std::ostringstream output;
    output << "{"
           << "\"session_id\":" << jsonString(session.sessionId()) << ","
           << "\"run_id\":" << jsonString(session.runId()) << ","
           << "\"stage\":" << jsonString(stage) << ","
           << "\"attempt\":" << attempt << ","
           << "\"max_attempts\":" << maxAttempts << ","
           << "\"error_code\":" << jsonString(errorCode) << ","
           << "\"error_category\":" << jsonString(errorCategory) << ","
           << "\"recoverable\":" << jsonBool(recoverable) << ","
           << "\"tool_name\":" << jsonString(toolName) << ","
           << "\"tool_side_effect\":" << jsonString(toolSideEffect) << ","
           << "\"idempotency_policy\":" << jsonString(idempotencyPolicy) << ","
           << "\"has_idempotency_key\":" << jsonBool(hasIdempotencyKey) << ","
           << "\"tool_read_only\":" << jsonBool(toolReadOnly) << ","
           << "\"tool_destructive\":" << jsonBool(toolDestructive) << ","
           << "\"retry_after_seconds\":0,"
           << "\"elapsed_ms\":" << elapsedMilliseconds
           << "}";
    return output.str();
}

static void sleepForRetryDecision(const RuntimeCallbacks &callbacks, const std::string &retryRequest, const RuntimeRetryDecision &decision) {
    callbacks.emitEvent(
        "runtime.retry.scheduled",
        "{\"request\":" + retryRequest +
            ",\"decision\":{\"action\":" + jsonString(decision.action) +
            ",\"delay_ms\":" + std::to_string(std::max<long long>(0, decision.delayMilliseconds)) +
            ",\"reason\":" + jsonString(decision.reason) + "}}"
    );
    if (decision.delayMilliseconds > 0) {
        std::this_thread::sleep_for(std::chrono::milliseconds(decision.delayMilliseconds));
    }
}

static bool terminalGuardrailToolDecision(
    RuntimeSession &session,
    const RuntimeCallbacks &callbacks,
    const ToolRegistry &tools,
    const std::string &toolName,
    const std::string &parameters,
    const RuntimeGuardrailDecision &decision,
    std::string &result
) {
    if (decision.decision == "tripwire_failure") {
        const std::string message = decision.message.empty() ? "tool guardrail tripwire failure" : decision.message;
        session.failWithResult("guardrail-tripwire", "### 已终止\n\n" + message);
        callbacks.emitEvent("guardrail_tripwire", "{\"stage\":\"tool\",\"tool_name\":" + jsonString(toolName) + ",\"message\":" + jsonString(message) + "}");
        result = failureResult("failed", message, correctionOutput(tools, toolName, parameters, "guardrail_tripwire", message, "stop"));
        return true;
    }
    if (decision.decision == "reject") {
        const std::string message = decision.message.empty() ? "tool guardrail rejected payload" : decision.message;
        callbacks.emitEvent("guardrail_rejected", "{\"stage\":\"tool\",\"tool_name\":" + jsonString(toolName) + ",\"message\":" + jsonString(message) + "}");
        result = failureResult("denied", message, correctionOutput(tools, toolName, parameters, "guardrail_rejected", message, "request_permission"));
        return true;
    }
    return false;
}

static std::string guardrailRewritePayload(const RuntimeGuardrailDecision &decision) {
    if (decision.decision != "rewrite" || decision.payloadJson.empty()) {
        return "";
    }
    return decision.payloadJson;
}

ToolExecutor::ToolExecutor(const ToolRegistry &tools, const RuntimeCallbacks &callbacks, RuntimeReplayController *replay,
                           const std::atomic_bool *cancelled)
    : tools_(tools), callbacks_(callbacks), replay_(replay), cancelled_(cancelled) {}

bool ToolExecutor::cancellationRequested() const {
    return cancelled_ != nullptr && cancelled_->load();
}

std::string ToolExecutor::runToolCall(
    RuntimeSession &session,
    const std::string &toolName,
    const std::string &parameters,
    bool requiresConfirmation
) const {
    std::string activeToolName = toolName;
    std::string activeParameters = parameters.empty() ? "{}" : parameters;
    bool confirmationRequired = requiresConfirmation;
    const std::string callId = session.nextToolCallId();
    const auto logicalCallKey = [&]() {
        return makeDedupKey(activeToolName, "", "caller_keyed", activeParameters);
    };
    auto stopBeforeCallback = [&]() {
        if (cancellationRequested()) session.cancel();
        const std::string reason = "Task stopped before the tool callback executed; this call performed no operation.";
        const std::string output = correctionOutput(tools_, activeToolName, activeParameters, "cancelled", reason, "stop");
        const std::string result = failureResult("cancelled", reason, output);
        const std::string observation = session.recordObservation(activeToolName, "cancelled", "", reason, false, false, output, callId);
        const std::string detail = "{\"call_id\":" + jsonString(callId) + ",\"tool_name\":" + jsonString(activeToolName) + "}";
        callbacks_.emitEvent("tool_call_cancelled_before_execution", detail);
        callbacks_.audit("tool_call_cancelled_before_execution", detail);
        callbacks_.emitEvent("observation_created", observation);
        return result;
    };
    if (cancellationRequested()) return stopBeforeCallback();

    auto failBeforeExecution = [&](const std::string &observedToolName, const std::string &error, bool emitUnknownTool) {
        const std::string output = correctionOutput(tools_, observedToolName, activeParameters,
            tools_.contains(observedToolName) ? "tool_unavailable" : "unknown_tool", error, "discover_tool");
        const std::string result = failureResult("failed", error, output, true);
        const std::string observation = session.recordObservation(observedToolName, "failed", "", error, false, false, output, callId, logicalCallKey(), true);
        if (emitUnknownTool) {
            callbacks_.emitEvent("tool_loading.unknown_tool", "{\"tool_name\":" + jsonString(observedToolName) + ",\"reason\":" + jsonString(error) + "}");
        }
        callbacks_.emitEvent("observation_created", observation);
        return result;
    };
    auto resolveAndValidate = [&]() -> std::string {
        const std::string requestedName = activeToolName;
        const std::string canonicalName = tools_.resolveName(requestedName);
        if (canonicalName.empty()) {
            return failBeforeExecution(requestedName, "tool is not registered", false);
        }
        if (canonicalName != requestedName) {
            const std::string warning = tools_.aliasWarning(requestedName);
            callbacks_.emitEvent(
                warning.empty() ? "tool_alias_resolved" : "tool_deprecated_alias_resolved",
                "{\"requested_tool_name\":" + jsonString(requestedName) +
                    ",\"tool_name\":" + jsonString(canonicalName) +
                    ",\"warning\":" + jsonString(warning) + "}"
            );
            activeToolName = canonicalName;
        }
        confirmationRequired = confirmationRequired || tools_.requiresConfirmation(activeToolName);
        if (!tools_.isCallable(activeToolName, session.loadedToolNames())) {
            const std::string error = tools_.isDeferred(activeToolName)
                ? "tool is deferred; emit tool_discovery to load its full schema before tool_use"
                : "tool is not callable";
            return failBeforeExecution(activeToolName, error, true);
        }
        const std::string localCanonicalParameters = canonicalizeJsonObject(activeParameters);
        const std::string localIdempotencyPolicy = tools_.idempotencyPolicy(activeToolName);
        const std::string localDedupKey = makeDedupKey(activeToolName, localCanonicalParameters, localIdempotencyPolicy, activeParameters);
        if (localIdempotencyPolicy != "always_execute") {
            const ToolCallLedgerEntry *entry = session.findReplayableToolCall(localDedupKey);
            if (entry != nullptr) {
                std::map<std::string, JsonField> previousFields;
                parseFieldsOrEmpty(entry->rawResultJson, previousFields);
                // Preserve hook/guardrail rewriting before replaying an executed call.
                if (entry->status != "failed" || !boolField(previousFields, "validation_failed", false)) {
                    return "";
                }
            }
            if (entry != nullptr && !allowsCorrectedValidationCall(*entry, localCanonicalParameters)) {
                const std::string observation = session.recordReplayObservation(activeToolName, *entry, callId, logicalCallKey());
                callbacks_.emitEvent("observation_created", observation);
                callbacks_.emitEvent(
                    "tool_call_replayed",
                    "{\"tool_name\":" + jsonString(activeToolName) +
                        ",\"call_id\":" + jsonString(callId) +
                        ",\"duplicate_of\":" + jsonString(entry->callId) +
                        ",\"dedup_key\":" + jsonString(localDedupKey) +
                        ",\"previous_status\":" + jsonString(entry->status) +
                        ",\"previous_summary\":" + jsonString(excerpt(entry->summary, 800)) + "}"
                );
                callbacks_.audit(
                    "tool_replayed",
                    "{\"tool_name\":" + jsonString(activeToolName) +
                        ",\"call_id\":" + jsonString(callId) +
                        ",\"duplicate_of\":" + jsonString(entry->callId) +
                        ",\"dedup_key\":" + jsonString(localDedupKey) + "}"
                );
                HookDispatcher(callbacks_).dispatch("observation_created", observation);
                return replayResult(*entry);
            }
        }
        const std::string validation = tools_.validateCallJson(activeToolName, activeParameters);
        std::map<std::string, JsonField> validationFields;
        if (parseFieldsOrEmpty(validation, validationFields) && !boolField(validationFields, "ok", false)) {
            const std::string error = stringField(validationFields, "error", "tool parameters failed validation");
            const std::string output = correctionOutput(tools_, activeToolName, activeParameters, "validation_failed", error, "correct_arguments", validation);
            const std::string result = failureResult("failed", error, output, true);
            const std::string observation = session.recordObservation(activeToolName, "failed", "", error, false, false, output, callId, logicalCallKey(), true);
            std::map<std::string, JsonField> observationFields;
            parseFieldsOrEmpty(observation, observationFields);
            if (localIdempotencyPolicy != "always_execute") {
                ToolCallLedgerEntry entry;
                entry.callId = callId;
                entry.toolName = activeToolName;
                entry.dedupKey = localDedupKey;
                entry.canonicalParameters = localCanonicalParameters;
                entry.status = "failed";
                entry.summary = stringField(observationFields, "summary", error);
                entry.rawResultJson = result;
                entry.timestamp = timestampMilliseconds();
                entry.replayable = true;
                session.recordToolCallLedgerEntry(entry);
            }
            callbacks_.emitEvent(
                "tool_parameter_validation_failed",
                "{\"tool_name\":" + jsonString(activeToolName) +
                    ",\"call_id\":" + jsonString(callId) +
                    ",\"error\":" + jsonString(error) +
                    ",\"parameters\":" + jsonString(excerpt(activeParameters, 800)) + "}"
            );
            callbacks_.emitEvent("observation_created", observation);
            return result;
        }
        return "";
    };
    std::string preflightFailure = resolveAndValidate();
    if (!preflightFailure.empty()) {
        return preflightFailure;
    }

    const std::string guardrailPayload = "{\"tool_name\":" + jsonString(activeToolName) +
        ",\"call_id\":" + jsonString(callId) +
        ",\"parameters\":" + activeParameters +
        ",\"requires_confirmation\":" + jsonBool(confirmationRequired) +
        ",\"side_effect\":" + jsonString(tools_.sideEffect(activeToolName)) +
        ",\"sensitivity\":" + jsonString(tools_.sensitivity(activeToolName)) +
        ",\"destructive\":" + jsonBool(tools_.isDestructive(activeToolName)) + "}";
    const RuntimeGuardrailDecision toolInputGuardrail = callbacks_.evaluateGuardrail("tool_input", guardrailPayload);
    std::string guardrailResult;
    if (terminalGuardrailToolDecision(session, callbacks_, tools_, activeToolName, activeParameters, toolInputGuardrail, guardrailResult)) {
        if (toolInputGuardrail.decision == "reject") {
            std::map<std::string, JsonField> rejectedFields;
            parseFieldsOrEmpty(guardrailResult, rejectedFields);
            const std::string observation = session.recordObservation(
                activeToolName,
                "denied",
                "",
                toolInputGuardrail.message.empty() ? "tool guardrail rejected payload" : toolInputGuardrail.message,
                false,
                false,
                rawField(rejectedFields, "output", "{}"),
                callId
            );
            callbacks_.emitEvent("observation_created", observation);
        }
        return guardrailResult;
    }
    const std::string rewrittenToolInput = guardrailRewritePayload(toolInputGuardrail);
    if (!rewrittenToolInput.empty()) {
        std::map<std::string, JsonField> rewrittenFields;
        std::string rewrittenObject = rewrittenToolInput;
        std::map<std::string, JsonField> envelopeFields;
        if (parseFieldsOrEmpty(rewrittenToolInput, envelopeFields) && rawField(envelopeFields, "call", "").size() > 0) {
            rewrittenObject = rawField(envelopeFields, "call", "{}");
        }
        if (parseFieldsOrEmpty(rewrittenObject, rewrittenFields)) {
            activeToolName = stringField(rewrittenFields, "tool_name", stringField(rewrittenFields, "toolName", activeToolName));
            activeParameters = rawField(rewrittenFields, "parameters", rawField(rewrittenFields, "arguments", activeParameters.empty() ? "{}" : activeParameters));
            confirmationRequired = confirmationRequired || boolField(rewrittenFields, "requires_confirmation", boolField(rewrittenFields, "requiresConfirmation", false));
            callbacks_.emitEvent("guardrail_rewritten", "{\"stage\":\"tool_input\",\"tool_name\":" + jsonString(activeToolName) + "}");
        }
    }

    preflightFailure = resolveAndValidate();
    if (!preflightFailure.empty()) {
        return preflightFailure;
    }

    std::string canonicalParameters = canonicalizeJsonObject(activeParameters);
    std::string idempotencyPolicy = tools_.idempotencyPolicy(activeToolName);
    std::string dedupKey = makeDedupKey(activeToolName, canonicalParameters, idempotencyPolicy, activeParameters);
    const std::string initialHookPayload = "{\"tool_name\":" + jsonString(activeToolName) +
        ",\"call_id\":" + jsonString(callId) +
        ",\"parameters\":" + activeParameters +
        ",\"requires_confirmation\":" + jsonBool(confirmationRequired) +
        ",\"side_effect\":" + jsonString(tools_.sideEffect(activeToolName)) +
        ",\"sensitivity\":" + jsonString(tools_.sensitivity(activeToolName)) +
        ",\"destructive\":" + jsonBool(tools_.isDestructive(activeToolName)) + "}";
    const RuntimeHookDirectives beforeToolDirectives = parseRuntimeHookDirectives(
        HookDispatcher(callbacks_).dispatch("before_tool", initialHookPayload)
    );
    if (beforeToolDirectives.hasFail) {
        session.failWithResult(
            beforeToolDirectives.reason.empty() ? "hook failed tool call" : beforeToolDirectives.reason,
            beforeToolDirectives.markdown.empty() ? "### 已终止\n\nRuntime hook stopped this tool call." : beforeToolDirectives.markdown
        );
        return "{\"status\":\"failed\",\"content\":\"\",\"errorMessage\":\"hook failed run\"}";
    }
    if (beforeToolDirectives.hasPause) {
        session.pause(
            beforeToolDirectives.pauseKind.empty() ? "hook" : beforeToolDirectives.pauseKind,
            beforeToolDirectives.pausePayloadJson.empty() ? "{}" : beforeToolDirectives.pausePayloadJson
        );
        return "{\"status\":\"cancelled\",\"content\":\"\",\"errorMessage\":\"hook paused run\"}";
    }
    if (beforeToolDirectives.hasRejectToolCall) {
        const std::string error = beforeToolDirectives.reason.empty() ? "tool call rejected by hook" : beforeToolDirectives.reason;
        const bool validationFailed = beforeToolDirectives.rejectionValidationFailed;
        const std::string status = validationFailed ? "failed" : "denied";
        const std::string output = beforeToolDirectives.rejectionOutputJson.empty() || beforeToolDirectives.rejectionOutputJson == "{}"
            ? correctionOutput(tools_, activeToolName, activeParameters, validationFailed ? "validation_failed" : "policy_denied", error,
                validationFailed ? "correct_arguments" : "request_permission")
            : beforeToolDirectives.rejectionOutputJson;
        const std::string result = failureResult(status, error, output, validationFailed);
        const std::string observation = session.recordObservation(activeToolName, status, "", error, false, false, output, callId, logicalCallKey(), validationFailed);
        callbacks_.emitEvent("observation_created", observation);
        return result;
    }
    if (beforeToolDirectives.hasRewriteToolCall) {
        if (!beforeToolDirectives.rewrittenToolName.empty()) {
            activeToolName = beforeToolDirectives.rewrittenToolName;
        }
        if (!beforeToolDirectives.rewrittenParametersJson.empty()) {
            activeParameters = beforeToolDirectives.rewrittenParametersJson;
        }
        confirmationRequired = confirmationRequired || beforeToolDirectives.requiresConfirmation;
        if (!tools_.contains(activeToolName)) {
            const std::string error = "rewritten tool is not registered";
            const std::string result = "{\"status\":\"failed\",\"content\":\"\",\"errorMessage\":" + jsonString(error) + "}";
            const std::string observation = session.recordObservation(activeToolName, "failed", "", error, false, false, "{}", callId);
            callbacks_.emitEvent("observation_created", observation);
            return result;
        }
        preflightFailure = resolveAndValidate();
        if (!preflightFailure.empty()) {
            return preflightFailure;
        }
        canonicalParameters = canonicalizeJsonObject(activeParameters);
        idempotencyPolicy = tools_.idempotencyPolicy(activeToolName);
        dedupKey = makeDedupKey(activeToolName, canonicalParameters, idempotencyPolicy, activeParameters);
        callbacks_.emitEvent(
            "tool_call_rewritten",
            "{\"tool_name\":" + jsonString(activeToolName) +
                ",\"call_id\":" + jsonString(callId) +
                ",\"canonical_parameters\":" + jsonString(excerpt(canonicalParameters, 800)) + "}"
        );
    } else if (beforeToolDirectives.requiresConfirmation) {
        confirmationRequired = true;
    }

    callbacks_.emitEvent(
        "tool_call_resolved",
        "{\"tool_name\":" + jsonString(activeToolName) +
            ",\"call_id\":" + jsonString(callId) +
            ",\"idempotency_policy\":" + jsonString(idempotencyPolicy) +
            ",\"dedup_key\":" + jsonString(dedupKey) +
            ",\"canonical_parameters\":" + jsonString(excerpt(canonicalParameters, 800)) + "}"
    );

    if (replay_ != nullptr && replay_->shouldReplayTools()) {
        const std::string replayedResult = replay_->consumeToolResult(activeToolName, canonicalParameters);
        if (!replayedResult.empty()) {
            std::map<std::string, JsonField> replayFields;
            const bool parsedReplay = parseFieldsOrEmpty(replayedResult, replayFields);
            const std::string status = parsedReplay ? stringField(replayFields, "status", "succeeded") : "succeeded";
            const std::string content = parsedReplay ? stringField(replayFields, "content", replayedResult) : replayedResult;
            const std::string error = parsedReplay ? stringField(replayFields, "errorMessage", "") : "";
            const std::string observation = session.recordObservation(
                activeToolName,
                status,
                content,
                error,
                confirmationRequired,
                true,
                parsedReplay ? rawField(replayFields, "output", "{}") : "{}",
                callId,
                logicalCallKey(),
                parsedReplay && boolField(replayFields, "validation_failed", false)
            );
            callbacks_.emitEvent(
                "tool_observation_replayed",
                "{\"tool_name\":" + jsonString(activeToolName) +
                    ",\"call_id\":" + jsonString(callId) +
                    ",\"canonical_parameters\":" + jsonString(excerpt(canonicalParameters, 800)) +
                    ",\"result_excerpt\":" + jsonString(excerpt(replayedResult, 1200)) + "}"
            );
            callbacks_.emitEvent("observation_created", observation);
            callbacks_.trace("tool_observation_replayed", "{\"tool_name\":" + jsonString(activeToolName) + ",\"call_id\":" + jsonString(callId) + ",\"observation\":" + observation + "}");
            HookDispatcher(callbacks_).dispatch("observation_created", observation);
            return replayedResult;
        }
        const bool toolReadOnly = tools_.isReadOnly(activeToolName);
        const bool toolDestructive = tools_.isDestructive(activeToolName);
        if (!replay_->allowsLiveTool(toolReadOnly, toolDestructive)) {
            const std::string error = "replay script did not provide a matching tool observation";
            const std::string result = "{\"status\":\"failed\",\"content\":\"\",\"errorMessage\":" + jsonString(error) + "}";
            const std::string observation = session.recordObservation(activeToolName, "failed", "", error, confirmationRequired, false, "{}", callId);
            callbacks_.emitEvent(
                "replay_missing_entry",
                "{\"kind\":\"tool_observation\",\"tool_name\":" + jsonString(activeToolName) +
                    ",\"call_id\":" + jsonString(callId) +
                    ",\"canonical_parameters\":" + jsonString(excerpt(canonicalParameters, 800)) +
                    ",\"allow_live_tool\":false}"
            );
            callbacks_.emitEvent("observation_created", observation);
            if (replay_->failOnMissingObservation()) {
                session.failWithResult("replay-missing-observation", "### 无法回放\n\n" + error);
            }
            return result;
        }
        if (replay_->requiresConfirmationForLiveSideEffect(toolReadOnly, toolDestructive)) {
            confirmationRequired = true;
        }
        callbacks_.emitEvent(
            "replay_live_fallback",
            "{\"kind\":\"tool_observation\",\"tool_name\":" + jsonString(activeToolName) +
                ",\"call_id\":" + jsonString(callId) +
                ",\"read_only\":" + jsonBool(toolReadOnly) +
                ",\"destructive\":" + jsonBool(toolDestructive) +
                ",\"requires_confirmation\":" + jsonBool(confirmationRequired) + "}"
        );
    }

    if (idempotencyPolicy != "always_execute") {
        const ToolCallLedgerEntry *entry = session.findReplayableToolCall(dedupKey);
        if (entry != nullptr && !allowsCorrectedValidationCall(*entry, canonicalParameters)) {
            const std::string observation = session.recordReplayObservation(activeToolName, *entry, callId, logicalCallKey());
            callbacks_.emitEvent("observation_created", observation);
            callbacks_.emitEvent(
                "tool_call_replayed",
                "{\"tool_name\":" + jsonString(activeToolName) +
                    ",\"call_id\":" + jsonString(callId) +
                    ",\"duplicate_of\":" + jsonString(entry->callId) +
                    ",\"dedup_key\":" + jsonString(dedupKey) +
                    ",\"previous_status\":" + jsonString(entry->status) +
                    ",\"previous_summary\":" + jsonString(excerpt(entry->summary, 800)) + "}"
            );
            callbacks_.audit(
                "tool_replayed",
                "{\"tool_name\":" + jsonString(activeToolName) +
                    ",\"call_id\":" + jsonString(callId) +
                    ",\"duplicate_of\":" + jsonString(entry->callId) +
                    ",\"dedup_key\":" + jsonString(dedupKey) + "}"
            );
            HookDispatcher(callbacks_).dispatch("observation_created", observation);
            return replayResult(*entry);
        }
    }

    const std::string validation = tools_.validateCallJson(activeToolName, activeParameters);
    std::map<std::string, JsonField> validationFields;
    if (parseFieldsOrEmpty(validation, validationFields) && !boolField(validationFields, "ok", false)) {
        const std::string error = stringField(validationFields, "error", "tool parameters failed validation");
        const std::string output = correctionOutput(tools_, activeToolName, activeParameters, "validation_failed", error, "correct_arguments", validation);
        const std::string result = failureResult("failed", error, output, true);
        const std::string observation = session.recordObservation(activeToolName, "failed", "", error, false, false, output, callId, logicalCallKey(), true);
        callbacks_.emitEvent(
            "tool_parameter_validation_failed",
            "{\"tool_name\":" + jsonString(activeToolName) +
                ",\"call_id\":" + jsonString(callId) +
                ",\"error\":" + jsonString(error) +
                ",\"parameters\":" + jsonString(excerpt(activeParameters, 800)) + "}"
        );
        std::map<std::string, JsonField> observationFields;
        parseFieldsOrEmpty(observation, observationFields);
        if (idempotencyPolicy != "always_execute") {
            ToolCallLedgerEntry entry;
            entry.callId = callId;
            entry.toolName = activeToolName;
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

    std::string callJson = "{\"tool_name\":" + jsonString(activeToolName) +
        ",\"call_id\":" + jsonString(callId) +
        ",\"parameters\":" + activeParameters +
        ",\"requires_confirmation\":" + jsonBool(confirmationRequired) + "}";
    std::string redactedCallJson = "{\"tool_name\":" + jsonString(activeToolName) +
        ",\"call_id\":" + jsonString(callId) +
        ",\"parameters\":" + tools_.redactedParametersJson(activeToolName, activeParameters) +
        ",\"requires_confirmation\":" + jsonBool(confirmationRequired) + "}";

    const bool skipsPermissionByYolo = session.yoloMode();
    const bool skipsPermissionByGrant = session.isToolPermissionConfirmed(activeToolName);
    if (skipsPermissionByYolo || skipsPermissionByGrant) {
        callbacks_.emitEvent(
            skipsPermissionByYolo ? "runtime.permission.yolo_allowed" : "runtime.permission.grant_reused",
            "{\"tool_name\":" + jsonString(activeToolName) +
                ",\"call_id\":" + jsonString(callId) +
                ",\"read_only\":" + jsonBool(tools_.isReadOnly(activeToolName)) +
                ",\"destructive\":" + jsonBool(tools_.isDestructive(activeToolName)) + "}"
        );
        confirmationRequired = false;
    }

    const bool needsPermissionDecision = !tools_.isReadOnly(activeToolName) && !skipsPermissionByYolo && !skipsPermissionByGrant;
    if (callbacks_.hasPermission() && needsPermissionDecision) {
        callbacks_.span("start", "runtime.permission.check", "{\"tool_name\":" + jsonString(activeToolName) + ",\"call_id\":" + jsonString(callId) + "}");
        HookDispatcher(callbacks_).dispatch("before_permission", redactedCallJson);
        const std::string permissionJson = callbacks_.decidePermission(callJson);
        HookDispatcher(callbacks_).dispatch("after_permission", "{\"call\":" + redactedCallJson + ",\"decision\":" + (trim(permissionJson).empty() ? "{}" : permissionJson) + "}");
        callbacks_.span("end", "runtime.permission.check", "{\"tool_name\":" + jsonString(activeToolName) + ",\"call_id\":" + jsonString(callId) + "}");
        std::map<std::string, JsonField> permissionFields;
        if (parseFieldsOrEmpty(permissionJson, permissionFields)) {
            const std::string decision = lowercased(stringField(permissionFields, "decision"));
            if (decision == "denied" || decision == "deny" || decision == "false") {
                const std::string error = stringField(permissionFields, "reason", "permission denied");
                session.recordPermissionDenied(activeToolName);
                const std::string output = correctionOutput(tools_, activeToolName, activeParameters, "permission_denied", error, "request_permission");
                const std::string result = failureResult("denied", error, output);
                const std::string observation = session.recordObservation(activeToolName, "denied", "", error, false, false, output, callId);
                callbacks_.emitEvent("observation_created", observation);
                return result;
            }
            if (decision == "always") {
                session.confirmToolPermission(activeToolName);
                session.clearPermissionDenials(activeToolName);
            } else if (decision == "allowed" || decision == "allow" || decision == "once" || decision == "true") {
                session.clearPermissionDenials(activeToolName);
            }
            confirmationRequired = confirmationRequired || decision == "requires_confirmation" || decision == "requires-confirmation";
        }
    } else if (!callbacks_.hasPermission() && needsPermissionDecision) {
        callbacks_.emitEvent(
            "runtime.permission.no_callback",
            "{\"tool_name\":" + jsonString(activeToolName) +
                ",\"call_id\":" + jsonString(callId) +
                ",\"read_only\":false}"
        );
    }

    bool confirmed = !confirmationRequired;
    if (session.yoloMode()) {
        confirmed = true;
    } else if (confirmationRequired) {
        if (!callbacks_.hasConfirmation()) {
            const std::string error = "confirmation callback is not registered";
            const std::string output = correctionOutput(tools_, activeToolName, activeParameters, "confirmation_unavailable", error, "request_permission");
            const std::string result = failureResult("denied", error, output);
            const std::string observation = session.recordObservation(activeToolName, "denied", "", error, true, false, output, callId);
            callbacks_.emitEvent("observation_created", observation);
            return result;
        }
        callbacks_.span("start", "runtime.confirmation.wait", "{\"tool_name\":" + jsonString(activeToolName) + ",\"call_id\":" + jsonString(callId) + "}");
        HookDispatcher(callbacks_).dispatch("before_confirmation", redactedCallJson);
        const std::string confirmationJson = callbacks_.confirm(callJson);
        HookDispatcher(callbacks_).dispatch("after_confirmation", "{\"call\":" + redactedCallJson + ",\"decision\":" + (trim(confirmationJson).empty() ? "{}" : confirmationJson) + "}");
        callbacks_.span("end", "runtime.confirmation.wait", "{\"tool_name\":" + jsonString(activeToolName) + ",\"call_id\":" + jsonString(callId) + "}");
        std::map<std::string, JsonField> confirmationFields;
        if (parseFieldsOrEmpty(confirmationJson, confirmationFields)) {
            confirmed = boolField(confirmationFields, "confirmed", false);
        }
        if (!confirmed) {
            const std::string error = "user did not confirm";
            const std::string output = correctionOutput(tools_, activeToolName, activeParameters, "confirmation_declined", error, "stop");
            const std::string result = failureResult("denied", error, output);
            const std::string observation = session.recordObservation(activeToolName, "denied", "", error, true, false, output, callId);
            callbacks_.emitEvent("observation_created", observation);
            return result;
        }
    }

    if (!callbacks_.hasTool()) {
        const std::string error = "tool callback is not registered";
        const std::string output = correctionOutput(tools_, activeToolName, activeParameters, "tool_unavailable", error, "stop");
        const std::string result = failureResult("failed", error, output);
        const std::string observation = session.recordObservation(activeToolName, "failed", "", error, confirmationRequired, confirmed, output, callId);
        callbacks_.emitEvent("observation_created", observation);
        return result;
    }
    callbacks_.emitEvent("tool_will_execute", redactedCallJson);
    HookDispatcher(callbacks_).dispatch("tool_will_execute", redactedCallJson);
    std::string result;
    long long toolElapsedMs = 0;
    int toolAttempt = 1;
    int maxToolAttempts = 3;
    while (true) {
        if (cancellationRequested() && toolAttempt > 1) {
            // Preserve the actual previous attempt in audit and observation.
            session.cancel();
            break;
        }
        if (cancellationRequested() || session.isTerminated() || session.isPaused()) {
            return stopBeforeCallback();
        }
        callbacks_.span("start", "runtime.tool.execute", "{\"tool_name\":" + jsonString(activeToolName) + ",\"call_id\":" + jsonString(callId) + ",\"retry.attempt\":" + std::to_string(toolAttempt) + "}");
        if (cancellationRequested()) {
            if (toolAttempt > 1) {
                session.cancel();
                break;
            }
            callbacks_.span("end", "runtime.tool.execute", "{\"tool_name\":" + jsonString(activeToolName) +
                ",\"call_id\":" + jsonString(callId) + ",\"status\":\"cancelled_before_execution\"}");
            return stopBeforeCallback();
        }
        const auto toolStartedAt = std::chrono::steady_clock::now();
        result = callbacks_.callTool(callJson);
        toolElapsedMs = std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::steady_clock::now() - toolStartedAt
        ).count();
        const bool emptyResult = trim(result).empty();
        if (emptyResult) {
            result = "{\"status\":\"failed\",\"content\":\"\",\"errorMessage\":\"tool returned an empty result\",\"retryable\":true,\"errorCode\":\"empty-result\",\"errorCategory\":\"transport\"}";
        }
        std::map<std::string, JsonField> attemptFields;
        const bool parsedAttempt = parseFieldsOrEmpty(result, attemptFields);
        const std::string attemptStatus = lowercased(parsedAttempt ? stringField(attemptFields, "status", "succeeded") : "succeeded");
        const bool failedAttempt = attemptStatus == "failed" || attemptStatus == "cancelled";
        if (!failedAttempt) {
            if (toolAttempt > 1) {
                callbacks_.emitEvent("runtime.retry.succeeded", "{\"stage\":\"tool_execution\",\"tool_name\":" + jsonString(activeToolName) + ",\"call_id\":" + jsonString(callId) + ",\"attempts\":" + std::to_string(toolAttempt) + "}");
            }
            break;
        }
        const bool validationFailed = boolField(attemptFields, "validation_failed", false);
        const bool recoverable = attemptStatus != "cancelled" && !validationFailed &&
            (emptyResult || boolField(attemptFields, "retryable", false) || boolField(attemptFields, "recoverable", false));
        const std::string errorCode = stringField(attemptFields, "errorCode", stringField(attemptFields, "error_code", emptyResult ? "empty-result" : "tool-failed"));
        const std::string errorCategory = stringField(attemptFields, "errorCategory", stringField(attemptFields, "error_category", emptyResult ? "transport" : "tool"));
        const std::string retryRequest = retryRequestJson(
            session,
            "tool_execution",
            toolAttempt,
            maxToolAttempts,
            errorCode,
            errorCategory,
            recoverable,
            toolElapsedMs,
            activeToolName,
            tools_.sideEffect(activeToolName),
            idempotencyPolicy,
            !callerProvidedIdempotencyKey(activeParameters).empty(),
            tools_.isReadOnly(activeToolName),
            tools_.isDestructive(activeToolName)
        );
        const RuntimeRetryDecision retry = callbacks_.decideRetry(retryRequest);
        // Parameter correction needs a new model call; uncertain writes and cancellations must never be retried automatically.
        const bool safeAutomaticRetry = recoverable && tools_.isReadOnly(activeToolName);
        if (retry.action == "retry" && safeAutomaticRetry) {
            if (retry.maxAttemptsOverride > 0) {
                maxToolAttempts = std::max(toolAttempt, retry.maxAttemptsOverride);
            }
            callbacks_.span("end", "runtime.tool.execute", "{\"tool_name\":" + jsonString(activeToolName) + ",\"call_id\":" + jsonString(callId) + ",\"status\":\"retrying\",\"wall_time_ms\":" + std::to_string(toolElapsedMs) + "}");
            sleepForRetryDecision(callbacks_, retryRequest, retry);
            toolAttempt += 1;
            continue;
        }
        if (retry.action == "fallback") {
            callbacks_.emitEvent("runtime.fallback.used", "{\"request\":" + retryRequest + ",\"reason\":" + jsonString(retry.reason) + "}");
        } else if (toolAttempt > 1 || recoverable) {
            callbacks_.emitEvent("runtime.retry.failed", "{\"request\":" + retryRequest + ",\"reason\":" + jsonString(retry.reason) + "}");
        }
        break;
    }

    std::map<std::string, JsonField> resultFields;
    std::string resultValidation = tools_.validateResultJson(activeToolName, result);
    std::map<std::string, JsonField> resultValidationFields;
    bool parsed = parseFieldsOrEmpty(result, resultFields);
    if (parseFieldsOrEmpty(resultValidation, resultValidationFields) && !boolField(resultValidationFields, "ok", false)) {
        const std::string error = stringField(resultValidationFields, "error", "tool result failed validation");
        result = "{\"status\":\"failed\",\"content\":\"\",\"errorMessage\":" + jsonString(error) + "}";
        resultFields.clear();
        parsed = parseFieldsOrEmpty(result, resultFields);
    }
    const RuntimeGuardrailDecision toolOutputGuardrail = callbacks_.evaluateGuardrail(
        "tool_output",
        "{\"call\":" + redactedCallJson + ",\"result\":" + result + "}"
    );
    std::string outputGuardrailResult;
    if (terminalGuardrailToolDecision(session, callbacks_, tools_, activeToolName, activeParameters, toolOutputGuardrail, outputGuardrailResult)) {
        result = outputGuardrailResult;
        resultFields.clear();
        parsed = parseFieldsOrEmpty(result, resultFields);
    } else {
        const std::string rewrittenToolOutput = guardrailRewritePayload(toolOutputGuardrail);
        if (!rewrittenToolOutput.empty()) {
            std::map<std::string, JsonField> rewriteFields;
            if (parseFieldsOrEmpty(rewrittenToolOutput, rewriteFields)) {
                result = rawField(rewriteFields, "result", rewrittenToolOutput);
            } else {
                result = rewrittenToolOutput;
            }
            resultFields.clear();
            parsed = parseFieldsOrEmpty(result, resultFields);
            callbacks_.emitEvent("guardrail_rewritten", "{\"stage\":\"tool_output\",\"tool_name\":" + jsonString(activeToolName) + "}");
        }
    }
    if (parsed && lowercased(stringField(resultFields, "status", "succeeded")) != "succeeded") {
        const std::string output = rawField(resultFields, "output", "{}");
        std::map<std::string, JsonField> outputFields;
        parseFieldsOrEmpty(output, outputFields);
        if (outputFields.find("failure") == outputFields.end()) {
            const std::string status = lowercased(stringField(resultFields, "status", "failed"));
            const bool validationFailed = status == "failed" && boolField(resultFields, "validation_failed", false);
            const std::string error = stringField(resultFields, "errorMessage", "Tool execution failed without further details.");
            const std::string code = validationFailed ? "validation_failed" : status == "denied" ? "permission_denied" : status == "cancelled" ? "cancelled" : "execution_failed";
            const std::string policy = validationFailed ? "correct_arguments" : status == "denied" ? "request_permission" : status == "cancelled" || tools_.isReadOnly(activeToolName) ? "stop" : "verify_before_retry";
            std::map<std::string, JsonField> correctionFields;
            parseFieldsOrEmpty(correctionOutput(tools_, activeToolName, activeParameters, code, error, policy), correctionFields);
            result = withJsonField(result, "output", withJsonField(output, "failure", rawField(correctionFields, "failure", "{}")));
            resultFields.clear();
            parsed = parseFieldsOrEmpty(result, resultFields);
        }
    }
    callbacks_.audit("tool_did_execute", "{\"call\":" + redactedCallJson + ",\"result\":" + result + "}");
    callbacks_.emitEvent("tool_execution_completed", "{\"call_id\":" + jsonString(callId) +
        ",\"tool_name\":" + jsonString(activeToolName) + ",\"result\":" + result + "}");
    HookDispatcher(callbacks_).dispatch("tool_did_execute", "{\"call\":" + redactedCallJson + ",\"result\":" + result + "}");
    callbacks_.emitEvent(
        "tool_callback_returned",
        "{\"tool_name\":" + jsonString(activeToolName) +
            ",\"call_id\":" + jsonString(callId) +
            ",\"wall_time_ms\":" + std::to_string(toolElapsedMs) +
            ",\"raw_result_excerpt\":" + jsonString(excerpt(result, 1200)) + "}"
    );
    callbacks_.metric("tool_latency_ms", static_cast<double>(toolElapsedMs), "{\"tool_name\":" + jsonString(activeToolName) + ",\"call_id\":" + jsonString(callId) + "}");
    callbacks_.trace("tool_result", "{\"tool_name\":" + jsonString(activeToolName) + ",\"call_id\":" + jsonString(callId) + ",\"wall_time_ms\":" + std::to_string(toolElapsedMs) + ",\"result_excerpt\":" + jsonString(excerpt(result, 1200)) + "}");
    callbacks_.span("end", "runtime.tool.execute", "{\"tool_name\":" + jsonString(activeToolName) + ",\"call_id\":" + jsonString(callId) + ",\"wall_time_ms\":" + std::to_string(toolElapsedMs) + "}");

    const std::string status = parsed ? stringField(resultFields, "status", "succeeded") : "succeeded";
    const std::string content = tools_.truncateResultContent(activeToolName, parsed ? stringField(resultFields, "content", result) : result);
    const std::string error = parsed ? stringField(resultFields, "errorMessage", "") : "";
    const std::string outputJson = parsed ? rawField(resultFields, "output", "{}") : "{}";
    const std::string observation = session.recordObservation(
        activeToolName,
        status,
        content,
        error,
        confirmationRequired,
        confirmed,
        outputJson,
        callId,
        logicalCallKey(),
        parsed && boolField(resultFields, "validation_failed", false)
    );
    std::map<std::string, JsonField> observationFields;
    parseFieldsOrEmpty(observation, observationFields);
    if (parsed && shouldRecordForReplay(idempotencyPolicy, resultFields)) {
        ToolCallLedgerEntry entry;
        entry.callId = callId;
        entry.toolName = activeToolName;
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
    callbacks_.trace("observation_created", "{\"tool_name\":" + jsonString(activeToolName) + ",\"call_id\":" + jsonString(callId) + ",\"observation\":" + observation + "}");
    HookDispatcher(callbacks_).dispatch("observation_created", observation);
    return result;
}

std::string ToolExecutor::runMultiToolCall(RuntimeSession &session, const std::string &toolCallsJson) const {
    const std::string batchId = session.runId() + ":multi:" + std::to_string(session.stepCount());
    const std::vector<std::string> calls = extractObjectArrayItems(toolCallsJson);
    if (calls.empty()) {
        const std::string result = "{\"status\":\"failed\",\"content\":\"\",\"errorMessage\":\"multi_tool_use contained no tool calls\"}";
        const std::string observation = session.recordObservation("multi_tool_use", "failed", "", "multi_tool_use contained no tool calls", false, false);
        callbacks_.emitEvent("multi_tool_use_call_failed", "{\"batch_id\":" + jsonString(batchId) + ",\"call_index\":0,\"error\":\"multi_tool_use contained no tool calls\"}");
        callbacks_.recordHistory("observation_created", observation);
        return result;
    }

    struct ParsedCall {
        std::string toolName;
        std::string parameters;
        bool requiresConfirmation = false;
        size_t originalIndex = 0;
    };
    std::vector<ParsedCall> parsedCalls;
    parsedCalls.reserve(calls.size());
    bool batchHasSideEffect = false;
    for (size_t index = 0; index < calls.size(); index++) {
        std::map<std::string, JsonField> fields;
        if (!parseFieldsOrEmpty(calls[index], fields)) {
            const std::string error = "multi_tool_use contains an invalid tool call object";
            const std::string result = "{\"status\":\"failed\",\"content\":\"\",\"errorMessage\":" + jsonString(error) + "}";
            const std::string observation = session.recordObservation("multi_tool_use", "failed", "", error, false, false);
            callbacks_.emitEvent("multi_tool_use_call_failed", "{\"batch_id\":" + jsonString(batchId) + ",\"call_index\":" + std::to_string(index) + ",\"error\":" + jsonString(error) + "}");
            callbacks_.recordHistory("observation_created", observation);
            return result;
        }
        const std::string toolName = stringField(fields, "tool_name", stringField(fields, "toolName"));
        const std::string parameters = rawField(fields, "parameters", rawField(fields, "arguments", "{}"));
        if (toolName.empty()) {
            const std::string error = "multi_tool_use contains a tool call without a tool name";
            const std::string result = "{\"status\":\"failed\",\"content\":\"\",\"errorMessage\":" + jsonString(error) + "}";
            const std::string observation = session.recordObservation("multi_tool_use", "failed", "", error, false, false);
            callbacks_.emitEvent("multi_tool_use_call_failed", "{\"batch_id\":" + jsonString(batchId) + ",\"call_index\":" + std::to_string(index) + ",\"error\":" + jsonString(error) + "}");
            callbacks_.recordHistory("observation_created", observation);
            return result;
        }
        if (session.ignoreInternalToolCalls() && isInternalRuntimeTool(toolName)) {
            callbacks_.emitEvent(
                "internal_tool_ignored",
                "{\"batch_id\":" + jsonString(batchId) +
                    ",\"tool_name\":" + jsonString(toolName) +
                    ",\"call_index\":" + std::to_string(index) +
                    ",\"reason\":\"evaluation_internal_tool\"}"
            );
            continue;
        }
        const std::string canonicalName = tools_.resolveName(toolName);
        const std::string sideEffectName = canonicalName.empty() ? toolName : canonicalName;
        batchHasSideEffect = batchHasSideEffect || !tools_.isReadOnly(sideEffectName);
        parsedCalls.push_back({
            toolName,
            parameters.empty() ? "{}" : parameters,
            boolField(fields, "requires_confirmation", boolField(fields, "requiresConfirmation", false)),
            index
        });
    }

    callbacks_.emitEvent(
        "multi_tool_use_started",
        "{\"batch_id\":" + jsonString(batchId) +
            ",\"call_count\":" + std::to_string(parsedCalls.size()) +
            ",\"raw_call_count\":" + std::to_string(calls.size()) +
            ",\"contains_side_effect\":" + jsonBool(batchHasSideEffect) + "}"
    );
    if (parsedCalls.empty()) {
        // Internal helper calls are intentionally ignored. Preserve the prior observation
        // and let the model continue without manufacturing a task-tool observation.
        return "{\"status\":\"succeeded\",\"content\":\"\",\"ignored_internal_calls\":true}";
    }

    std::ostringstream observations;
    observations << "[";
    for (size_t index = 0; index < parsedCalls.size(); index++) {
        const ParsedCall &call = parsedCalls[index];
        if (cancellationRequested() || session.isTerminated() || session.isPaused()) {
            if (cancellationRequested()) session.cancel();
            const std::string stopped = "{\"batch_id\":" + jsonString(batchId) +
                ",\"call_index\":" + std::to_string(call.originalIndex) +
                ",\"reason\":" + jsonString(cancellationRequested() ? "cancelled" : "session_stopped") +
                ",\"skipped_call_count\":" + std::to_string(parsedCalls.size() - index) + "}";
            callbacks_.emitEvent("multi_tool_use_stopped", stopped);
            callbacks_.audit("multi_tool_use_stopped", stopped);
            break;
        }
        if (!session.consumeToolCallBudget()) {
            const std::string reason = "Tool call budget exhausted; " + std::to_string(parsedCalls.size() - index) + " remaining batch calls were not executed.";
            session.failWithResult("tool-budget", "### 已达到工具调用预算\n\n" + reason);
            const std::string stopped = "{\"batch_id\":" + jsonString(batchId) +
                ",\"call_index\":" + std::to_string(call.originalIndex) +
                ",\"reason\":\"tool_budget\",\"skipped_call_count\":" + std::to_string(parsedCalls.size() - index) + "}";
            callbacks_.emitEvent("multi_tool_use_stopped", stopped);
            callbacks_.audit("multi_tool_use_stopped", stopped);
            break;
        }
        callbacks_.emitEvent("tool_call_budget_consumed", "{\"batch_id\":" + jsonString(batchId) +
            ",\"call_index\":" + std::to_string(call.originalIndex) +
            ",\"actionCount\":" + std::to_string(session.actionCount()) +
            ",\"remainingToolCalls\":" + std::to_string(std::max(0, session.maximumToolCalls() - session.actionCount())) + "}");
        if (index > 0) {
            observations << ",";
        }
        const std::string result = runToolCall(session, call.toolName, call.parameters, call.requiresConfirmation);
        observations << result;
        std::map<std::string, JsonField> resultFields;
        parseFieldsOrEmpty(result, resultFields);
        const std::string status = lowercased(stringField(resultFields, "status", "succeeded"));
        const bool failed = status != "succeeded";
        if (failed) {
            callbacks_.emitEvent(
                "multi_tool_use_call_failed",
                "{\"batch_id\":" + jsonString(batchId) +
                    ",\"call_index\":" + std::to_string(call.originalIndex) +
                    ",\"execution_index\":" + std::to_string(index) +
                    ",\"tool_name\":" + jsonString(call.toolName) +
                    ",\"status\":" + jsonString(status) +
                    ",\"replayed\":" + jsonBool(boolField(resultFields, "replayed", false)) + "}"
            );
            const bool stopBatch = status == "cancelled" || batchHasSideEffect || !session.continueReadOnlyMultiToolFailures();
            if (stopBatch) {
                if (status == "cancelled") session.cancel();
                callbacks_.emitEvent(
                    "multi_tool_use_stopped",
                    "{\"batch_id\":" + jsonString(batchId) +
                        ",\"call_index\":" + std::to_string(call.originalIndex) +
                        ",\"reason\":" + jsonString(status == "cancelled" ? "cancelled" : batchHasSideEffect ? "side_effect_failure" : "read_only_failure") + "}"
                );
                break;
            }
        }
        if (session.hasResult()) {
            break;
        }
    }
    observations << "]";
    return observations.str();
}

} // namespace LuminaAgent
