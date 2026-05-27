#include "AgentPipeline.hpp"

#include "Json.hpp"
#include "PlannerInputBuilder.hpp"

namespace LuminaAgent {

std::string Distiller::distill(const std::string &requestJson, const std::string &contextJson) const {
    return "{\"request\":" + (trim(requestJson).empty() ? "{}" : requestJson) +
        ",\"context\":" + (trim(contextJson).empty() ? "null" : contextJson) + "}";
}

std::string Executor::plannerInput(
    const ToolRegistry &tools,
    const RuntimeSession &session,
    const std::string &requestJson,
    const std::string &contextJson,
    const std::string &lastObservationJson
) const {
    return PlannerInputBuilder(tools, session).build(requestJson, contextJson, lastObservationJson);
}

std::string Responder::finalize(RuntimeSession &session) const {
    if (session.isPaused()) {
        return session.snapshotJson();
    }
    return session.finishIfNeeded();
}

} // namespace LuminaAgent
