#pragma once

#include <string>

#include "Callbacks.hpp"

namespace LuminaAgent {

class StreamingModelRunner {
public:
    // Uses the preferred streaming model callback and records generation metrics.
    explicit StreamingModelRunner(const RuntimeCallbacks &callbacks);

    // Returns the first valid structured ReAct object extracted from model output.
    std::string generate(const std::string &plannerInput) const;

private:
    const RuntimeCallbacks &callbacks_;
};

} // namespace LuminaAgent
