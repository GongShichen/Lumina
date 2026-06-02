#pragma once

#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/**
 * Opaque handle for a platform-neutral LuminaAgent runtime instance.
 *
 * Create an instance with `LuminaAgentRuntimeCreate` and release it with
 * `LuminaAgentRuntimeDestroy`. The runtime owns registered tool schemas and
 * callback pointers, but never owns caller-provided callback contexts.
 */
typedef struct LuminaAgentRuntimeRef LuminaAgentRuntimeRef;

/**
 * Opaque handle for a single explicit agent task session.
 *
 * Create with `LuminaAgentRuntimeCreateSession`, continue with
 * `LuminaAgentRuntimeRunSession` / `LuminaAgentRuntimeResumeSession`, and
 * release with `LuminaAgentRuntimeDestroySession`. A session is not safe to use
 * concurrently from multiple threads.
 */
typedef struct LuminaAgentRuntimeSessionRef LuminaAgentRuntimeSessionRef;

/**
 * Callback used by the runtime to request the next structured ReAct step from a model.
 *
 * The input is a UTF-8 JSON string containing the user request, registered tool
 * schemas, loaded context, trace summary, and current budget. The callback must
 * return a heap-allocated UTF-8 JSON string accepted by the ReAct transport
 * schema, or `NULL` on failure. Returned strings are released by the runtime
 * with `LuminaAgentRuntimeReleaseString`.
 */
typedef char *(*LuminaAgentModelCallback)(const char *planner_input_json, void *user_context);

/**
 * Callback used by streaming model adapters to emit generated chunks.
 *
 * `chunk_json` should be a UTF-8 JSON object such as
 * `{"delta":"...","tokenCount":1}`. The runtime consumes the chunk during the
 * callback and does not retain the pointer. Return `false` to ask the model
 * adapter to stop generation early, for example after cancellation.
 */
typedef bool (*LuminaAgentModelStreamEmitCallback)(const char *chunk_json, void *emit_context);

/**
 * Callback used by the runtime to request a streamed structured ReAct step.
 *
 * The callback receives the same model-facing task envelope as
 * `LuminaAgentModelCallback`. It should emit token/chunk deltas through `emit`
 * and return the final generated text as a heap-allocated UTF-8 string. The
 * runtime releases the returned string with `LuminaAgentRuntimeReleaseString`.
 */
typedef char *(*LuminaAgentStreamingModelCallback)(
    const char *planner_input_json,
    LuminaAgentModelStreamEmitCallback emit,
    void *emit_context,
    void *user_context
);

/**
 * Callback used by the runtime to read provider/model metadata before a run.
 *
 * The callback receives `{"request":...}` and should return JSON such as
 * `{"model_id":"mimo-v2.5-pro","max_context_tokens":131072,
 *   "provider_native_context_management":true}`. Missing or invalid metadata
 * falls back to the caller-supplied runtime configuration.
 */
typedef char *(*LuminaAgentModelMetadataCallback)(const char *metadata_request_json, void *user_context);

/**
 * Callback used by the runtime to execute a registered tool call.
 *
 * The input is a UTF-8 JSON object with `tool_name`, `parameters`, and runtime
 * metadata. The callback must return a heap-allocated UTF-8 JSON result object,
 * typically containing `status`, `content`, and optional `errorMessage`.
 */
typedef char *(*LuminaAgentToolCallback)(const char *tool_call_json, void *user_context);

/**
 * Callback used by the runtime to load platform or application context.
 *
 * The input is a UTF-8 JSON object describing the request and current budget.
 * The callback should return a heap-allocated UTF-8 JSON array or object of
 * context sections. Return `NULL` or an empty string if no context is available.
 */
typedef char *(*LuminaAgentContextCallback)(const char *context_request_json, void *user_context);

/**
 * Callback used by the runtime to ask whether a tool call is allowed.
 *
 * The input is a UTF-8 JSON object containing the proposed tool call and schema.
 * Return a heap-allocated JSON decision such as `{"decision":"allowed"}`,
 * `{"decision":"denied","reason":"..."}`, or
 * `{"decision":"requires_confirmation"}`.
 */
typedef char *(*LuminaAgentPermissionCallback)(const char *permission_request_json, void *user_context);

