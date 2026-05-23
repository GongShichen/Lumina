# Performance Strategy

## Runtime

- `runStream` emits planning, permission, confirmation, tool, rollback, and final events as work happens.
- `AgentRunResult.timing` records planning/tool/total latency.
- `AgentRuntimeConfiguration` caps model output and can stop after failed tools.
- Multimodal content is passed by reference where possible. Large images/audio/video should use file URLs or security-scoped bookmarks, not inline base64.
- User-facing natural language output should prefer `AgentContentPart.markdown` so the app can stream and render structured answers incrementally without post-processing plain text into UI sections.

## Memory

- Ingest never waits for embedding by default.
- Search uses metadata filters before vector ranking.
- Vector scoring is capped with `maximumVectorCandidates`.
- Recent search results are cached in memory.
- Persistence is snapshot-based and does not block the public ingest path.

## App

- Lumina loads model adapters lazily in `AppEnvironment.live()`.
- Missing Core ML models fall back to deterministic local implementations.
- Audit logs and memory index files live under Application Support.
- The main interaction consumes `runStream`, so confirmation prompts, tool progress, and multimodal outputs appear without waiting for the full run to finish.
- Markdown rendering is local and AST-based via `swift-markdown`. Parsing runs off the main actor, AST output is flattened into Sendable view models, parsed documents are cached with `NSCache`, long answers are displayed in a `LazyVStack`, and wide code/table blocks use horizontal scrolling to avoid expensive layout retries on the main interaction path.
- Each block type maps to a dedicated SwiftUI component, which keeps layout cost predictable and allows expensive treatments such as syntax highlighting or richer table cells to be added behind block-specific budgets later.
