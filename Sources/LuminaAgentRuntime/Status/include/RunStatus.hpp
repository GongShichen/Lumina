#pragma once

namespace LuminaAgent {

enum class RunStatus {
    running,
    succeeded,
    partiallySucceeded,
    failed,
    cancelled
};

const char *runStatusName(RunStatus status);

} // namespace LuminaAgent