/**
 * Callback used by the runtime to request human confirmation before a side effect.
 *
 * The input is a UTF-8 JSON object containing the proposed action and reason.
 * Return a heap-allocated JSON decision such as `{"confirmed":true}` or
 * `{"confirmed":false,"reason":"..."}`. The runtime waits for this callback
 * before executing the tool.
 */
typedef char *(*LuminaAgentConfirmationCallback)(const char *confirmation_request_json, void *user_context);

/**
 * Callback used by runtime-owned guardrail checkpoints.
 *
 * The input is a UTF-8 JSON object with `stage` and `payload`. Supported stages
 * are `request`, `tool_input`, `tool_output`, and `result`. Return
 * `{"decision":"allow"}`, `{"decision":"reject","message":"..."}`,
 * `{"decision":"rewrite","payload":{...}}`, or
 * `{"decision":"tripwire_failure","message":"..."}`. The core runtime owns
 * when the decision is applied; language bindings should only translate their
 * native guardrail interfaces into this callback.
 */
typedef char *(*LuminaAgentGuardrailCallback)(const char *guardrail_request_json, void *user_context);

/**
 * Callback used by the runtime to ask whether a failed runtime stage should be
 * retried, handed to a host fallback, failed, or accepted as-is.
 *
 * The input is a UTF-8 JSON object with correlation fields, `stage`, `attempt`,
 * `max_attempts`, error metadata, and optional tool idempotency metadata. Return
 * `{"action":"retry","delay_ms":1000}`, `{"action":"fallback"}`,
 * `{"action":"fail"}`, or `{"action":"proceed"}`. Returning NULL or invalid
 * JSON falls back to the runtime default retry policy.
 */
typedef char *(*LuminaAgentRetryProviderCallback)(const char *retry_request_json, void *user_context);

/**
 * Callback used by the runtime to let the host customize context compaction.
 *
 * The input is a UTF-8 JSON object with correlation fields, `trigger`,
 * `strategy`, provider/model context-window metadata, a budget snapshot, and
 * a context frame. Return `{"status":"skipped"}` to let the core continue
 * its default pipeline, or `{"status":"compacted","compacted_context":{...}}`
 * with optional `boundary`, `tokens_saved_estimate`, and `preserved_ids`.
 * Returning NULL or invalid JSON falls back to the runtime default strategy.
 */
typedef char *(*LuminaAgentCompactionProviderCallback)(const char *compaction_request_json, void *user_context);

/**
 * Callback used by the runtime to write audit records.
 *
 * The input is a UTF-8 JSON object describing lifecycle events, tool calls,
 * observations, and final status. The runtime does not retain the pointer after
 * the callback returns.
 */
typedef void (*LuminaAgentAuditCallback)(const char *audit_record_json, void *user_context);

/**
 * Callback used by external trace collectors.
 *
 * Trace records are optional and emitted only when this sink is installed.
 * Payloads are intended for replay/debug harnesses and are not persisted by the
 * core runtime.
 */
typedef void (*LuminaAgentTraceCallback)(const char *trace_record_json, void *user_context);

/**
 * Callback used by external metrics collectors.
 *
 * Metric samples are optional atomic observations such as model latency, tool
 * latency, retry counts, or parser latency. The runtime does not aggregate or
 * persist metrics when no sink is installed.
 */
typedef void (*LuminaAgentMetricsCallback)(const char *metric_json, void *user_context);

/**
 * Callback used by external span/tracing integrations.
 *
 * Span records are optional start/end markers suitable for caller-owned
 * OpenTelemetry or custom tracing bridges.
 */
typedef void (*LuminaAgentSpanCallback)(const char *span_json, void *user_context);

/**
 * Callback used by the runtime to request best-effort rollback.
 *
 * The input is a UTF-8 JSON object containing rollback metadata emitted by a
 * failed tool or audit event. Return a heap-allocated JSON result. Rollback is
 * best effort and must not be assumed to succeed.
 */
typedef char *(*LuminaAgentRollbackCallback)(const char *rollback_request_json, void *user_context);

/**
 * Callback used by the runtime to stream execution events.
 *
 * The input is a UTF-8 JSON event object. Events include run start/end, context
 * loaded, model generation, tool execution, observation, result, failure,
 * and cancellation. The runtime does not retain the pointer after the callback
 * returns.
 */
typedef void (*LuminaAgentEventCallback)(const char *event_json, void *user_context);

