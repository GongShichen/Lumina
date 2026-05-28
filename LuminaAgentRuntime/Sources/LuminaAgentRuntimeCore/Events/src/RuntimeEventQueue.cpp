#include "RuntimeEventQueue.hpp"

#include <sstream>

#include "Json.hpp"

namespace LuminaAgent {

RuntimeEventQueue::RuntimeEventQueue(const RuntimeCallbacks &callbacks)
    : callbacks_(callbacks) {}

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
        "\"channel\":" + jsonString(channel) + ","
        "\"type\":" + jsonString(type) + ","
        "\"payload\":" + payload +
        "}";
    events_.push_back(event);
    callbacks_.emitEvent(type, "{\"sequence\":" + std::to_string(sequence_) + ",\"channel\":" + jsonString(channel) + ",\"payload\":" + payload + "}");
}

} // namespace LuminaAgent
