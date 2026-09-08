# Tool calling and recovery

The app uses the same prompt, result transport, and recovery policy in normal operation and isolated local-model regression. Relevant tools receive full schemas; other registered tools remain in a short directory. Runtime still validates every call and controls permission and idempotency.

## Failure feedback

Tool results carry structured failure feedback in `output.failure`. The Apple bridge preserves nested output through C++ and into the next model step. The envelope uses:

- `code`, `reason`, `toolName`, and the attempted `arguments`.
- `fieldErrors`, `toolSchema`, and optional `availableTools` for relevant registered alternatives.
- `suggestedCall` only when a valid next call can be formed from known facts; otherwise `null` and `missingInformation` describe what is needed.
- `retryPolicy`: `correct_arguments`, `prerequisite`, `discover_tool`, `request_permission`, `verify_before_retry`, or `stop`.
- Optional `guidance` explaining how to preserve the user's goal while correcting the call.

Failure guidance is evidence for correction, not authorization. Unknown fields, dates, and IDs must not be fabricated. The latest failure envelope is retained intact in the model prompt rather than truncating its serialized JSON.

`LuminaToolResult.validationFailed` defaults to `nil`. Only a host tool's checks performed before side effects may set it to `true`. This allows changed parameters to correct a cached validation failure. Successful writes and uncertain execution failures retain the existing replay protections. A host prerequisite can use `rejectToolCallForValidation(reason:failure:)`; ordinary permission rejection remains a denial.

Relative-date writes require a successful current-time observation in the current run. Invalid explicit reminder dates fail rather than creating undated reminders. One correction is allowed for the same tool and error category; successful execution resets that tool's correction budget. Permissions and uncertain writes cannot be bypassed by automatic retries.

## Local Mac Catalyst regression

From the repository root:

```sh
bash scripts/test_tool_calling_catalyst.sh
```

For one scenario:

```sh
LUMINA_TOOL_CALL_REGRESSION_CASES=reminder bash scripts/test_tool_calling_catalyst.sh
```

The script builds a distinct Mac Catalyst native engine, builds the Debug app with temporary test signing settings, and runs local MiniCPM against isolated tool stores. It does not create real system calendar/reminder/notification items. It verifies reminder, notification, calendar update, and cross-domain scenarios, including real returned IDs and target dates.

By default, reports and logs are under `.build/tool-calling-catalyst/`. JSON reports include actual tool calls, observations, model token counts, elapsed time, and failure reasons. Existing model resources are required. The normal UI does not activate this harness unless `LUMINA_TOOL_CALL_REGRESSION=1` is explicitly set.

## Runtime and inference integrity

MiniCPM input is serialized with the chat template embedded in its GGUF: a system turn, the initial user goal, assistant tool calls, and user turns wrapping results in `tool_response`. The goal is not reintroduced after every tool result. The non-thinking assistant prefix and diagnostic role boundaries are preserved during format correction.

Host-derived scheduling facts use a successful current-run clock observation and explicit user time expressions only. Ambiguous expressions have no inferred default. Failed writes remain pending after other tools succeed; an outcome checker permits one model correction before rejecting an unsupported completion claim. Calendar mutations require an observed object ID rather than a guessed title.

Core execution is authoritative for model observations, completion events, audit and final tool results. Output guardrails run before results are published. Batch calls consume the same per-call budget as individual calls, and cancellation prevents starting the next call. Call IDs distinguish repeated or same-name operations.

Native generation uses the actual tokenizer count for its context and output limits. Decoder failures and incomplete outputs are failures, not successful responses. Cancellation propagates through the Swift queue and the per-request C ABI; on Metal it is checked at 256-token prefill boundaries and decode-token boundaries. Older external engines remain ABI-compatible, with cancelled results discarded. Cached model resources are released before backend shutdown.

Regression commands:

```sh
swift test --package-path LuminaAgentRuntime
swift test --package-path app
LUMINA_TOOL_CALL_REGRESSION_ENGINE_CHECK=1 bash scripts/test_tool_calling_catalyst.sh
```

The optional real-engine checks cover cancellation, reuse after cancellation, and rejection of a context that is too small. The standalone native contract test in `app/NativeEngines/MiniCPMV46/Tests/EngineContractTests.cpp` additionally injects decoder failures and exact budget boundaries without loading GPU weights.

## Human decisions stay pending

OS authorization, confirmation, questions, message composition, sharing and location authorization wait for an actual decision. They do not become successful or denied because a short timer elapsed. `LuminaPermissionDecisionAwaiter` supports cancellation without allowing late callbacks to resume a call twice or perform a later write. Permission UI starts on the main actor; waiting suspends the tool rather than blocking the interface.

Message/share results follow the platform completion callback. Dismissing a confirmation or cancelling the run resolves the pending interaction as cancellation. A `.notDetermined` location callback is still pending. Explicit refusal, cancellation and real system errors remain distinguishable from waiting.

A corrected validation failure stays in audit history but no longer makes the overall run partially failed once the same operation has actually succeeded. Unrelated operation keys and real execution failures do not clear each other.
