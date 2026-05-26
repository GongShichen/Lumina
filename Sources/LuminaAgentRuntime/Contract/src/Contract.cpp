#include "Contract.hpp"

namespace LuminaAgent {

std::string reactStepSchemaJson() {
    return R"({"schema_version":"1.0","allowed_step_types":["reasoning","tool_use","multi_tool_use","ask_user","final_answer","cannot_complete"],"rules":["Return exactly one JSON object.","Never emit observations; observations are runtime-owned.","final_answer.content must be Markdown.","tool_use.parameters must be a JSON object.","multi_tool_use may only contain read-only tools."]})";
}

std::string taskEnvelopeSchemaJson() {
    return R"({"schema_version":"1.0","fields":["instructions","task","available_tools","context","progress","execution_budget","output_contract"],"task_fields":["user_goal","input_parts","modalities","attachments_summary"],"input_part_types":["text","image","audio","video","file","structuredData"]})";
}

std::string responderSchemaJson() {
    return R"({"schema_version":"1.0","format":"Markdown","rules":["Summarize only runtime-observed facts.","Do not include raw JSON or internal trace dumps.","Cite sources when citations are present."]})";
}

std::string contractJson() {
    return R"({"react":)" + reactStepSchemaJson() + R"(,"responder":)" + responderSchemaJson() + "}";
}

std::string allContractsJson() {
    return R"({"task_envelope_schema":)" + taskEnvelopeSchemaJson() + R"(,"react_step_schema":)" + reactStepSchemaJson() + R"(,"responder_schema":)" + responderSchemaJson() + "}";
}

} // namespace LuminaAgent
