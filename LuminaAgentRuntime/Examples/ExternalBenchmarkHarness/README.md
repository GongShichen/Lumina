# External Benchmark Harness

This example shows the intended benchmark shape: the runtime executes sessions,
while an external harness computes scores from public APIs and optional
observability sinks.

The runtime does not own task suites, pass/fail rules, F1, semantic verification,
or latency aggregation. A harness can register only the sinks it needs:

- `LuminaRuntimeTraceSink` for canonical steps, tool calls, observations, and run results.
- `LuminaRuntimeMetricsSink` for atomic latency/token samples.
- `LuminaRuntimeSpanSink` for caller-owned tracing systems.
- `runStream` events for UI-style lifecycle progress.

This example returns a `BenchmarkSummary`, not just raw run results. It calculates:

- runtime status and task completion
- tool exact match, micro precision/recall/F1
- semantic verifier pass/fail
- wall-clock p95
- trace/metric event counts
- runtime contract failure count, derived from traces

The semantic verifier should inspect the canonical `result`, runtime-owned
observations, and tool result payloads. Model output must not fabricate
observations.
