# JD Readiness

Lumina is structured as a端侧 AI 基建 project rather than a demo-only app.

## 端侧 AI 架构

- `AgentRuntime` provides a ReAct loop, structured tool routing, permission gates, confirmation, audit logging, cancellation, and rollback hooks.
- `LuminaAppCore` exposes app tools as SwiftPM-testable infrastructure.
- `Lumina` is the iOS shell that hosts App Intents and multimodal UI.

## SLM / Core ML 工程化

- Planner models use the `LocalStructuredInferenceModel` / `LocalMultimodalStructuredInferenceModel` contracts.
- Gemma4 can be loaded as `Gemma4Planner.mlmodelc`.
- Embedding defaults to the lightweight BGE profile `BGETextEmbedding.mlmodelc` for Chinese personal memory retrieval.
- Missing models fall back to deterministic local implementations so CI remains stable.

## 性能与稳定性

- Personal memory uses metadata filtering before vector ranking and caps vector candidates.
- Ingest returns before embedding completes.
- Runtime and UI support streaming progress.
- Markdown rendering is AST-based, cached, and block-specific.
- SwiftPM performance tests cover runtime latency, memory scale, markdown parsing, cancellation, and app tool flows.

## 跨平台迁移价值

The tool schema, ReAct trace, memory search query, and benchmark dataset patterns are platform-neutral. Android/HarmonyOS ports can reuse the same contracts while replacing the Swift/iOS-specific tool implementations.
