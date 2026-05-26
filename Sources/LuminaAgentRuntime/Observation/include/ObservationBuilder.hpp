#pragma once

#include <string>

namespace LuminaAgent {

struct ObservationInput {
    std::string status;
    std::string content;
    std::string errorMessage;
    bool confirmationRequired = false;
    bool confirmed = false;
    int maximumCharacters = 2400;
};

class ObservationBuilder {
public:
    std::string buildSummary(const ObservationInput &input) const;
};

} // namespace LuminaAgent
