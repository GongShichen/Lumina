#include "LuminaAgentRuntime.h"

#include <cstdlib>

#include "Json.hpp"
#include "ReAct.hpp"
#include "Runtime.hpp"
#include "Session.hpp"
#include "Contract.hpp"

struct LuminaAgentRuntimeRef {
    LuminaAgent::Runtime runtime;

    explicit LuminaAgentRuntimeRef(const char *configurationJson)
        : runtime(configurationJson) {}
};

struct LuminaAgentRuntimeSessionRef {
    LuminaAgent::RuntimeSession session;

    explicit LuminaAgentRuntimeSessionRef(LuminaAgent::RuntimeSessionConfig config, const char *requestJson)
        : session(config) {
        session.setRequestJson(requestJson == nullptr ? "{}" : LuminaAgent::trim(requestJson));
    }

    explicit LuminaAgentRuntimeSessionRef(LuminaAgent::RuntimeSessionConfig config)
        : session(config) {}
};

extern "C" LuminaAgentRuntimeRef *LuminaAgentRuntimeCreate(const char *configuration_json) {
    return new LuminaAgentRuntimeRef(configuration_json);
}

extern "C" void LuminaAgentRuntimeDestroy(LuminaAgentRuntimeRef *runtime) {
    delete runtime;
}

extern "C" char *LuminaAgentRuntimeRegisterToolSchema(LuminaAgentRuntimeRef *runtime, const char *tool_schema_json) {
    if (runtime == nullptr) {
        return LuminaAgent::failureResponse("missing runtime.");
    }
    return LuminaAgent::copyCString(runtime->runtime.registerToolSchema(tool_schema_json));
}

extern "C" char *LuminaAgentRuntimeRegisterExternalToolProvider(LuminaAgentRuntimeRef *runtime, const char *provider_json) {
    if (runtime == nullptr) {
        return LuminaAgent::failureResponse("missing runtime.");
    }
    return LuminaAgent::copyCString(runtime->runtime.registerExternalToolProvider(provider_json));
}

extern "C" void LuminaAgentRuntimeSetModelCallback(
    LuminaAgentRuntimeRef *runtime,
    LuminaAgentModelCallback callback,
    void *user_context
) {
    if (runtime != nullptr) {
        runtime->runtime.setModelCallback(callback, user_context);
    }
}

extern "C" void LuminaAgentRuntimeSetStreamingModelCallback(
    LuminaAgentRuntimeRef *runtime,
    LuminaAgentStreamingModelCallback callback,
    void *user_context
) {
    if (runtime != nullptr) {
        runtime->runtime.setStreamingModelCallback(callback, user_context);
    }
}

extern "C" void LuminaAgentRuntimeSetModelMetadataCallback(
    LuminaAgentRuntimeRef *runtime,
    LuminaAgentModelMetadataCallback callback,
    void *user_context
) {
    if (runtime != nullptr) {
        runtime->runtime.setModelMetadataCallback(callback, user_context);
    }
}

extern "C" void LuminaAgentRuntimeSetToolCallback(
    LuminaAgentRuntimeRef *runtime,
    LuminaAgentToolCallback callback,
    void *user_context
) {
    if (runtime != nullptr) {
        runtime->runtime.setToolCallback(callback, user_context);
    }
}

extern "C" void LuminaAgentRuntimeSetContextCallback(
    LuminaAgentRuntimeRef *runtime,
    LuminaAgentContextCallback callback,
    void *user_context
) {
    if (runtime != nullptr) {
        runtime->runtime.setContextCallback(callback, user_context);
    }
}

extern "C" void LuminaAgentRuntimeSetPermissionCallback(
    LuminaAgentRuntimeRef *runtime,
    LuminaAgentPermissionCallback callback,
    void *user_context
) {
    if (runtime != nullptr) {
        runtime->runtime.setPermissionCallback(callback, user_context);
    }
}

extern "C" void LuminaAgentRuntimeSetConfirmationCallback(
    LuminaAgentRuntimeRef *runtime,
    LuminaAgentConfirmationCallback callback,
    void *user_context
) {
    if (runtime != nullptr) {
        runtime->runtime.setConfirmationCallback(callback, user_context);
    }
}

extern "C" void LuminaAgentRuntimeSetGuardrailCallback(
    LuminaAgentRuntimeRef *runtime,
    LuminaAgentGuardrailCallback callback,
    void *user_context
) {
    if (runtime != nullptr) {
        runtime->runtime.setGuardrailCallback(callback, user_context);
    }
}

