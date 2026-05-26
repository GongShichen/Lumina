#include "ObservationBuilder.hpp"

#include "Json.hpp"

namespace LuminaAgent {

std::string ObservationBuilder::buildSummary(const ObservationInput &input) const {
    std::string summary;
    if (input.confirmationRequired && !input.confirmed) {
        summary = "用户未确认工具调用。";
    } else if (!input.errorMessage.empty()) {
        summary = input.errorMessage;
    } else if (!input.content.empty()) {
        summary = input.content;
    } else if (lowercased(input.status.empty() ? "failed" : input.status) == "succeeded") {
        summary = "工具执行成功。";
    } else {
        summary = "工具执行未完成。";
    }

    if (input.confirmationRequired && input.confirmed) {
        summary = "用户已确认执行该工具。\n" + summary;
    }
    return truncateToCharacters(summary, input.maximumCharacters);
}

} // namespace LuminaAgent
