# ReAct Runtime

Lumina's `AgentRuntime` executes requests as a local ReAct loop:

1. `Thought`: the planner summarizes what it needs next.
2. `Action`: the planner emits one structured `ToolCall`.
3. `Observation`: the runtime compresses the `ToolResult`.
4. Repeat until `Final` or the runtime budget is reached.

Actions are never free-form commands. They must reference an available `ToolSchema`, and side-effect tools still pass through the permission gate, human confirmation, audit logging, and best-effort rollback.

`runStream` emits ReAct events (`thoughtGenerated`, `actionProposed`, `observationCreated`, `finalGenerated`) alongside legacy planning/tool/confirmation events so the app can render progress without waiting for the whole run.

Observation text is capped by `AgentRuntimeConfiguration.maximumObservationCharacters` to avoid feeding large private payloads back into the planner.
