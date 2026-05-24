# Lumina Integration Notes

`Sources/LuminaApp` 是 Lumina iOS App target 源码目录，不参与 SwiftPM 的 macOS 单元测试构建。可测试的领域逻辑放在 `Sources/LuminaAppCore`，UI、App Intents、UIKit 桥接和真实系统权限适配留在 App target。

当前 App target 分层：

- `Application`：app entry、service assembly、环境配置和 runtime bootstrap。
- `DesignSystem`：C 端 Lumina 视觉系统。
- `Features`：Today、Memory、Activity、Trust、Permissions 等用户场景。
- `Intents`：薄 App Intents / App Shortcuts system surface。
- `Models`：App UI 层数据模型。
- `Platform`：Message compose 等系统桥接。

在 Xcode 中维护 target 时：

1. `Lumina` App target 链接并嵌入 `AgentRuntime`、`PersonalMemory`、`LuminaModelRuntime`、`LuminaMarkdownUI`、`LuminaAppCore`。
2. `LuminaAppCore` 只保留 deterministic tools/stores，保证 `swift test` 可重复。
3. `Info.plist` 必须保留 `UILaunchScreen`，否则现代 iPhone 模拟器会 letterbox。
4. deployment target 设为 iOS 26。

性能路径：

- App 启动不等待 memory index 初始化。
- `LuminaMemoryStore.ingest(_:)` 立即写入 chunk，后台异步生成 embedding。
- `LuminaMemoryStore.search(_:)` 先执行 `LuminaMemorySearchFilter` metadata filter，再用 `LuminaMemorySearchRanker` 融合 keyword/vector 结果，最近查询由 `LuminaMemorySearchCache` 做短期缓存。
- `LuminaMemoryStore` 只作为 actor 并发边界；chunk/index mutation 在 `LuminaMemoryIndex`，embedding 后台优先级在 `LuminaEmbeddingScheduler`。
- 所有 runtime/tool 调用通过 Swift concurrency 支持取消。

Agent Runtime 路径：

- `LuminaAgentRuntime` actor 负责 run lifecycle、streaming events、取消、预算和终止状态。
- ReAct 子系统拆分为 `LuminaReActTypes`、`LuminaReActPlanner`、`LuminaStructuredReActPrompt`、`LuminaReActStepParser`、`LuminaReActObservationCompressor`。
- action 必须是结构化 `LuminaToolCall`，工具执行仍统一经过 `LuminaToolRouter`、`LuminaPermissionGate`、`LuminaConfirmationCoordinator`、`LuminaAuditLogger`。
- `AgentRuntime` 不包含 Core ML 具体推理实现；它只依赖 `LuminaLocalStructuredInferenceModel` 等协议。
- `PersonalMemory` 不包含 BGE/Core ML 具体实现；它只依赖 `LuminaEmbeddingProvider` 协议。

本地模型接口：

- Planner 模型走通用 `LuminaLocalStructuredInferenceModel`，Core ML 适配器是 `LuminaCoreMLTextToJSONModel`。
- `LuminaCoreMLTextToJSONModel` 位于 `LuminaModelRuntime` framework。
- 默认 bundle 文件名是 `Gemma4Planner.mlmodelc` 或 `LocalPlanner.mlmodelc`，输入名 `prompt`，输出名 `json`。
- Embedding 模型走通用 `LuminaEmbeddingProvider`，Core ML 适配器是 `LuminaCoreMLEmbeddingProvider`。
- `LuminaCoreMLEmbeddingProvider` / `LuminaBGECoreMLEmbeddingProvider` 位于 `LuminaModelRuntime` framework。
- 默认 bundle 文件名优先 `BGETextEmbedding.mlmodelc`，再降级到 `Gemma4Embedding.mlmodelc` / `LocalEmbedding.mlmodelc`，输入名 `text`，输出名 `embedding`。
- Gemma 4 Core ML 可以作为上述接口的一个实现；为了迁移方便，bootstrap 也兼容 `Gemma4Planner.mlmodelc` 和 `Gemma4Embedding.mlmodelc`。
