# Local Model Contracts

The app supports Core ML models through generic contracts. Gemma 4 can be used for local planning if it is wrapped to satisfy the planner contract. The default lightweight embedding profile is `BAAI/bge-small-zh-v1.5`.

## Planner Model

Adapter: `CoreMLTextToJSONModel`

Preferred bundle name: `Gemma4Planner.mlmodelc`

Fallback bundle name: `LocalPlanner.mlmodelc`

Bundle location:

- `Resources/Models/Gemma4Planner.mlmodelc` in the Xcode project, copied into `Lumina.app/Models`
- or `LUMINA_GEMMA4_PLANNER_MODEL=/absolute/path/Gemma4Planner.mlmodelc` for local development overrides
- `Resources/Models/Gemma4Planner/` for the downloaded chunked/stateful Gemma4 E2B asset

Inputs:

- `prompt`: `String`

Outputs:

- `json`: `String`

The JSON must match:

```json
{
  "summary": "short summary",
  "toolCalls": [
    {
      "toolName": "local.search",
      "arguments": {"query": "coffee", "limit": 5},
      "requiresConfirmation": false
    }
  ]
}
```

Runtime guardrails:

- Unknown tool names are discarded.
- Tool calls are capped by `AgentRuntimeConfiguration.maximumToolCalls`.
- Side-effect tools are forced through confirmation even if the model says otherwise.
- In ReAct mode the model can also emit one structured next step at a time: `thought`, `action`, or `final`.

Downloaded Gemma4 profile:

- repository: `mlboydaisuke/gemma-4-E2B-stateful-coreml`
- local path: `Resources/Models/Gemma4Planner/`
- files: `chunk_1.mlmodelc`, `chunk_2.mlmodelc`, `chunk_3.mlmodelc`, sidecar embeddings, RoPE tables, tokenizer, `model_config.json`
- status: downloaded and locally configured as the SLM asset; using it as the ReAct planner requires a stateful decoder engine that converts prompts to generated JSON. Until that adapter is enabled, Lumina keeps the deterministic/Foundation fallback planner active for repeatable local tests.

## Multimodal Planner Model

Protocol: `LocalMultimodalStructuredInferenceModel`

Input:

- `prompt`: text prompt with extracted summaries and tool schemas.
- `content`: `[AgentContentPart]`, containing text/image/audio/video/file/structured data references.
- `availableTools`: schemas with accepted input and output modalities.

Use this protocol for Gemma 4 or another multimodal model package that can inspect media directly. A text-only model can still use `LocalStructuredInferenceModel`; `TextOnlyStructuredModelAdapter` bridges it into the multimodal planner pipeline.

## Agent Content Parts

Runtime-supported modalities:

- `text`
- `image`
- `audio`
- `video`
- `file`
- `structuredData`

Media is represented by `AgentMediaAsset`, which can point to inline base64, local file URL, remote URL, or a security-scoped bookmark. Large binary payloads should use file/bookmark references rather than inline base64.

## Embedding Model

Adapter: `BGECoreMLEmbeddingProvider`

Preferred bundle name: `BGETextEmbedding.mlmodelc`

Compatible fallback bundle names: `Gemma4Embedding.mlmodelc`, `LocalEmbedding.mlmodelc`

Bundle location:

- `Resources/Models/BGETextEmbedding.mlmodelc` in the Xcode project, copied into `Lumina.app/Models`
- or `LUMINA_EMBEDDING_MODEL=/absolute/path/BGETextEmbedding.mlmodelc` for local development overrides
- tokenizer override: `LUMINA_EMBEDDING_TOKENIZER=/absolute/path/BGETextEmbedding-tokenizer.json`

Inputs:

- `input_ids`: `MLMultiArray(Int32, shape: 1 x 512)`
- `attention_mask`: `MLMultiArray(Int32, shape: 1 x 512)`

Outputs:

- `pooler_output`: `MLMultiArray(Float32, shape: 1 x 512)`

The adapter uses a lightweight WordPiece tokenizer backed by `tokenizer.json`. The configured dimension must match the model output. Output is normalized by default.

Runtime compute policy:

- iOS device: `.all`, so Core ML can use ANE/GPU/CPU according to system scheduling.
- iOS Simulator: `.cpuOnly`, because simulator Core ML backends can route through incompatible MPSGraph/E5RT paths for mobile models.

Default BGE profile:

- model family: `BAAI/bge-small-zh-v1.5`
- dimension: `512`
- intended use: Chinese-first local RAG / personal memory retrieval

Legacy Gemma/local embedding profiles can still use dimension `768` when loaded through their compatible bundle names.
