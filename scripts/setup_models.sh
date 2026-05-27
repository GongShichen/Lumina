#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODELS_DIR="$ROOT_DIR/app/Resources/Models"
HF_BIN="${HF_BIN:-hf}"

BGE_REPO="${LUMINA_BGE_REPO:-zhufucdev/BAAI-bge-small-zh-v1.5}"
MINICPM_REPO="${LUMINA_MINICPMV46_REPO:-openbmb/MiniCPM-V-4_6-gguf}"
MINICPM_QUANT="${LUMINA_MINICPMV46_QUANT:-F16}"
MINICPM_CONTEXT_LENGTH="${LUMINA_MINICPMV46_CONTEXT_LENGTH:-16000}"
MINICPM_OUTPUT_DIR="${LUMINA_MINICPMV46_OUTPUT_DIR:-$MODELS_DIR/MiniCPMV46ReActModel}"
TEXT_MODEL_FILE="MiniCPM-V-4_6-${MINICPM_QUANT}.gguf"
PROJECTOR_FILE="mmproj-model-f16.gguf"

mkdir -p "$MODELS_DIR/.staging/BGETextEmbedding" "$MODELS_DIR/.staging/MiniCPMV46ReActModel"

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

echo "[Lumina] Downloading MiniCPM-V 4.6 GGUF planner assets: $MINICPM_REPO / $TEXT_MODEL_FILE"
"$HF_BIN" download "$MINICPM_REPO" \
  --include "$TEXT_MODEL_FILE" \
  --include "$PROJECTOR_FILE" \
  --local-dir "$MODELS_DIR/.staging/MiniCPMV46ReActModel"

rm -rf "$MINICPM_OUTPUT_DIR"
mkdir -p "$MINICPM_OUTPUT_DIR"
mv "$MODELS_DIR/.staging/MiniCPMV46ReActModel/$TEXT_MODEL_FILE" "$MINICPM_OUTPUT_DIR/model.gguf"
mv "$MODELS_DIR/.staging/MiniCPMV46ReActModel/$PROJECTOR_FILE" "$MINICPM_OUTPUT_DIR/$PROJECTOR_FILE"

python3 - "$MINICPM_OUTPUT_DIR" "$MINICPM_CONTEXT_LENGTH" "$MINICPM_QUANT" "$MINICPM_REPO" <<'PY'
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
context = int(sys.argv[2])
quant = sys.argv[3]
repo = sys.argv[4]
model_config = {
    "model_name": "MiniCPM-V 4.6",
    "architecture": "minicpm-v-4_6",
    "context_length": context,
    "quantization": quant,
    "text_model": "model.gguf",
    "vision_projector": "mmproj-model-f16.gguf",
    "source_repo": repo,
    "runtime": "LuminaModelRuntimeCore native C++",
    "macos_acceleration": "MPS backend",
    "ios_acceleration": "ANE backend"
}
(root / "model_config.json").write_text(
    json.dumps(model_config, ensure_ascii=False, indent=2),
    encoding="utf-8",
)
PY

"$ROOT_DIR/scripts/validate_minicpmv46_bundle.py" \
  "$MINICPM_OUTPUT_DIR" \
  --expected-context "$MINICPM_CONTEXT_LENGTH"

if [[ "${LUMINA_SKIP_NATIVE_ENGINE:-0}" != "1" ]]; then
  LUMINA_MINICPMV46_OUTPUT_DIR="$MINICPM_OUTPUT_DIR" \
    "$ROOT_DIR/scripts/build_minicpmv46_native_engine.sh"
else
  echo "[Lumina] Skipping MiniCPM-V native engine build because LUMINA_SKIP_NATIVE_ENGINE=1"
fi

rm -rf "$MODELS_DIR/.staging"

echo "[Lumina] Model setup complete"
echo "  BGE model:       $MODELS_DIR/BGETextEmbedding.mlmodelc"
echo "  BGE tokenizer:   $MODELS_DIR/BGETextEmbedding-tokenizer.json"
echo "  MiniCPM-V 4.6:   $MINICPM_OUTPUT_DIR"
echo "  MiniCPM context: $MINICPM_CONTEXT_LENGTH"
