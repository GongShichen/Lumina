#include "PlannerInputBuilder.hpp"

#include <algorithm>
#include <sstream>

#include "TaskEnvelopeBuilder.hpp"
#include "Json.hpp"

namespace LuminaAgent {

PlannerInputBuilder::PlannerInputBuilder(const ToolRegistry &tools, const SkillRegistry &skills, const RuntimeSession &session)
    : tools_(tools), skills_(skills), session_(session) {}

std::string PlannerInputBuilder::build(
    const std::string &request,
    const std::string &context,
    const std::string &lastObservation
) const {
    return TaskEnvelopeBuilder(tools_, skills_, session_).build(request, context, lastObservation);
}

} // namespace LuminaAgent
