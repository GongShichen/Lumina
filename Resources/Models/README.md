# Local Core ML Models

Place compiled Core ML bundles here:

- `Gemma4Planner.mlmodelc`
- `BGETextEmbedding.mlmodelc`

`Gemma4Planner.mlmodelc` must accept a `String` input named `prompt` and return a `String` output named `json`.

`BGETextEmbedding.mlmodelc` is the default lightweight local embedding model profile for `BAAI/bge-small-zh-v1.5`. It must accept a `String` input named `text` and return an `MLMultiArray` output named `embedding` with dimension `512`.

For compatibility, `Gemma4Embedding.mlmodelc` and `LocalEmbedding.mlmodelc` are still supported as fallback bundle names.

For local development, you can override bundle lookup with environment variables:

- `LUMINA_GEMMA4_PLANNER_MODEL=/absolute/path/Gemma4Planner.mlmodelc`
- `LUMINA_EMBEDDING_MODEL=/absolute/path/BGETextEmbedding.mlmodelc`

The repository intentionally does not commit `.mlmodelc` bundles.
