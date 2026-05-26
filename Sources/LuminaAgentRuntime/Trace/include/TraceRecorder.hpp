#pragma once

#include <string>
#include <vector>

namespace LuminaAgent {

class TraceRecorder {
public:
    void append(const std::string &phase, const std::string &payloadJson);
    std::string json() const;
    std::string jsonl() const;
    std::string summaryJson(int limit) const;

private:
    std::vector<std::string> events_;
};

} // namespace LuminaAgent
