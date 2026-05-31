#include "Contract.hpp"

namespace LuminaAgent {

std::string reactStepSchemaJson() {
    return R"({"schema_version":"1.0","allowed_step_types":["reasoning","tool_discovery","tool_use","multi_tool_use","ask_user","result","cannot_complete"],"rules":["Return exactly one JSON object.","Never emit observations; observations are runtime-owned.","result.content must be Markdown.","tool_use.parameters must be a JSON object.","multi_tool_use may only contain read-only tools.","tool_discovery only returns schema metadata."]})";
}

std::string taskEnvelopeSchemaJson() {
    return R"({"schema_version":"1.0","fields":["instructions","task","available_tools","context","progress","execution_budget","output_contract"],"task_fields":["user_goal","input_parts","modalities","attachments_summary"],"input_part_types":["text","image","audio","video","file","structuredData"]})";
}

std::string responderSchemaJson() {
    return R"({"schema_version":"1.0","format":"Markdown","rules":["Summarize only runtime-observed facts.","Do not include raw JSON or internal trace dumps.","Cite sources when citations are present."]})";
}

std::string runtimeConfigurationSchemaJson() {
    return R"({"schema_version":"1.0","type":"object","required":["maxIterations","maxToolCalls","contextWindowTokens","maxOutputTokens","reservedOutputTokens","maxObservationCharacters","toolResultTokenBudget","compactThresholdTokens","maxCompactFailures","maxReasoningSteps","maxReplayObservations"],"fields":{"maxIterations":"integer","maxToolCalls":"integer","contextWindowTokens":"integer","maxOutputTokens":"integer","reservedOutputTokens":"integer","maxObservationCharacters":"integer","toolResultTokenBudget":"integer","compactThresholdTokens":"integer","maxCompactFailures":"integer","maxReasoningSteps":"integer","maxReplayObservations":"integer","stopOnToolFailure":"boolean","toolSchemaProfile":"full|compact|name-only"}})";
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
    return R"({"schema_version":"1.0","type":"object","required":["name"],"fields":{"name":"string","description":"string","aliases":"string[]","category":"string","searchHint":"string","parameters":"ToolParameterSchema","sideEffect":"string","readOnly":"boolean","destructive":"boolean","concurrencySafe":"boolean","requiresUserInteraction":"boolean","interruptBehavior":"string","idempotencyPolicy":"replay_identical|always_execute|caller_keyed","maxResultSize":"integer","strict":"boolean","inputSchema":"object","outputSchema":"object","displaySummary":"string","sensitivity":"string","requiresConfirmation":"boolean"}})";
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
    return R"({"schema_version":"1.0","type":"object","required":["type","sequence","timestamp","session_id","run_id"],"fields":{"type":"string","sequence":"integer","timestamp":"integer","session_id":"string","run_id":"string","payload":"object"}})";
}

std::string runResultSchemaJson() {
    return R"({"schema_version":"1.0","type":"object","fields":{"ok":"boolean","status":"string","resultMarkdown":"string","terminationReason":"string","trace":"Trace","timing":"object"}})";
}

std::string auditRecordSchemaJson() {
    return R"({"schema_version":"1.0","type":"object","fields":{"requestID":"string","toolName":"string","arguments":"object","permission":"string","confirmed":"boolean","resultStatus":"string","outputSummary":"string","timestamp":"string"}})";
}

std::string traceSchemaJson() {
    return R"({"schema_version":"1.0","type":"object","fields":{"steps":"array","observations":"ReActObservation[]","terminationReason":"string"}})";
}

std::string hookEventSchemaJson() {
    return R"({"schema_version":"1.0","type":"object","fields":{"route_id":"string","lifecycle":"string","payload":"object"}})";
}

std::string hookDirectiveSchemaJson() {
    return R"({"schema_version":"1.0","type":"object","allowed_types":["proceed","append_context","rewrite_tool_call","reject_tool_call","require_confirmation","pause","fail"],"fields":{"type":"string","context":"RuntimeContext","tool_name":"string","parameters":"object","reason":"string","markdown":"string","payload":"object","kind":"string","requires_confirmation":"boolean"}})";
}

std::string guardrailDecisionSchemaJson() {
    return R"({"schema_version":"1.0","type":"object","allowed_decisions":["allow","reject","rewrite","tripwire_failure"],"fields":{"decision":"string","message":"string","payload":"object"}})";
}

std::string runtimeStateSchemaJson() {
    return R"({"schema_version":"1.0","type":"object","scopes":["temp","session","user","app"],"rules":["Models cannot mutate state directly.","Mutations occur through host calls, tools, hooks, or runtime APIs.","Persistence is caller-owned through checkpoints or host storage."]})";
}

std::string checkpointSchemaJson() {
    return R"({"schema_version":"1.0","type":"object","required":["contract","session_id","run_id","request","runtime_state"],"fields":{"contract":"runtime_checkpoint","session_id":"string","run_id":"string","request":"AgentRequest","context":"RuntimeContext","step_index":"integer","pending":"object","budget":"object","last_observation":"ReActObservation","runtime_state":"RuntimeState","tool_replay_ledger":"array","trace_summary":"array","trace":"array","resultMarkdown":"string"}})";
}

std::string externalToolProviderSchemaJson() {
    return R"({"schema_version":"1.0","type":"object","fields":{"namespace":"string","allowed_tools":"string[]","schemas":"ToolSchema[]","health":"object","token_redaction":"required"},"rules":["Transport is implemented by the provider or binding, not by Runtime Core.","Provider tools are registered as normal runtime tools.","Secrets and tokens must never enter trace, audit, events, or benchmark reports."]})";
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
        R"("hook_directive":)" + hookDirectiveSchemaJson() + ","
        R"("guardrail_decision":)" + guardrailDecisionSchemaJson() + ","
        R"("runtime_state":)" + runtimeStateSchemaJson() + ","
        R"("runtime_checkpoint":)" + checkpointSchemaJson() + ","
        R"("external_tool_provider":)" + externalToolProviderSchemaJson() +
        "}}";
}

} // namespace LuminaAgent
