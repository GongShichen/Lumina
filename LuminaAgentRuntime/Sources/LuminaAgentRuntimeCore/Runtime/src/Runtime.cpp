#include "Runtime.hpp"

#include <algorithm>
#include <chrono>
#include <sstream>
#include <thread>
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

static std::string retryRequestJson(
    const RuntimeSession &session,
    const std::string &stage,
    int attempt,
    int maxAttempts,
    const std::string &errorCode,
    const std::string &errorCategory,
    bool recoverable,
    double retryAfterSeconds,
    long long elapsedMilliseconds,
    const std::string &toolName = "",
    const std::string &toolSideEffect = "",
    const std::string &idempotencyPolicy = "",
    bool hasIdempotencyKey = false,
    bool toolReadOnly = false,
    bool toolDestructive = false
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
           << "\"retry_after_seconds\":" << retryAfterSeconds << ","
           << "\"elapsed_ms\":" << elapsedMilliseconds
           << "}";
    return output.str();
}

static void sleepForRetryDecision(const RuntimeCallbacks &callbacks, const std::string &retryRequest, const RuntimeRetryDecision &decision) {
    const std::string payload = "{\"request\":" + retryRequest +
        ",\"decision\":{\"action\":" + jsonString(decision.action) +
        ",\"delay_ms\":" + std::to_string(std::max<long long>(0, decision.delayMilliseconds)) +
        ",\"reason\":" + jsonString(decision.reason) + "}}";
    callbacks.emitEvent("runtime.retry.scheduled", payload);
    if (decision.delayMilliseconds > 0) {
        std::this_thread::sleep_for(std::chrono::milliseconds(decision.delayMilliseconds));
    }
}

static std::string rewrittenResultMarkdown(const std::string &payloadJson) {
    std::map<std::string, JsonField> fields;
    if (!parseFieldsOrEmpty(payloadJson, fields)) {
        return "";
    }
    return stringField(fields, "resultMarkdown", stringField(fields, "content"));
}

static bool isPromptTooLongSignal(const std::string &modelOutput) {
    const std::string value = lowercased(modelOutput);
    return value.find("context_length_exceeded") != std::string::npos ||
        value.find("prompt_too_long") != std::string::npos ||
        value.find("prompt-too-long") != std::string::npos ||
        value.find("maximum context length") != std::string::npos ||
        value.find("too many tokens") != std::string::npos ||
        value.find("context window") != std::string::npos && value.find("exceed") != std::string::npos;
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
    callbacks.recordHistory("checkpoint_created", payload);
}

static void applyModelMetadataIfAvailable(RuntimeSession &session, RuntimeCallbacks &callbacks, const std::string &requestJson) {
    if (!callbacks.hasModelMetadata()) {
        return;
    }
    const std::string metadataJson = callbacks.loadModelMetadata("{\"request\":" + (trim(requestJson).empty() ? "{}" : requestJson) + "}");
    std::map<std::string, JsonField> fields;
    if (!parseFieldsOrEmpty(metadataJson, fields)) {
        callbacks.emitEvent("runtime.model.metadata.skipped", "{\"reason\":\"invalid metadata json\"}");
        return;
    }
    const int maxContext = std::max(0, intField(fields, "max_context_tokens", intField(fields, "maxContextTokens", intField(fields, "context_window_tokens", 0))));
    const std::string modelId = stringField(fields, "model_id", stringField(fields, "modelId", stringField(fields, "model")));
    const bool nativeContext = boolField(fields, "provider_native_context_management", boolField(fields, "providerNativeContextManagement", boolField(fields, "native_context_management", false)));
    session.applyModelMetadata(maxContext, modelId, nativeContext);
    callbacks.emitEvent(
        "runtime.model.metadata.applied",
        "{\"model_id\":" + jsonString(modelId) +
            ",\"max_context_tokens\":" + std::to_string(maxContext) +
            ",\"provider_native_context_management\":" + jsonBool(nativeContext) + "}"
    );
}

