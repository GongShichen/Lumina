#include "LuminaAgentRuntime.h"

#include <napi/native_api.h>

#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

namespace {

struct NativeRuntime {
    napi_env env = nullptr;
    napi_ref bridge = nullptr;
    LuminaAgentRuntimeRef *runtime = nullptr;
};

struct NativeSession {
    LuminaAgentRuntimeSessionRef *session = nullptr;
};

char *copyCString(const std::string &value) {
    auto *buffer = static_cast<char *>(std::malloc(value.size() + 1));
    if (buffer == nullptr) {
        return nullptr;
    }
    std::memcpy(buffer, value.c_str(), value.size() + 1);
    return buffer;
}

std::string stringFromValue(napi_env env, napi_value value) {
    size_t length = 0;
    napi_get_value_string_utf8(env, value, nullptr, 0, &length);
    std::vector<char> buffer(length + 1, '\0');
    napi_get_value_string_utf8(env, value, buffer.data(), buffer.size(), &length);
    return std::string(buffer.data(), length);
}

napi_value stringValue(napi_env env, const std::string &value) {
    napi_value output = nullptr;
    napi_create_string_utf8(env, value.c_str(), value.size(), &output);
    return output;
}

napi_value stringValueAndRelease(napi_env env, char *runtimeString) {
    if (runtimeString == nullptr) {
        return stringValue(env, "{}");
    }
    napi_value output = stringValue(env, runtimeString);
    LuminaAgentRuntimeReleaseString(runtimeString);
    return output;
}

NativeRuntime *nativeFromExternal(napi_env env, napi_value value) {
    void *data = nullptr;
    napi_get_value_external(env, value, &data);
    return static_cast<NativeRuntime *>(data);
}

NativeSession *sessionFromExternal(napi_env env, napi_value value) {
    void *data = nullptr;
    napi_get_value_external(env, value, &data);
    return static_cast<NativeSession *>(data);
}

std::string callStringMethod(NativeRuntime *native, const char *methodName, const char *json) {
    if (native == nullptr || native->bridge == nullptr) {
        return "{}";
    }
    napi_value bridge = nullptr;
    napi_get_reference_value(native->env, native->bridge, &bridge);
    napi_value method = nullptr;
    napi_get_named_property(native->env, bridge, methodName, &method);
    napi_value input = stringValue(native->env, json == nullptr ? "" : json);
    napi_value output = nullptr;
    napi_call_function(native->env, bridge, method, 1, &input, &output);
    return output == nullptr ? "{}" : stringFromValue(native->env, output);
}

void callVoidMethod(NativeRuntime *native, const char *methodName, const char *json) {
    if (native == nullptr || native->bridge == nullptr) {
        return;
    }
    napi_value bridge = nullptr;
    napi_get_reference_value(native->env, native->bridge, &bridge);
    napi_value method = nullptr;
    napi_get_named_property(native->env, bridge, methodName, &method);
    napi_value input = stringValue(native->env, json == nullptr ? "" : json);
    napi_value output = nullptr;
    napi_call_function(native->env, bridge, method, 1, &input, &output);
}

char *modelCallback(const char *plannerInputJson, void *context) {
    return copyCString(callStringMethod(static_cast<NativeRuntime *>(context), "provideModelStep", plannerInputJson));
}

char *modelMetadataCallback(const char *metadataRequestJson, void *context) {
    return copyCString(callStringMethod(static_cast<NativeRuntime *>(context), "provideModelMetadata", metadataRequestJson));
}

char *toolCallback(const char *toolCallJson, void *context) {
    return copyCString(callStringMethod(static_cast<NativeRuntime *>(context), "executeTool", toolCallJson));
}

char *contextCallback(const char *contextRequestJson, void *context) {
    return copyCString(callStringMethod(static_cast<NativeRuntime *>(context), "loadContext", contextRequestJson));
}

char *permissionCallback(const char *permissionRequestJson, void *context) {
    return copyCString(callStringMethod(static_cast<NativeRuntime *>(context), "decidePermission", permissionRequestJson));
}

char *confirmationCallback(const char *confirmationRequestJson, void *context) {
    return copyCString(callStringMethod(static_cast<NativeRuntime *>(context), "confirm", confirmationRequestJson));
}

char *guardrailCallback(const char *guardrailRequestJson, void *context) {
    return copyCString(callStringMethod(static_cast<NativeRuntime *>(context), "evaluateGuardrail", guardrailRequestJson));
}

char *compactionCallback(const char *compactionRequestJson, void *context) {
    return copyCString(callStringMethod(static_cast<NativeRuntime *>(context), "compactContext", compactionRequestJson));
}

char *hookCallback(const char *hookEventJson, void *context) {
    return copyCString(callStringMethod(static_cast<NativeRuntime *>(context), "dispatchHook", hookEventJson));
}

void auditCallback(const char *auditJson, void *context) {
    callVoidMethod(static_cast<NativeRuntime *>(context), "writeAudit", auditJson);
}

void eventCallback(const char *eventJson, void *context) {
    callVoidMethod(static_cast<NativeRuntime *>(context), "emitEvent", eventJson);
}

void traceCallback(const char *traceJson, void *context) {
    callVoidMethod(static_cast<NativeRuntime *>(context), "writeTrace", traceJson);
}

void metricsCallback(const char *metricJson, void *context) {
    callVoidMethod(static_cast<NativeRuntime *>(context), "writeMetric", metricJson);
}

void spanCallback(const char *spanJson, void *context) {
    callVoidMethod(static_cast<NativeRuntime *>(context), "writeSpan", spanJson);
}

napi_value create(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2] = {};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    std::string configuration = argc > 0 ? stringFromValue(env, args[0]) : "{}";

