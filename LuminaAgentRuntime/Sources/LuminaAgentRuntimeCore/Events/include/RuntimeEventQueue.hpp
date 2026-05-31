#pragma once

#include <string>
#include <vector>

#include "Callbacks.hpp"

namespace LuminaAgent {

class RuntimeEventQueue {
public:
    RuntimeEventQueue(const RuntimeCallbacks &callbacks, std::string sessionId = "", std::string runId = "");

    void emitEvent(const std::string &type, const std::string &payloadJson = "{}");
    void emitControl(const std::string &type, const std::string &payloadJson = "{}");
    std::string queuedEventsJson() const;
    long long sequence() const;

private:
    const RuntimeCallbacks &callbacks_;
    std::string sessionId_;
    std::string runId_;
    long long sequence_ = 0;
    std::vector<std::string> events_;

    void emit(const std::string &channel, const std::string &type, const std::string &payloadJson);
};

} // namespace LuminaAgent
