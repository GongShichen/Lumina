#include "LuminaAgentRuntime.h"

#include <jni.h>

#include <cstdlib>
#include <cstring>
#include <string>

namespace {

struct NativeRuntime {
    LuminaAgentRuntimeRef *runtime = nullptr;
    jobject bridge = nullptr;
};

struct NativeSession {
    LuminaAgentRuntimeSessionRef *session = nullptr;
};

JavaVM *gJvm = nullptr;

char *copyCString(const std::string &value) {
    auto *buffer = static_cast<char *>(std::malloc(value.size() + 1));
    if (buffer == nullptr) {
        return nullptr;
    }
    std::memcpy(buffer, value.c_str(), value.size() + 1);
    return buffer;
}

JNIEnv *envForCallback(bool &didAttach) {
    didAttach = false;
    JNIEnv *env = nullptr;
    if (gJvm == nullptr) {
        return nullptr;
    }
    if (gJvm->GetEnv(reinterpret_cast<void **>(&env), JNI_VERSION_1_6) == JNI_OK) {
        return env;
    }
    if (gJvm->AttachCurrentThread(reinterpret_cast<void **>(&env), nullptr) == JNI_OK) {
        didAttach = true;
        return env;
    }
    return nullptr;
}

void detachIfNeeded(bool didAttach) {
    if (didAttach && gJvm != nullptr) {
        gJvm->DetachCurrentThread();
    }
}

std::string callStringMethod(NativeRuntime *native, const char *methodName, const char *json) {
    if (native == nullptr || native->bridge == nullptr) {
        return "{}";
    }
    bool didAttach = false;
    JNIEnv *env = envForCallback(didAttach);
    if (env == nullptr) {
        return "{}";
    }
    jclass cls = env->GetObjectClass(native->bridge);
    jmethodID method = env->GetMethodID(cls, methodName, "(Ljava/lang/String;)Ljava/lang/String;");
    if (method == nullptr) {
        detachIfNeeded(didAttach);
        return "{}";
    }
    jstring input = env->NewStringUTF(json == nullptr ? "" : json);
    auto output = static_cast<jstring>(env->CallObjectMethod(native->bridge, method, input));
    env->DeleteLocalRef(input);
    if (env->ExceptionCheck() || output == nullptr) {
        env->ExceptionClear();
        detachIfNeeded(didAttach);
        return "{}";
    }
    const char *chars = env->GetStringUTFChars(output, nullptr);
    std::string result = chars == nullptr ? "{}" : chars;
    if (chars != nullptr) {
        env->ReleaseStringUTFChars(output, chars);
    }
    env->DeleteLocalRef(output);
    detachIfNeeded(didAttach);
    return result;
}

void callVoidMethod(NativeRuntime *native, const char *methodName, const char *json) {
    if (native == nullptr || native->bridge == nullptr) {
        return;
    }
    bool didAttach = false;
    JNIEnv *env = envForCallback(didAttach);
    if (env == nullptr) {
        return;
    }
    jclass cls = env->GetObjectClass(native->bridge);
    jmethodID method = env->GetMethodID(cls, methodName, "(Ljava/lang/String;)V");
    if (method != nullptr) {
        jstring input = env->NewStringUTF(json == nullptr ? "" : json);
        env->CallVoidMethod(native->bridge, method, input);
        env->DeleteLocalRef(input);
        if (env->ExceptionCheck()) {
            env->ExceptionClear();
        }
    }
    detachIfNeeded(didAttach);
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

void sessionHistoryCallback(const char *historyJson, void *context) {
    callVoidMethod(static_cast<NativeRuntime *>(context), "recordSessionHistory", historyJson);
}

NativeRuntime *nativeFromHandle(jlong handle) {
    return reinterpret_cast<NativeRuntime *>(handle);
}

NativeSession *sessionFromHandle(jlong handle) {
    return reinterpret_cast<NativeSession *>(handle);
}

jstring toJString(JNIEnv *env, char *runtimeString) {
    if (runtimeString == nullptr) {
        return env->NewStringUTF("{}");
    }
    jstring result = env->NewStringUTF(runtimeString);
    LuminaAgentRuntimeReleaseString(runtimeString);
    return result;
}

} // namespace

extern "C" jint JNI_OnLoad(JavaVM *vm, void *) {
    gJvm = vm;
    return JNI_VERSION_1_6;
}

extern "C" JNIEXPORT jlong JNICALL
Java_dev_lumina_agent_runtime_LuminaAgentRuntime_00024Native_create(
    JNIEnv *env,
    jobject,
    jstring configurationJson,
    jobject bridge
) {
    const char *configuration = env->GetStringUTFChars(configurationJson, nullptr);
    auto *native = new NativeRuntime();
    native->runtime = LuminaAgentRuntimeCreate(configuration == nullptr ? "{}" : configuration);
    native->bridge = env->NewGlobalRef(bridge);
    if (configuration != nullptr) {
        env->ReleaseStringUTFChars(configurationJson, configuration);
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
    LuminaAgentRuntimeSetSessionHistoryCallback(native->runtime, sessionHistoryCallback, native);
    LuminaAgentRuntimeSetHookCallback(native->runtime, hookCallback, native);
    return reinterpret_cast<jlong>(native);
}

extern "C" JNIEXPORT void JNICALL
Java_dev_lumina_agent_runtime_LuminaAgentRuntime_00024Native_destroy(JNIEnv *env, jobject, jlong handle) {
    NativeRuntime *native = nativeFromHandle(handle);
    if (native == nullptr) {
        return;
    }
    LuminaAgentRuntimeDestroy(native->runtime);
    if (native->bridge != nullptr) {
        env->DeleteGlobalRef(native->bridge);
    }
    delete native;
}

extern "C" JNIEXPORT jstring JNICALL
Java_dev_lumina_agent_runtime_LuminaAgentRuntime_00024Native_registerToolSchema(
    JNIEnv *env,
    jobject,
    jlong handle,
    jstring toolSchemaJson
) {
    NativeRuntime *native = nativeFromHandle(handle);
    const char *schema = env->GetStringUTFChars(toolSchemaJson, nullptr);
    char *result = LuminaAgentRuntimeRegisterToolSchema(native->runtime, schema == nullptr ? "{}" : schema);
    if (schema != nullptr) {
        env->ReleaseStringUTFChars(toolSchemaJson, schema);
    }
    return toJString(env, result);
}

extern "C" JNIEXPORT jstring JNICALL
Java_dev_lumina_agent_runtime_LuminaAgentRuntime_00024Native_registerExternalToolProvider(
    JNIEnv *env,
    jobject,
    jlong handle,
    jstring providerJson
) {
    NativeRuntime *native = nativeFromHandle(handle);
    const char *provider = env->GetStringUTFChars(providerJson, nullptr);
    char *result = LuminaAgentRuntimeRegisterExternalToolProvider(native->runtime, provider == nullptr ? "{}" : provider);
    if (provider != nullptr) {
        env->ReleaseStringUTFChars(providerJson, provider);
    }
    return toJString(env, result);
}

extern "C" JNIEXPORT jstring JNICALL
Java_dev_lumina_agent_runtime_LuminaAgentRuntime_00024Native_registerHookRoute(
    JNIEnv *env,
    jobject,
    jlong handle,
    jstring routeJson
) {
    NativeRuntime *native = nativeFromHandle(handle);
    const char *route = env->GetStringUTFChars(routeJson, nullptr);
    char *result = LuminaAgentRuntimeRegisterHookRoute(native->runtime, route == nullptr ? "{}" : route);
    if (route != nullptr) {
        env->ReleaseStringUTFChars(routeJson, route);
    }
    return toJString(env, result);
}

extern "C" JNIEXPORT jstring JNICALL
Java_dev_lumina_agent_runtime_LuminaAgentRuntime_00024Native_run(
    JNIEnv *env,
    jobject,
    jlong handle,
    jstring requestJson
) {
    NativeRuntime *native = nativeFromHandle(handle);
    const char *request = env->GetStringUTFChars(requestJson, nullptr);
    char *result = LuminaAgentRuntimeRun(native->runtime, request == nullptr ? "{}" : request);
    if (request != nullptr) {
        env->ReleaseStringUTFChars(requestJson, request);
    }
    return toJString(env, result);
}

extern "C" JNIEXPORT jstring JNICALL
Java_dev_lumina_agent_runtime_LuminaAgentRuntime_00024Native_runReplay(
    JNIEnv *env,
    jobject,
    jlong handle,
    jstring requestJson,
    jstring replayJson
) {
    NativeRuntime *native = nativeFromHandle(handle);
    const char *request = env->GetStringUTFChars(requestJson, nullptr);
    const char *replay = env->GetStringUTFChars(replayJson, nullptr);
    char *result = LuminaAgentRuntimeRunReplay(
        native->runtime,
        request == nullptr ? "{}" : request,
        replay == nullptr ? "{}" : replay
    );
    if (request != nullptr) {
        env->ReleaseStringUTFChars(requestJson, request);
    }
    if (replay != nullptr) {
        env->ReleaseStringUTFChars(replayJson, replay);
    }
    return toJString(env, result);
}

extern "C" JNIEXPORT jstring JNICALL
Java_dev_lumina_agent_runtime_LuminaAgentRuntime_00024Native_runReplayArtifact(
    JNIEnv *env,
    jobject,
    jlong handle,
    jstring artifactJson,
    jstring optionsJson
) {
    NativeRuntime *native = nativeFromHandle(handle);
    const char *artifact = env->GetStringUTFChars(artifactJson, nullptr);
    const char *options = env->GetStringUTFChars(optionsJson, nullptr);
    char *result = LuminaAgentRuntimeRunReplayArtifact(
        native->runtime,
        artifact == nullptr ? "{}" : artifact,
        options == nullptr ? "{}" : options
    );
    if (artifact != nullptr) {
        env->ReleaseStringUTFChars(artifactJson, artifact);
    }
    if (options != nullptr) {
        env->ReleaseStringUTFChars(optionsJson, options);
    }
    return toJString(env, result);
}

extern "C" JNIEXPORT jlong JNICALL
Java_dev_lumina_agent_runtime_LuminaAgentRuntime_00024Native_createSession(
    JNIEnv *env,
    jobject,
    jlong handle,
    jstring requestJson
) {
    NativeRuntime *native = nativeFromHandle(handle);
    const char *request = env->GetStringUTFChars(requestJson, nullptr);
    auto *nativeSession = new NativeSession();
    nativeSession->session = LuminaAgentRuntimeCreateSession(native->runtime, request == nullptr ? "{}" : request);
    if (request != nullptr) {
        env->ReleaseStringUTFChars(requestJson, request);
    }
    return reinterpret_cast<jlong>(nativeSession);
}

extern "C" JNIEXPORT jlong JNICALL
Java_dev_lumina_agent_runtime_LuminaAgentRuntime_00024Native_createSessionFromReplayArtifact(
    JNIEnv *env,
    jobject,
    jlong handle,
    jstring artifactJson,
    jstring forkOptionsJson
) {
    NativeRuntime *native = nativeFromHandle(handle);
    const char *artifact = env->GetStringUTFChars(artifactJson, nullptr);
    const char *options = env->GetStringUTFChars(forkOptionsJson, nullptr);
    auto *nativeSession = new NativeSession();
    nativeSession->session = LuminaAgentRuntimeCreateSessionFromReplayArtifact(
        native->runtime,
        artifact == nullptr ? "{}" : artifact,
        options == nullptr ? "{}" : options
    );
    if (artifact != nullptr) {
        env->ReleaseStringUTFChars(artifactJson, artifact);
    }
    if (options != nullptr) {
        env->ReleaseStringUTFChars(forkOptionsJson, options);
    }
    return reinterpret_cast<jlong>(nativeSession);
}

extern "C" JNIEXPORT jlong JNICALL
Java_dev_lumina_agent_runtime_LuminaAgentRuntime_00024Native_createSessionFromCheckpoint(
    JNIEnv *env,
    jobject,
    jlong handle,
    jstring checkpointJson
) {
    NativeRuntime *native = nativeFromHandle(handle);
    const char *checkpoint = env->GetStringUTFChars(checkpointJson, nullptr);
    auto *nativeSession = new NativeSession();
    nativeSession->session = LuminaAgentRuntimeCreateSessionFromCheckpoint(native->runtime, checkpoint == nullptr ? "{}" : checkpoint);
    if (checkpoint != nullptr) {
        env->ReleaseStringUTFChars(checkpointJson, checkpoint);
    }
    return reinterpret_cast<jlong>(nativeSession);
}

extern "C" JNIEXPORT jstring JNICALL
Java_dev_lumina_agent_runtime_LuminaAgentRuntime_00024Native_runSession(JNIEnv *env, jobject, jlong handle, jlong sessionHandle) {
    NativeRuntime *native = nativeFromHandle(handle);
    NativeSession *session = sessionFromHandle(sessionHandle);
    return toJString(env, LuminaAgentRuntimeRunSession(native->runtime, session->session));
}

extern "C" JNIEXPORT jstring JNICALL
Java_dev_lumina_agent_runtime_LuminaAgentRuntime_00024Native_runSessionReplay(
    JNIEnv *env,
    jobject,
    jlong handle,
    jlong sessionHandle,
    jstring replayJson
) {
    NativeRuntime *native = nativeFromHandle(handle);
    NativeSession *session = sessionFromHandle(sessionHandle);
    const char *replay = env->GetStringUTFChars(replayJson, nullptr);
    char *result = LuminaAgentRuntimeRunSessionReplay(native->runtime, session->session, replay == nullptr ? "{}" : replay);
    if (replay != nullptr) {
        env->ReleaseStringUTFChars(replayJson, replay);
    }
    return toJString(env, result);
}

extern "C" JNIEXPORT jstring JNICALL
Java_dev_lumina_agent_runtime_LuminaAgentRuntime_00024Native_resumeSession(
    JNIEnv *env,
    jobject,
    jlong handle,
    jlong sessionHandle,
    jstring observationJson
) {
    NativeRuntime *native = nativeFromHandle(handle);
    NativeSession *session = sessionFromHandle(sessionHandle);
    const char *observation = env->GetStringUTFChars(observationJson, nullptr);
    char *result = LuminaAgentRuntimeResumeSession(native->runtime, session->session, observation == nullptr ? "{}" : observation);
    if (observation != nullptr) {
        env->ReleaseStringUTFChars(observationJson, observation);
    }
    return toJString(env, result);
}

extern "C" JNIEXPORT jstring JNICALL
Java_dev_lumina_agent_runtime_LuminaAgentRuntime_00024Native_snapshotSession(JNIEnv *env, jobject, jlong sessionHandle) {
    NativeSession *session = sessionFromHandle(sessionHandle);
    return toJString(env, LuminaAgentRuntimeSnapshotSession(session->session));
}

extern "C" JNIEXPORT jstring JNICALL
Java_dev_lumina_agent_runtime_LuminaAgentRuntime_00024Native_exportSessionCheckpoint(
    JNIEnv *env,
    jobject,
    jlong handle,
    jlong sessionHandle
) {
    NativeRuntime *native = nativeFromHandle(handle);
    NativeSession *session = sessionFromHandle(sessionHandle);
    return toJString(env, LuminaAgentRuntimeExportSessionCheckpointWithHistory(native->runtime, session->session));
}

extern "C" JNIEXPORT jstring JNICALL
Java_dev_lumina_agent_runtime_LuminaAgentRuntime_00024Native_exportReplayArtifact(
    JNIEnv *env,
    jobject,
    jlong sessionHandle,
    jstring optionsJson
) {
    NativeSession *session = sessionFromHandle(sessionHandle);
    const char *options = env->GetStringUTFChars(optionsJson, nullptr);
    char *result = LuminaAgentRuntimeExportReplayArtifact(session->session, options == nullptr ? "{}" : options);
    if (options != nullptr) {
        env->ReleaseStringUTFChars(optionsJson, options);
    }
    return toJString(env, result);
}

extern "C" JNIEXPORT jstring JNICALL
Java_dev_lumina_agent_runtime_LuminaAgentRuntime_00024Native_sessionSetState(
    JNIEnv *env,
    jobject,
    jlong handle,
    jlong sessionHandle,
    jstring scopeString,
    jstring keyString,
    jstring valueJson
) {
    NativeRuntime *native = nativeFromHandle(handle);
    NativeSession *session = sessionFromHandle(sessionHandle);
    const char *scope = env->GetStringUTFChars(scopeString, nullptr);
    const char *key = env->GetStringUTFChars(keyString, nullptr);
    const char *value = env->GetStringUTFChars(valueJson, nullptr);
    char *result = LuminaAgentRuntimeSessionSetState(native->runtime, session->session, scope, key, value == nullptr ? "null" : value);
    if (scope != nullptr) env->ReleaseStringUTFChars(scopeString, scope);
    if (key != nullptr) env->ReleaseStringUTFChars(keyString, key);
    if (value != nullptr) env->ReleaseStringUTFChars(valueJson, value);
    return toJString(env, result);
}

extern "C" JNIEXPORT jstring JNICALL
Java_dev_lumina_agent_runtime_LuminaAgentRuntime_00024Native_sessionGetState(
    JNIEnv *env,
    jobject,
    jlong sessionHandle,
    jstring scopeString,
    jstring keyString
) {
    NativeSession *session = sessionFromHandle(sessionHandle);
    const char *scope = env->GetStringUTFChars(scopeString, nullptr);
    const char *key = env->GetStringUTFChars(keyString, nullptr);
    char *result = LuminaAgentRuntimeSessionGetState(session->session, scope, key);
    if (scope != nullptr) env->ReleaseStringUTFChars(scopeString, scope);
    if (key != nullptr) env->ReleaseStringUTFChars(keyString, key);
    return toJString(env, result);
}

extern "C" JNIEXPORT jstring JNICALL
Java_dev_lumina_agent_runtime_LuminaAgentRuntime_00024Native_sessionDeleteState(
    JNIEnv *env,
    jobject,
    jlong handle,
    jlong sessionHandle,
    jstring scopeString,
    jstring keyString
) {
    NativeRuntime *native = nativeFromHandle(handle);
    NativeSession *session = sessionFromHandle(sessionHandle);
    const char *scope = env->GetStringUTFChars(scopeString, nullptr);
    const char *key = env->GetStringUTFChars(keyString, nullptr);
    char *result = LuminaAgentRuntimeSessionDeleteState(native->runtime, session->session, scope, key);
    if (scope != nullptr) env->ReleaseStringUTFChars(scopeString, scope);
    if (key != nullptr) env->ReleaseStringUTFChars(keyString, key);
    return toJString(env, result);
}

extern "C" JNIEXPORT void JNICALL
Java_dev_lumina_agent_runtime_LuminaAgentRuntime_00024Native_destroySession(JNIEnv *, jobject, jlong sessionHandle) {
    NativeSession *session = sessionFromHandle(sessionHandle);
    if (session != nullptr) {
        LuminaAgentRuntimeDestroySession(session->session);
        delete session;
    }
}

extern "C" JNIEXPORT jstring JNICALL
Java_dev_lumina_agent_runtime_LuminaAgentRuntime_00024Native_cancel(
    JNIEnv *env,
    jobject,
    jlong handle,
    jstring requestId
) {
    NativeRuntime *native = nativeFromHandle(handle);
    const char *id = requestId == nullptr ? nullptr : env->GetStringUTFChars(requestId, nullptr);
    char *result = LuminaAgentRuntimeCancel(native->runtime, id);
    if (id != nullptr) {
        env->ReleaseStringUTFChars(requestId, id);
    }
    return toJString(env, result);
}

extern "C" JNIEXPORT jstring JNICALL
Java_dev_lumina_agent_runtime_LuminaAgentRuntime_00024Native_exportContracts(JNIEnv *env, jobject) {
    return toJString(env, LuminaAgentRuntimeExportContracts());
}

extern "C" JNIEXPORT jstring JNICALL
Java_dev_lumina_agent_runtime_LuminaAgentRuntime_00024Native_diffReplayArtifacts(
    JNIEnv *env,
    jobject,
    jstring expectedJson,
    jstring actualJson,
    jstring optionsJson
) {
    const char *expected = env->GetStringUTFChars(expectedJson, nullptr);
    const char *actual = env->GetStringUTFChars(actualJson, nullptr);
    const char *options = env->GetStringUTFChars(optionsJson, nullptr);
    char *result = LuminaAgentRuntimeDiffReplayArtifacts(
        expected == nullptr ? "{}" : expected,
        actual == nullptr ? "{}" : actual,
        options == nullptr ? "{}" : options
    );
    if (expected != nullptr) {
        env->ReleaseStringUTFChars(expectedJson, expected);
    }
    if (actual != nullptr) {
        env->ReleaseStringUTFChars(actualJson, actual);
    }
    if (options != nullptr) {
        env->ReleaseStringUTFChars(optionsJson, options);
    }
    return toJString(env, result);
}