    auto *native = new NativeRuntime();
    native->env = env;
    native->runtime = LuminaAgentRuntimeCreate(configuration.c_str());
    if (argc > 1) {
        napi_create_reference(env, args[1], 1, &native->bridge);
    }

    LuminaAgentRuntimeSetModelCallback(native->runtime, modelCallback, native);
    LuminaAgentRuntimeSetModelMetadataCallback(native->runtime, modelMetadataCallback, native);
    LuminaAgentRuntimeSetToolCallback(native->runtime, toolCallback, native);
    LuminaAgentRuntimeSetContextCallback(native->runtime, contextCallback, native);
    LuminaAgentRuntimeSetPermissionCallback(native->runtime, permissionCallback, native);
    LuminaAgentRuntimeSetConfirmationCallback(native->runtime, confirmationCallback, native);
    LuminaAgentRuntimeSetGuardrailCallback(native->runtime, guardrailCallback, native);
    LuminaAgentRuntimeSetCompactionProviderCallback(native->runtime, compactionCallback, native);
    LuminaAgentRuntimeSetAuditCallback(native->runtime, auditCallback, native);
    LuminaAgentRuntimeSetEventCallback(native->runtime, eventCallback, native);
    LuminaAgentRuntimeSetTraceCallback(native->runtime, traceCallback, native);
    LuminaAgentRuntimeSetMetricsCallback(native->runtime, metricsCallback, native);
    LuminaAgentRuntimeSetSpanCallback(native->runtime, spanCallback, native);
    LuminaAgentRuntimeSetHookCallback(native->runtime, hookCallback, native);

    napi_value external = nullptr;
    napi_create_external(env, native, nullptr, nullptr, &external);
    return external;
}

napi_value destroy(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    NativeRuntime *native = nativeFromExternal(env, args[0]);
    if (native != nullptr) {
        LuminaAgentRuntimeDestroy(native->runtime);
        if (native->bridge != nullptr) {
            napi_delete_reference(env, native->bridge);
        }
        delete native;
    }
    return nullptr;
}

napi_value registerToolSchema(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2] = {};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    NativeRuntime *native = nativeFromExternal(env, args[0]);
    std::string schema = stringFromValue(env, args[1]);
    return stringValueAndRelease(env, LuminaAgentRuntimeRegisterToolSchema(native->runtime, schema.c_str()));
}

napi_value registerExternalToolProvider(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2] = {};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    NativeRuntime *native = nativeFromExternal(env, args[0]);
    std::string provider = stringFromValue(env, args[1]);
    return stringValueAndRelease(env, LuminaAgentRuntimeRegisterExternalToolProvider(native->runtime, provider.c_str()));
}

