#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONTEXT_LENGTH="${LUMINA_GEMMA4_CONTEXT_LENGTH:-12000}"
OUTPUT_DIR="${LUMINA_GEMMA4_OUTPUT_DIR:-$ROOT_DIR/Resources/Models/.staging/Gemma4Planner-${CONTEXT_LENGTH}}"
FINAL_DIR="${LUMINA_GEMMA4_FINAL_DIR:-$ROOT_DIR/Resources/Models/Gemma4Planner}"
CONVERSION_DIR="$ROOT_DIR/.build/checkouts/CoreML-LLM/conversion"
PYTHON_BIN="${PYTHON_BIN:-python3}"
HF_DIR="${GEMMA4_HF_DIR:-}"

if [[ ! -f "$CONVERSION_DIR/build_gemma4_e2b_stateful_3chunks.py" ]]; then
  echo "[Lumina] CoreML-LLM conversion scripts were not found at $CONVERSION_DIR" >&2
  exit 1
fi

if ! "$PYTHON_BIN" - <<'PY' >/dev/null 2>&1
import coremltools, torch, safetensors, huggingface_hub, numpy
PY
then
  cat >&2 <<EOF
[Lumina] Missing Gemma4 conversion dependencies for $PYTHON_BIN.
Install them in an isolated environment, for example:
  $PYTHON_BIN -m pip install -r "$CONVERSION_DIR/requirements.txt"
EOF
  exit 2
fi

rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"

args=(
  "$CONVERSION_DIR/build_gemma4_e2b_stateful_3chunks.py"
  --model gemma4-e2b
  --output "$OUTPUT_DIR/mlpackage"
  --ctx "$CONTEXT_LENGTH"
  --linear-projections
  --prefill-batches "8"
)
if [[ -n "$HF_DIR" ]]; then
  args+=(--hf-dir "$HF_DIR")
fi

echo "[Lumina] Converting Gemma4 stateful planner with context=$CONTEXT_LENGTH"
"$PYTHON_BIN" "${args[@]}"

COMPILED_DIR="$OUTPUT_DIR/compiled"
rm -rf "$COMPILED_DIR"
mkdir -p "$COMPILED_DIR"

for chunk in 1 2 3; do
  echo "[Lumina] Compiling chunk_$chunk.mlpackage"
  xcrun coremlcompiler compile \
    "$OUTPUT_DIR/mlpackage/chunk_$chunk.mlpackage" \
    "$COMPILED_DIR" >/dev/null
done

ASSEMBLED_DIR="$OUTPUT_DIR/assembled"
rm -rf "$ASSEMBLED_DIR"
mkdir -p "$ASSEMBLED_DIR"

for chunk in 1 2 3; do
  mv "$COMPILED_DIR/chunk_$chunk.mlmodelc" "$ASSEMBLED_DIR/chunk_$chunk.mlmodelc"
done

SOURCE_SIDE_CARS="$FINAL_DIR"
if [[ -n "$HF_DIR" && -d "$HF_DIR" ]]; then
  mkdir -p "$ASSEMBLED_DIR/hf_model"
  cp "$HF_DIR"/tokenizer*.json "$ASSEMBLED_DIR/hf_model/" 2>/dev/null || true
fi

for item in \
  hf_model \
  embed_tokens_q8.bin \
  embed_tokens_scales.bin \
  embed_tokens_per_layer_q8.bin \
  embed_tokens_per_layer_scales.bin \
  per_layer_projection.bin \
  per_layer_norm_weight.bin; do
  if [[ -e "$SOURCE_SIDE_CARS/$item" && ! -e "$ASSEMBLED_DIR/$item" ]]; then
    cp -R "$SOURCE_SIDE_CARS/$item" "$ASSEMBLED_DIR/$item"
  fi
done

"$PYTHON_BIN" - <<PY
import json
from pathlib import Path
path = Path("$ASSEMBLED_DIR/model_config.json")
config = {
  "model_name": "gemma4-e2b-swa-ple",
  "architecture": "gemma4",
  "hidden_size": 1536,
  "num_hidden_layers": 35,
  "context_length": int("$CONTEXT_LENGTH"),
  "sliding_window": 512,
  "vocab_size": 262144,
  "bos_token_id": 2,
  "eos_token_id": 1,
  "per_layer_dim": 256,
  "max_head_dim": 512,
  "embed_scale": 39.191835884530846,
  "per_layer_model_projection_scale": 0.02551551815399144,
  "per_layer_input_scale": 0.7071067811865476,
  "per_layer_embed_scale": 16.0,
  "external_embeddings": True,
  "has_multimodal": True,
  "stateless": True,
  "sliding_window_attention": True,
  "ple_inside_chunk1": True,
  "num_chunks": 4
}
path.write_text(json.dumps(config, indent=2) + "\\n")
PY

"$PYTHON_BIN" - <<PY
from pathlib import Path
import numpy as np
ctx = int("$CONTEXT_LENGTH")
out = Path("$ASSEMBLED_DIR")
hd_s = 256
hd_f = 512
t = np.arange(ctx, dtype=np.float32)
inv_s = 1.0 / (10000.0 ** (np.arange(0, hd_s, 2, dtype=np.float32) / hd_s))
freq_s = np.einsum("i,j->ij", t, inv_s)
emb_s = np.concatenate([freq_s, freq_s], axis=-1)
inv_f = 1.0 / (1000000.0 ** (np.arange(0, hd_f, 2, dtype=np.float32) / hd_f))
freq_f = np.einsum("i,j->ij", t, inv_f)
emb_f = np.concatenate([freq_f, freq_f], axis=-1)
np.save(out / "cos_sliding.npy", np.cos(emb_s).astype(np.float16))
np.save(out / "sin_sliding.npy", np.sin(emb_s).astype(np.float16))
np.save(out / "cos_full.npy", np.cos(emb_f).astype(np.float16))
np.save(out / "sin_full.npy", np.sin(emb_f).astype(np.float16))
PY

"$ROOT_DIR/scripts/validate_gemma4_bundle.py" "$ASSEMBLED_DIR" --expected-context "$CONTEXT_LENGTH"

rm -rf "$FINAL_DIR"
mv "$ASSEMBLED_DIR" "$FINAL_DIR"
echo "[Lumina] Installed Gemma4 stateful planner at $FINAL_DIR with context=$CONTEXT_LENGTH"
