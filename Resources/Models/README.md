# Local Core ML Models

Place compiled Core ML bundles here:

- `BGETextEmbedding.mlmodelc`
- `BGETextEmbedding-tokenizer.json`
- `Gemma4Planner/`
- optional `Gemma4Planner.mlmodelc`

`Gemma4Planner.mlmodelc` must accept a `String` input named `prompt` and return a `String` output named `json`.

The downloaded Gemma4 profile is `mlboydaisuke/gemma-4-E2B-stateful-coreml`. It is a chunked/stateful decoder bundle under `Gemma4Planner/`, not a single `prompt -> json` planner bundle. Lumina keeps it configured as the local SLM asset and continues to use the deterministic/Foundation fallback planner until a Gemma4 stateful decoder adapter is enabled.

`BGETextEmbedding.mlmodelc` is the default lightweight local embedding model profile for `BAAI/bge-small-zh-v1.5`. The bundled Core ML model accepts `input_ids` and `attention_mask`, produced by `BGETextEmbedding-tokenizer.json`, and returns `pooler_output` with dimension `512`.

For compatibility, `Gemma4Embedding.mlmodelc` and `LocalEmbedding.mlmodelc` are still supported as fallback bundle names.

For local development, you can override bundle lookup with environment variables:

- `LUMINA_GEMMA4_PLANNER_MODEL=/absolute/path/Gemma4Planner.mlmodelc`
- `LUMINA_EMBEDDING_MODEL=/absolute/path/BGETextEmbedding.mlmodelc`
- `LUMINA_EMBEDDING_TOKENIZER=/absolute/path/BGETextEmbedding-tokenizer.json`

The repository intentionally does not commit downloaded model weights or compiled `.mlmodelc` bundles.
