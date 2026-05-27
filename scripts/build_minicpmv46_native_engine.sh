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

echo "[Lumina] Native engine ready: $OUTPUT_DYLIB"
