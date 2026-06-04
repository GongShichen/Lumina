#include "TaskEnvelopeBuilder.hpp"

#include <algorithm>
#include <map>
#include <set>
#include <sstream>

#include "Contract.hpp"
#include "Json.hpp"

namespace LuminaAgent {

TaskEnvelopeBuilder::TaskEnvelopeBuilder(const ToolRegistry &tools, const RuntimeSession &session)
    : tools_(tools), session_(session) {}

std::string TaskEnvelopeBuilder::build(
    const std::string &requestJson,
    const std::string &contextJson,
    const std::string &lastObservationJson
) const {
    std::map<std::string, JsonField> requestFields;
    parseFieldsOrEmpty(requestJson, requestFields);
    std::ostringstream output;
    const std::string schemaProfile = session_.toolSchemaProfile();
    const bool includeFocusedSchemas = schemaProfile == "full";
    const std::string capabilities = schemaProfile == "name-only"
        ? tools_.nameOnlyListJson(session_.loadedToolNames())
        : tools_.capabilityListJson(session_.loadedToolNames());
    output << "{"
           << "\"schema_version\":\"1.0\","
           << "\"instructions\":{"
           << "\"system\":" << jsonString(stringField(requestFields, "systemInstructions")) << ","
           << "\"output_contract\":" << contractJson()
           << "},"
           << "\"task\":" << taskJson(requestJson) << ","
           << "\"available_tools\":{"
           << "\"mode\":\"progressive_disclosure\","
           << "\"profile\":" << jsonString(schemaProfile) << ","
           << "\"capabilities\":" << capabilities << ","
           << "\"focused_schemas\":" << (includeFocusedSchemas ? tools_.modelFacingSchemasJson(session_.loadedToolNames()) : "[]") << ","
           << "\"deferred_catalog\":" << tools_.deferredCatalogJson(session_.loadedToolNames()) << ","
           << "\"loaded_tool_set\":" << session_.loadedToolSetJson() << ","
           << "\"discovery_hint\":\"Use available capabilities first. Emit tool_discovery to search deferred_catalog or load a full schema before tool_use. Deferred schemas become callable on the next turn.\""
           << "},"
           << "\"context\":{"
           << "\"loaded_sections\":" << contextSectionsJson(contextJson)
           << "},"
           << "\"progress\":" << progressJson(lastObservationJson) << ","
           << "\"execution_budget\":" << executionBudgetJson() << ","
           << "\"runtime_debug\":{"
           << "\"raw_request_available\":false"
           << "}"
           << "}";
    return output.str();
}

std::string TaskEnvelopeBuilder::taskJson(const std::string &requestJson) const {
    std::map<std::string, JsonField> fields;
    parseFieldsOrEmpty(requestJson, fields);
    const std::string content = rawField(fields, "content", "[]");
    std::ostringstream output;
    output << "{"
           << "\"user_goal\":" << jsonString(stringField(fields, "text")) << ","
           << "\"locale\":" << jsonString(stringField(fields, "localeIdentifier")) << ","
           << "\"modalities\":" << modalitiesJson(content) << ","
           << "\"input_parts\":" << inputPartsJson(content) << ","
           << "\"attachments_summary\":" << attachmentsSummaryJson(content)
           << "}";
    return output.str();
}

std::string TaskEnvelopeBuilder::inputPartsJson(const std::string &contentJson) const {
    const std::vector<std::string> parts = extractObjectArrayItems(contentJson);
    std::ostringstream output;
    output << "[";
    for (size_t index = 0; index < parts.size(); index++) {
        if (index > 0) {
            output << ",";
        }
        output << inputPartJson(parts[index], static_cast<int>(index));
    }
    output << "]";
    return output.str();
}

std::string TaskEnvelopeBuilder::inputPartJson(const std::string &partJson, int index) const {
    std::map<std::string, JsonField> fields;
    parseFieldsOrEmpty(partJson, fields);
    const std::string modality = stringField(fields, "modality", "structured_data");
    std::ostringstream output;
    output << "{"
           << "\"index\":" << index << ","
           << "\"type\":" << jsonString(modality);
    if (modality == "text" || modality == "markdown") {
        output << ",\"role\":\"user_request\","
               << "\"content\":" << jsonString(stringField(fields, "text"));
    } else if (fields.find("asset") != fields.end()) {
        std::map<std::string, JsonField> asset;
        parseFieldsOrEmpty(rawField(fields, "asset", "{}"), asset);
        output << ",\"mime_type\":" << jsonString(stringField(asset, "mimeType"))
               << ",\"filename\":" << jsonString(stringField(asset, "filename"))
               << ",\"summary\":" << jsonString(stringField(asset, "summary"))
               << ",\"transcript\":" << jsonString(stringField(asset, "transcript"))
               << ",\"byte_count\":" << rawField(asset, "byteCount", "null")
               << ",\"duration_seconds\":" << rawField(asset, "durationSeconds", "null")
               << ",\"width\":" << rawField(asset, "width", "null")
               << ",\"height\":" << rawField(asset, "height", "null");
    } else {
        output << ",\"summary\":\"structured input\","
               << "\"value\":" << rawField(fields, "value", "null");
    }
    output << "}";
    return output.str();
}

std::string TaskEnvelopeBuilder::attachmentsSummaryJson(const std::string &contentJson) const {
    const std::vector<std::string> parts = extractObjectArrayItems(contentJson);
    std::ostringstream output;
    output << "[";
bool wrote = false;
    int attachmentIndex = 0;
    for (const std::string &part : parts) {
        std::map<std::string, JsonField> fields;
        parseFieldsOrEmpty(part, fields);
        const std::string modality = stringField(fields, "modality");
        if (modality == "text" || modality == "markdown") {
            continue;
        }
        if (wrote) {
            output << ",";
        }
        wrote = true;
        output << inputPartJson(part, attachmentIndex++);
    }
    output << "]";
    return output.str();
}

std::string TaskEnvelopeBuilder::modalitiesJson(const std::string &contentJson) const {
    std::set<std::string> modalities;
    for (const std::string &part : extractObjectArrayItems(contentJson)) {
        std::map<std::string, JsonField> fields;
        parseFieldsOrEmpty(part, fields);
        const std::string modality = stringField(fields, "modality");
        if (!modality.empty()) {
            modalities.insert(modality);
        }
    }
    if (modalities.empty()) {
        modalities.insert("text");
    }
    std::ostringstream output;
    output << "[";
    size_t index = 0;
    for (const std::string &modality : modalities) {
        if (index++ > 0) {
            output << ",";
        }
        output << jsonString(modality);
    }
    output << "]";
    return output.str();
}

std::string TaskEnvelopeBuilder::contextSectionsJson(const std::string &contextJson) const {
    if (trim(contextJson).empty() || trim(contextJson) == "null") {
        return "[]";
    }
    std::map<std::string, JsonField> fields;
    if (parseFieldsOrEmpty(contextJson, fields) && fields.find("sections") != fields.end()) {
        const std::string summary = stringField(fields, "compact_summary");
        const std::string sections = rawField(fields, "sections", "[]");
        if (summary.empty()) {
            return sections;
        }
        std::vector<std::string> items = extractObjectArrayItems(sections);
        std::ostringstream output;
        output << "[{\"id\":\"runtime.context_compaction\",\"title\":\"Compacted context\",\"summary\":"
               << jsonString(summary)
               << ",\"priority\":100,\"disclosure_level\":0}";
        for (const std::string &item : items) {
            output << "," << item;
        }
        output << "]";
        return output.str();
    }
    if (!contextJson.empty() && contextJson.front() == '[') {
        return contextJson;
    }
    return "[" + contextJson + "]";
}

std::string TaskEnvelopeBuilder::progressJson(const std::string &lastObservationJson) const {
    std::ostringstream output;
    output << "{"
           << "\"previous_steps_summary\":" << session_.stepsSummaryJson() << ","
           << "\"last_observation\":" << (trim(lastObservationJson).empty() ? "null" : lastObservationJson)
           << "}";
    return output.str();
}

std::string TaskEnvelopeBuilder::executionBudgetJson() const {
    const int iteration = session_.stepCount();
    const int remainingIterations = std::max(0, session_.maximumReActIterations() - iteration);
    const int remainingToolCalls = std::max(0, session_.maximumToolCalls() - session_.actionCount());
    std::ostringstream output;
    output << "{"
           << "\"iteration\":" << iteration << ","
           << "\"remaining_iterations\":" << remainingIterations << ","
           << "\"remaining_tool_calls\":" << remainingToolCalls << ","
           << "\"context_window_tokens\":" << session_.contextWindowTokens() << ","
           << "\"max_context_tokens\":" << session_.maxContextTokens() << ","
           << "\"effective_context_window\":" << std::max(1, session_.maxContextTokens() - session_.reservedOutputTokens()) << ","
           << "\"remaining_context_tokens_estimate\":" << session_.remainingContextTokensEstimate() << ","
           << "\"max_output_tokens\":" << session_.maxOutputTokens() << ","
           << "\"reserved_output_tokens\":" << session_.reservedOutputTokens() << ","
           << "\"auto_compact_buffer_tokens\":" << session_.autoCompactBufferTokens() << ","
           << "\"warning_buffer_tokens\":" << session_.warningBufferTokens() << ","
           << "\"max_observation_characters\":" << session_.maximumObservationCharacters() << ","
           << "\"tool_result_token_budget\":" << session_.toolResultTokenBudget() << ","
           << "\"compact_threshold_tokens\":" << session_.compactThresholdTokens()
           << "}";
    return output.str();
}

} // namespace LuminaAgent
