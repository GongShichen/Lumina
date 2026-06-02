# Lumina Agent Runtime

Lumina Agent Runtime 是一个面向端侧 Agent 的 Runtime。它把模型输出、工具 schema、权限确认、上下文、审计、事件流和 session 状态组织成一套稳定的执行契约，让宿主应用可以在端侧运行可控、可观察、可恢复的 Agent。

![Lumina Agent Runtime 架构](docs/lumina-agent-runtime-architecture.png)

## Runtime 概览

Runtime Core 是跨端的 C/C++ 执行核心。宿主负责提供模型、工具和 UI 策略，Runtime 负责执行循环与契约治理：

- 组装 planner input：用户请求、上下文、工具 schema、trace、预算和历史 observation。
- 消费 blocking 或 streaming model callback，解析并校验 canonical ReAct step。
- 调度工具调用，执行参数校验、权限检查、用户确认和幂等控制。
- 将 tool result 转成 runtime-owned observation，模型不得伪造 observation。
- 管理 session、checkpoint、snapshot、cancel、resume 和 replay。
- 根据 provider/model 的上下文窗口动态管理预算，并在接近上限或 prompt-too-long 时压缩上下文。
- 通过可选 sinks 暴露 event、trace、metrics、audit、span，未注册时不强制持久化。
- 通过 hook、guardrail、retry provider 和 compaction provider 让宿主控制运行时行为。

Canonical ReAct step 使用 `reasoning`、`tool_discovery`、`tool_use`、`multi_tool_use`、`ask_user`、`result`、`cannot_complete`。最终产物统一是 `result`，不接受 `final_answer`。

## Runtime 架构

一次任务的执行流：

1. 宿主创建 Runtime session，并传入 Agent request。
2. Runtime 读取 context、state、tool schemas 和 budget，生成 planner input。
3. Model provider 返回 ReAct step；Runtime 完成 dialect normalization 和 schema validation。
4. Hook / guardrail 可以在固定 lifecycle 点拦截、补上下文、改写工具调用、拒绝或暂停。
5. Tool registry 根据 schema 路由工具调用；permission / confirmation 决定是否执行。
6. Tool result 被校验、脱敏、截断，并记录为 observation。
7. Runtime 继续下一轮规划，直到 `result`、`cannot_complete`、failure、pause 或 cancellation。

核心能力：

- **Tool Registry & Executor**：工具 schema、参数校验、副作用、幂等策略、external provider。
- **Session / Checkpoint / Replay**：Core 导出 checkpoint JSON，宿主负责持久化；replay 可固定 model output 或 tool observation。
- **RuntimeState**：`temp`、`session`、`user`、`app` 四类 scope；模型不能直接写 state。
- **Context Budget & Compaction**：从 provider/model 读取 `max_context_tokens`，动态计算可用窗口和压缩阈值；默认先清理大型工具结果，再按预算摘要压缩。
- **RuntimeHook**：按 lifecycle、tool name、sensitivity、side effect 匹配；支持 proceed、append context、rewrite、reject、require confirmation、pause、fail。
- **Guardrails**：request 入站、tool 输入、tool 输出、result 输出前的策略校验。
- **Retry Provider**：Core 暴露 retry request / decision contract，默认策略处理 provider、normalization、tool execution 的可重试失败。
- **Observability**：event、trace、metrics、audit、span、snapshot 都是可插拔接口，外部按需订阅。

## 上下文压缩

上下文压缩是 Runtime Core 的可插拔能力，不依赖某一端的 UI 或模型实现。Runtime 优先通过 `LuminaAgentModelMetadataCallback` 从当前 provider/model metadata 读取 `max_context_tokens`、`model_id` 和 `provider_native_context_management`；如果 provider 不提供，才使用宿主配置的 fallback 窗口。

预算计算：

```text
effective_context_window = max_context_tokens - reserved_output_tokens
auto_compact_threshold = effective_context_window - auto_compact_buffer_tokens
```

默认 pipeline 参考 Claude Code 风格，按顺序执行：

- `snip_projection`：过滤已隐藏、已移除或不应暴露给模型的历史片段。
- `microcompact`：优先清理旧的大型工具结果和历史大段 context，保留工具调用结构、摘要和最近 observation。
- `provider_native`：如果模型 provider metadata 声明支持原生上下文管理，则允许 provider 自己清理 tool result / thinking。
- `summarizing_compact`：超过动态阈值时，把旧上下文压缩成 compact summary，并保留最近上下文。
- `partial_summarize`：支持只压缩一段历史窗口。
- `reactive_compact`：模型请求因为 prompt-too-long 失败时触发恢复压缩。

宿主可以注册 `LuminaAgentCompactionProviderCallback`，替换完整 pipeline 或只处理某个 strategy；返回 `{"status":"skipped"}` 时 Core 会继续执行默认策略。压缩请求会携带 redacted `context_frame`、`trace_summary`、`tool_result_candidates` 和预算快照；API key、token、secret 会在进入 compaction payload 前脱敏。压缩事件、边界、tokens saved estimate 和失败原因会通过可选 observability sinks 暴露，未注册 sink 时不做持久化输出。

## 开箱即用接入

