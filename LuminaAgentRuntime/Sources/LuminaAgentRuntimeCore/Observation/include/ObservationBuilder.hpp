#pragma once

#include <string>

namespace LuminaAgent {

struct ObservationInput {
    // Tool result status normalized by the runtime.
    std::string status;
    // Tool-provided user-readable content.
    std::string content;
    // Tool-provided failure or denial reason.
    std::string errorMessage;
    // Whether a human confirmation gate was required before execution.
    bool confirmationRequired = false;
    // Whether the human confirmation gate approved execution.
    bool confirmed = false;
    // Maximum size of the observation summary returned to the model.
    int maximumCharacters = 2400;
};

class ObservationBuilder {
public:
    // Produces a compact observation summary owned by the runtime.
    std::string buildSummary(const ObservationInput &input) const;
};

} // namespace LuminaAgent
