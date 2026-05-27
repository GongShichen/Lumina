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
    LuminaAgentRuntimeSetToolCallback(native->runtime, toolCallback, native);
    LuminaAgentRuntimeSetContextCallback(native->runtime, contextCallback, native);
    LuminaAgentRuntimeSetPermissionCallback(native->runtime, permissionCallback, native);
    LuminaAgentRuntimeSetConfirmationCallback(native->runtime, confirmationCallback, native);
    LuminaAgentRuntimeSetAuditCallback(native->runtime, auditCallback, native);
    LuminaAgentRuntimeSetEventCallback(native->runtime, eventCallback, native);

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

napi_value run(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2] = {};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    NativeRuntime *native = nativeFromExternal(env, args[0]);
    std::string request = stringFromValue(env, args[1]);
    return stringValueAndRelease(env, LuminaAgentRuntimeRun(native->runtime, request.c_str()));
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

napi_value init(napi_env env, napi_value exports) {
    napi_property_descriptor descriptors[] = {
        {"create", nullptr, create, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"destroy", nullptr, destroy, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"registerToolSchema", nullptr, registerToolSchema, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"run", nullptr, run, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"cancel", nullptr, cancel, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"exportContracts", nullptr, exportContracts, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, sizeof(descriptors) / sizeof(descriptors[0]), descriptors);
    return exports;
}

} // namespace

NAPI_MODULE(NODE_GYP_MODULE_NAME, init)
