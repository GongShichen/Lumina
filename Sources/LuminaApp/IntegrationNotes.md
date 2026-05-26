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

1. `Lumina` App target 链接并嵌入 `LuminaAgentRuntime`、`LuminaAgentClient`、`PersonalMemory`、`LuminaModelRuntime`、`LuminaMarkdownUI`、`LuminaAppCore`。
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

- `LuminaAgentRuntime` 是纯 C/C++ framework，只暴露稳定 C ABI；目录内不放 Swift、ObjC、UIKit/EventKit 等平台代码。
- C++ runtime 负责 session lifecycle、typed task envelope、streaming model callback、ReAct step validation、tool routing、permission/confirmation、observation、audit、rollback、context budget、pause/resume 和 trace export。
- `LuminaAgentClient` 是 App 侧 Swift adapter：负责把 Swift tools、model、context provider、permission gate、confirmation coordinator、audit logger 和 hooks 转成 C callback。它不是 runtime 的一部分。
- action 必须是结构化 ReAct transport，工具执行仍统一经过 C++ runtime 的 schema validation、permission、confirmation 和 observation 生成。
- `LuminaAgentRuntime` 不包含 Core ML / MiniCPM-V 具体推理实现，不包含 App system prompt，也不包含 memory 策略。
- `PersonalMemory` 不包含 BGE/Core ML 具体实现；它只依赖 `LuminaEmbeddingProvider` 协议。

本地模型接口：

- Model 模型走通用 `LuminaLocalDynamicOutputStreamingStructuredInferenceModel`，当前 App 注入的适配器是 `LuminaMiniCPMV46ReActModel`。
- `LuminaMiniCPMV46ReActModel` 位于 `LuminaModelRuntime` framework，并通过 `LuminaModelBackedReActStepGenerator` 接入 `LuminaAgentClient`，再由 `LuminaAgentClient` 接入纯 C++ `LuminaAgentRuntime`。
- 默认 planner bundle 文件名是 `MiniCPMV46ReActModel/`，内部包含 `model.gguf`、`mmproj-model-f16.gguf` 和 `model_config.json`。
- Embedding 模型走通用 `LuminaEmbeddingProvider`，Core ML 适配器是 `LuminaCoreMLEmbeddingProvider`。
- `LuminaCoreMLEmbeddingProvider` / `LuminaBGECoreMLEmbeddingProvider` 位于 `LuminaModelRuntime` framework。
- 默认 embedding bundle 文件名优先 `BGETextEmbedding.mlmodelc`，再降级到 `LocalEmbedding.mlmodelc`，输入名 `text`，输出名 `embedding`。
- MiniCPM-V 4.6 GGUF 是 planner 默认模型；`LuminaAgentRuntime` 只看到外部 model callback 返回的标准 ReAct JSON，不知道具体模型实现。
