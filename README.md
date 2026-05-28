# Lumina Agent Runtime

Lumina Agent Runtime 是一个面向端侧 Agent 的 Runtime。它负责 ReAct 执行循环、工具注册与调度、权限检查、用户确认、审计记录和运行时事件。

Lumina Agent Runtime 架构

## Runtime 概览

Runtime 将模型输出转换为结构化 ReAct step，校验 step，按工具 schema 路由工具调用，并把工具结果整理成 observation 反馈给下一轮规划。宿主应用负责提供模型适配器和具体工具实现；Runtime 负责围绕这些能力建立稳定的执行契约。

核心职责：

- 根据用户请求、上下文、trace、预算和已注册工具 schema 组装 planner input。
- 消费 blocking 或 streaming model callback，生成标准 ReAct step。
- 在工具执行前校验参数、执行权限和确认策略。
- 将工具结果校验、脱敏、截断，并整理成 observation。
- 记录 audit、runtime events、hooks 和 trace，便于调试、评估与回放。
- 通过稳定的 Runtime 契约接入宿主应用。

## Runtime 架构

Runtime 包含 session loop、planner input builder、ReAct transport、tool registry、tool executor、context/budget manager、trace recorder、audit/event callbacks、contract export，以及 status/cancellation 处理。Core loop 支持 reasoning、tool discovery、tool use、只读 multi-tool use、ask_user、final answer 和 cannot-complete 状态。

宿主应用只需要提供模型适配器、工具实现、上下文加载、权限/确认策略和事件消费。Runtime 负责把这些能力组织成一次可控、可审计、可回放的 Agent 执行过程。

一次任务的执行流：

1. 宿主应用把 request 送入 Runtime session。
2. Runtime 从 request、context、tool schemas、trace 和 budget 组装 planner input。
3. Model adapter 返回结构化 ReAct step。
4. Runtime 校验 step，执行 permission / confirmation 策略，并调度工具调用。
5. 工具结果被校验、审计脱敏、按策略去重回放，并转换成 observation。
6. Observation 进入下一轮规划，直到 final answer、failure 或 cancellation。

## 开箱即用

接入 Agent Runtime 的核心是同一套执行契约，而不是某一个具体 UI 或端侧框架。宿主应用需要提供模型适配器、工具实现、上下文来源、权限/确认策略，并消费 Runtime 事件流。

最小接入流程：

1. 定义工具 schema，描述工具名称、参数、副作用和敏感字段。
2. 实现工具 provider，把 Runtime 的 tool call 映射到真实系统或应用能力。
3. 接入 model adapter，返回结构化 ReAct step。
4. 配置 permission / confirmation / audit / event sink。
5. 创建 Runtime session，发送 request，并监听运行事件和最终结果。

iOS、Android 和 HarmonyOS 都按这套 Runtime 契约接入：端侧负责提供本地工具与系统能力，Runtime 负责规划输入、ReAct step 校验、工具调度、observation 回传、审计和事件流。

### iOS

通过 Swift Package 引入 `LuminaAgentRuntime`，在宿主侧提供 tools、step generator 和 runtime policy：

```swift
let runtime = LuminaAgentRuntime(
    tools: tools.map(AnyLuminaAgentTool.init),
    stepGenerator: stepGenerator,
    configuration: configuration
)

for await event in runtime.runStream(request: request) {
    // 更新 UI、观察工具事件或收集运行状态。
}
```

### Android

Android 侧使用 Runtime Core 的 CMake 构建，并打开 JNI 入口：

```bash
cmake -S LuminaAgentRuntime -B build/android-arm64 \
  -DCMAKE_TOOLCHAIN_FILE=$ANDROID_NDK_HOME/build/cmake/android.toolchain.cmake \
  -DANDROID_ABI=arm64-v8a \
  -DANDROID_PLATFORM=android-26 \
  -DLUMINA_BUILD_ANDROID_JNI=ON \
  -DLUMINA_BUILD_LINUX_SAMPLE=OFF

cmake --build build/android-arm64
```

宿主侧实现 model、tool、context、permission、confirmation、event、audit 方法，并把 JSON 字符串传给 Runtime：

```kotlin
val runtime = LuminaAgentRuntime(configurationJson, providers)
runtime.registerToolSchema(calendarSchemaJson)
val resultJson = runtime.run(requestJson)
runtime.cancel(requestId)
```

### HarmonyOS

HarmonyOS 侧使用 ETS wrapper 调用 native runtime。编译时需要把 Runtime Core 源码、`Runtime/include` 头文件，以及 `Bindings/HarmonyOS/native/lumina_runtime_harmony.cpp` 加入 Harmony native module，并链接 N-API。

ETS 侧提供 `LuminaRuntimeProviders`，把模型、工具、上下文、权限、确认、事件和审计回调交给 Runtime：

```ts
const runtime = new LuminaAgentRuntime(configurationJson, providers)
runtime.registerToolSchema(calendarSchemaJson)
const resultJson = runtime.run(requestJson)
runtime.cancel(requestId)
runtime.close()
```

## Runtime 核心概念

- **Tool Schema**：描述工具名称、参数、副作用、敏感性、幂等策略和展示信息。
- **Tool Call / Tool Result**：Runtime 与宿主工具适配层之间的 JSON 契约。
- **ReAct Step**：模型生成的结构化动作、思考、提问或最终回答。
- **Permission & Confirmation**：决定工具调用可以直接执行、需要用户确认，还是必须拒绝。
- **Audit & Events**：暴露运行过程，用于调试、检查、benchmark 和信任链路展示。
- **Trace & Contracts**：支持导出执行 trace 和 Runtime contract，帮助宿主侧保持一致行为。
- **Conformance Tests**：验证 Runtime contract 和核心执行行为。

## Lumina App

app 用来演示端侧 Agent 如何在真实界面中完成任务。用户可以输入自然语言请求，Agent 会根据目标规划步骤、选择合适工具、执行系统或应用能力，并把中间状态和最终结果反馈到界面中。

这个 app 覆盖了几类典型能力：对话式任务入口、真实工具调用、用户确认、权限申请、本地或远程推理配置，以及真实任务 benchmark。它的重点不是提供一套固定产品功能，而是展示 Runtime 如何被宿主应用接入、驱动和观察。

## Setup & Run App

要求：

- 已安装 Xcode 的开发环境。
- Swift Package 支持。
- 可运行 iOS App 的真机设备。

用 Xcode 运行：

1. 打开 `app/Lumina.xcodeproj`。
2. 选择 `Lumina` scheme。
3. 选择已连接的 iPhone 或 iPad。
4. Build & Run。

本地推理依赖设备侧加速能力，推荐在真机上运行。iOS Simulator 可以用于部分 UI 或编译检查，但不能完整验证 MPS / ANE 推理路径。

命令行构建真机版本：

```bash
xcodebuild -project app/Lumina.xcodeproj \
  -scheme Lumina \
  -destination 'generic/platform=iOS' \
  -configuration Debug build
```

运行 Runtime 测试：

```bash
swift test --package-path LuminaAgentRuntime
```
