#pragma once

#include <string>
#include <vector>

namespace LuminaAgent {

class TraceRecorder {
public:
    // Appends one normalized event to the in-memory session trace.
    void append(const std::string &phase, const std::string &payloadJson);

    // Exports the full trace as a JSON array string.
    std::string json() const;

    // Exports the full trace as newline-delimited JSON.
    std::string jsonl() const;

    // Exports a compact tail summary suitable for the next model turn.
    std::string summaryJson(int limit) const;

private:
    std::vector<std::string> events_;
};

} // namespace LuminaAgent