/**
 * Callback used by the runtime to expose generic lifecycle hook points.
 *
 * The input is a UTF-8 JSON object with `lifecycle` and `payload`. Hooks may
 * return a heap-allocated JSON directive object for observability or future
 * policy extensions. The runtime remains app-agnostic; hook payloads must use
 * generic runtime terms only.
 */
typedef char *(*LuminaAgentHookCallback)(const char *hook_event_json, void *user_context);

/**
 * Creates a runtime instance from a JSON configuration supplied by the caller.
 *
 * `configuration_json` must include model/runtime budgets such as
 * `maxIterations`, `maxToolCalls`, `contextWindowTokens`, `maxOutputTokens`,
 * `reservedOutputTokens`, `maxObservationCharacters`, `toolResultTokenBudget`,
 * `compactThresholdTokens`, `maxCompactFailures`, `maxReasoningSteps`, and
 * `maxReplayObservations`.
 * The runtime never infers these values from a specific model. If required
 * values are missing, run calls return a configuration error. The returned
 * handle must be destroyed with `LuminaAgentRuntimeDestroy`.
 */
LuminaAgentRuntimeRef *LuminaAgentRuntimeCreate(const char *configuration_json);

/**
 * Destroys a runtime instance and releases all runtime-owned memory.
 *
 * Passing `NULL` is allowed and has no effect. The caller remains responsible
 * for any callback context objects previously passed to setter functions.
 */
void LuminaAgentRuntimeDestroy(LuminaAgentRuntimeRef *runtime);

/**
 * Registers a tool schema with the runtime.
 *
 * `tool_schema_json` must be a UTF-8 JSON object. At minimum it should include
 * `name` and side-effect metadata that the permission layer can inspect. The
 * returned string is a heap-allocated JSON status and must be released with
 * `LuminaAgentRuntimeReleaseString`.
 */
char *LuminaAgentRuntimeRegisterToolSchema(LuminaAgentRuntimeRef *runtime, const char *tool_schema_json);

/**
 * Registers schemas from a generic external tool provider.
 *
 * `provider_json` is a JSON object containing optional `provider_id`,
 * `namespace`, `allowed_tools`, and `schemas`/`tools`. The core runtime does
 * not open MCP/HTTP/stdio connections; adapters own transport and provide
 * already-discovered schemas here. Secrets in provider config are ignored and
 * never emitted by runtime observability.
 */
char *LuminaAgentRuntimeRegisterExternalToolProvider(
    LuminaAgentRuntimeRef *runtime,
    const char *provider_json
);

/**
 * Installs the model callback used to produce structured ReAct steps.
 *
 * The callback and `user_context` are stored without ownership transfer. Set a
 * `NULL` callback to clear the current model callback.
 */
void LuminaAgentRuntimeSetModelCallback(
    LuminaAgentRuntimeRef *runtime,
    LuminaAgentModelCallback callback,
    void *user_context
);

/**
 * Installs the streaming model callback used to produce structured ReAct steps.
 *
 * When installed, the runtime prefers this callback over the blocking model
 * callback. Deltas are surfaced through runtime events and used for generation
 * metrics; the final return value is still schema-validated before execution.
 */
void LuminaAgentRuntimeSetStreamingModelCallback(
    LuminaAgentRuntimeRef *runtime,
    LuminaAgentStreamingModelCallback callback,
    void *user_context
);

/**
 * Installs the model metadata callback used for dynamic context-window budgets.
 */
void LuminaAgentRuntimeSetModelMetadataCallback(
    LuminaAgentRuntimeRef *runtime,
    LuminaAgentModelMetadataCallback callback,
    void *user_context
);

/**
 * Installs the tool execution callback used for all registered tools.
 *
 * The callback receives tool calls as JSON and returns tool results as JSON.
 * The runtime validates tool names before invoking it.
 */
void LuminaAgentRuntimeSetToolCallback(
    LuminaAgentRuntimeRef *runtime,
    LuminaAgentToolCallback callback,
    void *user_context
);

/**
 * Installs the context callback used before and during planner input assembly.
 *
 * The runtime remains platform-neutral; callers decide which context sections
 * to expose and return them as JSON.
 */
void LuminaAgentRuntimeSetContextCallback(
    LuminaAgentRuntimeRef *runtime,
    LuminaAgentContextCallback callback,
    void *user_context
);

