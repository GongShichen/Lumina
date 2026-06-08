# Lumina 模型资产

`model/` 是 Lumina 模型资产、训练代码和训练数据的统一本地收口目录。

## 目录结构

- `bundles/original/MiniCPMV46ReActModel/`：原始 MiniCPM-V 4.6 GGUF app bundle。
- `bundles/trained/MiniCPMV46ReActModel-AgenticSFTDPO-Q8/`：Agentic SFT+DPO 训练后的 GGUF app bundle。
- `embeddings/BGETextEmbedding/`：BGE embedding 编译模型和 tokenizer。
- `training/code/agentic_rl/`：SFT/DPO 训练包、配置、训练脚本和训练数据 QA 脚本。
- `training/data/TrainingData/`：XML ReAct SFT/DPO 训练与评估数据。

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

训练基座是 MiniCPM-V 4.6。训练流程为 XML ReAct SFT、holdout 检查、standard DPO、LoRA 合并回 base model、GGUF Q8 转换。

SFT/DPO 均为 LoRA 微调，主要训练 language modules，并冻结 vision、visual、projector、resampler 等视觉相关模块。

数据规模：

- SFT train/test：16,673 / 1,867
- DPO train/test：16,673 / 1,867
- holdout evaluation：SFT 1,680，DPO 1,680
- 当前提交的数据为 text/tool-only；已剔除 `localImagePath` 多模态图片样本。

训练数据 QA：

```bash
python3 model/training/code/agentic_rl/scripts/qa_training_xml_data.py --root model/training/data/TrainingData
```

