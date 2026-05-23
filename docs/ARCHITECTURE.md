# Lumina Architecture

Lumina is split into two reusable core frameworks, one app-side Markdown UI framework, and one iOS app shell.

In `Lumina.xcodeproj`, these are native Xcode targets:

- `AgentRuntime.framework`
- `PersonalMemory.framework`
- `LuminaMarkdownUI.framework`
- `Lumina.app`

`Package.swift` mirrors the framework products for CLI tests and reuse, but the app target links the native framework targets directly.

## AgentRuntime

`AgentRuntime` owns the execution loop:

1. Planner creates a structured `AgentPlan`.
2. `ToolRouter` validates tool availability and permission.
3. Side-effecting tools pass through `ConfirmationCoordinator`.
4. Tool execution emits streaming events.
5. Audit records are written asynchronously.
6. Failed side effects can attempt best-effort rollback.

The planner is model-agnostic. Any local model can implement `LocalStructuredInferenceModel` by returning a JSON tool plan. `CoreMLTextToJSONModel` is the Core ML adapter.

Runtime I/O is multimodal. `AgentRequest.content` and `ToolResult.content` carry text, Markdown, image, audio, video, file, and structured data parts. Markdown is the preferred format for user-facing agent output because it can preserve headings, lists, tables, code blocks, citations, and recovery actions without inventing another rich-text schema. The legacy `AgentRequest(text:)` and `ToolResult(output:)` APIs remain as convenience paths.

## PersonalMemory

`PersonalMemory` owns local-first retrieval:

1. Ingest documents into chunks immediately.
2. Make chunks searchable via keyword and metadata before embeddings finish.
3. Generate embeddings asynchronously.
4. Search with metadata filtering first, then vector/keyword ranking.
5. Persist snapshots through `MemoryRepository`.

The embedding model is also pluggable through `EmbeddingProvider`. `CoreMLEmbeddingProvider` accepts a Core ML model with `text -> MLMultiArray`.

## Lumina App

The app code in `Sources/LuminaApp` wires production dependencies in `AppEnvironment.live()`:

- `JSONMemoryRepository` for local index persistence.
- `JSONLAuditLogger` for auditable tool calls.
- local model bootstrap for Core ML planner/embedding.
- EventKit, MessageUI, ledger, subscription, and local search tools.
- multimodal request composition and rendering for Markdown, text, image, audio, video, file, and structured data.
- streaming runtime UI driven by `AgentRuntime.runStream`.

## LuminaMarkdownUI

`LuminaMarkdownUI` is an app-side rendering module built on `swift-markdown` instead of a hand-written parser. Its pipeline is:

1. Parse Markdown into the official GFM AST.
2. Convert AST nodes into stable, Sendable view models.
3. Render each block type with a dedicated SwiftUI component.
4. Cache parsed documents so repeated streaming updates and result re-renders avoid reparsing.

Supported block-level styles include headings, paragraphs, block quotes, ordered/unordered/task lists, code blocks, raw HTML blocks, tables with alignment, thematic breaks, block directives, custom blocks, and fallback blocks.
