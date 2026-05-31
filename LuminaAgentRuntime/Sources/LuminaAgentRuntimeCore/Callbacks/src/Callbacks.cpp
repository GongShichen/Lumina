#include "Callbacks.hpp"

#include <algorithm>
#include <chrono>
#include <sstream>
#include <set>

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

void RuntimeCallbacks::setGuardrail(LuminaAgentGuardrailCallback callback, void *context) {
    guardrail_ = {reinterpret_cast<void *>(callback), context};
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
bool RuntimeCallbacks::hasGuardrail() const { return guardrail_.function != nullptr; }
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

static RuntimeGuardrailDecision parseGuardrailDecision(const std::string &decisionJson) {
    RuntimeGuardrailDecision decision;
    const std::string text = trim(decisionJson);
    if (text.empty() || text == "{}" || text == "null") {
        return decision;
    }
    std::map<std::string, JsonField> fields;
    if (!parseFieldsOrEmpty(text, fields)) {
        decision.decision = "reject";
        decision.message = "guardrail returned invalid JSON";
        return decision;
    }
    decision.decision = lowercased(stringField(fields, "decision", stringField(fields, "type", "allow")));
    if (decision.decision == "allowed") {
        decision.decision = "allow";
    } else if (decision.decision == "denied") {
        decision.decision = "reject";
    } else if (decision.decision == "tripwire" || decision.decision == "fail") {
        decision.decision = "tripwire_failure";
    }
    decision.message = stringField(fields, "message", stringField(fields, "reason"));
    decision.payloadJson = rawField(fields, "payload", rawField(fields, "value", ""));
    return decision;
}

RuntimeGuardrailDecision RuntimeCallbacks::evaluateGuardrail(const std::string &stage, const std::string &payloadJson) const {
    auto callback = reinterpret_cast<LuminaAgentGuardrailCallback>(guardrail_.function);
    if (callback == nullptr) {
        return RuntimeGuardrailDecision{};
    }
    const std::string request = "{\"stage\":" + jsonString(stage) +
        ",\"payload\":" + (trim(payloadJson).empty() ? "{}" : payloadJson) + "}";
    return parseGuardrailDecision(consumeCString(callback(request.c_str(), guardrail_.context)));
}

std::string RuntimeCallbacks::dispatchHook(const std::string &hookEvent) const {
    auto callback = reinterpret_cast<LuminaAgentHookCallback>(hook_.function);
    return callback == nullptr ? "" : consumeCString(callback(hookEvent.c_str(), hook_.context));
}

static std::vector<std::string> stringArrayField(const std::map<std::string, JsonField> &fields, const std::string &key) {
    const std::string raw = rawField(fields, key, "");
    std::vector<std::string> values;
    if (raw.empty()) {
        return values;
    }
    size_t index = 0;
    while (index < raw.size()) {
        while (index < raw.size() && raw[index] != '"') {
            index++;
        }
        if (index >= raw.size()) {
            break;
        }
        index++;
        std::string value;
        bool escaped = false;
        while (index < raw.size()) {
            const char c = raw[index++];
            if (escaped) {
                switch (c) {
                case '"':
                case '\\':
                case '/':
                    value += c;
                    break;
                case 'n': value += '\n'; break;
                case 'r': value += '\r'; break;
                case 't': value += '\t'; break;
                default: value += c; break;
                }
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

static bool containsValue(const std::vector<std::string> &values, const std::string &candidate) {
    if (values.empty()) {
        return true;
    }
    const std::string normalized = lowercased(candidate);
    for (const std::string &value : values) {
        if (lowercased(value) == normalized) {
            return true;
        }
    }
    return false;
}

static bool patternMatches(const std::string &pattern, const std::string &value) {
    if (pattern == "*") {
        return true;
    }
    if (!pattern.empty() && pattern.back() == '*') {
        return value.rfind(pattern.substr(0, pattern.size() - 1), 0) == 0;
    }
    return pattern == value;
}

static bool matchesAnyPattern(const std::vector<std::string> &patterns, const std::string &value) {
    if (patterns.empty()) {
        return true;
    }
    for (const std::string &pattern : patterns) {
        if (patternMatches(pattern, value)) {
            return true;
        }
    }
    return false;
}

static std::string nestedStringField(const std::map<std::string, JsonField> &fields, const std::string &objectKey, const std::string &nestedKey) {
    std::map<std::string, JsonField> nestedFields;
    if (!parseFieldsOrEmpty(rawField(fields, objectKey, ""), nestedFields)) {
        return "";
    }
    return stringField(nestedFields, nestedKey, stringField(nestedFields, nestedKey == "tool_name" ? "toolName" : nestedKey));
}

std::vector<std::string> RuntimeCallbacks::matchingHookRouteIds(const std::string &lifecycle, const std::string &payloadJson) const {
    std::vector<std::string> matched;
    if (hookRoutes_.empty()) {
        return matched;
    }
    std::map<std::string, JsonField> fields;
    parseFieldsOrEmpty(payloadJson.empty() ? "{}" : payloadJson, fields);
    const std::string toolName = stringField(fields, "tool_name",
        stringField(fields, "toolName", nestedStringField(fields, "call", "tool_name")));
    const std::string sensitivity = stringField(fields, "sensitivity",
        nestedStringField(fields, "call", "sensitivity"));
    const std::string sideEffect = stringField(fields, "side_effect",
        stringField(fields, "sideEffect", nestedStringField(fields, "call", "side_effect")));

    for (const RuntimeHookRoute &route : hookRoutes_) {
        if (!containsValue(route.events, lifecycle)) {
            continue;
        }
        if (!route.toolNamePatterns.empty() && !matchesAnyPattern(route.toolNamePatterns, toolName)) {
            continue;
        }
        if (!route.sensitivities.empty() && !containsValue(route.sensitivities, sensitivity)) {
            continue;
        }
        if (!route.sideEffects.empty() && !containsValue(route.sideEffects, sideEffect)) {
            continue;
        }
        matched.push_back(route.id);
    }
    return matched;
}

std::string RuntimeCallbacks::registerHookRoute(const std::string &routeJson) {
    std::map<std::string, JsonField> fields;
    if (!parseFieldsOrEmpty(routeJson, fields)) {
        return "{\"ok\":false,\"error\":\"hook route must be a JSON object\"}";
    }
    RuntimeHookRoute route;
    route.id = stringField(fields, "id", stringField(fields, "route_id"));
    if (route.id.empty()) {
        route.id = "route-" + std::to_string(hookRoutes_.size() + 1);
    }
    route.events = stringArrayField(fields, "events");
    route.toolNamePatterns = stringArrayField(fields, "tool_name_patterns");
    if (route.toolNamePatterns.empty()) {
        route.toolNamePatterns = stringArrayField(fields, "toolNamePatterns");
    }
    route.sensitivities = stringArrayField(fields, "sensitivities");
    route.sideEffects = stringArrayField(fields, "side_effects");
    if (route.sideEffects.empty()) {
        route.sideEffects = stringArrayField(fields, "sideEffects");
    }
    hookRoutes_.push_back(route);
    return "{\"ok\":true,\"route_id\":" + jsonString(route.id) + "}";
}

void RuntimeCallbacks::clearHookRoutes() {
    hookRoutes_.clear();
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
