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

std::string runtimeConfigurationSchemaJson() {
    return R"({"schema_version":"1.0","type":"object","fields":{"maximumReActIterations":"integer","maximumToolCalls":"integer","maximumObservationCharacters":"integer","maximumConsecutiveReasoningSteps":"integer","stopOnToolFailure":"boolean","contextWindowCharacterBudget":"integer"}})";
}

std::string agentRequestSchemaJson() {
    return R"({"schema_version":"1.0","type":"object","required":["id","text"],"fields":{"id":"string","text":"string","content":"AgentContentPart[]","metadata":"object","locale":"string","createdAt":"string"}})";
}

std::string agentContentPartSchemaJson() {
    return R"({"schema_version":"1.0","type":"object","required":["type"],"allowed_types":["text","image","audio","video","file","structuredData"],"fields":{"type":"string","text":"string","media":"AgentMediaAsset","data":"object"}})";
}

std::string agentMediaAssetSchemaJson() {
    return R"({"schema_version":"1.0","type":"object","fields":{"id":"string","modality":"string","mimeType":"string","filename":"string","location":"object","metadata":"object"}})";
}

std::string toolSchemaJson() {
    return R"({"schema_version":"1.0","type":"object","required":["name"],"fields":{"name":"string","description":"string","parameters":"ToolParameterSchema","sideEffect":"string","sensitivity":"string","requiresConfirmation":"boolean"}})";
}

std::string toolParameterSchemaJson() {
    return R"({"schema_version":"1.0","type":"object","fields":{"type":"string","description":"string","required":"boolean","properties":"object","items":"object","enum":"array"}})";
}

std::string toolCallSchemaJson() {
    return R"({"schema_version":"1.0","type":"object","required":["tool_name","parameters"],"fields":{"tool_name":"string","parameters":"object","requires_confirmation":"boolean","call_id":"string"}})";
}

std::string toolResultSchemaJson() {
    return R"({"schema_version":"1.0","type":"object","required":["status"],"allowed_status":["succeeded","failed","cancelled"],"fields":{"status":"string","content":"string","errorMessage":"string","output":"object","rollback":"object"}})";
}

std::string permissionRequestSchemaJson() {
    return R"({"schema_version":"1.0","type":"object","fields":{"tool_name":"string","parameters":"object","schema":"ToolSchema","request":"AgentRequest"}})";
}

std::string permissionDecisionSchemaJson() {
    return R"({"schema_version":"1.0","type":"object","required":["decision"],"allowed_decisions":["allowed","denied","requires_confirmation"],"fields":{"decision":"string","reason":"string"}})";
}

std::string confirmationRequestSchemaJson() {
    return R"({"schema_version":"1.0","type":"object","fields":{"tool_name":"string","parameters":"object","reason":"string","schema":"ToolSchema"}})";
}

std::string confirmationDecisionSchemaJson() {
    return R"({"schema_version":"1.0","type":"object","required":["confirmed"],"fields":{"confirmed":"boolean","reason":"string"}})";
}

std::string runtimeContextRequestSchemaJson() {
    return R"({"schema_version":"1.0","type":"object","fields":{"request":"AgentRequest","available_tools":"ToolSchema[]","iteration":"integer","remaining_tool_calls":"integer","maximum_characters":"integer","trace":"Trace"}})";
}

std::string runtimeContextSchemaJson() {
    return R"({"schema_version":"1.0","type":"object","fields":{"sections":"RuntimeContextSection[]"}})";
}

std::string runtimeContextSectionSchemaJson() {
    return R"({"schema_version":"1.0","type":"object","required":["title","content"],"fields":{"id":"string","title":"string","content":"string","priority":"integer","metadata":"object"}})";
}

std::string plannerInputEnvelopeSchemaJson() {
    return taskEnvelopeSchemaJson();
}

std::string reactObservationSchemaJson() {
    return R"({"schema_version":"1.0","type":"object","fields":{"tool_name":"string","status":"string","summary":"string","errorMessage":"string","metadata":"object"}})";
}

std::string runEventSchemaJson() {
    return R"({"schema_version":"1.0","type":"object","required":["type"],"fields":{"type":"string","payload":"object","timestamp":"string"}})";
}

std::string runResultSchemaJson() {
    return R"({"schema_version":"1.0","type":"object","fields":{"ok":"boolean","status":"string","finalMarkdown":"string","terminationReason":"string","trace":"Trace","timing":"object"}})";
}

std::string auditRecordSchemaJson() {
    return R"({"schema_version":"1.0","type":"object","fields":{"requestID":"string","toolName":"string","arguments":"object","permission":"string","confirmed":"boolean","resultStatus":"string","outputSummary":"string","timestamp":"string"}})";
}

std::string traceSchemaJson() {
    return R"({"schema_version":"1.0","type":"object","fields":{"steps":"array","observations":"ReActObservation[]","terminationReason":"string"}})";
}

std::string hookEventSchemaJson() {
    return R"({"schema_version":"1.0","type":"object","fields":{"lifecycle":"string","payload":"object"}})";
}

std::string hookDirectiveSchemaJson() {
    return R"({"schema_version":"1.0","type":"object","fields":{"appendContextSection":"RuntimeContextSection","terminate":"object","annotate":"object","mergeRequestMetadata":"object"}})";
}

std::string contractJson() {
    return R"({"react":)" + reactStepSchemaJson() + R"(,"responder":)" + responderSchemaJson() + "}";
}

std::string allContractsJson() {
    return R"({"schema_version":"1.0",)"
        R"("task_envelope_schema":)" + taskEnvelopeSchemaJson() + ","
        R"("react_step_schema":)" + reactStepSchemaJson() + ","
        R"("responder_schema":)" + responderSchemaJson() + ","
        R"("contracts":{)"
        R"("runtime_configuration":)" + runtimeConfigurationSchemaJson() + ","
        R"("agent_request":)" + agentRequestSchemaJson() + ","
        R"("agent_content_part":)" + agentContentPartSchemaJson() + ","
        R"("agent_media_asset":)" + agentMediaAssetSchemaJson() + ","
        R"("tool_schema":)" + toolSchemaJson() + ","
        R"("tool_parameter_schema":)" + toolParameterSchemaJson() + ","
        R"("tool_call":)" + toolCallSchemaJson() + ","
        R"("tool_result":)" + toolResultSchemaJson() + ","
        R"("permission_request":)" + permissionRequestSchemaJson() + ","
        R"("permission_decision":)" + permissionDecisionSchemaJson() + ","
        R"("confirmation_request":)" + confirmationRequestSchemaJson() + ","
        R"("confirmation_decision":)" + confirmationDecisionSchemaJson() + ","
        R"("runtime_context_request":)" + runtimeContextRequestSchemaJson() + ","
        R"("runtime_context":)" + runtimeContextSchemaJson() + ","
        R"("runtime_context_section":)" + runtimeContextSectionSchemaJson() + ","
        R"("planner_input_envelope":)" + plannerInputEnvelopeSchemaJson() + ","
        R"("react_step":)" + reactStepSchemaJson() + ","
        R"("react_observation":)" + reactObservationSchemaJson() + ","
        R"("run_event":)" + runEventSchemaJson() + ","
        R"("run_result":)" + runResultSchemaJson() + ","
        R"("audit_record":)" + auditRecordSchemaJson() + ","
        R"("trace":)" + traceSchemaJson() + ","
        R"("hook_event":)" + hookEventSchemaJson() + ","
        R"("hook_directive":)" + hookDirectiveSchemaJson() +
        "}}";
}

} // namespace LuminaAgent
