# Local Models

Lumina ships local model assets inside the app bundle. The production app loads
these bundled files directly and does not ask the user to download models at
runtime.

- `MiniCPMV46ReActModel/`
- `BGETextEmbedding.mlmodelc`
- `BGETextEmbedding-tokenizer.json`

`MiniCPMV46ReActModel/` contains:

- `model.gguf`: MiniCPM-V 4.6 text model, default precision `F16`.
- `mmproj-model-f16.gguf`: MiniCPM-V vision projector.
- `model_config.json`: Lumina runtime metadata, including context length.

`BGETextEmbedding.mlmodelc` is the default lightweight local embedding model
profile for `BAAI/bge-small-zh-v1.5`. The bundled Core ML model accepts
`input_ids` and `attention_mask`, produced by
`BGETextEmbedding-tokenizer.json`, and returns `pooler_output` with dimension
`512`.

For local development only, you can override bundle lookup with environment
variables:

- `LUMINA_MINICPMV46_MODEL=/absolute/path/MiniCPMV46ReActModel`
- `LUMINA_MINICPMV46_BACKEND=ane|mps|automatic`
- `LUMINA_EMBEDDING_MODEL=/absolute/path/BGETextEmbedding.mlmodelc`
- `LUMINA_EMBEDDING_TOKENIZER=/absolute/path/BGETextEmbedding-tokenizer.json`

Do not add UI that downloads these models at runtime. `scripts/setup_models.sh`
is only a developer refresh script for replacing the bundled assets before
building the app.