static void initializeDeferredToolWorkingSet(RuntimeSession &session, const ToolRegistry &tools, const RuntimeSessionConfig &config, RuntimeCallbacks &callbacks) {
    const std::vector<std::string> deferredNames = tools.deferredToolNames();
    if (deferredNames.empty()) {
        return;
    }
    bool lazyEnabled = config.toolLoadingMode == "enabled";
    const int estimatedTokens = tools.estimatedDeferredSchemaTokens();
    const int threshold = static_cast<int>(std::max(1, session.maxContextTokens()) * config.toolLoadingThresholdRatio);
    if (config.toolLoadingMode == "auto") {
        lazyEnabled = estimatedTokens >= threshold;
    }
    const std::string payload = "{\"mode\":" + jsonString(config.toolLoadingMode) +
        ",\"lazy_enabled\":" + jsonBool(lazyEnabled) +
        ",\"deferred_tool_count\":" + std::to_string(deferredNames.size()) +
        ",\"estimated_deferred_schema_tokens\":" + std::to_string(estimatedTokens) +
        ",\"threshold_tokens\":" + std::to_string(threshold) + "}";
    callbacks.emitEvent("tool_loading.catalog_emitted", payload);
    callbacks.metric("tool_loading.schema_tokens_saved_estimate", lazyEnabled ? static_cast<double>(estimatedTokens) : 0.0, payload);
    if (!lazyEnabled) {
        session.loadDeferredTools(deferredNames);
    }
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
           << "\"parameters\":" << rawField(fields, "parameters", "[]") << ","
           << "\"deferByDefault\":true,"
           << "\"alwaysLoad\":" << rawField(fields, "alwaysLoad", rawField(fields, "always_load", "false"));
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
    requireInt({"maximumContextTokens", "contextWindowTokens", "maxContextTokens"}, "contextWindowTokens", 1, sessionConfig_.contextWindowTokens);
    if (!configurationError_.empty()) { sessionConfig_.configurationError = configurationError_; return; }
    sessionConfig_.maxContextTokens = intField(fields, "maxContextTokens", intField(fields, "providerMaxContextTokens", intField(fields, "maximumContextTokens", sessionConfig_.contextWindowTokens)));
    sessionConfig_.modelId = stringField(fields, "modelId", stringField(fields, "model_id"));
    sessionConfig_.providerNativeContextManagement = boolField(fields, "providerNativeContextManagement", boolField(fields, "provider_native_context_management", false));
    requireInt({"maxOutputTokens", "maximumOutputTokens"}, "maxOutputTokens", 1, sessionConfig_.maxOutputTokens);
    if (!configurationError_.empty()) { sessionConfig_.configurationError = configurationError_; return; }
    requireInt({"reservedOutputTokens"}, "reservedOutputTokens", 0, sessionConfig_.reservedOutputTokens);
    if (!configurationError_.empty()) { sessionConfig_.configurationError = configurationError_; return; }
    sessionConfig_.autoCompactBufferTokens = std::max(0, intField(fields, "autoCompactBufferTokens", intField(fields, "auto_compact_buffer_tokens", 0)));
    sessionConfig_.warningBufferTokens = std::max(0, intField(fields, "warningBufferTokens", intField(fields, "warning_buffer_tokens", 0)));
    requireInt({"maximumObservationCharacters", "maxObservationCharacters"}, "maxObservationCharacters", 1, sessionConfig_.maximumObservationCharacters);
    if (!configurationError_.empty()) { sessionConfig_.configurationError = configurationError_; return; }
    requireInt({"toolResultTokenBudget"}, "toolResultTokenBudget", 1, sessionConfig_.toolResultTokenBudget);
    if (!configurationError_.empty()) { sessionConfig_.configurationError = configurationError_; return; }
    requireInt({"compactThresholdTokens"}, "compactThresholdTokens", 0, sessionConfig_.compactThresholdTokens);
    if (!configurationError_.empty()) { sessionConfig_.configurationError = configurationError_; return; }
    if (sessionConfig_.autoCompactBufferTokens <= 0) {
        sessionConfig_.autoCompactBufferTokens = sessionConfig_.compactThresholdTokens;
    }
    if (sessionConfig_.warningBufferTokens <= 0) {
        sessionConfig_.warningBufferTokens = std::max(sessionConfig_.autoCompactBufferTokens, sessionConfig_.compactThresholdTokens);
    }
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
    const std::string toolLoadingMode = lowercased(stringField(fields, "toolLoadingMode", stringField(fields, "tool_loading_mode", sessionConfig_.toolLoadingMode)));
    sessionConfig_.toolLoadingMode =
        (toolLoadingMode == "enabled" || toolLoadingMode == "disabled" || toolLoadingMode == "auto") ? toolLoadingMode : "auto";
    sessionConfig_.toolLoadingThresholdRatio = doubleField(fields, "toolLoadingThresholdRatio", doubleField(fields, "tool_loading_threshold_ratio", sessionConfig_.toolLoadingThresholdRatio));
    if (sessionConfig_.toolLoadingThresholdRatio < 0.0) {
        sessionConfig_.toolLoadingThresholdRatio = 0.0;
    }
    if (sessionConfig_.toolLoadingThresholdRatio > 1.0) {
        sessionConfig_.toolLoadingThresholdRatio = 1.0;
    }
    sessionConfig_.checkpointPolicy = normalizedCheckpointPolicy(
        stringField(fields, "checkpointPolicy", stringField(fields, "checkpoint_policy", sessionConfig_.checkpointPolicy))
    );
    sessionConfig_.isConfigured = true;
    sessionConfig_.configurationError.clear();
}

