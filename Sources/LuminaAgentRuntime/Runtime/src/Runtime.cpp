#include "Runtime.hpp"

#include <algorithm>
#include <sstream>

#include "Hooks.hpp"
#include "Json.hpp"
#include "ReAct.hpp"
#include "AgentPipeline.hpp"
#include "ContextManager.hpp"
#include "StreamingModelRunner.hpp"

namespace LuminaAgent {

static bool applyHookDirective(RuntimeSession &session, const std::string &directiveJson) {
    std::map<std::string, JsonField> fields;
    if (!parseFieldsOrEmpty(directiveJson, fields) || !boolField(fields, "terminate", false)) {
        return false;
    }
    session.failWithFinal(
        stringField(fields, "reason", "hook terminated run"),
        stringField(fields, "markdown", "### 已终止\n\nRuntime hook terminated this run.")
    );
    return true;
}

Runtime::Runtime(const char *configurationJson) {
    if (configurationJson == nullptr) {
        return;
    }
    std::map<std::string, JsonField> fields;
    if (!parseFieldsOrEmpty(configurationJson, fields)) {
        return;
    }
    sessionConfig_.maximumReActIterations = std::max(1, intField(fields, "maximumReActIterations", sessionConfig_.maximumReActIterations));
    sessionConfig_.maximumToolCalls = std::max(0, intField(fields, "maximumToolCalls", sessionConfig_.maximumToolCalls));
    sessionConfig_.maximumObservationCharacters = std::max(128, intField(fields, "maximumObservationCharacters", sessionConfig_.maximumObservationCharacters));
    sessionConfig_.maximumContextTokens = std::max(1024, intField(fields, "maximumContextTokens", sessionConfig_.maximumContextTokens));
    sessionConfig_.stopOnToolFailure = boolField(fields, "stopOnToolFailure", sessionConfig_.stopOnToolFailure);
    maximumConsecutiveReasoningSteps_ = std::max(1, intField(fields, "maximumConsecutiveReasoningSteps", maximumConsecutiveReasoningSteps_));
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

void Runtime::setAuditCallback(LuminaAgentAuditCallback callback, void *context) {
    callbacks_.setAudit(callback, context);
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

std::string Runtime::run(const char *requestJson) {
    RuntimeSession session(sessionConfig_);
    return runSession(session, requestJson, false);
}

std::string Runtime::runSession(RuntimeSession &session, const char *requestJson, bool allowPause) {
    if (requestJson == nullptr) {
        return "{\"ok\":false,\"status\":\"failed\",\"finalMarkdown\":\"### 无法执行\\n\\n缺少请求 JSON。\"}";
    }
    if (!callbacks_.hasModel() && !callbacks_.hasStreamingModel()) {
        return "{\"ok\":false,\"status\":\"failed\",\"finalMarkdown\":\"### 无法执行\\n\\n没有可用的模型回调。\"}";
    }

    cancelled_ = false;
    const std::string request = session.requestJson().empty() ? trim(requestJson) : session.requestJson();
    session.setRequestJson(request);
    callbacks_.emitEvent("run_started", request.empty() ? "{}" : request);
    callbacks_.audit("run_started", request.empty() ? "{}" : request);
    if (applyHookDirective(session, HookDispatcher(callbacks_).dispatch("run_started", request.empty() ? "{}" : request))) {
        return session.finishIfNeeded();
    }

    std::string contextJson = session.contextJson().empty() ? "null" : session.contextJson();
    if (contextJson == "null" && callbacks_.hasContext()) {
        contextJson = callbacks_.loadContext(ContextManager(session).initialRequestJson(request));
        if (trim(contextJson).empty()) {
            contextJson = "null";
        }
        contextJson = ContextManager(session).compactIfNeeded(contextJson);
        session.setContextJson(contextJson);
        callbacks_.emitEvent("context_loaded", contextJson);
        if (applyHookDirective(session, HookDispatcher(callbacks_).dispatch("context_loaded", contextJson))) {
            return session.finishIfNeeded();
        }
    }

    std::string lastObservation = session.lastObservationJson();
    while (!cancelled_ && session.canContinue()) {
        const std::string plannerInput = Executor().plannerInput(tools_, session, request, contextJson, lastObservation);
        callbacks_.emitEvent("planner_input_ready", "{\"tokens_estimate\":" + std::to_string(static_cast<int>(plannerInput.size() / 4)) + "}");
        if (applyHookDirective(session, HookDispatcher(callbacks_).dispatch("planner_input_ready", "{\"characters\":" + std::to_string(plannerInput.size()) + "}"))) {
            break;
        }
        const std::string stepJson = StreamingModelRunner(callbacks_).generate(plannerInput);
        if (trim(stepJson).empty()) {
            session.failWithFinal("model-empty-output", "### 无法执行\n\n模型没有返回有效的 ReAct step。");
            break;
        }

        std::string error;
        if (!validateReActStepObject(stepJson, true, error)) {
            session.failWithFinal("invalid-model-output", "### 无法执行\n\n模型返回的 ReAct step 不符合协议：" + error);
            break;
        }

        std::map<std::string, JsonField> fields;
        parseFieldsOrEmpty(stepJson, fields);
        const std::string type = reactStepType(fields);
        callbacks_.emitEvent("step_produced", stepJson);
        if (applyHookDirective(session, HookDispatcher(callbacks_).dispatch("step_produced", stepJson))) {
            break;
        }
        const std::string recordJson = session.recordStep(stepJson);
        callbacks_.audit("step_recorded", recordJson);

        if (type == "final_answer" || type == "cannot_complete") {
            break;
        }
        if (type == "reasoning") {
            if (session.consecutiveReasoningCount() >= maximumConsecutiveReasoningSteps_) {
                session.failWithFinal("reasoning-budget", "### 无法继续\n\n模型连续输出 reasoning，已达到空转保护上限。");
                break;
            }
            continue;
        }
        if (type == "tool_use") {
            lastObservation = ToolExecutor(tools_, callbacks_).runToolCall(
                session,
                stringField(fields, "tool_name"),
                rawField(fields, "parameters", "{}"),
                boolField(fields, "requires_confirmation", false)
            );
            session.setLastObservationJson(lastObservation);
            continue;
        }
        if (type == "ask_user") {
            const std::string askParameters = "{\"questions\":" + rawField(fields, "questions", "[]") +
                ",\"reason\":" + jsonString(stringField(fields, "reason")) +
                ",\"sensitivity\":" + jsonString(stringField(fields, "sensitivity")) +
                ",\"timeoutSeconds\":" + rawField(fields, "timeout_seconds", "0") +
                ",\"allow_custom_answer\":" + rawField(fields, "allow_custom_answer", "true") + "}";
            if (allowPause) {
                session.pause("ask_user", askParameters);
                break;
            }
            lastObservation = ToolExecutor(tools_, callbacks_).runToolCall(session, "ask_user", askParameters, false);
            session.setLastObservationJson(lastObservation);
            continue;
        }
        if (type == "multi_tool_use") {
            lastObservation = ToolExecutor(tools_, callbacks_).runMultiToolCall(session, rawField(fields, "tool_calls", "[]"));
            session.setLastObservationJson(lastObservation);
            continue;
        }
    }

    if (cancelled_) {
        session.cancel();
    }

    const std::string finished = Responder().finalize(session);
    HookDispatcher(callbacks_).dispatch("final_generated", finished);
    callbacks_.emitEvent("run_finished", finished);
    callbacks_.audit("run_finished", finished);
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

std::string Runtime::cancel(const char *requestId) {
    (void) requestId;
    cancelled_ = true;
    return "{\"ok\":true,\"cancelled\":true}";
}

RuntimeSessionConfig Runtime::sessionConfig() const {
    return sessionConfig_;
}

} // namespace LuminaAgent
