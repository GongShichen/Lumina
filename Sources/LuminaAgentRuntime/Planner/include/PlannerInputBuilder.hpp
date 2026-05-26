#pragma once

#include <string>

#include "Session.hpp"
#include "ToolRegistry.hpp"

namespace LuminaAgent {

class PlannerInputBuilder {
public:
    PlannerInputBuilder(const ToolRegistry &tools, const RuntimeSession &session);

    std::string build(
        const std::string &request,
        const std::string &context,
        const std::string &lastObservation
    ) const;

private:
    const ToolRegistry &tools_;
    const RuntimeSession &session_;
};

} // namespace LuminaAgent
