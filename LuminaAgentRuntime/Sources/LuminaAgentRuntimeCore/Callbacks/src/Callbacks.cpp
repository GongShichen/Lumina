#include "Callbacks.hpp"

#include <algorithm>
#include <chrono>
#include <sstream>

#include "Json.hpp"

namespace LuminaAgent {

static long long timestampMilliseconds() {
    const auto now = std::chrono::system_clock::now().time_since_epoch();
    return std::chrono::duration_cast<std::chrono::milliseconds>(now).count();
}

void RuntimeCallbacks::setModel(LuminaAgentModelCallback callback, void *context) {
    model_ = {reinterpret_cast<void *>(callback), context};
}

void RuntimeCallbacks::setStreamingModel(LuminaAgentStreamingModelCallback callback, void *context) {
    streamingModel_ = {reinterpret_cast<void *>(callback), context};
}

void RuntimeCallbacks::setTool(LuminaAgentToolCallback callback, void *context) {
    tool_ = {reinterpret_cast<void *>(callback), context};
}

void RuntimeCallbacks::setContext(LuminaAgentContextCallback callback, void *context) {
    context_ = {reinterpret_cast<void *>(callback), context};
}

void RuntimeCallbacks::setPermission(LuminaAgentPermissionCallback callback, void *context) {
    permission_ = {reinterpret_cast<void *>(callback), context};
}

void RuntimeCallbacks::setConfirmation(LuminaAgentConfirmationCallback callback, void *context) {
    confirmation_ = {reinterpret_cast<void *>(callback), context};
}

void RuntimeCallbacks::setAudit(LuminaAgentAuditCallback callback, void *context) {
    audit_ = {reinterpret_cast<void *>(callback), context};
}

void RuntimeCallbacks::setTrace(LuminaAgentTraceCallback callback, void *context) {
    trace_ = {reinterpret_cast<void *>(callback), context};
}

void RuntimeCallbacks::setMetrics(LuminaAgentMetricsCallback callback, void *context) {
    metrics_ = {reinterpret_cast<void *>(callback), context};
}

void RuntimeCallbacks::setSpan(LuminaAgentSpanCallback callback, void *context) {
    span_ = {reinterpret_cast<void *>(callback), context};
}

void RuntimeCallbacks::setRollback(LuminaAgentRollbackCallback callback, void *context) {
    rollback_ = {reinterpret_cast<void *>(callback), context};
}

void RuntimeCallbacks::setEvent(LuminaAgentEventCallback callback, void *context) {
    event_ = {reinterpret_cast<void *>(callback), context};
}

void RuntimeCallbacks::setHook(LuminaAgentHookCallback callback, void *context) {
    hook_ = {reinterpret_cast<void *>(callback), context};
}

bool RuntimeCallbacks::hasModel() const { return model_.function != nullptr; }
bool RuntimeCallbacks::hasStreamingModel() const { return streamingModel_.function != nullptr; }
bool RuntimeCallbacks::hasTool() const { return tool_.function != nullptr; }
bool RuntimeCallbacks::hasContext() const { return context_.function != nullptr; }
bool RuntimeCallbacks::hasPermission() const { return permission_.function != nullptr; }
bool RuntimeCallbacks::hasConfirmation() const { return confirmation_.function != nullptr; }
bool RuntimeCallbacks::hasHook() const { return hook_.function != nullptr; }
bool RuntimeCallbacks::hasTrace() const { return trace_.function != nullptr; }
bool RuntimeCallbacks::hasMetrics() const { return metrics_.function != nullptr; }
bool RuntimeCallbacks::hasSpan() const { return span_.function != nullptr; }

std::string RuntimeCallbacks::callModel(const std::string &plannerInput) const {
    auto callback = reinterpret_cast<LuminaAgentModelCallback>(model_.function);
    return callback == nullptr ? "" : consumeCString(callback(plannerInput.c_str(), model_.context));
}

struct StreamingEmissionState {
    const RuntimeCallbacks *callbacks = nullptr;
    std::chrono::steady_clock::time_point startedAt;
    bool sawFirstToken = false;
    int outputTokenCount = 0;
    long long timeToFirstTokenMilliseconds = -1;
    long long chunkCount = 0;
};

static bool emitStreamingModelChunk(const char *chunkJson, void *context) {
    auto state = static_cast<StreamingEmissionState *>(context);
    if (state != nullptr && state->callbacks != nullptr && chunkJson != nullptr) {
        state->chunkCount += 1;
        std::map<std::string, JsonField> fields;
        if (parseFieldsOrEmpty(chunkJson, fields)) {
            state->outputTokenCount += std::max(0, intField(fields, "tokenCount", intField(fields, "outputTokens", 0)));
        }
        if (!state->sawFirstToken) {
            state->sawFirstToken = true;
            state->timeToFirstTokenMilliseconds = std::chrono::duration_cast<std::chrono::milliseconds>(
                std::chrono::steady_clock::now() - state->startedAt
            ).count();
        }
        state->callbacks->emitEvent("model_generation_delta", chunkJson);
    }
    return true;
}

std::string RuntimeCallbacks::callStreamingModel(const std::string &plannerInput) const {
    return callStreamingModelWithMetrics(plannerInput).text;
}

StreamingModelResult RuntimeCallbacks::callStreamingModelWithMetrics(const std::string &plannerInput) const {
    auto callback = reinterpret_cast<LuminaAgentStreamingModelCallback>(streamingModel_.function);
    if (callback == nullptr) {
        const std::string text = callModel(plannerInput);
        return StreamingModelResult{
            text,
            static_cast<int>(std::max<size_t>(1, text.size() / 4)),
            -1,
            text.empty() ? 0 : 1
        };
    }
    StreamingEmissionState state{
        this,
        std::chrono::steady_clock::now(),
        false,
        0,
        -1,
        0
    };
    const std::string text = consumeCString(callback(
        plannerInput.c_str(),
        emitStreamingModelChunk,
        &state,
        streamingModel_.context
    ));
    return StreamingModelResult{
        text,
        state.outputTokenCount > 0 ? state.outputTokenCount : static_cast<int>(std::max<size_t>(1, text.size() / 4)),
        state.timeToFirstTokenMilliseconds,
        state.chunkCount
    };
}

std::string RuntimeCallbacks::callTool(const std::string &toolCall) const {
    auto callback = reinterpret_cast<LuminaAgentToolCallback>(tool_.function);
    return callback == nullptr ? "" : consumeCString(callback(toolCall.c_str(), tool_.context));
}

std::string RuntimeCallbacks::loadContext(const std::string &contextRequest) const {
    auto callback = reinterpret_cast<LuminaAgentContextCallback>(context_.function);
    return callback == nullptr ? "" : consumeCString(callback(contextRequest.c_str(), context_.context));
}

std::string RuntimeCallbacks::decidePermission(const std::string &permissionRequest) const {
    auto callback = reinterpret_cast<LuminaAgentPermissionCallback>(permission_.function);
    return callback == nullptr ? "" : consumeCString(callback(permissionRequest.c_str(), permission_.context));
}

std::string RuntimeCallbacks::confirm(const std::string &confirmationRequest) const {
    auto callback = reinterpret_cast<LuminaAgentConfirmationCallback>(confirmation_.function);
    return callback == nullptr ? "" : consumeCString(callback(confirmationRequest.c_str(), confirmation_.context));
}

std::string RuntimeCallbacks::dispatchHook(const std::string &hookEvent) const {
    auto callback = reinterpret_cast<LuminaAgentHookCallback>(hook_.function);
    return callback == nullptr ? "" : consumeCString(callback(hookEvent.c_str(), hook_.context));
}

void RuntimeCallbacks::emitEvent(const std::string &type, const std::string &payload) const {
    auto callback = reinterpret_cast<LuminaAgentEventCallback>(event_.function);
    if (callback == nullptr) {
        return;
    }
    const std::string event = "{\"type\":" + jsonString(type) +
        ",\"timestamp\":" + std::to_string(timestampMilliseconds()) +
        ",\"payload\":" + payload + "}";
    callback(event.c_str(), event_.context);
}

void RuntimeCallbacks::audit(const std::string &type, const std::string &payload) const {
    auto callback = reinterpret_cast<LuminaAgentAuditCallback>(audit_.function);
    if (callback == nullptr) {
        return;
    }
    const std::string record = "{\"type\":" + jsonString(type) +
        ",\"timestamp\":" + std::to_string(timestampMilliseconds()) +
        ",\"payload\":" + payload + "}";
    callback(record.c_str(), audit_.context);
}

void RuntimeCallbacks::trace(const std::string &type, const std::string &payload) const {
    auto callback = reinterpret_cast<LuminaAgentTraceCallback>(trace_.function);
    if (callback == nullptr) {
        return;
    }
    const std::string record = "{\"type\":" + jsonString(type) +
        ",\"timestamp\":" + std::to_string(timestampMilliseconds()) +
        ",\"payload\":" + payload + "}";
    callback(record.c_str(), trace_.context);
}

void RuntimeCallbacks::metric(const std::string &name, double value, const std::string &payload) const {
    auto callback = reinterpret_cast<LuminaAgentMetricsCallback>(metrics_.function);
    if (callback == nullptr) {
        return;
    }
    std::ostringstream output;
    output << "{\"name\":" << jsonString(name)
           << ",\"value\":" << value
           << ",\"timestamp\":" << timestampMilliseconds()
           << ",\"payload\":" << (trim(payload).empty() ? "{}" : payload)
           << "}";
    const std::string record = output.str();
    callback(record.c_str(), metrics_.context);
}

void RuntimeCallbacks::span(const std::string &phase, const std::string &name, const std::string &payload) const {
    auto callback = reinterpret_cast<LuminaAgentSpanCallback>(span_.function);
    if (callback == nullptr) {
        return;
    }
    const std::string record = "{\"phase\":" + jsonString(phase) +
        ",\"name\":" + jsonString(name) +
        ",\"timestamp\":" + std::to_string(timestampMilliseconds()) +
        ",\"payload\":" + (trim(payload).empty() ? "{}" : payload) + "}";
    callback(record.c_str(), span_.context);
}

} // namespace LuminaAgent
