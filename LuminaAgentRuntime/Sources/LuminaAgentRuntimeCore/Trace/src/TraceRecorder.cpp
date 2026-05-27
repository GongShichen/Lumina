#include "TraceRecorder.hpp"

#include <sstream>

#include "Json.hpp"

namespace LuminaAgent {

void TraceRecorder::append(const std::string &phase, const std::string &payloadJson) {
    std::ostringstream output;
    output << "{"
           << "\"phase\":" << jsonString(phase) << ","
           << "\"payload\":" << (trim(payloadJson).empty() ? "{}" : payloadJson)
           << "}";
    events_.push_back(output.str());
}

std::string TraceRecorder::json() const {
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

std::string TraceRecorder::jsonl() const {
    std::ostringstream output;
    for (const std::string &event : events_) {
        output << event << "\n";
    }
    return output.str();
}

std::string TraceRecorder::summaryJson(int limit) const {
    const int safeLimit = limit < 0 ? 0 : limit;
    const size_t start = events_.size() > static_cast<size_t>(safeLimit)
        ? events_.size() - static_cast<size_t>(safeLimit)
        : 0;
    std::ostringstream output;
    output << "[";
    for (size_t index = start; index < events_.size(); index++) {
        if (index > start) {
            output << ",";
        }
        output << events_[index];
    }
    output << "]";
    return output.str();
}

} // namespace LuminaAgent
