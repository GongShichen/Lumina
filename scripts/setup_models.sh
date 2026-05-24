#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODELS_DIR="$ROOT_DIR/Resources/Models"
HF_BIN="${HF_BIN:-hf}"

BGE_REPO="${LUMINA_BGE_REPO:-zhufucdev/BAAI-bge-small-zh-v1.5}"
GEMMA4_REPO="${LUMINA_GEMMA4_REPO:-mlboydaisuke/gemma-4-E2B-stateful-coreml}"
GEMMA4_CONTEXT_LENGTH="${LUMINA_GEMMA4_CONTEXT_LENGTH:-12000}"

mkdir -p "$MODELS_DIR/.staging/BGETextEmbedding" "$MODELS_DIR/.staging/Gemma4Planner"

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

if [[ "${LUMINA_SKIP_GEMMA4_DOWNLOAD:-0}" != "1" ]]; then
  echo "[Lumina] Downloading Gemma4 stateful Core ML model: $GEMMA4_REPO"
  "$HF_BIN" download "$GEMMA4_REPO" \
    --include 'chunk_*.mlmodelc/**' \
    --include 'hf_model/tokenizer.json' \
    --include 'hf_model/tokenizer_config.json' \
    --include 'model_config.json' \
    --include 'README.md' \
    --include '*.npy' \
    --include '*embed*' \
    --include '*projection*' \
    --include '*norm*' \
    --local-dir "$MODELS_DIR/.staging/Gemma4Planner"

  rm -rf "$MODELS_DIR/Gemma4Planner"
  mv "$MODELS_DIR/.staging/Gemma4Planner" "$MODELS_DIR/Gemma4Planner"
else
  echo "[Lumina] Skipping Gemma4 download because LUMINA_SKIP_GEMMA4_DOWNLOAD=1"
fi

if [[ -d "$MODELS_DIR/Gemma4Planner" ]]; then
  "$ROOT_DIR/scripts/validate_gemma4_bundle.py" \
    "$MODELS_DIR/Gemma4Planner" \
    --expected-context "$GEMMA4_CONTEXT_LENGTH"
fi

rm -rf "$MODELS_DIR/.staging"

echo "[Lumina] Model setup complete"
echo "  BGE model:      $MODELS_DIR/BGETextEmbedding.mlmodelc"
echo "  BGE tokenizer:  $MODELS_DIR/BGETextEmbedding-tokenizer.json"
echo "  Gemma4 bundle:  $MODELS_DIR/Gemma4Planner"
echo "  Gemma4 context: $GEMMA4_CONTEXT_LENGTH"