extern "C" void LuminaAgentRuntimeSetRetryProviderCallback(
    LuminaAgentRuntimeRef *runtime,
    LuminaAgentRetryProviderCallback callback,
    void *user_context
) {
    if (runtime != nullptr) {
        runtime->runtime.setRetryProviderCallback(callback, user_context);
    }
}

extern "C" void LuminaAgentRuntimeSetCompactionProviderCallback(
    LuminaAgentRuntimeRef *runtime,
    LuminaAgentCompactionProviderCallback callback,
    void *user_context
) {
    if (runtime != nullptr) {
        runtime->runtime.setCompactionProviderCallback(callback, user_context);
    }
}

extern "C" void LuminaAgentRuntimeSetAuditCallback(
    LuminaAgentRuntimeRef *runtime,
    LuminaAgentAuditCallback callback,
    void *user_context
) {
    if (runtime != nullptr) {
        runtime->runtime.setAuditCallback(callback, user_context);
    }
}

extern "C" void LuminaAgentRuntimeSetTraceCallback(
    LuminaAgentRuntimeRef *runtime,
    LuminaAgentTraceCallback callback,
    void *user_context
) {
    if (runtime != nullptr) {
        runtime->runtime.setTraceCallback(callback, user_context);
    }
}

extern "C" void LuminaAgentRuntimeSetMetricsCallback(
    LuminaAgentRuntimeRef *runtime,
    LuminaAgentMetricsCallback callback,
    void *user_context
) {
    if (runtime != nullptr) {
        runtime->runtime.setMetricsCallback(callback, user_context);
    }
}

extern "C" void LuminaAgentRuntimeSetSpanCallback(
    LuminaAgentRuntimeRef *runtime,
    LuminaAgentSpanCallback callback,
    void *user_context
) {
    if (runtime != nullptr) {
        runtime->runtime.setSpanCallback(callback, user_context);
    }
}

extern "C" void LuminaAgentRuntimeSetRollbackCallback(
    LuminaAgentRuntimeRef *runtime,
    LuminaAgentRollbackCallback callback,
    void *user_context
) {
    if (runtime != nullptr) {
        runtime->runtime.setRollbackCallback(callback, user_context);
    }
}

extern "C" void LuminaAgentRuntimeSetEventCallback(
    LuminaAgentRuntimeRef *runtime,
    LuminaAgentEventCallback callback,
    void *user_context
) {
    if (runtime != nullptr) {
        runtime->runtime.setEventCallback(callback, user_context);
    }
}

extern "C" void LuminaAgentRuntimeSetHookCallback(
    LuminaAgentRuntimeRef *runtime,
    LuminaAgentHookCallback callback,
    void *user_context
) {
    if (runtime != nullptr) {
        runtime->runtime.setHookCallback(callback, user_context);
    }
}

extern "C" char *LuminaAgentRuntimeRegisterHookRoute(LuminaAgentRuntimeRef *runtime, const char *route_json) {
    if (runtime == nullptr) {
        return LuminaAgent::failureResponse("missing runtime.");
    }
    return LuminaAgent::copyCString(runtime->runtime.registerHookRoute(route_json));
}

extern "C" void LuminaAgentRuntimeClearHookRoutes(LuminaAgentRuntimeRef *runtime) {
    if (runtime != nullptr) {
        runtime->runtime.clearHookRoutes();
    }
}

extern "C" char *LuminaAgentRuntimeRun(LuminaAgentRuntimeRef *runtime, const char *request_json) {
    if (runtime == nullptr) {
        return LuminaAgent::failureResponse("missing runtime.");
    }
    return LuminaAgent::copyCString(runtime->runtime.run(request_json));
}

extern "C" char *LuminaAgentRuntimeRunReplay(
    LuminaAgentRuntimeRef *runtime,
    const char *request_json,
    const char *replay_json
) {
    if (runtime == nullptr) {
        return LuminaAgent::failureResponse("missing runtime.");
    }
    return LuminaAgent::copyCString(runtime->runtime.runReplay(request_json, replay_json));
}

extern "C" char *LuminaAgentRuntimeRunReplayArtifact(
    LuminaAgentRuntimeRef *runtime,
    const char *artifact_json,
    const char *options_json
) {
    if (runtime == nullptr) {
        return LuminaAgent::failureResponse("missing runtime.");
    }
    return LuminaAgent::copyCString(runtime->runtime.runReplayArtifact(artifact_json, options_json));
}

