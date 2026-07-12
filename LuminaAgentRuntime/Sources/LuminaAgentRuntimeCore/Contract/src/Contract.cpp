#include "Contract.hpp"

namespace LuminaAgent {

std::string reactStepSchemaJson() {
    return R"({"schema_version":"1.0","semantic_contract":"lumina_code_runtime_canonical_with_minicpm_v46_transport","model_facing_transport":{"dialect":"minicpm_v46_tool_calls","tokenizer_special_tokens":{"bos":"<|im_start|>","eos":"<|im_end|>","pad":"<|endoftext|>","vision":["<|vision_start|>","<|vision_end|>","<|image_pad|>","<image>","</image>","<image_id>","</image_id>","<slice>","</slice>","<|video_pad|>"],"audio":["<|audio_start|>","<|audio_end|>","<|audio_pad|>"]},"react_tags":["<think>","</think>","<tool_call>","</tool_call>","<function=NAME>","</function>","<parameter=NAME>","</parameter>"],"assistant_may_emit":["plain final answer text","<think>private reasoning</think>","<tool_call><function=EXACT_TOOL_NAME><parameter=field_name>value</parameter></function></tool_call>"],"extraction":"Runtime extracts thinking from <think>, tool actions from <tool_call>/<function>/<parameter>, and final visible text from remaining assistant text."},"runtime_canonical_types":["reasoning","tool_discovery","tool_use","multi_tool_use","ask_user","result","cannot_complete"],"rules":["The model-facing output contract is MiniCPM-V4.6 text transport.","The MiniCPM-V4.6 local adapter normalizes chat-template tool-call tags into Runtime canonical steps after generation.","Tool input is one object semantically, represented locally by one parameter block per object field.","Final answers are visible assistant text and are valid only after the whole user goal is complete from runtime-observed facts.","Observations, permission, confirmation, replay, checkpoints, and hard guardrails are runtime-owned."]})";
}

std::string taskEnvelopeSchemaJson() {
    return R"({"schema_version":"1.0","fields":["instructions","task","available_tools","context","progress","execution_budget","output_contract"],"instruction_fields":["system","system_prompt_source","instruction_priority","trust_boundary","model_visible_information","skill_policy","output_contract"],"task_fields":["user_goal","input_parts","modalities","attachments_summary"],"input_part_types":["text","image","audio","video","file","structuredData"]})";
}

std::string responderSchemaJson() {
    return R"({"schema_version":"1.0","format":"Markdown","rules":["Summarize only runtime-observed facts.","Keep raw JSON and internal trace dumps out of user-facing final answers.","Cite sources when citations are present."]})";
}

std::string runtimeConfigurationSchemaJson() {
    return R"({"schema_version":"1.0","type":"object","required":["maxIterations","maxToolCalls","contextWindowTokens","maxOutputTokens","reservedOutputTokens","maxObservationCharacters","toolResultTokenBudget","compactThresholdTokens","maxCompactFailures","maxReasoningSteps","maxReplayObservations"],"fields":{"maxIterations":"integer","maxToolCalls":"integer","contextWindowTokens":"integer fallback provider max context","maxContextTokens":"integer provider/model max context","modelId":"string optional provider/model id","providerNativeContextManagement":"boolean optional native context management support","maxOutputTokens":"integer","reservedOutputTokens":"integer","autoCompactBufferTokens":"integer","warningBufferTokens":"integer","maxObservationCharacters":"integer","toolResultTokenBudget":"integer","compactThresholdTokens":"integer auto compact buffer fallback","maxCompactFailures":"integer","maxReasoningSteps":"integer","maxReplayObservations":"integer","stopOnToolFailure":"boolean","yoloMode":"boolean explicit dangerous mode; skips permission/confirmation only","toolSchemaProfile":"full|compact|name-only","toolLoadingMode":"enabled|auto|disabled","toolLoadingThresholdRatio":"number 0.0-1.0","checkpointPolicy":"none|onPause|onStep|onExit"}})";
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
    return R"({"schema_version":"1.0","type":"object","required":["name"],"fields":{"name":"string","description":"string","aliases":"string[]","deprecatedAliases":"object alias->warning","category":"string","searchHint":"string","parameters":"ToolParameterSchema","sideEffect":"string","readOnly":"boolean","destructive":"boolean","concurrencySafe":"boolean","requiresUserInteraction":"boolean","requiresConfirmation":"boolean","interruptBehavior":"string","idempotencyPolicy":"replay_identical|always_execute|caller_keyed","maxResultSize":"integer","strict":"boolean","inputSchema":"object","outputSchema":"object","displaySummary":"string","sensitivity":"string"}})";
}

std::string toolParameterSchemaJson() {
    return R"({"schema_version":"1.0","type":"object","fields":{"type":"string","description":"string","required":"boolean","properties":"object","items":"object","enum":"array"}})";
}

std::string toolCallSchemaJson() {
    return R"({"schema_version":"1.0","type":"object","required":["type","id","name","input"],"fields":{"type":"tool_use","id":"string provider/runtime tool use id","name":"string exact tool name","input":"object tool parameters"},"runtime_canonical_fields":{"tool_name":"internal name mirror","parameters":"internal input mirror","call_id":"internal id mirror"}})";
}

std::string toolResultSchemaJson() {
    return R"({"schema_version":"1.0","type":"object","required":["type","tool_use_id","content"],"fields":{"type":"tool_result","tool_use_id":"string matching tool_use.id","content":"string or content blocks owned by runtime"},"runtime_status_fields":{"status":"succeeded|failed|cancelled","errorMessage":"string","output":"object","rollback":"object"}})";
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

std::string contextLoadingPluginSchemaJson() {
    return R"({"schema_version":"1.0","type":"object","actions":["catalog","search","load","range","invalidate"],"request_fields":{"action":"string","session_id":"string","run_id":"string","request":"AgentRequest","query":"string","reasoning_step":"ReActStep|null","context_budget":"object","loaded_context_set":"ContextSection metadata[]","context_catalog_summary":"object|null","items":"ContextSection metadata[]"},"response_fields":{"status":"ok|skipped|failed","items":"ContextSection metadata[]","sections":"RuntimeContextSection[]","next_cursor":"string","failure_reason":"string"},"rules":["Host owns memory, files, knowledge bases, history, and persistence.","Runtime Core only manages per-session context working set and budget.","Returning skipped or empty JSON may fall back to the installed context callback.","Secrets must stay out of plugin payloads."]})";
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

std::string retryRequestSchemaJson() {
    return R"({"schema_version":"1.0","type":"object","required":["session_id","run_id","stage","attempt","max_attempts","error_code","error_category","recoverable"],"allowed_stages":["model_generation","step_normalization","tool_execution","context_load","external_provider"],"fields":{"session_id":"string","run_id":"string","stage":"string","attempt":"integer","max_attempts":"integer","error_code":"string","error_category":"string","recoverable":"boolean","tool_name":"string","tool_side_effect":"string","idempotency_policy":"replay_identical|always_execute|caller_keyed","has_idempotency_key":"boolean","retry_after_seconds":"number","elapsed_ms":"number"},"rules":["permission and confirmation are not retried by default.","tool_execution retry must be constrained by idempotency metadata.","Secrets must never be included."]})";
}

std::string retryDecisionSchemaJson() {
    return R"({"schema_version":"1.0","type":"object","required":["action"],"allowed_actions":["retry","fallback","fail","proceed"],"fields":{"action":"string","delay_ms":"integer","reason":"string","max_attempts_override":"integer"},"rules":["Returning invalid JSON from a host retry provider falls back to the runtime default policy.","fallback is host-owned; Runtime Core only surfaces the decision."]})";
}

std::string runtimeStateSchemaJson() {
    return R"({"schema_version":"1.0","type":"object","scopes":["temp","session","user","app"],"rules":["Models cannot mutate state directly.","Mutations occur through host calls, tools, hooks, or runtime APIs.","Persistence is caller-owned through checkpoints or host storage."]})";
}

std::string runtimePermissionStateSchemaJson() {
    return R"({"schema_version":"1.0","type":"object","fields":{"confirmed_tools":"string[]","confirmed_paths":"string[]","confirmed_command_rules":"string[]","yolo_mode":"boolean"},"rules":["Permission and confirmation are runtime decision points, not model-callable tools.","YOLO skips prompts only; it does not bypass schema validation, hard guardrails, cancellation, budgets, or replay/idempotency checks."]})";
}

std::string skillMetadataSchemaJson() {
    return R"({"schema_version":"1.0","type":"object","required":["canonicalName","description"],"fields":{"canonicalName":"string canonical skill name","canonical_name":"string alias","name":"string alias","description":"string","whenToUse":"string","when_to_use":"string","source":"host|project|user|system","directory":"string optional cwd visibility root","skillFile":"string optional SKILL.md path","context":"inline|fork|host","visible":"boolean","modelInvocable":"boolean"},"rules":["Skills are model-visible only through runtime.skill_discovery, the Skill tool schema, or loaded context.","Skill execution is host-owned; Runtime Core preserves ReAct/tool semantics."]})";
}

std::string skillDiscoverySchemaJson() {
    return R"({"schema_version":"1.0","tool_name":"runtime.skill_discovery","type":"tool_schema","sideEffect":"readOnly","readOnly":true,"parameters":{"query":"string optional skill query or select:canonical-name","max_results":"integer optional"},"response_fields":{"matches":"SkillMetadata compact[]","listing_reminder":"LuminaCode-style <system-reminder> text"},"rules":["Discovery does not execute a skill or grant permission.","Invoke Skill only when a listed skill matches the current task.","Permission and confirmation are not skills or tools."]})";
}

std::string mcpDiscoverySchemaJson() {
    return R"({"schema_version":"1.0","tool_name":"runtime.mcp_discovery","type":"tool_schema","sideEffect":"readOnly","readOnly":true,"parameters":{"query":"string optional MCP query or select:mcp.tool","max_results":"integer optional","include_schemas":"boolean optional; loads matching deferred schemas into this session"},"response_fields":{"matches":"MCP tool metadata[]","catalog":"MCP compact catalog"},"rules":["MCP tools are namespaced runtime tools such as mcp__server__tool or mcp.tool.","Discovery/schema loading does not grant execution permission.","External provider trust is runtime/host-owned and may be auto-trusted only by explicit YOLO mode."]})";
}

std::string checkpointSchemaJson() {
    return R"({"schema_version":"1.0","type":"object","required":["contract","session_id","run_id","request","runtime_state"],"fields":{"contract":"runtime_checkpoint","session_id":"string","run_id":"string","request":"AgentRequest","context":"RuntimeContext","step_index":"integer","pending":"object","budget":"object","last_observation":"ReActObservation","loaded_tool_set":"string[]","loaded_context_set":"ContextSection metadata[]","permission_state":"RuntimePermissionState","context_catalog_summary":"object|null","runtime_state":"RuntimeState","tool_replay_ledger":"array","trace_summary":"array","trace":"array","resultMarkdown":"string"}})";
}

std::string replayScriptSchemaJson() {
    return R"({"schema_version":"1.0","type":"object","fields":{"mode":"mixed|model|tools|all|live","model_outputs":"ReActStep[]","tool_observations":"ToolResult[]"},"rules":["Replay is caller-owned input to Runtime Core.","Replay does not change the canonical ReAct schema.","Mode all/model/tools can disable live model or tool callbacks for deterministic debug and benchmark regression."]})";
}

std::string externalToolProviderSchemaJson() {
    return R"({"schema_version":"1.0","type":"object","fields":{"provider_id":"string","namespace":"string","allowed_tools":"string[]","schemas":"ToolSchema[]","requiresTrust":"boolean","trustRequest":"object|string","trusted":"boolean","health":"object","token_redaction":"required"},"rules":["Transport is implemented by the provider or binding, not by Runtime Core.","Provider tools are registered as normal runtime tools.","A provider trust request must be explicitly trusted by the host unless YOLO mode is enabled.","YOLO may auto-trust provider registration but does not grant permission to execute tools.","Secrets and tokens must never enter trace, audit, events, or benchmark reports."]})";
}

std::string toolLoadingPluginSchemaJson() {
    return R"({"schema_version":"1.0","type":"object","actions":["catalog","search","load","invalidate"],"request_fields":{"action":"string","session_id":"string","run_id":"string","query":"string","category":"string","max_results":"integer","include_schemas":"boolean","names":"string[]","loaded_tool_set":"string[]"},"response_fields":{"matches":"ToolSchema metadata[]","schemas":"ToolSchema[]","loaded":"string[]","failed":"string[]"},"rules":["tool_discovery is the model-facing entrypoint.","Loading schemas only changes the next planner turn.","Discovery and schema loading do not grant permission to execute tools.","Secrets must never be included."]})";
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
        R"("context_loading_plugin":)" + contextLoadingPluginSchemaJson() + ","
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
        R"("retry_request":)" + retryRequestSchemaJson() + ","
        R"("retry_decision":)" + retryDecisionSchemaJson() + ","
        R"("runtime_state":)" + runtimeStateSchemaJson() + ","
        R"("runtime_permission_state":)" + runtimePermissionStateSchemaJson() + ","
        R"("skill_metadata":)" + skillMetadataSchemaJson() + ","
        R"("skill_discovery":)" + skillDiscoverySchemaJson() + ","
        R"("mcp_discovery":)" + mcpDiscoverySchemaJson() + ","
        R"("runtime_checkpoint":)" + checkpointSchemaJson() + ","
        R"("runtime_replay":)" + replayScriptSchemaJson() + ","
        R"("external_tool_provider":)" + externalToolProviderSchemaJson() + ","
        R"("tool_loading_plugin":)" + toolLoadingPluginSchemaJson() +
        "}}";
}

} // namespace LuminaAgent