napi_value registerHookRoute(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2] = {};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    NativeRuntime *native = nativeFromExternal(env, args[0]);
    std::string route = stringFromValue(env, args[1]);
    return stringValueAndRelease(env, LuminaAgentRuntimeRegisterHookRoute(native->runtime, route.c_str()));
}

napi_value run(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2] = {};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    NativeRuntime *native = nativeFromExternal(env, args[0]);
    std::string request = stringFromValue(env, args[1]);
    return stringValueAndRelease(env, LuminaAgentRuntimeRun(native->runtime, request.c_str()));
}

napi_value runReplay(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3] = {};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    NativeRuntime *native = nativeFromExternal(env, args[0]);
    std::string request = stringFromValue(env, args[1]);
    std::string replay = stringFromValue(env, args[2]);
    return stringValueAndRelease(env, LuminaAgentRuntimeRunReplay(native->runtime, request.c_str(), replay.c_str()));
}

napi_value runReplayArtifact(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3] = {};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    NativeRuntime *native = nativeFromExternal(env, args[0]);
    std::string artifact = stringFromValue(env, args[1]);
    std::string options = stringFromValue(env, args[2]);
    return stringValueAndRelease(env, LuminaAgentRuntimeRunReplayArtifact(native->runtime, artifact.c_str(), options.c_str()));
}

napi_value createSession(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2] = {};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    NativeRuntime *native = nativeFromExternal(env, args[0]);
    std::string request = stringFromValue(env, args[1]);
    auto *session = new NativeSession();
    session->session = LuminaAgentRuntimeCreateSession(native->runtime, request.c_str());
    napi_value external = nullptr;
    napi_create_external(env, session, nullptr, nullptr, &external);
    return external;
}

napi_value createSessionFromCheckpoint(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2] = {};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    NativeRuntime *native = nativeFromExternal(env, args[0]);
    std::string checkpoint = stringFromValue(env, args[1]);
    auto *session = new NativeSession();
    session->session = LuminaAgentRuntimeCreateSessionFromCheckpoint(native->runtime, checkpoint.c_str());
    napi_value external = nullptr;
    napi_create_external(env, session, nullptr, nullptr, &external);
    return external;
}

napi_value createSessionFromReplayArtifact(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3] = {};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    NativeRuntime *native = nativeFromExternal(env, args[0]);
    std::string artifact = stringFromValue(env, args[1]);
    std::string options = stringFromValue(env, args[2]);
    auto *session = new NativeSession();
    session->session = LuminaAgentRuntimeCreateSessionFromReplayArtifact(native->runtime, artifact.c_str(), options.c_str());
    napi_value external = nullptr;
    napi_create_external(env, session, nullptr, nullptr, &external);
    return external;
}

napi_value runSession(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2] = {};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    NativeRuntime *native = nativeFromExternal(env, args[0]);
    NativeSession *session = sessionFromExternal(env, args[1]);
    return stringValueAndRelease(env, LuminaAgentRuntimeRunSession(native->runtime, session->session));
}

napi_value runSessionReplay(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3] = {};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    NativeRuntime *native = nativeFromExternal(env, args[0]);
    NativeSession *session = sessionFromExternal(env, args[1]);
    std::string replay = stringFromValue(env, args[2]);
    return stringValueAndRelease(env, LuminaAgentRuntimeRunSessionReplay(native->runtime, session->session, replay.c_str()));
}

napi_value resumeSession(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3] = {};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    NativeRuntime *native = nativeFromExternal(env, args[0]);
    NativeSession *session = sessionFromExternal(env, args[1]);
    std::string observation = stringFromValue(env, args[2]);
    return stringValueAndRelease(env, LuminaAgentRuntimeResumeSession(native->runtime, session->session, observation.c_str()));
}

napi_value snapshotSession(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    NativeSession *session = sessionFromExternal(env, args[0]);
    return stringValueAndRelease(env, LuminaAgentRuntimeSnapshotSession(session->session));
}

napi_value exportSessionCheckpoint(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    NativeSession *session = sessionFromExternal(env, args[0]);
    return stringValueAndRelease(env, LuminaAgentRuntimeExportSessionCheckpoint(session->session));
}

napi_value exportReplayArtifact(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2] = {};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    NativeSession *session = sessionFromExternal(env, args[0]);
    std::string options = stringFromValue(env, args[1]);
    return stringValueAndRelease(env, LuminaAgentRuntimeExportReplayArtifact(session->session, options.c_str()));
}

