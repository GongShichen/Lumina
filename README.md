# LocalAgentRuntime

性能体验优先的本地 iOS Agent MVP 骨架。

## Targets

- `AgentRuntime`: planner、tool router、权限 gate、人类确认、rollback、审计日志。
- `PersonalMemory`: 本地 chunk、metadata filter、异步 embedding、轻量向量检索。
- `LuminaMarkdownUI`: 基于 `swift-markdown` AST 的高性能 Markdown 渲染模块。
- `Sources/LuminaApp`: 可加入 iOS App target 的 SwiftUI / App Intents 宿主代码。

## Quick Check

```sh
swift test
```

或运行完整检查：

```sh
./scripts/check.sh
```

## iOS App 集成

在 Xcode 中创建一个名为 Lumina 的 iOS App target 后，把 `Sources/LuminaApp` 加入 App target，并把 package products `AgentRuntime`、`PersonalMemory`、`LuminaMarkdownUI` 链接到 App。该目录包含 EventKit、MessageUI、AppIntents 相关实现，核心 package 保持跨平台可测。

仓库里的 `Lumina.xcodeproj` 已经是主工程。Xcode 工程包含 4 个 native targets：

- `AgentRuntime.framework`
- `PersonalMemory.framework`
- `LuminaMarkdownUI.framework`
- `Lumina.app`

App target 直接依赖这三个 framework target。`Package.swift` 仍然保留对应 library products，用于命令行测试、复用和 CI。

如果修改了 `project.yml`，可以重新生成工程：

```sh
xcodegen generate
```

## 工程文档

- `docs/ARCHITECTURE.md`: framework 和 App 的边界。
- `docs/MODEL_CONTRACTS.md`: 通用本地模型 / Core ML 接口约定。
- `docs/PERFORMANCE.md`: 端侧性能策略。

## 本地模型接口

Agent planner 使用通用协议 `LocalStructuredInferenceModel`，只要求模型把 prompt 转成 JSON tool plan。Core ML 适配器是 `CoreMLTextToJSONModel`，默认约定：

- bundle 文件：`LocalPlanner.mlmodelc`
- 输入：`prompt`，类型 String
- 输出：`json`，类型 String

Personal Memory embedding 使用通用协议 `EmbeddingProvider`。Core ML 适配器是 `CoreMLEmbeddingProvider`，默认约定：

- bundle 文件：`LocalEmbedding.mlmodelc`
- 输入：`text`，类型 String
- 输出：`embedding`，类型 MLMultiArray

Gemma 4 Core ML 可以作为这些接口的一个实现；Lumina 的 bootstrap 也兼容 `Gemma4Planner.mlmodelc` / `Gemma4Embedding.mlmodelc` 文件名。

## 全模态 Agent I/O

`AgentRuntime` 支持 text、markdown、image、audio、video、file、structuredData：

- 输入：`AgentRequest(content:)`
- 输出：`ToolResult(content:)`
- Markdown 输出：`AgentContentPart.markdown(_:)`，用于 agent 最终答复、检索引用、表格、代码块和工具结果摘要。
- 媒体引用：`AgentMediaAsset`
- 模型接口：`LocalMultimodalStructuredInferenceModel`

旧的 `AgentRequest(text:)` / `ToolResult(output:)` 仍然可用。

Lumina App 也支持全模态：

- 输入侧：文本、照片/视频选择器、文件导入器。
- 输出侧：统一渲染 `ToolResult.content`，包括 Markdown、文本、图片、音频、视频、文件和结构化数据。
- 流式执行：订阅 `AgentRuntime.runStream`，实时显示 planning、权限、确认、工具执行、rollback 和最终状态。
- 工具侧：`media.import` 可把用户输入的媒体附件导入本地记忆。

## Markdown 输出

Runtime 的推荐自然语言输出格式是 Markdown。Lumina App 使用 `LuminaMarkdownUI` 渲染，不再维护自定义轻量 parser；解析层基于 `swift-markdown` / GFM AST，支持 heading、paragraph、blockquote、ordered/unordered/task list、code block、HTML block、table、thematic break、directive、custom/fallback block。每类 block 都有独立 SwiftUI 样式，解析结果缓存，长回答用 `LazyVStack` 渲染，代码块和表格走横向滚动。