/**
 * Installs the permission callback used before every tool execution.
 *
 * If no callback is installed, read-only style tool calls are allowed by
 * default and side-effect policies must be enforced by the caller's tool layer.
 */
void LuminaAgentRuntimeSetPermissionCallback(
    LuminaAgentRuntimeRef *runtime,
    LuminaAgentPermissionCallback callback,
    void *user_context
);

/**
 * Installs the confirmation callback used when permission requires user approval.
 *
 * The runtime calls this callback only after the permission callback returns a
 * confirmation-required decision or a model step explicitly requires
 * confirmation.
 */
void LuminaAgentRuntimeSetConfirmationCallback(
    LuminaAgentRuntimeRef *runtime,
    LuminaAgentConfirmationCallback callback,
    void *user_context
);

/**
 * Installs the optional guardrail callback used at core runtime checkpoints.
 */
void LuminaAgentRuntimeSetGuardrailCallback(
    LuminaAgentRuntimeRef *runtime,
    LuminaAgentGuardrailCallback callback,
    void *user_context
);

/**
 * Installs the optional retry provider callback.
 *
 * When this callback is not installed, the runtime uses its conservative
 * default retry policy. Bindings should translate host retry providers into
 * this callback without owning core retry semantics.
 */
void LuminaAgentRuntimeSetRetryProviderCallback(
    LuminaAgentRuntimeRef *runtime,
    LuminaAgentRetryProviderCallback callback,
    void *user_context
);

/**
 * Installs the optional context compaction provider callback.
 *
 * The core runtime still owns lifecycle, budget checks, boundary recording,
 * and observability. Bindings should translate host compaction providers into
 * this callback without making compaction Apple/Android/Harmony-specific.
 */
void LuminaAgentRuntimeSetCompactionProviderCallback(
    LuminaAgentRuntimeRef *runtime,
    LuminaAgentCompactionProviderCallback callback,
    void *user_context
);

/**
 * Installs the audit callback used to record runtime lifecycle and tool events.
 *
 * Audit is synchronous from the runtime's perspective, so callback
 * implementations should keep work bounded or hand off to their own queue.
 */
void LuminaAgentRuntimeSetAuditCallback(
    LuminaAgentRuntimeRef *runtime,
    LuminaAgentAuditCallback callback,
    void *user_context
);

/**
 * Installs the optional trace sink.
 */
void LuminaAgentRuntimeSetTraceCallback(
    LuminaAgentRuntimeRef *runtime,
    LuminaAgentTraceCallback callback,
    void *user_context
);

/**
 * Installs the optional metrics sink.
 */
void LuminaAgentRuntimeSetMetricsCallback(
    LuminaAgentRuntimeRef *runtime,
    LuminaAgentMetricsCallback callback,
    void *user_context
);

/**
 * Installs the optional span sink.
 */
void LuminaAgentRuntimeSetSpanCallback(
    LuminaAgentRuntimeRef *runtime,
    LuminaAgentSpanCallback callback,
    void *user_context
);

/**
 * Installs the rollback callback used after failed side-effect tool execution.
 *
 * The runtime passes generic rollback JSON. The caller decides whether rollback
 * is possible for the underlying platform action.
 */
void LuminaAgentRuntimeSetRollbackCallback(
    LuminaAgentRuntimeRef *runtime,
    LuminaAgentRollbackCallback callback,
    void *user_context
);

/**
 * Installs the streaming event callback.
 *
 * Events are delivered synchronously and must be copied by the caller if they
 * need to outlive the callback invocation.
 */
void LuminaAgentRuntimeSetEventCallback(
    LuminaAgentRuntimeRef *runtime,
    LuminaAgentEventCallback callback,
    void *user_context
);

/**
 * Installs the generic lifecycle hook callback.
 *
 * Hooks observe runtime lifecycle points such as run start, context loaded,
 * planner input ready, step produced, tool execution, observation, result,
 * cancellation, and error. The runtime stores the callback without taking
 * ownership of `user_context`.
 */
void LuminaAgentRuntimeSetHookCallback(
    LuminaAgentRuntimeRef *runtime,
    LuminaAgentHookCallback callback,
    void *user_context
);

/**
 * Registers a core hook route.
 *
 * `route_json` is a JSON object with an `id` and optional matcher fields:
 * `events`, `tool_name_patterns`, `sensitivities`, and `side_effects`.
 * Matching happens in the core runtime before the hook callback is invoked; the
 * callback receives `route_id` when a route matched.
 */