接入 Runtime 的核心是同一套 JSON contract 和 C ABI。iOS 可以直接使用 Swift Package；Android / HarmonyOS 通过 native binding 或 C ABI 接入 Core。

### iOS

通过 Swift Package 引入 `LuminaAgentRuntime`，提供 tools、model、context、permission、confirmation，以及可选 context compactor / hook / guardrail / observability / retry provider：

```swift
let runtime = LuminaAgentRuntime(
    tools: tools.map(AnyLuminaAgentTool.init),
    stepGenerator: stepGenerator,
    contextProvider: contextProvider,
    contextCompactor: contextCompactor,
    configuration: configuration,
    permissionGate: permissionGate,
    confirmationCoordinator: confirmation,
    hooks: hooks,
    observabilitySinks: sinks,
    guardrails: guardrails,
    retryProvider: retryProvider
)

for await event in runtime.runStream(request: request) {
    // 更新 UI、记录指标或展示工具执行状态。
}
```

运行测试：

```bash
swift test --package-path LuminaAgentRuntime
```

### Android

Android 侧使用 Runtime Core 的 CMake 构建，并打开 JNI binding：

```bash
cmake -S LuminaAgentRuntime -B build/android-arm64 \
  -DCMAKE_TOOLCHAIN_FILE=$ANDROID_NDK_HOME/build/cmake/android.toolchain.cmake \
  -DANDROID_ABI=arm64-v8a \
  -DANDROID_PLATFORM=android-26 \
  -DLUMINA_BUILD_ANDROID_JNI=ON \
  -DLUMINA_BUILD_LINUX_SAMPLE=OFF

cmake --build build/android-arm64
```

宿主侧实现 model、tool、context、permission、confirmation、guardrail、compaction、hook、event、trace、metrics、audit 等 JSON callback，然后注册工具 schema 并运行：

```kotlin
val runtime = LuminaAgentRuntime(configurationJson, providers)
runtime.registerToolSchema(calendarSchemaJson)
val resultJson = runtime.run(requestJson)
val checkpoint = runtime.exportSessionCheckpoint(session)
runtime.cancel(requestId)
```

### HarmonyOS

HarmonyOS 侧通过 ETS wrapper 调用 native runtime。编译时把 Runtime Core 源码、`Runtime/include` 头文件，以及 `Bindings/HarmonyOS/native/lumina_runtime_harmony.cpp` 加入 native module，并链接 N-API。

ETS 侧提供 providers，把模型、工具、上下文、权限、确认、压缩、事件和审计回调交给 Runtime：

```ts
const runtime = new LuminaAgentRuntime(configurationJson, providers)
runtime.registerToolSchema(calendarSchemaJson)
const resultJson = runtime.run(requestJson)
const snapshot = runtime.snapshotSession(session)
runtime.cancel(requestId)
runtime.close()
```

## Observability 与 Benchmark

Runtime 不内置 benchmark scoring。Benchmark 是外部 harness，通过 public APIs、events、trace、metrics、snapshot、checkpoint 和 replay 接入。

仓库中提供了外部 benchmark harness 示例：`LuminaAgentRuntime/Examples/ExternalBenchmarkHarness`。它可以通过自定义 sink 计算：

- runtime status、task completion、contract failure。
- tool exact match、micro precision / recall / F1。
- semantic pass、pass@1、tool execution@1。
- TTFT、step p95、tool p95、wall-clock p95。
- retry count、fallback count、normalization failure rate、replay diff。

观测 payload 默认遵守 redaction：API key、secret、token 不进入 event、trace、audit、metrics 或 benchmark report。

## Lumina App

Lumina App 展示端侧 Agent 的完整使用体验：

- Chat 入口：用户输入自然语言任务，Agent 规划步骤并返回最终结果。
- 真实工具执行：日历、提醒、联系人、通知、位置、文件、网页、剪贴板、消息草稿等工具能力。
- 权限与确认：在执行敏感或有副作用工具前触发系统权限和用户确认。
- 推理设置：Settings 中配置本地推理或 OpenAI-compatible 远程流式 API。
- Benchmark：运行真实任务集，报告 F1、recall、pass@1、tool execution@1、P95、retry / fallback 等指标。
- Trust / Debug：受代码开关控制，用于查看 runtime trace、checkpoint、observability 和诊断信息。

## Setup & Run App

要求：

- 安装 Xcode。
- 可运行 iOS App 的真机设备。
- Swift Package 支持。

用 Xcode 运行：

1. 打开 `app/Lumina.xcodeproj`。
2. 选择 `Lumina` scheme。
3. 选择已连接的 iPhone 或 iPad。
4. Build & Run。

本地推理依赖设备侧加速能力，推荐在真机上运行。iOS Simulator 可以用于 UI 和编译检查，但不能完整验证 MPS / ANE 推理路径。

命令行构建真机版本：

```bash
xcodebuild -project app/Lumina.xcodeproj \
  -scheme Lumina \
  -destination 'generic/platform=iOS' \
  -configuration Debug build
```

命令行构建模拟器版本：

```bash
xcodebuild -project app/Lumina.xcodeproj \
  -scheme Lumina \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -configuration Debug build
```
