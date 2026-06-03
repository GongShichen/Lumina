#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENGINE_SRC="$ROOT_DIR/app/NativeEngines/MiniCPMV46/LuminaMiniCPMV46GGUFEngine.cpp"
LLAMA_DIR="${LUMINA_LLAMA_CPP_DIR:-$ROOT_DIR/.build/vendor/llama.cpp}"
LLAMA_REPO="${LUMINA_LLAMA_CPP_REPO:-https://github.com/ggml-org/llama.cpp.git}"
LLAMA_BUILD_DIR="$LLAMA_DIR/build"
MODEL_DIR="${LUMINA_MINICPMV46_OUTPUT_DIR:-$ROOT_DIR/app/Resources/Models/MiniCPMV46ReActModel}"
OUTPUT_DYLIB="$MODEL_DIR/libLuminaMiniCPMV46GGUFEngine.dylib"

if [[ ! -f "$ENGINE_SRC" ]]; then
  echo "[Lumina] Missing native engine source: $ENGINE_SRC" >&2
  exit 1
fi

if [[ ! -d "$LLAMA_DIR/.git" ]]; then
  echo "[Lumina] Cloning llama.cpp library sources into .build"
  rm -rf "$LLAMA_DIR"
  git clone --depth 1 "$LLAMA_REPO" "$LLAMA_DIR"
fi

QWEN35_SRC="$LLAMA_DIR/src/models/qwen35.cpp"
if [[ -f "$QWEN35_SRC" ]]; then
  python3 - "$QWEN35_SRC" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
marker = "qwen35 metadata declares"
needle = "void llama_model_qwen35::load_arch_tensors(llama_model_loader & ml) {\n"
insert = r'''    if (hparams.nextn_predict_layers > 0) {
        const uint32_t n_main = hparams.n_layer - hparams.nextn_predict_layers;
        const std::string first_mtp_block = format("blk.%u.attn_norm.weight", n_main);
        const std::string first_mtp_nextn = format("blk.%u.nextn.eh_proj.weight", n_main);

        if (ml.get_weight(first_mtp_block.c_str()) == nullptr &&
            ml.get_weight(first_mtp_nextn.c_str()) == nullptr) {
            LLAMA_LOG_WARN(
                "%s: qwen35 metadata declares %u NextN/MTP layer(s), but no MTP tensors were found at block %u; "
                "loading the %u-layer main trunk only\n",
                __func__,
                hparams.nextn_predict_layers,
                n_main,
                n_main
            );
            hparams.n_layer = n_main;
            hparams.nextn_predict_layers = 0;
        }
    }

'''

if marker not in text:
    if needle not in text:
        raise SystemExit(f"[Lumina] qwen35.cpp patch point not found: {path}")
    path.write_text(text.replace(needle, needle + insert, 1))
PY
fi

echo "[Lumina] Building llama.cpp library backend with Metal + Accelerate"
cmake -S "$LLAMA_DIR" -B "$LLAMA_BUILD_DIR" \
  -DLLAMA_BUILD_TESTS=OFF \
  -DLLAMA_BUILD_EXAMPLES=OFF \
  -DLLAMA_BUILD_SERVER=OFF \
  -DGGML_METAL=ON \
  -DGGML_ACCELERATE=ON \
  -DCMAKE_BUILD_TYPE=Release >/dev/null
cmake --build "$LLAMA_BUILD_DIR" --target llama -j "$(sysctl -n hw.logicalcpu)" >/dev/null

mkdir -p "$MODEL_DIR"
echo "[Lumina] Building MiniCPM-V 4.6 native GGUF engine"
c++ -std=c++17 -O3 -fPIC -dynamiclib "$ENGINE_SRC" \
  -I"$LLAMA_DIR/include" \
  -I"$LLAMA_DIR/ggml/include" \
  -L"$LLAMA_BUILD_DIR/bin" \
  -lllama -lggml -lggml-base -lggml-cpu -lggml-metal -lggml-blas \
  -framework Foundation -framework Metal -framework Accelerate \
  -Wl,-rpath,@loader_path \
  -o "$OUTPUT_DYLIB"

for dylib in \
  libllama.0.dylib \
  libggml.0.dylib \
  libggml-base.0.dylib \
  libggml-cpu.0.dylib \
  libggml-metal.0.dylib \
  libggml-blas.0.dylib
do
  cp "$LLAMA_BUILD_DIR/bin/$dylib" "$MODEL_DIR/$dylib"
done

if command -v install_name_tool >/dev/null 2>&1; then
  install_name_tool -id @rpath/libLuminaMiniCPMV46GGUFEngine.dylib "$OUTPUT_DYLIB" || true
fi

SIGN_IDENTITY="${LUMINA_CODESIGN_IDENTITY:-${EXPANDED_CODE_SIGN_IDENTITY_NAME:-${CODE_SIGN_IDENTITY:-}}}"
if [[ -z "$SIGN_IDENTITY" || "$SIGN_IDENTITY" == "-" ]]; then
  SIGN_IDENTITY="$(
    security find-identity -v -p codesigning 2>/dev/null \
      | awk -F'"' '/Apple Development/ { print $2; exit }'
  )"
fi

if [[ -n "$SIGN_IDENTITY" && "$SIGN_IDENTITY" != "-" ]]; then
  echo "[Lumina] Signing MiniCPM-V 4.6 native engine dylibs with $SIGN_IDENTITY"
  for dylib in "$MODEL_DIR"/*.dylib; do
    codesign --force --sign "$SIGN_IDENTITY" --timestamp=none "$dylib"
  done
else
  echo "[Lumina] Skipping native engine dylib signing; set LUMINA_CODESIGN_IDENTITY to enable hardened-runtime loading." >&2
fi

echo "[Lumina] Native engine ready: $OUTPUT_DYLIB"