char *LuminaAgentRuntimeRegisterHookRoute(LuminaAgentRuntimeRef *runtime, const char *route_json);

/**
 * Clears all hook routes. With no routes installed, the hook callback is called
 * once for each lifecycle event for backward compatibility.
 */
void LuminaAgentRuntimeClearHookRoutes(LuminaAgentRuntimeRef *runtime);

/**
 * Runs one complete task session.
 *
 * `request_json` is a UTF-8 JSON object supplied by the caller. Each call
 * creates an isolated session; no temporary trace state is shared across calls.
 * The returned heap-allocated JSON result must be released with
 * `LuminaAgentRuntimeReleaseString`.
 */
char *LuminaAgentRuntimeRun(LuminaAgentRuntimeRef *runtime, const char *request_json);

/**
 * Runs one complete task using caller-provided replay data.
 *
 * `replay_json` may contain `mode`, `model_outputs`, and `tool_observations`.
 * Replay is executed by the core loop and can replace model outputs, tool
 * observations, or both without changing the ReAct schema.
 */
char *LuminaAgentRuntimeRunReplay(
    LuminaAgentRuntimeRef *runtime,
    const char *request_json,
    const char *replay_json
);

/**
 * Runs one complete task using a caller-provided replay artifact and options.
 *
 * This is an explicit replay entrypoint. Normal `LuminaAgentRuntimeRun` never
 * consumes external replay artifacts. `artifact_json` should be a JSON object
 * containing request/checkpoint/trace/model_outputs/tool_observations. The
 * optional `options_json` controls strict/mixed/fork style replay behavior.
 */
char *LuminaAgentRuntimeRunReplayArtifact(
    LuminaAgentRuntimeRef *runtime,
    const char *artifact_json,
    const char *options_json
);

/**
 * Creates an explicit pausable task session.
 *
 * `request_json` is copied by the runtime session and should contain caller
 * supplied system instructions, user content, metadata, and locale. The returned
 * session must be destroyed with `LuminaAgentRuntimeDestroySession`.
 */
LuminaAgentRuntimeSessionRef *LuminaAgentRuntimeCreateSession(
    LuminaAgentRuntimeRef *runtime,
    const char *request_json
);

/**
 * Runs or continues an explicit session until it finishes, fails, or pauses.
 *
 * The returned heap-allocated JSON contains the session status, pending state
 * when paused, and current result Markdown when available.
 */
char *LuminaAgentRuntimeRunSession(
    LuminaAgentRuntimeRef *runtime,
    LuminaAgentRuntimeSessionRef *session
);

/**
 * Runs or continues an explicit session using caller-provided replay data.
 */
char *LuminaAgentRuntimeRunSessionReplay(
    LuminaAgentRuntimeRef *runtime,
    LuminaAgentRuntimeSessionRef *session,
    const char *replay_json
);

/**
 * Resumes a paused explicit session with a runtime-owned observation payload.
 *
 * `resume_json` should describe the external answer/confirmation/context result
 * as JSON. The runtime appends it as the latest observation before continuing.
 */
char *LuminaAgentRuntimeResumeSession(
    LuminaAgentRuntimeRef *runtime,
    LuminaAgentRuntimeSessionRef *session,
    const char *resume_json
);

/**
 * Cancels an explicit task session and returns its cancelled snapshot.
 */
char *LuminaAgentRuntimeCancelSession(
    LuminaAgentRuntimeRef *runtime,
    LuminaAgentRuntimeSessionRef *session
);

/**
 * Returns the current explicit session snapshot.
 */
char *LuminaAgentRuntimeSnapshotSession(LuminaAgentRuntimeSessionRef *session);

/**
 * Exports a complete core checkpoint JSON for caller-owned persistence.
 */
char *LuminaAgentRuntimeExportSessionCheckpoint(LuminaAgentRuntimeSessionRef *session);

/**
 * Creates a session from a previously exported core checkpoint JSON.
 */
LuminaAgentRuntimeSessionRef *LuminaAgentRuntimeCreateSessionFromCheckpoint(
    LuminaAgentRuntimeRef *runtime,
    const char *checkpoint_json
);

/**
 * Creates a session from a replay artifact and optional fork options.
 *
 * The core restores the artifact checkpoint when present and applies simple
 * request/context overrides from `fork_options_json`. Callers remain
 * responsible for storing artifacts.
 */
