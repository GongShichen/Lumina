#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Quantize a local Hugging Face MiniCPM-V 4.6 model into a Lumina GGUF bundle.

Usage:
  model/quantize_minicpmv46.sh HF_MODEL_DIR OUTPUT_BUNDLE [QUANT]

Arguments:
  HF_MODEL_DIR   Local Hugging Face model directory containing config.json
  OUTPUT_BUNDLE  Destination directory for model.gguf and bundle metadata
  QUANT          llama.cpp quantization type, default: Q8_0

Environment:
  LUMINA_LLAMA_CPP_DIR       llama.cpp checkout, default: .build/vendor/llama.cpp
  LUMINA_LLAMA_CPP_REPO      llama.cpp Git URL
  LUMINA_QUANT_WORK_DIR      Temporary conversion directory
  LUMINA_PROJECTOR_GGUF      Existing mmproj-model-f16.gguf to package
  LUMINA_CONTEXT_LENGTH      Bundle context length, default: 16000
  LUMINA_KEEP_F16=1          Keep the intermediate F16 GGUF
  PYTHON_BIN                 Python interpreter, default: python3
USAGE
}

die() {
  printf '[Lumina quantize] ERROR: %s\n' "$*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"
}

[[ $# -ge 2 && $# -le 3 ]] || { usage; exit 2; }

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_DIR="$(cd "$1" && pwd)"
OUTPUT_BUNDLE="$2"
QUANT="${3:-Q8_0}"
PYTHON_BIN="${PYTHON_BIN:-python3}"
LLAMA_CPP="${LUMINA_LLAMA_CPP_DIR:-$ROOT_DIR/.build/vendor/llama.cpp}"
LLAMA_REPO="${LUMINA_LLAMA_CPP_REPO:-https://github.com/ggml-org/llama.cpp.git}"
LLAMA_BUILD="$LLAMA_CPP/build"
WORK_DIR="${LUMINA_QUANT_WORK_DIR:-$ROOT_DIR/model/.staging/quantize}"
CONVERT_DIR="$WORK_DIR/hf-input"
F16_GGUF="$WORK_DIR/model-f16.gguf"
CONTEXT_LENGTH="${LUMINA_CONTEXT_LENGTH:-16000}"

[[ -f "$SOURCE_DIR/config.json" ]] || die "config.json not found in $SOURCE_DIR"
need_cmd git
need_cmd cmake
need_cmd rsync
need_cmd "$PYTHON_BIN"

if [[ ! -d "$LLAMA_CPP/.git" ]]; then
  rm -rf "$LLAMA_CPP"
  git clone --depth 1 "$LLAMA_REPO" "$LLAMA_CPP"
fi

cmake -S "$LLAMA_CPP" -B "$LLAMA_BUILD" \
  -DLLAMA_BUILD_TESTS=OFF \
  -DLLAMA_BUILD_EXAMPLES=ON \
  -DLLAMA_BUILD_SERVER=OFF \
  -DGGML_METAL=ON \
  -DGGML_ACCELERATE=ON \
  -DCMAKE_BUILD_TYPE=Release
cmake --build "$LLAMA_BUILD" --target llama-quantize -j "$(sysctl -n hw.logicalcpu)"

rm -rf "$CONVERT_DIR"
mkdir -p "$CONVERT_DIR" "$OUTPUT_BUNDLE"
rsync -a --link-dest="$SOURCE_DIR" "$SOURCE_DIR/" "$CONVERT_DIR/"
cp "$SOURCE_DIR/config.json" "$CONVERT_DIR/config.json.tmp"
mv "$CONVERT_DIR/config.json.tmp" "$CONVERT_DIR/config.json"

"$PYTHON_BIN" - "$CONVERT_DIR/config.json" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
config = json.loads(path.read_text(encoding="utf-8"))
text_config = config.get("text_config") or {}

# Some checkpoints advertise an MTP layer without saving its tensors. Disable
# that absent layer only in the temporary conversion view.
if int(text_config.get("mtp_num_hidden_layers") or 0) > 0:
    text_config["mtp_num_hidden_layers"] = 0
    text_config["mtp_use_dedicated_embeddings"] = False
    config["text_config"] = text_config
    path.write_text(
        json.dumps(config, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
PY

"$PYTHON_BIN" "$LLAMA_CPP/convert_hf_to_gguf.py" \
  "$CONVERT_DIR" \
  --outfile "$F16_GGUF" \
  --outtype f16

"$LLAMA_BUILD/bin/llama-quantize" \
  "$F16_GGUF" \
  "$OUTPUT_BUNDLE/model.gguf" \
  "$QUANT"

for file in config.json tokenizer_config.json tokenizer.json chat_template.jinja; do
  [[ -f "$SOURCE_DIR/$file" ]] && cp "$SOURCE_DIR/$file" "$OUTPUT_BUNDLE/$file"
done

PROJECTOR="${LUMINA_PROJECTOR_GGUF:-$SOURCE_DIR/mmproj-model-f16.gguf}"
if [[ -f "$PROJECTOR" ]]; then
  cp "$PROJECTOR" "$OUTPUT_BUNDLE/mmproj-model-f16.gguf"
else
  printf '[Lumina quantize] Warning: projector not packaged; set LUMINA_PROJECTOR_GGUF.\n' >&2
fi

"$PYTHON_BIN" - "$OUTPUT_BUNDLE/model_config.json" "$CONTEXT_LENGTH" "$QUANT" <<'PY'
import json
import sys
from pathlib import Path

output = Path(sys.argv[1])
config = {
    "model_name": "MiniCPM-V 4.6",
    "architecture": "minicpm-v-4_6",
    "context_length": int(sys.argv[2]),
    "quantization": sys.argv[3],
    "text_model": "model.gguf",
    "vision_projector": "mmproj-model-f16.gguf",
    "runtime": "LuminaModelRuntimeCore native C++",
}
output.write_text(json.dumps(config, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
PY

rm -rf "$CONVERT_DIR"
if [[ "${LUMINA_KEEP_F16:-0}" != "1" ]]; then
  rm -f "$F16_GGUF"
fi

printf '[Lumina quantize] Bundle ready: %s\n' "$OUTPUT_BUNDLE"