extern "C" LuminaAgentRuntimeSessionRef *LuminaAgentRuntimeCreateSession(
    LuminaAgentRuntimeRef *runtime,
    const char *request_json
) {
    if (runtime == nullptr) {
        return nullptr;
    }
    return new LuminaAgentRuntimeSessionRef(runtime->runtime.sessionConfig(), request_json);
}

extern "C" char *LuminaAgentRuntimeRunSession(
    LuminaAgentRuntimeRef *runtime,
    LuminaAgentRuntimeSessionRef *session
) {
    if (runtime == nullptr || session == nullptr) {
        return LuminaAgent::failureResponse("missing runtime or session.");
    }
    return LuminaAgent::copyCString(runtime->runtime.runSession(session->session, session->session.requestJson().c_str(), true));
}

extern "C" char *LuminaAgentRuntimeRunSessionReplay(
    LuminaAgentRuntimeRef *runtime,
    LuminaAgentRuntimeSessionRef *session,
    const char *replay_json
) {
    if (runtime == nullptr || session == nullptr) {
        return LuminaAgent::failureResponse("missing runtime or session.");
    }
    return LuminaAgent::copyCString(runtime->runtime.runSession(
        session->session,
        session->session.requestJson().c_str(),
        true,
        replay_json
    ));
}

extern "C" char *LuminaAgentRuntimeResumeSession(
    LuminaAgentRuntimeRef *runtime,
    LuminaAgentRuntimeSessionRef *session,
    const char *resume_json
) {
    if (runtime == nullptr || session == nullptr) {
        return LuminaAgent::failureResponse("missing runtime or session.");
    }
    return LuminaAgent::copyCString(runtime->runtime.resumeSession(session->session, resume_json));
}

extern "C" char *LuminaAgentRuntimeCancelSession(
    LuminaAgentRuntimeRef *runtime,
    LuminaAgentRuntimeSessionRef *session
) {
    (void) runtime;
    if (session == nullptr) {
        return LuminaAgent::failureResponse("missing session.");
    }
    session->session.cancel();
    return LuminaAgent::copyCString(session->session.snapshotJson());
}

extern "C" char *LuminaAgentRuntimeSnapshotSession(LuminaAgentRuntimeSessionRef *session) {
    if (session == nullptr) {
        return LuminaAgent::failureResponse("missing session.");
    }
    return LuminaAgent::copyCString(session->session.snapshotJson());
}

extern "C" char *LuminaAgentRuntimeExportSessionCheckpoint(LuminaAgentRuntimeSessionRef *session) {
    if (session == nullptr) {
        return LuminaAgent::failureResponse("missing session.");
    }
    return LuminaAgent::copyCString(session->session.checkpointJson());
}

extern "C" LuminaAgentRuntimeSessionRef *LuminaAgentRuntimeCreateSessionFromCheckpoint(
    LuminaAgentRuntimeRef *runtime,
    const char *checkpoint_json
) {
    if (runtime == nullptr || checkpoint_json == nullptr) {
        return nullptr;
    }
    auto *sessionRef = new LuminaAgentRuntimeSessionRef(runtime->runtime.sessionConfig());
    std::string error;
    if (!sessionRef->session.restoreFromCheckpointJson(LuminaAgent::trim(checkpoint_json), error)) {
        delete sessionRef;
        return nullptr;
    }
    return sessionRef;
}

extern "C" LuminaAgentRuntimeSessionRef *LuminaAgentRuntimeCreateSessionFromReplayArtifact(
    LuminaAgentRuntimeRef *runtime,
    const char *artifact_json,
    const char *fork_options_json
) {
    if (runtime == nullptr || artifact_json == nullptr) {
        return nullptr;
    }
    LuminaAgent::RuntimeSession *session = runtime->runtime.createSessionFromReplayArtifact(artifact_json, fork_options_json);
    if (session == nullptr) {
        return nullptr;
    }
    auto *sessionRef = new LuminaAgentRuntimeSessionRef(runtime->runtime.sessionConfig());
    sessionRef->session = *session;
    delete session;
    return sessionRef;
}

extern "C" char *LuminaAgentRuntimeSessionSetState(
    LuminaAgentRuntimeRef *runtime,
    LuminaAgentRuntimeSessionRef *session,
    const char *scope,
    const char *key,
    const char *value_json
) {
    if (runtime == nullptr || session == nullptr) {
        return LuminaAgent::failureResponse("missing runtime or session.");
    }
    return LuminaAgent::copyCString(runtime->runtime.setSessionState(session->session, scope, key, value_json));
}

