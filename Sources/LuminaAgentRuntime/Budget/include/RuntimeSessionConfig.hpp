#pragma once

namespace LuminaAgent {

struct RuntimeSessionConfig {
    int maximumReActIterations = 12;
    int maximumToolCalls = 8;
    int maximumContextTokens = 12000;
    int maximumObservationCharacters = 2400;
    bool stopOnToolFailure = false;
};

} // namespace LuminaAgent
