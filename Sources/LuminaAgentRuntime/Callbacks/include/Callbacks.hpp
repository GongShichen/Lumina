#pragma once

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

class RuntimeCallbacks {
public:
    // Store caller-provided callbacks. Context ownership remains with the caller.
    void setModel(LuminaAgentModelCallback callback, void *context);
    void setStreamingModel(LuminaAgentStreamingModelCallback callback, void *context);
    void setTool(LuminaAgentToolCallback callback, void *context);
    void setContext(LuminaAgentContextCallback callback, void *context);
    void setPermission(LuminaAgentPermissionCallback callback, void *context);
    void setConfirmation(LuminaAgentConfirmationCallback callback, void *context);
    void setAudit(LuminaAgentAuditCallback callback, void *context);
    void setRollback(LuminaAgentRollbackCallback callback, void *context);
    void setEvent(LuminaAgentEventCallback callback, void *context);
    void setHook(LuminaAgentHookCallback callback, void *context);

    // Lightweight availability checks used by runtime guards and fallback paths.
    bool hasModel() const;
    bool hasStreamingModel() const;
    bool hasTool() const;
    bool hasContext() const;
    bool hasPermission() const;
    bool hasConfirmation() const;
    bool hasHook() const;

    // Invoke model callbacks and return runtime-owned std::string values.
    std::string callModel(const std::string &plannerInput) const;
    std::string callStreamingModel(const std::string &plannerInput) const;
    StreamingModelResult callStreamingModelWithMetrics(const std::string &plannerInput) const;

    // Invoke platform/application callbacks for tools, context, policy, and hooks.
    std::string callTool(const std::string &toolCall) const;
    std::string loadContext(const std::string &contextRequest) const;
    std::string decidePermission(const std::string &permissionRequest) const;
    std::string confirm(const std::string &confirmationRequest) const;
    std::string dispatchHook(const std::string &hookEvent) const;

    // Emit normalized runtime telemetry to event/audit callbacks.
    void emitEvent(const std::string &type, const std::string &payload = "{}") const;
    void audit(const std::string &type, const std::string &payload = "{}") const;

private:
    CallbackSlot model_;
    CallbackSlot streamingModel_;
    CallbackSlot tool_;
    CallbackSlot context_;
    CallbackSlot permission_;
    CallbackSlot confirmation_;
    CallbackSlot audit_;
    CallbackSlot rollback_;
    CallbackSlot event_;
    CallbackSlot hook_;
};

} // namespace LuminaAgent
