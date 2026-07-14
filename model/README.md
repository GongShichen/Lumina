# 模型推理与量化命令

下载并安装预量化 MiniCPM-V 4.6：

```bash
./model/lumina_model.sh download original
./model/lumina_model.sh install original
```

选择 GGUF 量化版本：

```bash
LUMINA_MINICPMV46_QUANT=Q8_0 ./model/lumina_model.sh download original
```

构建 native inference engine：

```bash
./model/lumina_model.sh build-native-engine
```

校验 bundle：

```bash
./model/lumina_model.sh validate original
./model/lumina_model.sh validate /absolute/path/to/custom-bundle
```

将本地 Hugging Face 格式模型转换并量化为 Q8_0：

```bash
LUMINA_PROJECTOR_GGUF=/absolute/path/to/mmproj-model-f16.gguf \
./model/quantize_minicpmv46.sh \
  /absolute/path/to/hf-model \
  /absolute/path/to/MiniCPMV46ReActModel-Q8 \
  Q8_0
```

完整依赖、App 部署和自定义 bundle 说明见根目录 [README](../README.md)。
