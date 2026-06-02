#pragma once

#include <vector>
#include <string>

#include "LuminaAgentRuntime.h"

namespace LuminaAgent {

struct CallbackSlot {
    void *function = nullptr;
    void *context = nullptr;
};

struct StreamingModelResult {
    std::string text;
    int outputTokenCount = 0;
    long long timeToFirstTokenMilliseconds = -1;
    long long chunkCount = 0;
};

struct RuntimeHookRoute {
    std::string id;
    std::vector<std::string> events;
    std::vector<std::string> toolNamePatterns;
    std::vector<std::string> sensitivities;
    std::vector<std::string> sideEffects;
};

struct RuntimeGuardrailDecision {
    std::string decision = "allow";
    std::string message;
    std::string payloadJson;
};

struct RuntimeRetryDecision {
    std::string action = "fail";
    std::string reason;
    long long delayMilliseconds = 0;
    int maxAttemptsOverride = 0;
};

class RuntimeCallbacks {
public:
    // Store caller-provided callbacks. Context ownership remains with the caller.
    void setModel(LuminaAgentModelCallback callback, void *context);
    void setStreamingModel(LuminaAgentStreamingModelCallback callback, void *context);
    void setTool(LuminaAgentToolCallback callback, void *context);
    void setContext(LuminaAgentContextCallback callback, void *context);
    void setPermission(LuminaAgentPermissionCallback callback, void *context);
    void setConfirmation(LuminaAgentConfirmationCallback callback, void *context);
    void setGuardrail(LuminaAgentGuardrailCallback callback, void *context);
    void setRetryProvider(LuminaAgentRetryProviderCallback callback, void *context);
    void setAudit(LuminaAgentAuditCallback callback, void *context);
    void setTrace(LuminaAgentTraceCallback callback, void *context);
    void setMetrics(LuminaAgentMetricsCallback callback, void *context);
    void setSpan(LuminaAgentSpanCallback callback, void *context);
    void setRollback(LuminaAgentRollbackCallback callback, void *context);
    void setEvent(LuminaAgentEventCallback callback, void *context);
    void setHook(LuminaAgentHookCallback callback, void *context);
    void setCorrelationContext(const std::string &sessionId, const std::string &runId);
    void clearCorrelationContext();

    // Lightweight availability checks used by runtime guards and fallback paths.
    bool hasModel() const;
    bool hasStreamingModel() const;
    bool hasTool() const;
    bool hasContext() const;
    bool hasPermission() const;
    bool hasConfirmation() const;
    bool hasGuardrail() const;
    bool hasRetryProvider() const;
    bool hasHook() const;
    bool hasTrace() const;
    bool hasMetrics() const;
    bool hasSpan() const;

    // Invoke model callbacks and return runtime-owned std::string values.
    std::string callModel(const std::string &plannerInput) const;
    std::string callStreamingModel(const std::string &plannerInput) const;
    StreamingModelResult callStreamingModelWithMetrics(const std::string &plannerInput) const;

    // Invoke platform/application callbacks for tools, context, policy, and hooks.
    std::string callTool(const std::string &toolCall) const;
    std::string loadContext(const std::string &contextRequest) const;
    std::string decidePermission(const std::string &permissionRequest) const;
    std::string confirm(const std::string &confirmationRequest) const;
    RuntimeGuardrailDecision evaluateGuardrail(const std::string &stage, const std::string &payloadJson) const;
    RuntimeRetryDecision decideRetry(const std::string &retryRequestJson) const;
    std::string dispatchHook(const std::string &hookEvent) const;
    std::vector<std::string> matchingHookRouteIds(const std::string &lifecycle, const std::string &payloadJson) const;
    std::string registerHookRoute(const std::string &routeJson);
    void clearHookRoutes();

    // Emit normalized runtime telemetry to caller-selected callbacks.
    void emitEvent(const std::string &type, const std::string &payload = "{}") const;
    void audit(const std::string &type, const std::string &payload = "{}") const;
    void trace(const std::string &type, const std::string &payload = "{}") const;
    void metric(const std::string &name, double value, const std::string &payload = "{}") const;
    void span(const std::string &phase, const std::string &name, const std::string &payload = "{}") const;

private:
    CallbackSlot model_;
    CallbackSlot streamingModel_;
    CallbackSlot tool_;
    CallbackSlot context_;
    CallbackSlot permission_;
    CallbackSlot confirmation_;
    CallbackSlot guardrail_;
    CallbackSlot retryProvider_;
    CallbackSlot audit_;
    CallbackSlot trace_;
    CallbackSlot metrics_;
    CallbackSlot span_;
    CallbackSlot rollback_;
    CallbackSlot event_;
    CallbackSlot hook_;
    std::vector<RuntimeHookRoute> hookRoutes_;
    std::string currentSessionId_;
    std::string currentRunId_;
    mutable long long telemetrySequence_ = 0;
    mutable std::vector<std::pair<std::string, std::string>> spanStack_;
};

} // namespace LuminaAgent
