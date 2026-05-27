#pragma once

namespace LuminaAgent {

enum class RunStatus {
    running,
    succeeded,
    partiallySucceeded,
    failed,
    cancelled
};

// Converts a runtime status enum into the stable JSON wire value.
const char *runStatusName(RunStatus status);

} // namespace LuminaAgent
