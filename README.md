# Lumina Agent Runtime

Lumina Agent Runtime 是一个面向端侧 Agent 的 Runtime。它把模型输出、工具 schema、权限确认、上下文、审计、事件流和 session 状态组织成一套稳定的执行契约，让宿主应用可以在端侧运行可控、可观察、可恢复的 Agent。

![Lumina Agent Runtime 架构](docs/lumina-agent-runtime-architecture.png)

## Runtime SDK

Runtime Core 是跨端的 C/C++ 执行核心。宿主提供模型、工具、上下文和 UI 策略；Runtime 负责把用户请求组织成 planner input，循环调用模型、校验 ReAct step、执行工具、写入 observation，并在 `result`、`cannot_complete`、失败、暂停或取消时结束。

Runtime canonical ReAct step 使用 `reasoning`、`tool_discovery`、`tool_use`、`multi_tool_use`、`ask_user`、`result`、`cannot_complete`。模型侧不输出 `result` 标签；最终回答是普通 assistant text，Runtime 在内部归一化为 `result`。旧 `final_answer` schema 不兼容。

## 核心能力

- **ReAct Loop**：解析 blocking 或 streaming model callback，并执行 dialect normalization、schema validation 和工具调度。
- **Tool Registry**：管理工具 schema、参数校验、副作用、权限确认、幂等策略和 external provider。
- **Deferred Tool Loading**：模型可通过 `tool_discovery` 按需加载完整工具 schema，避免首轮 prompt 过大。
- **Progressive Context Loading**：memory、文件、知识库和历史会话由宿主拥有，Runtime 只维护当前 session 的 loaded context。
- **Context Budget & Compaction**：按 provider/model context window 动态管理预算；宿主可替换 compaction provider。
- **Session / Checkpoint / Replay**：支持 session 状态、checkpoint、snapshot、cancel、resume 和 replay。
- **Hooks & Guardrails**：宿主可在请求、工具输入输出、result 输出前做拦截、确认、拒绝或暂停。
- **Observability**：event、trace、metrics、audit、span、snapshot 都是可选 sink，未注册时不强制持久化。

## 端侧接入

接入 Runtime 的核心是同一套 JSON contract 和 C ABI。iOS 可以直接使用 Swift Package；Android / HarmonyOS 通过 native binding 或 C ABI 接入 Core。

### iOS

通过 Swift Package 引入 `LuminaAgentRuntime`，并提供 model、tools、context、permission、confirmation，以及可选 hook、guardrail、observability、retry、context loading 和 tool loading provider。

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

### HarmonyOS

HarmonyOS 侧通过 ETS wrapper 调用 native runtime。将 Runtime Core 源码、`Runtime/include` 头文件和 `Bindings/HarmonyOS/native/lumina_runtime_harmony.cpp` 加入 native module，并链接 N-API。

## 模型推理部署与量化

本节介绍 MiniCPM-V 4.6 的端侧 GGUF 推理接入、native engine 构建、App 资源安装和离线量化。

### 环境要求

- macOS 与 Xcode
- Python 3
- Git、CMake、rsync
- Hugging Face CLI：`python3 -m pip install -U huggingface_hub`
- llama.cpp GGUF 转换依赖：`python3 -m pip install -r <llama.cpp>/requirements.txt`

### 下载预量化 GGUF

默认从 `openbmb/MiniCPM-V-4_6-gguf` 下载 F16 text model 和 F16 multimodal projector：

```bash
./model/lumina_model.sh download original
```

可通过环境变量选择仓库和量化文件：

```bash
LUMINA_MINICPMV46_REPO=openbmb/MiniCPM-V-4_6-gguf \
LUMINA_MINICPMV46_QUANT=Q8_0 \
./model/lumina_model.sh download original
```

下载结果位于：

```text
model/bundles/original/MiniCPMV46ReActModel/
├── model.gguf
├── mmproj-model-f16.gguf
├── model_config.json
├── libLuminaMiniCPMV46GGUFEngine.dylib
└── libllama / libggml dylibs
```

### 构建推理引擎

