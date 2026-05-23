# Local Model Contracts

The app supports Core ML models through generic contracts. Gemma 4 can be used for local planning if it is wrapped to satisfy the planner contract. The default lightweight embedding profile is `BAAI/bge-small-zh-v1.5`.

## Planner Model

Adapter: `CoreMLTextToJSONModel`

Preferred bundle name: `Gemma4Planner.mlmodelc`

Fallback bundle name: `LocalPlanner.mlmodelc`

Bundle location:

- `Resources/Models/Gemma4Planner.mlmodelc` in the Xcode project, copied into `Lumina.app/Models`
- or `LUMINA_GEMMA4_PLANNER_MODEL=/absolute/path/Gemma4Planner.mlmodelc` for local development overrides

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

Adapter: `CoreMLEmbeddingProvider`

Preferred bundle name: `BGETextEmbedding.mlmodelc`

Compatible fallback bundle names: `Gemma4Embedding.mlmodelc`, `LocalEmbedding.mlmodelc`

Bundle location:

- `Resources/Models/BGETextEmbedding.mlmodelc` in the Xcode project, copied into `Lumina.app/Models`
- or `LUMINA_EMBEDDING_MODEL=/absolute/path/BGETextEmbedding.mlmodelc` for local development overrides

Inputs:

- `text`: `String`

Outputs:

- `embedding`: `MLMultiArray`

The configured dimension must match the model output. Output is normalized by default.

Default BGE profile:

- model family: `BAAI/bge-small-zh-v1.5`
- dimension: `512`
- intended use: Chinese-first local RAG / personal memory retrieval

Legacy Gemma/local embedding profiles can still use dimension `768` when loaded through their compatible bundle names.
