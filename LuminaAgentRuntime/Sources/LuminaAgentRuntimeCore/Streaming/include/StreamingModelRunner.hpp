#pragma once

#include <string>

#include "Callbacks.hpp"

namespace LuminaAgent {

class StreamingModelRunner {
public:
    // Uses the preferred streaming model callback and records generation metrics.
    explicit StreamingModelRunner(const RuntimeCallbacks &callbacks);

    // Returns a complete canonical runtime step from a trusted host adapter or
    // by normalizing MiniCPM-V4.6 chat-template tool-call output.
    std::string generate(const std::string &plannerInput) const;

private:
    const RuntimeCallbacks &callbacks_;
};

} // namespace LuminaAgent
