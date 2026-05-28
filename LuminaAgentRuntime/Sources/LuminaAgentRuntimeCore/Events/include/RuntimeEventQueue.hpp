#pragma once

#include <string>
#include <vector>

#include "Callbacks.hpp"

namespace LuminaAgent {

class RuntimeEventQueue {
public:
    explicit RuntimeEventQueue(const RuntimeCallbacks &callbacks);

    void emitEvent(const std::string &type, const std::string &payloadJson = "{}");
    void emitControl(const std::string &type, const std::string &payloadJson = "{}");
    std::string queuedEventsJson() const;
    long long sequence() const;

private:
    const RuntimeCallbacks &callbacks_;
    long long sequence_ = 0;
    std::vector<std::string> events_;

    void emit(const std::string &channel, const std::string &type, const std::string &payloadJson);
};

} // namespace LuminaAgent
