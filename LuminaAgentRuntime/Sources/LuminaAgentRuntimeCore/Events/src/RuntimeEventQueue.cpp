#include "RuntimeEventQueue.hpp"

#include <sstream>
#include <utility>

#include "Json.hpp"

namespace LuminaAgent {

RuntimeEventQueue::RuntimeEventQueue(const RuntimeCallbacks &callbacks, std::string sessionId, std::string runId)
    : callbacks_(callbacks),
      sessionId_(std::move(sessionId)),
      runId_(std::move(runId)) {}

void RuntimeEventQueue::emitEvent(const std::string &type, const std::string &payloadJson) {
    emit("event", type, payloadJson);
}

void RuntimeEventQueue::emitControl(const std::string &type, const std::string &payloadJson) {
    emit("control", type, payloadJson);
}

std::string RuntimeEventQueue::queuedEventsJson() const {
    std::ostringstream output;
    output << "[";
    for (size_t index = 0; index < events_.size(); index++) {
        if (index > 0) {
            output << ",";
        }
        output << events_[index];
    }
    output << "]";
    return output.str();
}

long long RuntimeEventQueue::sequence() const {
    return sequence_;
}

void RuntimeEventQueue::emit(const std::string &channel, const std::string &type, const std::string &payloadJson) {
    sequence_ += 1;
    const std::string payload = trim(payloadJson).empty() ? "{}" : payloadJson;
    const std::string event = "{"
        "\"sequence\":" + std::to_string(sequence_) + ","
        "\"session_id\":" + jsonString(sessionId_) + ","
        "\"run_id\":" + jsonString(runId_) + ","
        "\"channel\":" + jsonString(channel) + ","
        "\"type\":" + jsonString(type) + ","
        "\"payload\":" + payload +
        "}";
    events_.push_back(event);
    callbacks_.emitEvent(type, "{\"sequence\":" + std::to_string(sequence_) +
        ",\"session_id\":" + jsonString(sessionId_) +
        ",\"run_id\":" + jsonString(runId_) +
        ",\"channel\":" + jsonString(channel) +
        ",\"payload\":" + payload + "}");
}

} // namespace LuminaAgent
