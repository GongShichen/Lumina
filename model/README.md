# Lumina 模型资产

`model/` 是 Lumina 模型资产、训练代码和训练数据的统一本地收口目录。

## 目录结构

- `bundles/original/MiniCPMV46ReActModel/`：原始 MiniCPM-V 4.6 GGUF app bundle。
- `bundles/trained/MiniCPMV46ReActModel-AgenticSFTDPO-Q8/`：Agentic SFT+DPO 训练后的 GGUF app bundle。
- `embeddings/BGETextEmbedding/`：BGE embedding 编译模型和 tokenizer。
- `training/code/agentic_rl/`：SFT/DPO 训练包、配置、训练脚本和训练数据 QA 脚本。
- `training/data/TrainingData/`：MiniCPM-V4.6 tool-call transport SFT/DPO 训练与评估数据。

训练后的模型 bundle、训练代码和训练数据会随仓库提交；原始模型、embedding 模型、虚拟环境和缓存不提交，需要时通过脚本下载或从远端拉取。

## 常用命令

下载原始 MiniCPM-V 4.6 和 embedding 资源：

```bash
./model/lumina_model.sh download all
```

把训练后模型安装到 app 资源目录：

```bash
./model/lumina_model.sh install trained
```

把原始模型安装到 app 资源目录：

```bash
./model/lumina_model.sh install original
```

把 embedding 模型安装到 app 资源目录：

```bash
./model/lumina_model.sh install embedding
```

把当前本地已有的所有模型资源安装到 app 资源目录：

```bash
./model/lumina_model.sh install all
```

从远端训练服务器拉取训练后模型 bundle：

```bash
./model/lumina_model.sh pull-trained
```

校验模型 bundle：

```bash
./model/lumina_model.sh validate trained
```

构建 MiniCPM-V 4.6 native GGUF engine dylib：

```bash
./model/lumina_model.sh build-native-engine
```

远端模型路径可以通过 `LUMINA_TRAINED_REMOTE` 覆盖，端口可以通过 `LUMINA_TRAINED_REMOTE_PORT` 覆盖。

## 模型训练

训练基座是 MiniCPM-V 4.6。训练流程为 MiniCPM-V4.6 special-token/tool-call transport SFT、holdout 检查、standard DPO、LoRA 合并回 base model、GGUF Q8 转换。

SFT/DPO 均为 LoRA 微调，主要训练 language modules，并冻结 vision、visual、projector、resampler 等视觉相关模块。

数据规模：

- SFT train/test/evaluation：50,844 / 6,351 / 6,351
- DPO train/test/evaluation：41,126 / 5,139 / 5,139
- 上下文窗口：16,000 tokens
- 当前提交的数据为 text/tool-only，仅从公开 parquet/metadata 抽取；SFT 与 DPO public sources 不相交，覆盖英文与中文，以及 intent recognition、multi-turn rewrite、knowledge retrieval、tool use、agent multi-hop 和 observation-driven multi-turn tool use。
- MiniCPM special token 清单：`training/data/TrainingData/minicpm_special_tokens.json`。

训练数据 QA：

```bash
python3 model/training/code/agentic_rl/scripts/qa_training_xml_data.py --root model/training/data/TrainingData
```

