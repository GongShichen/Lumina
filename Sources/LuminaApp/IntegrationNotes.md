# Lumina Integration Notes

`Sources/LuminaApp` 是 Lumina iOS App target 源码目录，不参与 SwiftPM 的 macOS 单元测试构建。

在 Xcode 中创建 iOS App target 后：

1. 将此目录下的 Swift 文件加入 App target。
2. 链接 package products `AgentRuntime` 和 `PersonalMemory`。
3. 合并 `Info.plist` 里的 Calendar / Reminder 权限说明。
4. 将 deployment target 设为 iOS 26。

性能路径：

- App 启动不等待 memory index 初始化。
- `MemoryStore.ingest(_:)` 立即写入 chunk，后台异步生成 embedding。
- `MemoryStore.search(_:)` 先执行 metadata filter，再融合 keyword/vector 结果。
- 所有 runtime/tool 调用通过 Swift concurrency 支持取消。

本地模型接口：

- Planner 模型走通用 `LocalStructuredInferenceModel`，Core ML 适配器是 `CoreMLTextToJSONModel`。
- 默认 bundle 文件名是 `LocalPlanner.mlmodelc`，输入名 `prompt`，输出名 `json`。
- Embedding 模型走通用 `EmbeddingProvider`，Core ML 适配器是 `CoreMLEmbeddingProvider`。
- 默认 bundle 文件名是 `LocalEmbedding.mlmodelc`，输入名 `text`，输出名 `embedding`。
- Gemma 4 Core ML 可以作为上述接口的一个实现；为了迁移方便，bootstrap 也兼容 `Gemma4Planner.mlmodelc` 和 `Gemma4Embedding.mlmodelc`。
