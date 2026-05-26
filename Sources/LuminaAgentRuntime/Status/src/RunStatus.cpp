#include "RunStatus.hpp"

namespace LuminaAgent {

const char *runStatusName(RunStatus status) {
    switch (status) {
    case RunStatus::running: return "running";
    case RunStatus::succeeded: return "succeeded";
    case RunStatus::partiallySucceeded: return "partiallySucceeded";
    case RunStatus::failed: return "failed";
    case RunStatus::cancelled: return "cancelled";
    }
    return "failed";
}

} // namespace LuminaAgent
