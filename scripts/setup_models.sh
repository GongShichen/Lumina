#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODELS_DIR="$ROOT_DIR/Resources/Models"
HF_BIN="${HF_BIN:-hf}"

BGE_REPO="${LUMINA_BGE_REPO:-zhufucdev/BAAI-bge-small-zh-v1.5}"
MINIMINDO_REPO="${LUMINA_MINIMINDO_REPO:-jingyaogong/minimind-3o}"
MINIMINDO_CONTEXT_LENGTH="${LUMINA_MINIMINDO_CONTEXT_LENGTH:-12000}"
MINIMINDO_COREML_SOURCE="${LUMINA_MINIMINDO_COREML_SOURCE:-}"
BUILD_MINIMINDO_COREML="${LUMINA_BUILD_MINIMINDO_COREML:-0}"

mkdir -p "$MODELS_DIR/.staging/BGETextEmbedding" "$MODELS_DIR/.staging/MiniMindOReActModel"

echo "[Lumina] Downloading BGE embedding model: $BGE_REPO"
"$HF_BIN" download "$BGE_REPO" \
  --include 'CoreML/model.mlpackage/**' \
  --include 'tokenizer.json' \
  --local-dir "$MODELS_DIR/.staging/BGETextEmbedding"

echo "[Lumina] Compiling BGE Core ML package"
rm -rf "$MODELS_DIR/.staging/BGETextEmbedding/Compiled"
xcrun coremlcompiler compile \
  "$MODELS_DIR/.staging/BGETextEmbedding/CoreML/model.mlpackage" \
  "$MODELS_DIR/.staging/BGETextEmbedding/Compiled" >/dev/null

rm -rf "$MODELS_DIR/BGETextEmbedding.mlmodelc" "$MODELS_DIR/BGETextEmbedding-tokenizer.json"
mv "$MODELS_DIR/.staging/BGETextEmbedding/Compiled/model.mlmodelc" "$MODELS_DIR/BGETextEmbedding.mlmodelc"
mv "$MODELS_DIR/.staging/BGETextEmbedding/tokenizer.json" "$MODELS_DIR/BGETextEmbedding-tokenizer.json"

echo "[Lumina] Preparing MiniMind-o planner assets: $MINIMINDO_REPO"
"$HF_BIN" download "$MINIMINDO_REPO" \
  --include 'config.json' \
  --include 'generation_config.json' \
  --include 'tokenizer.json' \
  --include 'tokenizer_config.json' \
  --include 'special_tokens_map.json' \
  --include 'chat_template.jinja' \
  --include 'model_minimind.py' \
  --include 'model_omni.py' \
  --local-dir "$MODELS_DIR/.staging/MiniMindOReActModel/hf_model"

rm -rf "$MODELS_DIR/MiniMindOReActModel"
mkdir -p "$MODELS_DIR/MiniMindOReActModel/hf_model"
cp -R "$MODELS_DIR/.staging/MiniMindOReActModel/hf_model/." "$MODELS_DIR/MiniMindOReActModel/hf_model/"

python3 - "$MODELS_DIR/MiniMindOReActModel" "$MINIMINDO_CONTEXT_LENGTH" <<'PY'
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
context = int(sys.argv[2])
hf_config = json.loads((root / "hf_model" / "config.json").read_text(encoding="utf-8"))
model_config = {
    "model_name": "MiniMind-o",
    "architecture": hf_config.get("model_type", "minimind-o"),
    "hidden_size": int(hf_config.get("hidden_size", 768)),
    "context_length": context,
    "vocab_size": int(hf_config.get("vocab_size", 6400)),
    "bos_token_id": int(hf_config.get("bos_token_id", 1)),
    "eos_token_id": int(hf_config.get("eos_token_id", 2)),
    "num_hidden_layers": int(hf_config.get("num_hidden_layers", 8)),
    "num_attention_heads": int(hf_config.get("num_attention_heads", 8)),
    "num_key_value_heads": int(hf_config.get("num_key_value_heads", 4)),
    "rope_theta": float(hf_config.get("rope_theta", 1_000_000.0)),
    "source_repo": "jingyaogong/minimind-3o"
}
(root / "model_config.json").write_text(json.dumps(model_config, ensure_ascii=False, indent=2), encoding="utf-8")
PY

if [[ "$BUILD_MINIMINDO_COREML" == "1" ]]; then
  echo "[Lumina] Converting MiniMind-o to Core ML because LUMINA_BUILD_MINIMINDO_COREML=1"
  LUMINA_MINIMINDO_REPO="$MINIMINDO_REPO" \
  LUMINA_MINIMINDO_CONTEXT_LENGTH="$MINIMINDO_CONTEXT_LENGTH" \
  LUMINA_MINIMINDO_OUTPUT_DIR="$MODELS_DIR/MiniMindOReActModel" \
  "$ROOT_DIR/scripts/build_minimindo_coreml.sh"
elif [[ -n "$MINIMINDO_COREML_SOURCE" ]]; then
  echo "[Lumina] Installing MiniMind-o Core ML artifact from $MINIMINDO_COREML_SOURCE"
  if [[ -d "$MINIMINDO_COREML_SOURCE/model.mlmodelc" ]]; then
    cp -R "$MINIMINDO_COREML_SOURCE/model.mlmodelc" "$MODELS_DIR/MiniMindOReActModel/model.mlmodelc"
  elif [[ -d "$MINIMINDO_COREML_SOURCE/model.mlpackage" ]]; then
    cp -R "$MINIMINDO_COREML_SOURCE/model.mlpackage" "$MODELS_DIR/MiniMindOReActModel/model.mlpackage"
  elif [[ "$MINIMINDO_COREML_SOURCE" == *.mlmodelc && -d "$MINIMINDO_COREML_SOURCE" ]]; then
    cp -R "$MINIMINDO_COREML_SOURCE" "$MODELS_DIR/MiniMindOReActModel/model.mlmodelc"
  elif [[ "$MINIMINDO_COREML_SOURCE" == *.mlpackage && -d "$MINIMINDO_COREML_SOURCE" ]]; then
    cp -R "$MINIMINDO_COREML_SOURCE" "$MODELS_DIR/MiniMindOReActModel/model.mlpackage"
  else
    echo "[Lumina] Unsupported LUMINA_MINIMINDO_COREML_SOURCE: $MINIMINDO_COREML_SOURCE" >&2
    exit 2
  fi
else
  cat >&2 <<EOF
[Lumina] MiniMind-o Transformers assets are ready, but no Core ML planner artifact was provided.
[Lumina] The official jingyaogong/minimind-o release does not include a Core ML/ANE bundle.
[Lumina] Set LUMINA_MINIMINDO_COREML_SOURCE=/path/to/MiniMindOCoreMLBundle or run an internal converter before packaging the app.
EOF
fi

if [[ -d "$MODELS_DIR/MiniMindOReActModel" ]]; then
  "$ROOT_DIR/scripts/validate_minimindo_bundle.py" \
    "$MODELS_DIR/MiniMindOReActModel" \
    --expected-context "$MINIMINDO_CONTEXT_LENGTH"
fi

rm -rf "$MODELS_DIR/.staging"

echo "[Lumina] Model setup complete"
echo "  BGE model:      $MODELS_DIR/BGETextEmbedding.mlmodelc"
echo "  BGE tokenizer:  $MODELS_DIR/BGETextEmbedding-tokenizer.json"
echo "  MiniMind-o:     $MODELS_DIR/MiniMindOReActModel"
echo "  MiniMind-o ctx: $MINIMINDO_CONTEXT_LENGTH"
