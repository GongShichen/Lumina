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
    const std::string &toolName,
    const RuntimeGuardrailDecision &decision,
    std::string &result
) {
    if (decision.decision == "tripwire_failure") {
        const std::string message = decision.message.empty() ? "tool guardrail tripwire failure" : decision.message;
        session.failWithResult("guardrail-tripwire", "### 已终止\n\n" + message);
        callbacks.emitEvent("guardrail_tripwire", "{\"stage\":\"tool\",\"tool_name\":" + jsonString(toolName) + ",\"message\":" + jsonString(message) + "}");
        result = "{\"status\":\"failed\",\"content\":\"\",\"errorMessage\":" + jsonString(message) + "}";
        return true;
    }
    if (decision.decision == "reject") {
        const std::string message = decision.message.empty() ? "tool guardrail rejected payload" : decision.message;
        callbacks.emitEvent("guardrail_rejected", "{\"stage\":\"tool\",\"tool_name\":" + jsonString(toolName) + ",\"message\":" + jsonString(message) + "}");
        result = "{\"status\":\"denied\",\"content\":\"\",\"errorMessage\":" + jsonString(message) + "}";
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

ToolExecutor::ToolExecutor(const ToolRegistry &tools, const RuntimeCallbacks &callbacks, RuntimeReplayController *replay)
    : tools_(tools), callbacks_(callbacks), replay_(replay) {}

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

    auto failBeforeExecution = [&](const std::string &observedToolName, const std::string &error, bool emitUnknownTool) {
        const std::string result = "{\"status\":\"failed\",\"content\":\"\",\"errorMessage\":" + jsonString(error) + "}";
        const std::string observation = session.recordObservation(observedToolName, "failed", "", error, false, false);
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
            if (const ToolCallLedgerEntry *entry = session.findReplayableToolCall(localDedupKey)) {
                if (entry->rawResultJson.find("\"validation_failed\":true") == std::string::npos) {
                    return "";
                }
                const std::string observation = session.recordReplayObservation(activeToolName, *entry);
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
                return "{\"status\":" + jsonString(entry->status) +
                    ",\"content\":" + jsonString(entry->summary) +
                    ",\"replayed\":true," +
                    "\"duplicate_of\":" + jsonString(entry->callId) + "}";
            }
        }
        const std::string validation = tools_.validateCallJson(activeToolName, activeParameters);
        std::map<std::string, JsonField> validationFields;
        if (parseFieldsOrEmpty(validation, validationFields) && !boolField(validationFields, "ok", false)) {
            const std::string error = stringField(validationFields, "error", "tool parameters failed validation");
            const std::string result = "{\"status\":\"failed\",\"content\":\"\",\"errorMessage\":" + jsonString(error) + ",\"validation_failed\":true}";
            const std::string observation = session.recordObservation(activeToolName, "failed", "", error, false, false);
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
    if (terminalGuardrailToolDecision(session, callbacks_, activeToolName, toolInputGuardrail, guardrailResult)) {
        if (toolInputGuardrail.decision == "reject") {
            const std::string observation = session.recordObservation(
                activeToolName,
                "denied",
                "",
                toolInputGuardrail.message.empty() ? "tool guardrail rejected payload" : toolInputGuardrail.message,
                false,
                false
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
        const std::string result = "{\"status\":\"denied\",\"content\":\"\",\"errorMessage\":" + jsonString(error) + "}";
        const std::string observation = session.recordObservation(activeToolName, "denied", "", error, false, false);
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
            const std::string observation = session.recordObservation(activeToolName, "failed", "", error, false, false);
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
                true
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
            const std::string observation = session.recordObservation(activeToolName, "failed", "", error, confirmationRequired, false);
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
        if (const ToolCallLedgerEntry *entry = session.findReplayableToolCall(dedupKey)) {
            const std::string observation = session.recordReplayObservation(activeToolName, *entry);
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
            return "{\"status\":" + jsonString(entry->status) +
                ",\"content\":" + jsonString(entry->summary) +
                ",\"replayed\":true," +
                "\"duplicate_of\":" + jsonString(entry->callId) + "}";
        }
    }

    const std::string validation = tools_.validateCallJson(activeToolName, activeParameters);
    std::map<std::string, JsonField> validationFields;
    if (parseFieldsOrEmpty(validation, validationFields) && !boolField(validationFields, "ok", false)) {
        const std::string error = stringField(validationFields, "error", "tool parameters failed validation");
        const std::string result = "{\"status\":\"failed\",\"content\":\"\",\"errorMessage\":" + jsonString(error) + "}";
        const std::string observation = session.recordObservation(activeToolName, "failed", "", error, false, false);
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
                const int denials = session.recordPermissionDenied(activeToolName);
                std::string content = error;
                if (denials >= 3) {
                    content += "\n\n<system_hint>\nThe user has explicitly denied '" + activeToolName + "' " + std::to_string(denials) + " times in a row. This action will NOT be approved on retry. Pivot to a different approach or explain why approval is necessary.\n</system_hint>";
                }
                const std::string result = "{\"status\":\"denied\",\"content\":\"\",\"errorMessage\":" + jsonString(content) + "}";
                const std::string observation = session.recordObservation(activeToolName, "denied", "", content, false, false);
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
            const std::string result = "{\"status\":\"denied\",\"content\":\"\",\"errorMessage\":\"confirmation callback is not registered\"}";
            const std::string observation = session.recordObservation(activeToolName, "denied", "", error, true, false);
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
            const std::string result = "{\"status\":\"denied\",\"content\":\"\",\"errorMessage\":\"user did not confirm\"}";
            const std::string observation = session.recordObservation(activeToolName, "denied", "", "user did not confirm", true, false);
            callbacks_.emitEvent("observation_created", observation);
            return result;
        }
    }

    if (!callbacks_.hasTool()) {
        const std::string result = "{\"status\":\"failed\",\"content\":\"\",\"errorMessage\":\"tool callback is not registered\"}";
        const std::string observation = session.recordObservation(activeToolName, "failed", "", "tool callback is not registered", confirmationRequired, confirmed);
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
        callbacks_.span("start", "runtime.tool.execute", "{\"tool_name\":" + jsonString(activeToolName) + ",\"call_id\":" + jsonString(callId) + ",\"retry.attempt\":" + std::to_string(toolAttempt) + "}");
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
        const bool recoverable = emptyResult || boolField(attemptFields, "retryable", false) || boolField(attemptFields, "recoverable", false);
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
        if (retry.action == "retry") {
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
    if (terminalGuardrailToolDecision(session, callbacks_, activeToolName, toolOutputGuardrail, outputGuardrailResult)) {
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
    callbacks_.audit("tool_did_execute", "{\"call\":" + redactedCallJson + ",\"result\":" + result + "}");
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
        outputJson
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
            const bool stopBatch = batchHasSideEffect || !session.continueReadOnlyMultiToolFailures();
            if (stopBatch) {
                callbacks_.emitEvent(
                    "multi_tool_use_stopped",
                    "{\"batch_id\":" + jsonString(batchId) +
                        ",\"call_index\":" + std::to_string(call.originalIndex) +
                        ",\"reason\":" + jsonString(batchHasSideEffect ? "side_effect_failure" : "read_only_failure") + "}"
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