extern "C" char *LuminaAgentRuntimeSessionGetState(
    LuminaAgentRuntimeSessionRef *session,
    const char *scope,
    const char *key
) {
    if (session == nullptr) {
        return LuminaAgent::failureResponse("missing session.");
    }
    return LuminaAgent::copyCString(session->session.getStateJson(
        scope == nullptr ? "" : std::string(scope),
        key == nullptr ? "" : std::string(key)
    ));
}

extern "C" char *LuminaAgentRuntimeSessionDeleteState(
    LuminaAgentRuntimeRef *runtime,
    LuminaAgentRuntimeSessionRef *session,
    const char *scope,
    const char *key
) {
    if (runtime == nullptr || session == nullptr) {
        return LuminaAgent::failureResponse("missing runtime or session.");
    }
    return LuminaAgent::copyCString(runtime->runtime.deleteSessionState(session->session, scope, key));
}

extern "C" char *LuminaAgentRuntimeSessionStateSnapshot(LuminaAgentRuntimeSessionRef *session) {
    if (session == nullptr) {
        return LuminaAgent::failureResponse("missing session.");
    }
    return LuminaAgent::copyCString(session->session.stateSnapshotJson());
}

extern "C" void LuminaAgentRuntimeDestroySession(LuminaAgentRuntimeSessionRef *session) {
    delete session;
}

extern "C" char *LuminaAgentRuntimeCancel(LuminaAgentRuntimeRef *runtime, const char *request_id) {
    if (runtime == nullptr) {
        return LuminaAgent::failureResponse("missing runtime.");
    }
    return LuminaAgent::copyCString(runtime->runtime.cancel(request_id));
}

extern "C" void LuminaAgentRuntimeReleaseString(char *value) {
    std::free(value);
}

extern "C" char *LuminaReActValidateStepJSON(const char *json) {
    if (json == nullptr) {
        return LuminaAgent::failureResponse("missing JSON input.");
    }
    const std::string input = LuminaAgent::trim(std::string(json));
    std::string error;
    if (!LuminaAgent::validateReActStepObject(input, false, error)) {
        return LuminaAgent::failureResponse(error);
    }
    return LuminaAgent::successResponse(input);
}

extern "C" char *LuminaReActExtractFirstStandardObject(const char *text) {
    if (text == nullptr) {
        return LuminaAgent::failureResponse("missing text input.");
    }
    const std::string object = LuminaAgent::firstValidReActStepObject(std::string(text));
    if (object.empty()) {
        return LuminaAgent::failureResponse("no standard ReAct JSON object found.");
    }
    return LuminaAgent::successResponse(object);
}

extern "C" char *LuminaReActNormalizeStepText(const char *text, const char *dialect) {
    if (text == nullptr) {
        return LuminaAgent::failureResponse("missing text input.");
    }
    std::string error;
    const std::string normalized = LuminaAgent::normalizeReActStepText(
        std::string(text),
        dialect == nullptr ? "canonical_json" : std::string(dialect),
        error
    );
    if (normalized.empty()) {
        return LuminaAgent::failureResponse(error.empty() ? "could not normalize model output." : error);
    }
    return LuminaAgent::successResponse(normalized);
}

extern "C" void LuminaReActFreeCString(char *value) {
    LuminaAgentRuntimeReleaseString(value);
}

extern "C" char *LuminaAgentRuntimeExportSessionTrace(LuminaAgentRuntimeSessionRef *session, const char *format) {
    if (session == nullptr) {
        return LuminaAgent::failureResponse("missing runtime session.");
    }
    const std::string requested = format == nullptr ? "" : LuminaAgent::lowercased(format);
    return LuminaAgent::copyCString(requested == "jsonl" ? session->session.traceJsonl() : session->session.traceJson());
}

extern "C" char *LuminaAgentRuntimeExportReplayArtifact(
    LuminaAgentRuntimeSessionRef *session,
    const char *options_json
) {
    if (session == nullptr) {
        return LuminaAgent::failureResponse("missing runtime session.");
    }
    return LuminaAgent::copyCString(LuminaAgent::Runtime::exportReplayArtifact(session->session, options_json));
}

extern "C" char *LuminaAgentRuntimeDiffReplayArtifacts(
    const char *expected_json,
    const char *actual_json,
    const char *options_json
) {
    return LuminaAgent::copyCString(LuminaAgent::Runtime::diffReplayArtifacts(expected_json, actual_json, options_json));
}

extern "C" char *LuminaAgentRuntimeExportContracts(void) {
    return LuminaAgent::copyCString(LuminaAgent::allContractsJson());
}