std::string Runtime::registerToolSchema(const char *toolSchemaJson) {
    return tools_.registerSchema(toolSchemaJson);
}

std::string Runtime::registerDeferredToolMetadata(const char *metadataJson) {
    const std::string result = tools_.registerDeferredMetadata(metadataJson);
    callbacks_.emitEvent("tool_loading.catalog_registered", "{\"result\":" + result + "}");
    return result;
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

void Runtime::setModelMetadataCallback(LuminaAgentModelMetadataCallback callback, void *context) {
    callbacks_.setModelMetadata(callback, context);
}

void Runtime::setToolCallback(LuminaAgentToolCallback callback, void *context) {
    callbacks_.setTool(callback, context);
}

void Runtime::setContextCallback(LuminaAgentContextCallback callback, void *context) {
    callbacks_.setContext(callback, context);
}

void Runtime::setContextLoadingPluginCallback(LuminaAgentContextLoadingPluginCallback callback, void *context) {
    callbacks_.setContextLoadingPlugin(callback, context);
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

void Runtime::setRetryProviderCallback(LuminaAgentRetryProviderCallback callback, void *context) {
    callbacks_.setRetryProvider(callback, context);
}

void Runtime::setCompactionProviderCallback(LuminaAgentCompactionProviderCallback callback, void *context) {
    callbacks_.setCompactionProvider(callback, context);
}

void Runtime::setToolLoadingPluginCallback(LuminaAgentToolLoadingPluginCallback callback, void *context) {
    callbacks_.setToolLoadingPlugin(callback, context);
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

void Runtime::setSessionHistoryCallback(LuminaAgentSessionHistoryCallback callback, void *context) {
    callbacks_.setSessionHistory(callback, context);
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

std::string Runtime::runReplayArtifact(const char *artifactJson, const char *optionsJson) {
    if (!sessionConfig_.isConfigured) {
        return "{\"ok\":false,\"status\":\"failed\",\"resultMarkdown\":\"### 无法执行\\n\\nRuntime 配置无效：" + escapeJson(sessionConfig_.configurationError) + "\"}";
    }
    const std::string artifact = artifactJson == nullptr ? "{}" : std::string(artifactJson);
    const std::string request = RuntimeReplayController::requestFromArtifact(artifact);
    const std::string replay = RuntimeReplayController::replayScriptFromArtifact(artifact, optionsJson == nullptr ? "{}" : std::string(optionsJson));
    RuntimeSession session(sessionConfig_);
    const std::string checkpoint = RuntimeReplayController::checkpointFromArtifact(artifact);
    if (!trim(checkpoint).empty()) {
        std::string error;
        session.restoreFromCheckpointJson(checkpoint, error);
    }
    return runSession(session, request.c_str(), false, replay.c_str());
}

RuntimeSession *Runtime::createSessionFromReplayArtifact(const char *artifactJson, const char *forkOptionsJson) const {
    const std::string artifact = artifactJson == nullptr ? "{}" : std::string(artifactJson);
    const std::string checkpoint = RuntimeReplayController::checkpointFromArtifact(artifact);
    auto *session = new RuntimeSession(sessionConfig_);
    if (!trim(checkpoint).empty()) {
        std::string error;
        if (!session->restoreFromCheckpointJson(checkpoint, error)) {
            delete session;
            return nullptr;
        }
    } else {
        session->setRequestJson(RuntimeReplayController::requestFromArtifact(artifact));
    }
    std::map<std::string, JsonField> fields;
    if (parseFieldsOrEmpty(forkOptionsJson == nullptr ? "{}" : std::string(forkOptionsJson), fields)) {
        const std::string overrides = rawField(fields, "overrides", "{}");
        std::map<std::string, JsonField> overrideFields;
        if (parseFieldsOrEmpty(overrides, overrideFields)) {
            const std::string request = rawField(overrideFields, "request", "");
            if (!request.empty() && request != "null") {
                session->setRequestJson(request);
            }
            const std::string context = rawField(overrideFields, "context", "");
            if (!context.empty() && context != "null") {
                session->setContextJson(context);
            }
        }
    }
    session->appendTrace("replay_session_created", "{\"source\":\"artifact\"}");
    return session;
}

std::string Runtime::exportReplayArtifact(const RuntimeSession &session, const char *optionsJson) {
    return RuntimeReplayController::artifactFromSession(
        session.checkpointJson(),
        session.traceJson(),
        session.toolReplayObservationsJson(),
        session.stateSnapshotJson(),
        optionsJson == nullptr ? "{}" : std::string(optionsJson)
    );
}

std::string Runtime::exportSessionCheckpointWithHistory(const RuntimeSession &session) const {
    const std::string checkpoint = session.checkpointJson();
    callbacks_.recordHistoryFor(session.sessionId(), session.runId(), "checkpoint_exported", checkpoint);
    return checkpoint;
}

std::string Runtime::diffReplayArtifacts(const char *expectedJson, const char *actualJson, const char *optionsJson) {
    return RuntimeReplayController::diffArtifacts(
        expectedJson == nullptr ? "{}" : std::string(expectedJson),
        actualJson == nullptr ? "{}" : std::string(actualJson),
        optionsJson == nullptr ? "{}" : std::string(optionsJson)
    );
}

static std::vector<std::string> namesFromMatchesJson(const std::string &matchesJson) {
    std::vector<std::string> names;
    const std::string text = trim(matchesJson);
    if (text.empty() || text == "null") {
        return names;
    }
    for (const std::string &item : extractObjectArrayItems(text)) {
        std::map<std::string, JsonField> fields;
        if (parseFieldsOrEmpty(item, fields)) {
            const std::string name = stringField(fields, "name", stringField(fields, "tool_name"));
            if (!name.empty() && std::find(names.begin(), names.end(), name) == names.end()) {
                names.push_back(name);
            }
        }
    }
    if (!names.empty()) {
        return names;
    }
    return stringArrayFromRaw(text);
}

std::string Runtime::loadDeferredToolsByName(RuntimeSession &session, const std::vector<std::string> &names) {
    if (names.empty()) {
        return "{\"ok\":true,\"loaded\":[],\"loaded_tool_set\":" + session.loadedToolSetJson() + "}";
    }
    std::vector<std::string> loaded;
    std::vector<std::string> failed;
    if (callbacks_.hasToolLoadingPlugin()) {
        std::ostringstream namesJson;
        namesJson << "[";
        for (size_t index = 0; index < names.size(); index++) {
            if (index > 0) {
                namesJson << ",";
            }
            namesJson << jsonString(names[index]);
        }
        namesJson << "]";
        const std::string request = "{\"action\":\"load\",\"session_id\":" + jsonString(session.sessionId()) +
            ",\"run_id\":" + jsonString(session.runId()) +
            ",\"names\":" + namesJson.str() +
            ",\"loaded_tool_set\":" + session.loadedToolSetJson() + "}";
        const std::string response = callbacks_.callToolLoadingPlugin(request);
        std::map<std::string, JsonField> fields;
        if (parseFieldsOrEmpty(response, fields)) {
            for (const std::string &schema : extractObjectArrayItems(rawField(fields, "schemas", "[]"))) {
                const std::string registered = tools_.registerSchema(schema.c_str());
                if (registered.find("\"ok\":true") == std::string::npos) {
                    callbacks_.emitEvent("tool_loading.load_failed", "{\"schema\":" + schema + ",\"result\":" + registered + "}");
                }
            }
            loaded = namesFromMatchesJson(rawField(fields, "loaded", rawField(fields, "names", "[]")));
            failed = namesFromMatchesJson(rawField(fields, "failed", "[]"));
        } else {
            callbacks_.emitEvent("tool_loading.load_failed", "{\"reason\":\"plugin returned invalid JSON\"}");
        }
    }
    if (loaded.empty() && failed.empty()) {
        for (const std::string &name : names) {
            if (tools_.contains(name)) {
                loaded.push_back(name);
            } else {
                failed.push_back(name);
            }
        }
    }
    session.loadDeferredTools(loaded);
    std::ostringstream loadedJson;
    loadedJson << "[";
    for (size_t index = 0; index < loaded.size(); index++) {
        if (index > 0) {
            loadedJson << ",";
        }
        loadedJson << jsonString(loaded[index]);
    }
    loadedJson << "]";
    std::ostringstream failedJson;
    failedJson << "[";
    for (size_t index = 0; index < failed.size(); index++) {
        if (index > 0) {
            failedJson << ",";
        }
        failedJson << jsonString(failed[index]);
    }
    failedJson << "]";
    const std::string payload = "{\"loaded\":" + loadedJson.str() +
        ",\"failed\":" + failedJson.str() +
        ",\"loaded_tool_set\":" + session.loadedToolSetJson() + "}";
    callbacks_.emitEvent("tool_loading.loaded", payload);
    callbacks_.metric("tool_loading.loaded_count", static_cast<double>(loaded.size()), payload);
    return "{\"ok\":true," + payload.substr(1);
}

std::string Runtime::loadDeferredTools(RuntimeSession &session, const char *namesJson) {
    if (namesJson == nullptr || trim(namesJson).empty()) {
        return "{\"ok\":false,\"error\":\"missing deferred tool names\"}";
    }
    std::map<std::string, JsonField> fields;
    const std::string text = trim(namesJson);
    std::vector<std::string> names;
    if (parseFieldsOrEmpty(text, fields)) {
        names = namesFromMatchesJson(rawField(fields, "names", rawField(fields, "tools", "[]")));
    } else {
        names = namesFromMatchesJson(text);
    }
    return loadDeferredToolsByName(session, names);
}

std::string Runtime::discoverAndMaybeLoadTools(RuntimeSession &session, const std::string &stepJson) {
    std::map<std::string, JsonField> fields;
    parseFieldsOrEmpty(stepJson, fields);
    const std::string query = stringField(fields, "query");
    const std::string category = stringField(fields, "category");
    const int maxResults = intField(fields, "max_results", 0);
    const bool includeSchemas = boolField(fields, "include_schemas", true);
    const bool explicitSelect = lowercased(query).rfind("select:", 0) == 0;
    const auto started = std::chrono::steady_clock::now();

    std::string discovery;
    if (callbacks_.hasToolLoadingPlugin()) {
        const std::string request = "{\"action\":\"search\",\"session_id\":" + jsonString(session.sessionId()) +
            ",\"run_id\":" + jsonString(session.runId()) +
            ",\"query\":" + jsonString(query) +
            ",\"category\":" + jsonString(category) +
            ",\"max_results\":" + std::to_string(maxResults) +
            ",\"include_schemas\":" + jsonBool(includeSchemas) +
            ",\"loaded_tool_set\":" + session.loadedToolSetJson() + "}";
        discovery = callbacks_.callToolLoadingPlugin(request);
        std::map<std::string, JsonField> pluginFields;
        if (!parseFieldsOrEmpty(discovery, pluginFields)) {
            callbacks_.emitEvent("tool_loading.search_failed", "{\"reason\":\"plugin returned invalid JSON\"}");
            discovery.clear();
        } else {
            for (const std::string &schema : extractObjectArrayItems(rawField(pluginFields, "schemas", "[]"))) {
                const std::string registered = tools_.registerSchema(schema.c_str());
                if (registered.find("\"ok\":true") == std::string::npos) {
                    callbacks_.emitEvent("tool_loading.load_failed", "{\"schema\":" + schema + ",\"result\":" + registered + "}");
                }
            }
        }
    }
    if (trim(discovery).empty()) {
        discovery = tools_.discoverToolsJson(query, category, maxResults, includeSchemas);
    }

    std::map<std::string, JsonField> discoveryFields;
    std::vector<std::string> names;
    if (parseFieldsOrEmpty(discovery, discoveryFields)) {
        names = namesFromMatchesJson(rawField(discoveryFields, "matches", "[]"));
    }
    if (includeSchemas || explicitSelect) {
        const std::string loadResult = loadDeferredToolsByName(session, names);
        callbacks_.trace("tool_loading.loaded", loadResult);
    }
    const auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now() - started).count();
    const std::string payload = "{\"query\":" + jsonString(query) +
        ",\"category\":" + jsonString(category) +
        ",\"match_count\":" + std::to_string(names.size()) +
        ",\"elapsed_ms\":" + std::to_string(elapsed) +
        ",\"loaded_tool_set\":" + session.loadedToolSetJson() + "}";
    callbacks_.emitEvent("tool_loading.search", payload);
    callbacks_.metric("tool_loading.search_latency_ms", static_cast<double>(elapsed), payload);
    return discovery;
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
    if (!callbacks_.hasModel() &&
        !callbacks_.hasStreamingModel() &&
        !replay.hasModelReplay() &&
        (replayController == nullptr || replayController->allowsLiveModel())) {
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
        const std::string failed = session.finishIfNeeded();
        callbacks_.recordHistory("run_failed", failed);
        return failed;
    }
    session.setRequestJson(request);
    applyModelMetadataIfAvailable(session, callbacks_, request);
    initializeDeferredToolWorkingSet(session, tools_, sessionConfig_, callbacks_);
    execution.setRequestJson(request);
    callbacks_.span("start", "runtime.run", "{\"session_id\":" + jsonString(session.sessionId()) + ",\"run_id\":" + jsonString(session.runId()) + "}");
    events.emitEvent("run_started", request.empty() ? "{}" : request);
    callbacks_.audit("run_started", request.empty() ? "{}" : request);
    callbacks_.trace("run_started", "{\"session_id\":" + jsonString(session.sessionId()) + ",\"run_id\":" + jsonString(session.runId()) + ",\"request\":" + (request.empty() ? "{}" : request) + "}");
    callbacks_.recordHistory("run_started", request.empty() ? "{}" : request);
    if (replay.isConfigured()) {
        events.emitControl("replay_started", replay.summaryJson());
        callbacks_.trace("replay_started", replay.summaryJson());
    }
    if (applyHookDirective(session, HookDispatcher(callbacks_).dispatch("run_started", request.empty() ? "{}" : request))) {
        return session.finishIfNeeded();
    }

    std::string contextJson = session.contextJson().empty() ? "null" : session.contextJson();
    if (contextJson == "null" && (callbacks_.hasContextLoadingPlugin() || callbacks_.hasContext())) {
        ContextManager contextManager(session);
        contextJson = callbacks_.hasContextLoadingPlugin()
            ? contextManager.loadProgressiveInitialContext(request, callbacks_)
            : callbacks_.loadContext(contextManager.initialRequestJson(request));
        if (trim(contextJson).empty()) {
            contextJson = "null";
        }
        contextJson = contextManager.compactIfNeeded(request, contextJson, session.stepsSummaryJson(), session.lastObservationJson(), &callbacks_, "auto");
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
        if (budgetSnapshot.warning || budgetSnapshot.shouldCompact) {
            ContextManager contextManager(session);
            const std::string compactedContext = contextManager.compactIfNeeded(
                request,
                contextJson,
                session.stepsSummaryJson(),
                lastObservation,
                &callbacks_,
                budgetSnapshot.overWindow ? "reactive" : "auto"
            );
            if (compactedContext != contextJson) {
                contextJson = compactedContext;
                execution.setContextJson(contextJson);
                events.emitControl("context_compacted", contextJson);
                if (applyHookDirective(session, HookDispatcher(callbacks_).dispatch("context_compacted", contextJson), &contextJson, request)) {
                    break;
                }
            }
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
        std::string error;
        bool stepReady = false;
        int modelAttempt = 1;
        int normalizationAttempt = 1;
        int maxModelAttempts = 3;
        int maxNormalizationAttempts = 2;
        bool reactivePromptTooLongRecoveryUsed = false;
        while (!cancelled_ && !stepReady) {
            const auto modelStartedAt = std::chrono::steady_clock::now();
            if (replayController != nullptr && replayController->hasModelReplay()) {
                stepJson = replayController->nextModelStep();
                events.emitEvent("model_output_replayed", "{\"iteration\":" + std::to_string(session.stepCount()) + "}");
            } else if (replayController != nullptr && !replayController->allowsLiveModel()) {
                events.emitEvent("replay_missing_entry", "{\"kind\":\"model_output\",\"iteration\":" + std::to_string(session.stepCount()) + "}");
                events.emitEvent("model_generation_failed", "{\"reason\":\"replay-missing-model-output\"}");
                session.failWithResult("replay-missing-model-output", "### 无法执行\n\nReplay script did not provide a matching model output.");
                break;
            } else {
                stepJson = StreamingModelRunner(callbacks_).generate(plannerInput);
            }
            const auto modelElapsedMs = std::chrono::duration_cast<std::chrono::milliseconds>(
                std::chrono::steady_clock::now() - modelStartedAt
            ).count();
            if (applyHookDirective(session, HookDispatcher(callbacks_).dispatch("after_model", "{\"characters\":" + std::to_string(stepJson.size()) + ",\"output_excerpt\":" + jsonString(excerpt(stepJson, 1200)) + "}"), &contextJson, request)) {
                break;
            }
            if (isPromptTooLongSignal(stepJson) && !reactivePromptTooLongRecoveryUsed && modelAttempt < maxModelAttempts) {
                reactivePromptTooLongRecoveryUsed = true;
                ContextManager contextManager(session);
                const std::string compactedContext = contextManager.compactIfNeeded(
                    request,
                    contextJson,
                    session.stepsSummaryJson(),
                    lastObservation,
                    &callbacks_,
                    "reactive"
                );
                if (compactedContext != contextJson) {
                    contextJson = compactedContext;
                    execution.setContextJson(contextJson);
                    plannerInput = Executor().plannerInput(tools_, session, request, contextJson, lastObservation);
                    callbacks_.emitEvent(
                        "runtime.context.compaction.prompt_too_long_recovered",
                        "{\"attempt\":" + std::to_string(modelAttempt) +
                            ",\"input_characters\":" + std::to_string(plannerInput.size()) + "}"
                    );
                    modelAttempt += 1;
                    continue;
                }
            }
            if (trim(stepJson).empty()) {
                const std::string retryRequest = retryRequestJson(session, "model_generation", modelAttempt, maxModelAttempts, "empty-output", "provider", true, 0, modelElapsedMs);
                const RuntimeRetryDecision retry = callbacks_.decideRetry(retryRequest);
                if (retry.action == "retry") {
                    if (retry.maxAttemptsOverride > 0) {
                        maxModelAttempts = std::max(modelAttempt, retry.maxAttemptsOverride);
                    }
                    sleepForRetryDecision(callbacks_, retryRequest, retry);
                    modelAttempt += 1;
                    continue;
                }
                if (retry.action == "fallback") {
                    callbacks_.emitEvent("runtime.fallback.used", "{\"request\":" + retryRequest + ",\"reason\":" + jsonString(retry.reason) + "}");
                    session.failWithResult("fallback-requested", "### 无法执行\n\nRetry provider requested fallback, but no fallback provider is installed in the core runtime.");
                    break;
                }
                events.emitEvent("model_generation_failed", "{\"reason\":\"empty-or-invalid-step\"}");
                callbacks_.emitEvent("runtime.retry.failed", "{\"request\":" + retryRequest + ",\"reason\":" + jsonString(retry.reason) + "}");
                session.failWithResult("model-empty-output", "### 无法执行\n\n模型没有返回有效的 ReAct step。");
                break;
            }

            callbacks_.span("start", "runtime.step.normalize", "{\"session_id\":" + jsonString(session.sessionId()) + ",\"run_id\":" + jsonString(session.runId()) + ",\"iteration\":" + std::to_string(session.stepCount()) + ",\"retry.attempt\":" + std::to_string(normalizationAttempt) + "}");
            if (applyHookDirective(session, HookDispatcher(callbacks_).dispatch("before_normalization", "{\"step_excerpt\":" + jsonString(excerpt(stepJson, 1200)) + "}"), &contextJson, request)) {
                break;
            }
            if (!validateReActStepObject(stepJson, true, error)) {
                callbacks_.span("end", "runtime.step.normalize", "{\"session_id\":" + jsonString(session.sessionId()) + ",\"run_id\":" + jsonString(session.runId()) + ",\"status\":\"failed\",\"error\":" + jsonString(error) + "}");
                const std::string retryRequest = retryRequestJson(session, "step_normalization", normalizationAttempt, maxNormalizationAttempts, "invalid-step", "normalization", true, 0, 0);
                const RuntimeRetryDecision retry = callbacks_.decideRetry(retryRequest);
                if (retry.action == "retry") {
                    if (retry.maxAttemptsOverride > 0) {
                        maxNormalizationAttempts = std::max(normalizationAttempt, retry.maxAttemptsOverride);
                    }
                    sleepForRetryDecision(callbacks_, retryRequest, retry);
                    normalizationAttempt += 1;
                    continue;
                }
                events.emitEvent(
                    "model_generation_failed",
                    "{\"reason\":\"invalid-step\",\"error\":" + jsonString(error) +
                        ",\"step_excerpt\":" + jsonString(excerpt(stepJson, 1200)) + "}"
                );
                callbacks_.emitEvent("runtime.retry.failed", "{\"request\":" + retryRequest + ",\"reason\":" + jsonString(retry.reason) + "}");
                session.failWithResult("invalid-model-output", "### 无法执行\n\n模型返回的 ReAct step 不符合协议：" + error);
                break;
            }
            callbacks_.span("end", "runtime.step.normalize", "{\"session_id\":" + jsonString(session.sessionId()) + ",\"run_id\":" + jsonString(session.runId()) + ",\"status\":\"succeeded\",\"retry.attempt\":" + std::to_string(normalizationAttempt) + "}");
            if (modelAttempt > 1 || normalizationAttempt > 1) {
                callbacks_.emitEvent("runtime.retry.succeeded", "{\"stage\":\"model_generation\",\"model_attempts\":" + std::to_string(modelAttempt) + ",\"normalization_attempts\":" + std::to_string(normalizationAttempt) + "}");
            }
            stepReady = true;
        }
        if (!stepReady) {
            break;
        }
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
        callbacks_.recordHistory("step_recorded", "{\"step\":" + stepJson + ",\"record\":" + recordJson + "}");
        emitCheckpointIfNeeded(sessionConfig_, session, callbacks_, events, "on_step");

        if (type == "result" || type == "cannot_complete") {
            break;
        }
        if (type == "reasoning") {
            if (boolField(fields, "needs_more_context", false) && (callbacks_.hasContextLoadingPlugin() || callbacks_.hasContext())) {
                ContextManager contextManager(session);
                std::string additionalContext = callbacks_.hasContextLoadingPlugin()
                    ? contextManager.loadProgressiveFollowUpContext(request, stepJson, contextJson, callbacks_)
                    : callbacks_.loadContext(contextManager.followUpRequestJson(request, stepJson));
                if (!trim(additionalContext).empty() && trim(additionalContext) != "null") {
                    const std::string mergedContext = callbacks_.hasContextLoadingPlugin()
                        ? additionalContext
                        : contextManager.mergeContextJson(contextJson, additionalContext);
                    contextJson = contextManager.compactIfNeeded(request, mergedContext, session.stepsSummaryJson(), lastObservation, &callbacks_, "auto");
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
            const std::string discovery = discoverAndMaybeLoadTools(session, stepJson);
            lastObservation = session.recordObservation("runtime.tool_discovery", "succeeded", discovery, "", false, true);
            execution.setLastObservationJson(lastObservation);
            events.emitControl("tool_discovery_completed", lastObservation);
            callbacks_.recordHistory("observation_created", lastObservation);
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
                callbacks_.recordHistory("observation_created", lastObservation);
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
        callbacks_.recordHistory("run_paused", snapshot);
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
    callbacks_.recordHistory(
        session.status() == RunStatus::succeeded || session.status() == RunStatus::partiallySucceeded ? "run_finished" : "run_failed",
        finished
    );
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
