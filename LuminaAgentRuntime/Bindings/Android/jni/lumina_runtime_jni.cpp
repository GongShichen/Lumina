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
    if (gJvm->AttachCurrentThread(&env, nullptr) == JNI_OK) {
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

void auditCallback(const char *auditJson, void *context) {
    callVoidMethod(static_cast<NativeRuntime *>(context), "writeAudit", auditJson);
}

void eventCallback(const char *eventJson, void *context) {
    callVoidMethod(static_cast<NativeRuntime *>(context), "emitEvent", eventJson);
}

NativeRuntime *nativeFromHandle(jlong handle) {
    return reinterpret_cast<NativeRuntime *>(handle);
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
    LuminaAgentRuntimeSetToolCallback(native->runtime, toolCallback, native);
    LuminaAgentRuntimeSetContextCallback(native->runtime, contextCallback, native);
    LuminaAgentRuntimeSetPermissionCallback(native->runtime, permissionCallback, native);
    LuminaAgentRuntimeSetConfirmationCallback(native->runtime, confirmationCallback, native);
    LuminaAgentRuntimeSetAuditCallback(native->runtime, auditCallback, native);
    LuminaAgentRuntimeSetEventCallback(native->runtime, eventCallback, native);
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

