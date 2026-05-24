# Local Core ML Models

Lumina ships compiled Core ML bundles inside the app. The production app loads
these bundled files directly and does not ask the user to download models.

- `BGETextEmbedding.mlmodelc`
- `BGETextEmbedding-tokenizer.json`
- `Gemma4Planner/`
- optional `Gemma4Planner.mlmodelc`

`Gemma4Planner.mlmodelc` must accept a `String` input named `prompt` and return a `String` output named `json`.

The bundled Gemma4 profile is `mlboydaisuke/gemma-4-E2B-stateful-coreml`. It is
a chunked/stateful decoder bundle under `Gemma4Planner/`, not a single
`prompt -> json` planner bundle. Lumina loads it through
`LuminaGemma4StatefulPlannerModel`, which wraps CoreML-LLM's stateful decoder
and extracts the generated structured JSON for the planner contract.

`BGETextEmbedding.mlmodelc` is the default lightweight local embedding model profile for `BAAI/bge-small-zh-v1.5`. The bundled Core ML model accepts `input_ids` and `attention_mask`, produced by `BGETextEmbedding-tokenizer.json`, and returns `pooler_output` with dimension `512`.

For compatibility, `Gemma4Embedding.mlmodelc` and `LocalEmbedding.mlmodelc` are still supported as fallback bundle names.

For local development only, you can override bundle lookup with environment variables:

- `LUMINA_GEMMA4_PLANNER_MODEL=/absolute/path/Gemma4Planner.mlmodelc`
- `LUMINA_EMBEDDING_MODEL=/absolute/path/BGETextEmbedding.mlmodelc`
- `LUMINA_EMBEDDING_TOKENIZER=/absolute/path/BGETextEmbedding-tokenizer.json`

Do not add UI that downloads these models at runtime. `scripts/setup_models.sh`
is only a developer refresh script for replacing the bundled assets before
building the app.