MiniCPM-V 4.6 在 App 内通过 `app/NativeEngines/MiniCPMV46/LuminaMiniCPMV46GGUFEngine.cpp` 和 llama.cpp/ggml 执行。单独构建 native engine：

```bash
./model/lumina_model.sh build-native-engine
```

将 engine 写入指定 bundle：

```bash
LUMINA_MINICPMV46_OUTPUT_DIR=/absolute/path/to/MiniCPMV46ReActModel \
./model/lumina_model.sh build-native-engine
```

需要 hardened runtime 时可指定签名身份：

```bash
LUMINA_CODESIGN_IDENTITY="Apple Development: Your Name" \
./model/lumina_model.sh build-native-engine
```

### 安装到 App

校验并安装 MiniCPM-V bundle：

```bash
./model/lumina_model.sh validate original
./model/lumina_model.sh install original
```

模型会复制到 `app/Resources/Models/MiniCPMV46ReActModel/`，并在 Xcode 构建时作为本地资源打包。

安装 embedding：

```bash
./model/lumina_model.sh download embedding
./model/lumina_model.sh install embedding
```

安装全部本地推理资源：

```bash
./model/lumina_model.sh download all
./model/lumina_model.sh install all
```

构建 Mac Catalyst App：

```bash
xcodebuild -project app/Lumina.xcodeproj \
  -scheme Lumina \
  -destination 'platform=macOS,variant=Mac Catalyst' \
  -configuration Debug build
```

开发环境也可以直接指定外部模型目录，避免复制权重。在 Xcode Scheme 的 Run 环境变量中设置：

```text
LUMINA_MINICPMV46_ORIGINAL_MODEL=/absolute/path/to/MiniCPMV46ReActModel
```

### 从 Hugging Face 权重量化

`model/quantize_minicpmv46.sh` 接收本地 Hugging Face 格式目录，先转换为 F16 GGUF，再使用 llama.cpp 生成目标量化文件。输入目录可以来自 ModelScope、Hugging Face 或本地导出，但必须包含 `config.json` 和模型分片。

准备 llama.cpp：

```bash
git clone --depth 1 https://github.com/ggml-org/llama.cpp .build/vendor/llama.cpp
python3 -m pip install -r .build/vendor/llama.cpp/requirements.txt
```

生成 Q8_0 bundle：

```bash
LUMINA_PROJECTOR_GGUF=/absolute/path/to/mmproj-model-f16.gguf \
./model/quantize_minicpmv46.sh \
  /absolute/path/to/hf-model \
  /absolute/path/to/MiniCPMV46ReActModel-Q8 \
  Q8_0
```

常用量化类型：

| 类型 | 体积 | 精度 | 适用场景 |
| --- | --- | --- | --- |
| `Q8_0` | 较大 | 最高 | 桌面端与高内存设备 |
| `Q6_K` | 中等偏大 | 高 | 精度和内存折中 |
| `Q5_K_M` | 中等 | 较高 | 常规端侧部署 |
| `Q4_K_M` | 较小 | 中等 | 内存受限设备 |

文本模型可以量化，`mmproj-model-f16.gguf` 保持 F16。完成后校验并安装自定义 bundle：

```bash
LUMINA_ORIGINAL_BUNDLE_DIR=/absolute/path/to/MiniCPMV46ReActModel-Q8 \
./model/lumina_model.sh validate original

LUMINA_MINICPMV46_OUTPUT_DIR=/absolute/path/to/MiniCPMV46ReActModel-Q8 \
./model/lumina_model.sh build-native-engine

LUMINA_ORIGINAL_BUNDLE_DIR=/absolute/path/to/MiniCPMV46ReActModel-Q8 \
./model/lumina_model.sh install original
```

### Bundle 校验

任意 MiniCPM-V bundle 都可以直接校验：

```bash
./model/lumina_model.sh validate /absolute/path/to/MiniCPMV46ReActModel
```

校验器会检查 `model.gguf`、`mmproj-model-f16.gguf`、`model_config.json`、context length 和配置中的文件映射。