LuminaAgentRuntimeSessionRef *LuminaAgentRuntimeCreateSessionFromReplayArtifact(
    LuminaAgentRuntimeRef *runtime,
    const char *artifact_json,
    const char *fork_options_json
);

/**
 * Sets, gets, deletes, or snapshots runtime-managed scoped state on a session.
 *
 * Supported scopes are `temp`, `session`, `user`, and `app`. Values are raw JSON
 * fragments owned by the caller and copied by the runtime.
 */
char *LuminaAgentRuntimeSessionSetState(
    LuminaAgentRuntimeRef *runtime,
    LuminaAgentRuntimeSessionRef *session,
    const char *scope,
    const char *key,
    const char *value_json
);
char *LuminaAgentRuntimeSessionGetState(
    LuminaAgentRuntimeSessionRef *session,
    const char *scope,
    const char *key
);
char *LuminaAgentRuntimeSessionDeleteState(
    LuminaAgentRuntimeRef *runtime,
    LuminaAgentRuntimeSessionRef *session,
    const char *scope,
    const char *key
);
char *LuminaAgentRuntimeSessionStateSnapshot(LuminaAgentRuntimeSessionRef *session);

/**
 * Destroys an explicit session created by `LuminaAgentRuntimeCreateSession`.
 */
void LuminaAgentRuntimeDestroySession(LuminaAgentRuntimeSessionRef *session);

/**
 * Requests cancellation for an active or recently active runtime task.
 *
 * `request_id` may be `NULL` to cancel the current task. The returned
 * heap-allocated JSON status must be released with
 * `LuminaAgentRuntimeReleaseString`.
 */
char *LuminaAgentRuntimeCancel(LuminaAgentRuntimeRef *runtime, const char *request_id);

/**
 * Releases a string allocated by the LuminaAgentRuntime C ABI.
 *
 * Call this for every non-NULL `char *` returned by runtime APIs and callbacks
 * documented as runtime-owned. Passing `NULL` is allowed.
 */
void LuminaAgentRuntimeReleaseString(char *value);

/**
 * Validates a single structured ReAct step JSON object.
 *
 * This utility is exposed for language bridges and tests. The returned
 * heap-allocated JSON status must be released with
 * `LuminaAgentRuntimeReleaseString`.
 */
char *LuminaReActValidateStepJSON(const char *json);

/**
 * Extracts the first valid structured ReAct step object from arbitrary text.
 *
 * This is useful for model adapters that receive streamed text with surrounding
 * prose. The returned heap-allocated JSON status must be released with
 * `LuminaAgentRuntimeReleaseString`.
 */
char *LuminaReActExtractFirstStandardObject(const char *text);

/**
 * Normalizes model output from a supported dialect into the canonical runtime
 * ReAct step contract.
 *
 * Supported dialects include `canonical_json` and `xml_tags`. Provider-native
 * or custom adapters should normalize before calling the runtime.
 */
char *LuminaReActNormalizeStepText(const char *text, const char *dialect);

/**
 * Exports the trace for an explicit task session.
 *
 * `format` may be `"jsonl"` for newline-delimited JSON or anything else for a
 * JSON array. The returned string must be released with
 * `LuminaAgentRuntimeReleaseString`.
 */
char *LuminaAgentRuntimeExportSessionTrace(LuminaAgentRuntimeSessionRef *session, const char *format);

/**
 * Exports a replay artifact JSON for caller-owned persistence.
 */
char *LuminaAgentRuntimeExportReplayArtifact(
    LuminaAgentRuntimeSessionRef *session,
    const char *options_json
);

/**
 * Diffs two replay artifact JSON values and returns drift flags.
 */
char *LuminaAgentRuntimeDiffReplayArtifacts(
    const char *expected_json,
    const char *actual_json,
    const char *options_json
);

/**
 * Exports runtime protocol contracts for model adapters and training tools.
 *
 * The returned JSON contains task envelope, ReAct step, and responder schemas.
 * Release it with `LuminaAgentRuntimeReleaseString`.
 */
char *LuminaAgentRuntimeExportContracts(void);

/**
 * Alias for `LuminaAgentRuntimeReleaseString`.
 */
void LuminaReActFreeCString(char *value);

#ifdef __cplusplus
}
#endif
