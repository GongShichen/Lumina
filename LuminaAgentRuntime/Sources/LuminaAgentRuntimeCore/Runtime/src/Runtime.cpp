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
    sessionConfig_.isConfigured = true;
    sessionConfig_.configurationError.clear();
}

std::string Runtime::registerToolSchema(const char *toolSchemaJson) {
    return tools_.registerSchema(toolSchemaJson);
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

std::string Runtime::runSession(RuntimeSession &session, const char *requestJson, bool allowPause) {
    if (!sessionConfig_.isConfigured) {
        return "{\"ok\":false,\"status\":\"failed\",\"resultMarkdown\":\"### 无法执行\\n\\nRuntime 配置无效：" + escapeJson(sessionConfig_.configurationError) + "\"}";
    }
    if (requestJson == nullptr) {
        return "{\"ok\":false,\"status\":\"failed\",\"resultMarkdown\":\"### 无法执行\\n\\n缺少请求 JSON。\"}";
    }
    if (!callbacks_.hasModel() && !callbacks_.hasStreamingModel()) {
        return "{\"ok\":false,\"status\":\"failed\",\"resultMarkdown\":\"### 无法执行\\n\\n没有可用的模型回调。\"}";
    }

    cancelled_ = false;
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
        const std::string plannerInput = Executor().plannerInput(tools_, session, request, contextJson, lastObservation);
        events.emitEvent(
            "planner_input_ready",
            "{\"tokens_estimate\":" + std::to_string(static_cast<int>(plannerInput.size() / 4)) +
                ",\"characters\":" + std::to_string(plannerInput.size()) +
                ",\"iteration\":" + std::to_string(session.stepCount()) +
                ",\"last_observation_excerpt\":" + jsonString(excerpt(lastObservation, 1200)) +
                ",\"input_excerpt\":" + jsonString(excerpt(plannerInput, 2400)) + "}"
        );
        if (applyHookDirective(session, HookDispatcher(callbacks_).dispatch("planner_input_ready", "{\"characters\":" + std::to_string(plannerInput.size()) + "}"), &contextJson, request)) {
            break;
        }
        if (applyHookDirective(session, HookDispatcher(callbacks_).dispatch("before_model", "{\"characters\":" + std::to_string(plannerInput.size()) + "}"), &contextJson, request)) {
            break;
        }
        const std::string stepJson = StreamingModelRunner(callbacks_).generate(plannerInput);
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
            ToolExecutor(tools_, callbacks_).runToolCall(
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
            ToolExecutor(tools_, callbacks_).runToolCall(session, "ask_user", askParameters, false);
            lastObservation = session.lastObservationJson();
            execution.setLastObservationJson(lastObservation);
            continue;
        }
        if (type == "multi_tool_use") {
            ToolExecutor(tools_, callbacks_).runMultiToolCall(session, rawField(fields, "tool_calls", "[]"));
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
