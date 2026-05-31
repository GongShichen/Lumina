#include "Runtime.hpp"

#include <algorithm>
#include <sstream>
#include <vector>

#include "Hooks.hpp"
#include "Json.hpp"
#include "ReAct.hpp"
#include "AgentPipeline.hpp"
#include "ContextManager.hpp"
#include "ContextBudgetManager.hpp"
#include "ExecutionContext.hpp"
#include "RuntimeEventQueue.hpp"
#include "Replay.hpp"
#include "StreamingModelRunner.hpp"

namespace LuminaAgent {

static std::string excerpt(const std::string &text, size_t limit) {
    if (text.size() <= limit) {
        return text;
    }
    return text.substr(0, limit) + "...";
}

static bool applyHookDirective(
    RuntimeSession &session,
    const std::string &directiveJson,
    std::string *contextJson = nullptr,
    const std::string &requestJson = "{}"
) {
    const RuntimeHookDirectives directives = parseRuntimeHookDirectives(directiveJson);
    if (directives.hasFail) {
        session.failWithResult(
            directives.reason.empty() ? "hook terminated run" : directives.reason,
            directives.markdown.empty() ? "### 已终止\n\nRuntime hook terminated this run." : directives.markdown
        );
        return true;
    }
    if (directives.hasPause) {
        session.pause(
            directives.pauseKind.empty() ? "hook" : directives.pauseKind,
            directives.pausePayloadJson.empty() ? "{}" : directives.pausePayloadJson
        );
        return true;
    }
    if (directives.hasAppendContext && contextJson != nullptr) {
        const std::string appended = directives.appendedContextJson.empty() ? "{}" : directives.appendedContextJson;
        *contextJson = ContextManager(session).mergeContextJson(
            contextJson->empty() ? "null" : *contextJson,
            appended
        );
        session.setContextJson(*contextJson);
        session.appendTrace(
            "hook_context_appended",
            "{\"request\":" + (trim(requestJson).empty() ? "{}" : requestJson) +
                ",\"context\":" + appended + "}"
        );
    }
    return false;
}

static bool applyTerminalGuardrailDecision(
    RuntimeSession &session,
    RuntimeCallbacks &callbacks,
    const std::string &stage,
    const RuntimeGuardrailDecision &decision
) {
    if (decision.decision != "reject" && decision.decision != "tripwire_failure") {
        return false;
    }
    const bool tripwire = decision.decision == "tripwire_failure";
    const std::string message = decision.message.empty()
        ? (tripwire ? "guardrail tripwire failure" : "guardrail rejected payload")
        : decision.message;
    session.failWithResult(
        tripwire ? "guardrail-tripwire" : "guardrail-rejected",
        std::string(tripwire ? "### 已终止\n\n" : "### 已拒绝\n\n") + message
    );
    callbacks.emitEvent(
        tripwire ? "guardrail_tripwire" : "guardrail_rejected",
        "{\"stage\":" + jsonString(stage) + ",\"message\":" + jsonString(message) + "}"
    );
    callbacks.audit(
        tripwire ? "guardrail_tripwire" : "guardrail_rejected",
        "{\"stage\":" + jsonString(stage) + ",\"message\":" + jsonString(message) + "}"
    );
    return true;
}

static std::string rewrittenResultMarkdown(const std::string &payloadJson) {
    std::map<std::string, JsonField> fields;
    if (!parseFieldsOrEmpty(payloadJson, fields)) {
        return "";
    }
    return stringField(fields, "resultMarkdown", stringField(fields, "content"));
}

static std::string normalizedCheckpointPolicy(const std::string &policy) {
    const std::string value = lowercased(policy);
    if (value == "onpause" || value == "on_pause") {
        return "on_pause";
    }
    if (value == "onstep" || value == "on_step") {
        return "on_step";
    }
    if (value == "onexit" || value == "on_exit") {
        return "on_exit";
    }
    return "none";
}

static void emitCheckpointIfNeeded(
    const RuntimeSessionConfig &config,
    RuntimeSession &session,
    RuntimeCallbacks &callbacks,
    RuntimeEventQueue &events,
    const std::string &point
) {
    if (config.checkpointPolicy != point) {
        return;
    }
    const std::string payload = "{\"policy\":" + jsonString(point) +
        ",\"checkpoint\":" + session.checkpointJson() + "}";
    events.emitControl("checkpoint_created", payload);
    callbacks.trace("checkpoint_created", payload);
}

static std::vector<std::string> stringArrayFromRaw(const std::string &arrayJson) {
    std::vector<std::string> values;
    const std::string text = trim(arrayJson);
    size_t index = 0;
    while (index < text.size()) {
        while (index < text.size() && text[index] != '"') {
            index += 1;
        }
        if (index >= text.size()) {
            break;
        }
        index += 1;
        std::string value;
        bool escaped = false;
        while (index < text.size()) {
            const char c = text[index++];
            if (escaped) {
                value += c;
                escaped = false;
            } else if (c == '\\') {
                escaped = true;
            } else if (c == '"') {
                values.push_back(value);
                break;
            } else {
                value += c;
            }
        }
    }
    return values;
}

static bool stringVectorContains(const std::vector<std::string> &values, const std::string &candidate) {
    if (values.empty()) {
        return true;
    }
    for (const std::string &value : values) {
        if (value == candidate) {
            return true;
        }
    }
    return false;
}

static std::string schemaWithProviderNamespace(
    const std::string &schema,
    const std::string &providerNamespace,
    const std::vector<std::string> &allowedTools
) {
    std::map<std::string, JsonField> fields;
    if (!parseFieldsOrEmpty(schema, fields)) {
        return "";
    }
    const std::string originalName = stringField(fields, "name");
    if (originalName.empty() || !stringVectorContains(allowedTools, originalName)) {
        return "";
    }
    const std::string prefix = providerNamespace.empty() ? "" : providerNamespace + ".";
    const bool alreadyNamespaced = !prefix.empty() && originalName.rfind(prefix, 0) == 0;
    const std::string name = prefix.empty() || alreadyNamespaced ? originalName : prefix + originalName;
    std::ostringstream output;
    output << "{"
           << "\"name\":" << jsonString(name) << ","
           << "\"description\":" << jsonString(stringField(fields, "description")) << ","
           << "\"category\":" << jsonString(stringField(fields, "category", "external")) << ","
           << "\"searchHint\":" << jsonString(stringField(fields, "searchHint", stringField(fields, "search_hint"))) << ","
           << "\"sideEffect\":" << jsonString(stringField(fields, "sideEffect", stringField(fields, "side_effect", "readOnly"))) << ","
           << "\"sensitivity\":" << jsonString(stringField(fields, "sensitivity", "normal")) << ","
           << "\"idempotencyPolicy\":" << jsonString(stringField(fields, "idempotencyPolicy", stringField(fields, "idempotency_policy", "replay_identical"))) << ","
           << "\"readOnly\":" << rawField(fields, "readOnly", "false") << ","
           << "\"destructive\":" << rawField(fields, "destructive", "false") << ","
           << "\"concurrencySafe\":" << rawField(fields, "concurrencySafe", rawField(fields, "concurrency_safe", "false")) << ","
           << "\"requiresUserInteraction\":" << rawField(fields, "requiresUserInteraction", rawField(fields, "requires_user_interaction", "false")) << ","
           << "\"parameters\":" << rawField(fields, "parameters", "[]");
    const std::string inputSchema = rawField(fields, "inputSchema", rawField(fields, "input_schema", ""));
    const std::string outputSchema = rawField(fields, "outputSchema", rawField(fields, "output_schema", ""));
    if (!inputSchema.empty()) {
        output << ",\"inputSchema\":" << inputSchema;
    }
    if (!outputSchema.empty()) {
        output << ",\"outputSchema\":" << outputSchema;
    }
    output << "}";
    return output.str();
}

Runtime::Runtime(const char *configurationJson) {
    if (configurationJson == nullptr || trim(configurationJson).empty()) {
        configurationError_ = "runtime configuration JSON is required.";
        sessionConfig_.configurationError = configurationError_;
        return;
    }
    std::map<std::string, JsonField> fields;
    if (!parseFieldsOrEmpty(configurationJson, fields)) {
        configurationError_ = "runtime configuration must be a JSON object.";
        sessionConfig_.configurationError = configurationError_;
        return;
    }
    auto requireInt = [&](const std::vector<std::string> &keys, const std::string &name, int minimumValue, int &target) {
        for (const std::string &key : keys) {
            auto it = fields.find(key);
            if (it != fields.end()) {
                target = intField(fields, key, 0);
                if (target < minimumValue) {
                    configurationError_ = name + " must be at least " + std::to_string(minimumValue) + ".";
                }
                return;
            }
        }
        configurationError_ = "missing required runtime budget: " + name + ".";
    };
    requireInt({"maximumReActIterations", "maxIterations"}, "maxIterations", 1, sessionConfig_.maximumReActIterations);
    if (!configurationError_.empty()) { sessionConfig_.configurationError = configurationError_; return; }
    requireInt({"maximumToolCalls", "maxToolCalls"}, "maxToolCalls", 1, sessionConfig_.maximumToolCalls);
    if (!configurationError_.empty()) { sessionConfig_.configurationError = configurationError_; return; }
    requireInt({"maximumContextTokens", "contextWindowTokens"}, "contextWindowTokens", 1, sessionConfig_.contextWindowTokens);
    if (!configurationError_.empty()) { sessionConfig_.configurationError = configurationError_; return; }
    requireInt({"maxOutputTokens", "maximumOutputTokens"}, "maxOutputTokens", 1, sessionConfig_.maxOutputTokens);
    if (!configurationError_.empty()) { sessionConfig_.configurationError = configurationError_; return; }
    requireInt({"reservedOutputTokens"}, "reservedOutputTokens", 0, sessionConfig_.reservedOutputTokens);
    if (!configurationError_.empty()) { sessionConfig_.configurationError = configurationError_; return; }
    requireInt({"maximumObservationCharacters", "maxObservationCharacters"}, "maxObservationCharacters", 1, sessionConfig_.maximumObservationCharacters);
    if (!configurationError_.empty()) { sessionConfig_.configurationError = configurationError_; return; }
    requireInt({"toolResultTokenBudget"}, "toolResultTokenBudget", 1, sessionConfig_.toolResultTokenBudget);
    if (!configurationError_.empty()) { sessionConfig_.configurationError = configurationError_; return; }
    requireInt({"compactThresholdTokens"}, "compactThresholdTokens", 0, sessionConfig_.compactThresholdTokens);
    if (!configurationError_.empty()) { sessionConfig_.configurationError = configurationError_; return; }
    requireInt({"maximumCompactFailures", "maxCompactFailures"}, "maxCompactFailures", 0, sessionConfig_.maximumCompactFailures);
    if (!configurationError_.empty()) { sessionConfig_.configurationError = configurationError_; return; }
    requireInt({"maximumConsecutiveReasoningSteps", "maxReasoningSteps"}, "maxReasoningSteps", 1, sessionConfig_.maximumConsecutiveReasoningSteps);
    if (!configurationError_.empty()) { sessionConfig_.configurationError = configurationError_; return; }
    requireInt({"maximumConsecutiveReplayObservations", "maxReplayObservations"}, "maxReplayObservations", 1, sessionConfig_.maximumConsecutiveReplayObservations);
    if (!configurationError_.empty()) { sessionConfig_.configurationError = configurationError_; return; }
    sessionConfig_.stopOnToolFailure = boolField(fields, "stopOnToolFailure", sessionConfig_.stopOnToolFailure);
    const std::string profile = lowercased(stringField(fields, "toolSchemaProfile", sessionConfig_.toolSchemaProfile));
    sessionConfig_.toolSchemaProfile =
        (profile == "full" || profile == "compact" || profile == "name-only") ? profile : "compact";
    sessionConfig_.checkpointPolicy = normalizedCheckpointPolicy(
        stringField(fields, "checkpointPolicy", stringField(fields, "checkpoint_policy", sessionConfig_.checkpointPolicy))
    );
    sessionConfig_.isConfigured = true;
    sessionConfig_.configurationError.clear();
}

std::string Runtime::registerToolSchema(const char *toolSchemaJson) {
    return tools_.registerSchema(toolSchemaJson);
}

std::string Runtime::registerExternalToolProvider(const char *providerJson) {
    if (providerJson == nullptr || trim(providerJson).empty()) {
        return "{\"ok\":false,\"error\":\"missing external provider JSON\"}";
    }
    std::map<std::string, JsonField> fields;
    if (!parseFieldsOrEmpty(providerJson, fields)) {
        return "{\"ok\":false,\"error\":\"external provider must be a JSON object\"}";
    }
    const std::string providerId = stringField(fields, "provider_id", stringField(fields, "id", "external"));
    const std::string providerNamespace = stringField(fields, "namespace");
    const std::vector<std::string> allowedTools = stringArrayFromRaw(rawField(fields, "allowed_tools", rawField(fields, "allowedTools", "[]")));
    const std::string schemasRaw = rawField(fields, "schemas", rawField(fields, "tools", "[]"));
    int registered = 0;
    std::string lastError;
    for (const std::string &schema : extractObjectArrayItems(schemasRaw)) {
        const std::string namespacedSchema = schemaWithProviderNamespace(schema, providerNamespace, allowedTools);
        if (namespacedSchema.empty()) {
            continue;
        }
        const std::string result = tools_.registerSchema(namespacedSchema.c_str());
        if (result.find("\"ok\":true") != std::string::npos) {
            registered += 1;
        } else {
            lastError = result;
        }
    }
    callbacks_.emitEvent(
        "external_tool_provider_registered",
        "{\"provider_id\":" + jsonString(providerId) +
            ",\"namespace\":" + jsonString(providerNamespace) +
            ",\"registered_tools\":" + std::to_string(registered) + "}"
    );
    if (registered == 0 && !lastError.empty()) {
        return "{\"ok\":false,\"provider_id\":" + jsonString(providerId) +
            ",\"registered_tools\":0,\"error\":\"no provider tools registered\",\"last_error\":" + lastError + "}";
    }
    return "{\"ok\":true,\"provider_id\":" + jsonString(providerId) +
        ",\"namespace\":" + jsonString(providerNamespace) +
        ",\"registered_tools\":" + std::to_string(registered) + "}";
}

void Runtime::setModelCallback(LuminaAgentModelCallback callback, void *context) {
    callbacks_.setModel(callback, context);
}

void Runtime::setStreamingModelCallback(LuminaAgentStreamingModelCallback callback, void *context) {
    callbacks_.setStreamingModel(callback, context);
}

void Runtime::setToolCallback(LuminaAgentToolCallback callback, void *context) {
    callbacks_.setTool(callback, context);
}

void Runtime::setContextCallback(LuminaAgentContextCallback callback, void *context) {
    callbacks_.setContext(callback, context);
}

void Runtime::setPermissionCallback(LuminaAgentPermissionCallback callback, void *context) {
    callbacks_.setPermission(callback, context);
}

void Runtime::setConfirmationCallback(LuminaAgentConfirmationCallback callback, void *context) {
    callbacks_.setConfirmation(callback, context);
}

void Runtime::setGuardrailCallback(LuminaAgentGuardrailCallback callback, void *context) {
    callbacks_.setGuardrail(callback, context);
}

void Runtime::setAuditCallback(LuminaAgentAuditCallback callback, void *context) {
    callbacks_.setAudit(callback, context);
}

void Runtime::setTraceCallback(LuminaAgentTraceCallback callback, void *context) {
    callbacks_.setTrace(callback, context);
}

void Runtime::setMetricsCallback(LuminaAgentMetricsCallback callback, void *context) {
    callbacks_.setMetrics(callback, context);
}

void Runtime::setSpanCallback(LuminaAgentSpanCallback callback, void *context) {
    callbacks_.setSpan(callback, context);
}

void Runtime::setRollbackCallback(LuminaAgentRollbackCallback callback, void *context) {
    callbacks_.setRollback(callback, context);
}

void Runtime::setEventCallback(LuminaAgentEventCallback callback, void *context) {
    callbacks_.setEvent(callback, context);
}

void Runtime::setHookCallback(LuminaAgentHookCallback callback, void *context) {
    callbacks_.setHook(callback, context);
}

std::string Runtime::registerHookRoute(const char *routeJson) {
    return callbacks_.registerHookRoute(routeJson == nullptr ? "{}" : std::string(routeJson));
}

void Runtime::clearHookRoutes() {
    callbacks_.clearHookRoutes();
}

std::string Runtime::run(const char *requestJson) {
    if (!sessionConfig_.isConfigured) {
        return "{\"ok\":false,\"status\":\"failed\",\"resultMarkdown\":\"### 无法执行\\n\\nRuntime 配置无效：" + escapeJson(sessionConfig_.configurationError) + "\"}";
    }
    RuntimeSession session(sessionConfig_);
    return runSession(session, requestJson, false);
}

std::string Runtime::runReplay(const char *requestJson, const char *replayJson) {
    if (!sessionConfig_.isConfigured) {
        return "{\"ok\":false,\"status\":\"failed\",\"resultMarkdown\":\"### 无法执行\\n\\nRuntime 配置无效：" + escapeJson(sessionConfig_.configurationError) + "\"}";
    }
    RuntimeSession session(sessionConfig_);
    return runSession(session, requestJson, false, replayJson);
}

std::string Runtime::runSession(RuntimeSession &session, const char *requestJson, bool allowPause, const char *replayJson) {
    if (!sessionConfig_.isConfigured) {
        return "{\"ok\":false,\"status\":\"failed\",\"resultMarkdown\":\"### 无法执行\\n\\nRuntime 配置无效：" + escapeJson(sessionConfig_.configurationError) + "\"}";
    }
    if (requestJson == nullptr) {
        return "{\"ok\":false,\"status\":\"failed\",\"resultMarkdown\":\"### 无法执行\\n\\n缺少请求 JSON。\"}";
    }
    RuntimeReplayController replay = RuntimeReplayController::fromJson(replayJson == nullptr ? "{}" : replayJson);
    RuntimeReplayController *replayController = replay.isConfigured() ? &replay : nullptr;
    if (!callbacks_.hasModel() && !callbacks_.hasStreamingModel() && !replay.hasModelReplay()) {
        return "{\"ok\":false,\"status\":\"failed\",\"resultMarkdown\":\"### 无法执行\\n\\n没有可用的模型回调。\"}";
    }

    cancelled_ = false;
    callbacks_.setCorrelationContext(session.sessionId(), session.runId());
    struct CorrelationScope {
        RuntimeCallbacks &callbacks;
        ~CorrelationScope() { callbacks.clearCorrelationContext(); }
    } correlationScope{callbacks_};
    RuntimeEventQueue events(callbacks_, session.sessionId(), session.runId());
    ExecutionContext execution(session, sessionConfig_, tools_, callbacks_, events);
    std::string request = session.requestJson().empty() ? trim(requestJson) : session.requestJson();
    const RuntimeGuardrailDecision requestGuardrail = callbacks_.evaluateGuardrail("request", request.empty() ? "{}" : request);
    if (requestGuardrail.decision == "rewrite" && !requestGuardrail.payloadJson.empty()) {
        request = requestGuardrail.payloadJson;
        events.emitEvent("guardrail_rewritten", "{\"stage\":\"request\"}");
    } else if (applyTerminalGuardrailDecision(session, callbacks_, "request", requestGuardrail)) {
        return session.finishIfNeeded();
    }
    session.setRequestJson(request);
    execution.setRequestJson(request);
    callbacks_.span("start", "runtime.run", "{\"session_id\":" + jsonString(session.sessionId()) + ",\"run_id\":" + jsonString(session.runId()) + "}");
    events.emitEvent("run_started", request.empty() ? "{}" : request);
    callbacks_.audit("run_started", request.empty() ? "{}" : request);
    callbacks_.trace("run_started", "{\"session_id\":" + jsonString(session.sessionId()) + ",\"run_id\":" + jsonString(session.runId()) + ",\"request\":" + (request.empty() ? "{}" : request) + "}");
    if (replay.isConfigured()) {
        events.emitControl("replay_started", replay.summaryJson());
        callbacks_.trace("replay_started", replay.summaryJson());
    }
    if (applyHookDirective(session, HookDispatcher(callbacks_).dispatch("run_started", request.empty() ? "{}" : request))) {
        return session.finishIfNeeded();
    }

    std::string contextJson = session.contextJson().empty() ? "null" : session.contextJson();
    if (contextJson == "null" && callbacks_.hasContext()) {
        contextJson = callbacks_.loadContext(ContextManager(session).initialRequestJson(request));
        if (trim(contextJson).empty()) {
            contextJson = "null";
        }
        contextJson = ContextManager(session).compactIfNeeded(request, contextJson, session.stepsSummaryJson(), session.lastObservationJson());
        execution.setContextJson(contextJson);
        events.emitEvent("context_loaded", contextJson);
        if (applyHookDirective(session, HookDispatcher(callbacks_).dispatch("context_loaded", contextJson), &contextJson, request)) {
            return session.finishIfNeeded();
        }
    }

    std::string lastObservation = session.lastObservationJson();
    while (!cancelled_ && session.canContinue()) {
        const ContextBudgetSnapshot budgetSnapshot = execution.budgetManager().snapshotFor(request, contextJson, session.stepsSummaryJson(), lastObservation);
        session.setContextTokenUsageEstimate(budgetSnapshot.usedTokens);
        if (budgetSnapshot.overWindow && !execution.budgetManager().canAttemptCompact(session.compactFailureCount())) {
            session.failWithResult("context-budget", "### 无法继续\n\n上下文超过调用方配置的窗口，且 auto compact 已达到失败上限。");
            break;
        }
        std::string plannerInput = Executor().plannerInput(tools_, session, request, contextJson, lastObservation);
        events.emitEvent(
            "planner_input_ready",
            "{\"tokens_estimate\":" + std::to_string(static_cast<int>(plannerInput.size() / 4)) +
                ",\"characters\":" + std::to_string(plannerInput.size()) +
                ",\"iteration\":" + std::to_string(session.stepCount()) +
                ",\"last_observation_excerpt\":" + jsonString(excerpt(lastObservation, 1200)) +
                ",\"input_excerpt\":" + jsonString(excerpt(plannerInput, 2400)) + "}"
        );
        std::string contextBeforeHook = contextJson;
        if (applyHookDirective(session, HookDispatcher(callbacks_).dispatch("planner_input_ready", "{\"characters\":" + std::to_string(plannerInput.size()) + "}"), &contextJson, request)) {
            break;
        }
        if (contextJson != contextBeforeHook) {
            plannerInput = Executor().plannerInput(tools_, session, request, contextJson, lastObservation);
        }
        contextBeforeHook = contextJson;
        if (applyHookDirective(session, HookDispatcher(callbacks_).dispatch("before_model", "{\"characters\":" + std::to_string(plannerInput.size()) + "}"), &contextJson, request)) {
            break;
        }
        if (contextJson != contextBeforeHook) {
            plannerInput = Executor().plannerInput(tools_, session, request, contextJson, lastObservation);
        }
        std::string stepJson;
        if (replayController != nullptr && replayController->hasModelReplay()) {
            stepJson = replayController->nextModelStep();
            events.emitEvent("model_output_replayed", "{\"iteration\":" + std::to_string(session.stepCount()) + "}");
        } else if (replayController != nullptr && !replayController->allowsLiveModel()) {
            events.emitEvent("model_generation_failed", "{\"reason\":\"replay-missing-model-output\"}");
            session.failWithResult("replay-missing-model-output", "### 无法执行\n\nReplay script did not provide a matching model output.");
            break;
        } else {
            stepJson = StreamingModelRunner(callbacks_).generate(plannerInput);
        }
        if (applyHookDirective(session, HookDispatcher(callbacks_).dispatch("after_model", "{\"characters\":" + std::to_string(stepJson.size()) + ",\"output_excerpt\":" + jsonString(excerpt(stepJson, 1200)) + "}"), &contextJson, request)) {
            break;
        }
        if (trim(stepJson).empty()) {
            events.emitEvent("model_generation_failed", "{\"reason\":\"empty-or-invalid-step\"}");
            session.failWithResult("model-empty-output", "### 无法执行\n\n模型没有返回有效的 ReAct step。");
            break;
        }

        std::string error;
        callbacks_.span("start", "runtime.step.normalize", "{\"session_id\":" + jsonString(session.sessionId()) + ",\"run_id\":" + jsonString(session.runId()) + ",\"iteration\":" + std::to_string(session.stepCount()) + "}");
        if (applyHookDirective(session, HookDispatcher(callbacks_).dispatch("before_normalization", "{\"step_excerpt\":" + jsonString(excerpt(stepJson, 1200)) + "}"), &contextJson, request)) {
            break;
        }
        if (!validateReActStepObject(stepJson, true, error)) {
            callbacks_.span("end", "runtime.step.normalize", "{\"session_id\":" + jsonString(session.sessionId()) + ",\"run_id\":" + jsonString(session.runId()) + ",\"status\":\"failed\",\"error\":" + jsonString(error) + "}");
            events.emitEvent(
                "model_generation_failed",
                "{\"reason\":\"invalid-step\",\"error\":" + jsonString(error) +
                    ",\"step_excerpt\":" + jsonString(excerpt(stepJson, 1200)) + "}"
            );
            session.failWithResult("invalid-model-output", "### 无法执行\n\n模型返回的 ReAct step 不符合协议：" + error);
            break;
        }
        callbacks_.span("end", "runtime.step.normalize", "{\"session_id\":" + jsonString(session.sessionId()) + ",\"run_id\":" + jsonString(session.runId()) + ",\"status\":\"succeeded\"}");
        if (applyHookDirective(session, HookDispatcher(callbacks_).dispatch("after_normalization", stepJson), &contextJson, request)) {
            break;
        }

        std::map<std::string, JsonField> fields;
        parseFieldsOrEmpty(stepJson, fields);
        const std::string type = reactStepType(fields);
        events.emitEvent("step_produced", stepJson);
        if (applyHookDirective(session, HookDispatcher(callbacks_).dispatch("step_produced", stepJson), &contextJson, request)) {
            break;
        }
        const std::string recordJson = session.recordStep(stepJson);
        callbacks_.audit("step_recorded", recordJson);
        callbacks_.trace("step_recorded", "{\"session_id\":" + jsonString(session.sessionId()) + ",\"run_id\":" + jsonString(session.runId()) + ",\"step\":" + stepJson + ",\"record\":" + recordJson + "}");
        emitCheckpointIfNeeded(sessionConfig_, session, callbacks_, events, "on_step");

        if (type == "result" || type == "cannot_complete") {
            break;
        }
        if (type == "reasoning") {
            if (boolField(fields, "needs_more_context", false) && callbacks_.hasContext()) {
                ContextManager contextManager(session);
                std::string additionalContext = callbacks_.loadContext(contextManager.followUpRequestJson(request, stepJson));
                if (!trim(additionalContext).empty() && trim(additionalContext) != "null") {
                    contextJson = contextManager.compactIfNeeded(request, contextManager.mergeContextJson(contextJson, additionalContext), session.stepsSummaryJson(), lastObservation);
                    execution.setContextJson(contextJson);
                    events.emitControl("context_updated", contextJson);
                    if (applyHookDirective(session, HookDispatcher(callbacks_).dispatch("context_updated", contextJson), &contextJson, request)) {
                        break;
                    }
                }
            }
            if (session.consecutiveReasoningCount() >= session.maximumConsecutiveReasoningSteps()) {
                session.failWithResult("reasoning-budget", "### 无法继续\n\n模型连续输出 reasoning，已达到空转保护上限。");
                break;
            }
            continue;
        }
        if (type == "tool_discovery") {
            const std::string discovery = tools_.discoverToolsJson(
                stringField(fields, "query"),
                stringField(fields, "category"),
                intField(fields, "max_results", 0),
                boolField(fields, "include_schemas", true)
            );
            lastObservation = session.recordObservation("runtime.tool_discovery", "succeeded", discovery, "", false, true);
            execution.setLastObservationJson(lastObservation);
            events.emitControl("tool_discovery_completed", lastObservation);
            continue;
        }
        if (type == "tool_use") {
            ToolExecutor(tools_, callbacks_, replayController).runToolCall(
                session,
                stringField(fields, "tool_name"),
                rawField(fields, "parameters", "{}"),
                boolField(fields, "requires_confirmation", false)
            );
            lastObservation = session.lastObservationJson();
            execution.setLastObservationJson(lastObservation);
            continue;
        }
        if (type == "ask_user") {
            if (!tools_.contains("ask_user")) {
                lastObservation = session.recordObservation("ask_user", "failed", "", "ask_user tool is not registered", false, false);
                execution.setLastObservationJson(lastObservation);
                events.emitControl("ask_user_unavailable", lastObservation);
                continue;
            }
            const std::string askParameters = "{\"questions\":" + rawField(fields, "questions", "[]") +
                ",\"reason\":" + jsonString(stringField(fields, "reason")) +
                ",\"sensitivity\":" + jsonString(stringField(fields, "sensitivity")) +
                ",\"timeoutSeconds\":" + rawField(fields, "timeout_seconds", "0") +
                ",\"allow_custom_answer\":" + rawField(fields, "allow_custom_answer", "true") + "}";
            if (allowPause) {
                session.pause("ask_user", askParameters);
                events.emitControl("ask_user_pending", session.pendingJson());
                break;
            }
            ToolExecutor(tools_, callbacks_, replayController).runToolCall(session, "ask_user", askParameters, false);
            lastObservation = session.lastObservationJson();
            execution.setLastObservationJson(lastObservation);
            continue;
        }
        if (type == "multi_tool_use") {
            ToolExecutor(tools_, callbacks_, replayController).runMultiToolCall(session, rawField(fields, "tool_calls", "[]"));
            lastObservation = session.lastObservationJson();
            execution.setLastObservationJson(lastObservation);
            continue;
        }
    }

    if (cancelled_) {
        session.cancel();
    }

    if (session.isPaused()) {
        const std::string snapshot = session.snapshotJson();
        emitCheckpointIfNeeded(sessionConfig_, session, callbacks_, events, "on_pause");
        events.emitControl("run_paused", snapshot);
        callbacks_.audit("run_paused", snapshot);
        HookDispatcher(callbacks_).dispatch("run_paused", snapshot);
        return snapshot;
    }

    std::string finished = Responder().finalize(session);
    const RuntimeGuardrailDecision resultGuardrail = callbacks_.evaluateGuardrail("result", finished);
    if (resultGuardrail.decision == "rewrite" && !resultGuardrail.payloadJson.empty()) {
        const std::string markdown = rewrittenResultMarkdown(resultGuardrail.payloadJson);
        if (!markdown.empty()) {
            session.rewriteResult(markdown);
            finished = Responder().finalize(session);
            events.emitEvent("guardrail_rewritten", "{\"stage\":\"result\"}");
        }
    } else if (applyTerminalGuardrailDecision(session, callbacks_, "result", resultGuardrail)) {
        finished = Responder().finalize(session);
    }
    emitCheckpointIfNeeded(sessionConfig_, session, callbacks_, events, "on_exit");
    events.emitEvent(
        "run_termination",
        "{\"status\":" + jsonString(runStatusName(session.status())) +
            ",\"snapshot\":" + session.snapshotJson() + "}"
    );
    callbacks_.span("start", "runtime.result", "{\"session_id\":" + jsonString(session.sessionId()) + ",\"run_id\":" + jsonString(session.runId()) + "}");
    HookDispatcher(callbacks_).dispatch("result_generated", finished);
    events.emitEvent("run_finished", finished);
    callbacks_.audit("run_finished", finished);
    callbacks_.trace("run_finished", "{\"session_id\":" + jsonString(session.sessionId()) + ",\"run_id\":" + jsonString(session.runId()) + ",\"result\":" + finished + "}");
    callbacks_.span("end", "runtime.result", "{\"session_id\":" + jsonString(session.sessionId()) + ",\"run_id\":" + jsonString(session.runId()) + ",\"status\":" + jsonString(runStatusName(session.status())) + "}");
    callbacks_.span("end", "runtime.run", "{\"session_id\":" + jsonString(session.sessionId()) + ",\"run_id\":" + jsonString(session.runId()) + ",\"status\":" + jsonString(runStatusName(session.status())) + "}");
    HookDispatcher(callbacks_).dispatch("run_finished", finished);
    return finished;
}

std::string Runtime::resumeSession(RuntimeSession &session, const char *resumeJson) {
    if (resumeJson == nullptr) {
        return "{\"ok\":false,\"status\":\"failed\",\"error\":\"missing resume JSON\"}";
    }
    session.resumeWithObservation(trim(resumeJson).empty() ? "{\"status\":\"cancelled\",\"content\":\"resume payload was empty\"}" : trim(resumeJson));
    return runSession(session, session.requestJson().c_str(), true);
}

std::string Runtime::setSessionState(RuntimeSession &session, const char *scope, const char *key, const char *valueJson) {
    const std::string result = session.setStateJson(
        scope == nullptr ? "" : std::string(scope),
        key == nullptr ? "" : std::string(key),
        valueJson == nullptr ? "null" : std::string(valueJson)
    );
    callbacks_.emitEvent("state_mutated", result);
    callbacks_.trace("state_mutated", "{\"session_id\":" + jsonString(session.sessionId()) + ",\"run_id\":" + jsonString(session.runId()) + ",\"mutation\":" + result + "}");
    return result;
}

std::string Runtime::deleteSessionState(RuntimeSession &session, const char *scope, const char *key) {
    const std::string result = session.deleteStateJson(
        scope == nullptr ? "" : std::string(scope),
        key == nullptr ? "" : std::string(key)
    );
    callbacks_.emitEvent("state_mutated", result);
    callbacks_.trace("state_mutated", "{\"session_id\":" + jsonString(session.sessionId()) + ",\"run_id\":" + jsonString(session.runId()) + ",\"mutation\":" + result + "}");
    return result;
}

std::string Runtime::cancel(const char *requestId) {
    (void) requestId;
    cancelled_ = true;
    return "{\"ok\":true,\"cancelled\":true}";
}

RuntimeSessionConfig Runtime::sessionConfig() const {
    return sessionConfig_;
}

} // namespace LuminaAgent