napi_value sessionSetState(napi_env env, napi_callback_info info) {
    size_t argc = 5;
    napi_value args[5] = {};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    NativeRuntime *native = nativeFromExternal(env, args[0]);
    NativeSession *session = sessionFromExternal(env, args[1]);
    std::string scope = stringFromValue(env, args[2]);
    std::string key = stringFromValue(env, args[3]);
    std::string value = stringFromValue(env, args[4]);
    return stringValueAndRelease(env, LuminaAgentRuntimeSessionSetState(native->runtime, session->session, scope.c_str(), key.c_str(), value.c_str()));
}

napi_value sessionGetState(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3] = {};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    NativeSession *session = sessionFromExternal(env, args[0]);
    std::string scope = stringFromValue(env, args[1]);
    std::string key = stringFromValue(env, args[2]);
    return stringValueAndRelease(env, LuminaAgentRuntimeSessionGetState(session->session, scope.c_str(), key.c_str()));
}

napi_value sessionDeleteState(napi_env env, napi_callback_info info) {
    size_t argc = 4;
    napi_value args[4] = {};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    NativeRuntime *native = nativeFromExternal(env, args[0]);
    NativeSession *session = sessionFromExternal(env, args[1]);
    std::string scope = stringFromValue(env, args[2]);
    std::string key = stringFromValue(env, args[3]);
    return stringValueAndRelease(env, LuminaAgentRuntimeSessionDeleteState(native->runtime, session->session, scope.c_str(), key.c_str()));
}

napi_value destroySession(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    NativeSession *session = sessionFromExternal(env, args[0]);
    if (session != nullptr) {
        LuminaAgentRuntimeDestroySession(session->session);
        delete session;
    }
    return nullptr;
}

napi_value cancel(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2] = {};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    NativeRuntime *native = nativeFromExternal(env, args[0]);
    std::string requestId = argc > 1 ? stringFromValue(env, args[1]) : "";
    return stringValueAndRelease(env, LuminaAgentRuntimeCancel(native->runtime, requestId.empty() ? nullptr : requestId.c_str()));
}

napi_value exportContracts(napi_env env, napi_callback_info) {
    return stringValueAndRelease(env, LuminaAgentRuntimeExportContracts());
}

napi_value diffReplayArtifacts(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3] = {};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    std::string expected = stringFromValue(env, args[0]);
    std::string actual = stringFromValue(env, args[1]);
    std::string options = stringFromValue(env, args[2]);
    return stringValueAndRelease(env, LuminaAgentRuntimeDiffReplayArtifacts(expected.c_str(), actual.c_str(), options.c_str()));
}

napi_value init(napi_env env, napi_value exports) {
    napi_property_descriptor descriptors[] = {
        {"create", nullptr, create, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"destroy", nullptr, destroy, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"registerToolSchema", nullptr, registerToolSchema, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"registerExternalToolProvider", nullptr, registerExternalToolProvider, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"registerHookRoute", nullptr, registerHookRoute, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"run", nullptr, run, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"runReplay", nullptr, runReplay, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"runReplayArtifact", nullptr, runReplayArtifact, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"createSession", nullptr, createSession, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"createSessionFromCheckpoint", nullptr, createSessionFromCheckpoint, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"createSessionFromReplayArtifact", nullptr, createSessionFromReplayArtifact, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"runSession", nullptr, runSession, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"runSessionReplay", nullptr, runSessionReplay, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"resumeSession", nullptr, resumeSession, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"snapshotSession", nullptr, snapshotSession, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"exportSessionCheckpoint", nullptr, exportSessionCheckpoint, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"exportReplayArtifact", nullptr, exportReplayArtifact, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"sessionSetState", nullptr, sessionSetState, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"sessionGetState", nullptr, sessionGetState, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"sessionDeleteState", nullptr, sessionDeleteState, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"destroySession", nullptr, destroySession, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"cancel", nullptr, cancel, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"exportContracts", nullptr, exportContracts, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"diffReplayArtifacts", nullptr, diffReplayArtifacts, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, sizeof(descriptors) / sizeof(descriptors[0]), descriptors);
    return exports;
}

} // namespace

NAPI_MODULE(lumina_agent_runtime_harmony, init)
