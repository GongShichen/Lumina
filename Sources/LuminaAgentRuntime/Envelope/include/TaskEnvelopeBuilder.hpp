#pragma once

#include <string>

#include "Session.hpp"
#include "ToolRegistry.hpp"

namespace LuminaAgent {

class TaskEnvelopeBuilder {
public:
    // Creates a model-facing envelope builder for one session turn.
    TaskEnvelopeBuilder(const ToolRegistry &tools, const RuntimeSession &session);

    // Builds the semantic task envelope consumed by the external model callback.
    std::string build(
        const std::string &requestJson,
        const std::string &contextJson,
        const std::string &lastObservationJson
    ) const;

private:
    const ToolRegistry &tools_;
    const RuntimeSession &session_;

    // Converts raw request JSON into normalized task fields.
    std::string taskJson(const std::string &requestJson) const;

    // Converts multimodal content parts into compact model-readable summaries.
    std::string inputPartsJson(const std::string &contentJson) const;
    std::string inputPartJson(const std::string &partJson, int index) const;
    std::string attachmentsSummaryJson(const std::string &contentJson) const;
    std::string modalitiesJson(const std::string &contentJson) const;

    // Normalizes caller context and session progress for progressive disclosure.
    std::string contextSectionsJson(const std::string &contextJson) const;
    std::string progressJson(const std::string &lastObservationJson) const;

    // Encodes remaining iteration/tool/context budgets in model-friendly terms.
    std::string executionBudgetJson() const;
};

} // namespace LuminaAgent
