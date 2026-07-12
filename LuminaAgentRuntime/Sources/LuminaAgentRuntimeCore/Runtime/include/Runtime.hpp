#pragma once

#include <string>

#include "Callbacks.hpp"
#include "Hooks.hpp"
#include "PlannerInputBuilder.hpp"
#include "Session.hpp"
#include "SkillRegistry.hpp"
#include "ToolExecutor.hpp"
#include "ToolRegistry.hpp"

namespace LuminaAgent {

class Runtime {
public:
    // Builds a platform-neutral runtime from JSON budget/configuration values.
    explicit Runtime(const char *configurationJson);

    // Parses, validates, and caches a caller-provided tool schema.
    std::string registerToolSchema(const char *toolSchemaJson);
    std::string registerDeferredToolMetadata(const char *metadataJson);
    std::string registerExternalToolProvider(const char *providerJson);
    std::string registerSkillMetadata(const char *skillMetadataJson);
    std::string discoverSkills(const char *queryJson) const;
    std::string discoverMCPTools(const char *queryJson) const;

    // Callback setters store function pointers and caller-owned contexts.
    void setModelCallback(LuminaAgentModelCallback callback, void *context);
    void setStreamingModelCallback(LuminaAgentStreamingModelCallback callback, void *context);
    void setModelMetadataCallback(LuminaAgentModelMetadataCallback callback, void *context);
    void setToolCallback(LuminaAgentToolCallback callback, void *context);
    void setContextCallback(LuminaAgentContextCallback callback, void *context);
    void setContextLoadingPluginCallback(LuminaAgentContextLoadingPluginCallback callback, void *context);
    void setPermissionCallback(LuminaAgentPermissionCallback callback, void *context);
    void setConfirmationCallback(LuminaAgentConfirmationCallback callback, void *context);
    void setGuardrailCallback(LuminaAgentGuardrailCallback callback, void *context);
    void setRetryProviderCallback(LuminaAgentRetryProviderCallback callback, void *context);
    void setCompactionProviderCallback(LuminaAgentCompactionProviderCallback callback, void *context);
    void setToolLoadingPluginCallback(LuminaAgentToolLoadingPluginCallback callback, void *context);
    void setAuditCallback(LuminaAgentAuditCallback callback, void *context);
    void setTraceCallback(LuminaAgentTraceCallback callback, void *context);
    void setMetricsCallback(LuminaAgentMetricsCallback callback, void *context);
    void setSpanCallback(LuminaAgentSpanCallback callback, void *context);
    void setSessionHistoryCallback(LuminaAgentSessionHistoryCallback callback, void *context);
    void setRollbackCallback(LuminaAgentRollbackCallback callback, void *context);
    void setEventCallback(LuminaAgentEventCallback callback, void *context);
    void setHookCallback(LuminaAgentHookCallback callback, void *context);
    std::string registerHookRoute(const char *routeJson);
    void clearHookRoutes();

    // Runs a single isolated task from request JSON to runtime result.
    std::string run(const char *requestJson);
    std::string runReplay(const char *requestJson, const char *replayJson);
    std::string runReplayArtifact(const char *artifactJson, const char *optionsJson);
    RuntimeSession *createSessionFromReplayArtifact(const char *artifactJson, const char *forkOptionsJson) const;
    static std::string exportReplayArtifact(const RuntimeSession &session, const char *optionsJson);
    std::string exportSessionCheckpointWithHistory(const RuntimeSession &session) const;
    static std::string diffReplayArtifacts(const char *expectedJson, const char *actualJson, const char *optionsJson);

    // Advances an explicit session until completion, failure, cancellation, or pause.
    std::string runSession(RuntimeSession &session, const char *requestJson, bool allowPause, const char *replayJson = nullptr);
    std::string loadDeferredTools(RuntimeSession &session, const char *namesJson);

    // Adds an external observation to a paused session and continues execution.
    std::string resumeSession(RuntimeSession &session, const char *resumeJson);
    std::string setSessionState(RuntimeSession &session, const char *scope, const char *key, const char *valueJson);
    std::string deleteSessionState(RuntimeSession &session, const char *scope, const char *key);
    std::string setYoloMode(bool enabled);
    bool yoloMode() const;

    // Marks the current runtime execution as cancelled.
    std::string cancel(const char *requestId);

    // Exposes normalized session budgets for explicit session creation.
    RuntimeSessionConfig sessionConfig() const;

private:
    RuntimeSessionConfig sessionConfig_;
    std::string configurationError_;
    bool cancelled_ = false;
    ToolRegistry tools_;
    SkillRegistry skills_;
    RuntimeCallbacks callbacks_;

    std::string discoverAndMaybeLoadTools(RuntimeSession &session, const std::string &stepJson);
    std::string loadDeferredToolsByName(RuntimeSession &session, const std::vector<std::string> &names);
    void registerRuntimeDiscoveryTools();
};

} // namespace LuminaAgent
