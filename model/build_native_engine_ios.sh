#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LLAMA_DIR="${LUMINA_LLAMA_CPP_DIR:-$ROOT_DIR/.build/vendor/llama.cpp}"
BUILD_DIR="$LLAMA_DIR/build-ios"
OUTPUT_DIR="${LUMINA_MINICPMV46_OUTPUT_DIR:-$ROOT_DIR/.build/ios-engine}"
IOS_VERSION="${LUMINA_IOS_DEPLOYMENT_TARGET:-26.0}"

if [[ ! -d "$LLAMA_DIR/.git" ]]; then
    git clone --depth 1 https://github.com/ggml-org/llama.cpp.git "$LLAMA_DIR"
fi

cmake -S "$LLAMA_DIR" -B "$BUILD_DIR" \
    -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT=iphoneos \
    -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET="$IOS_VERSION" \
    -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
    -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON \
    -DGGML_ACCELERATE=ON -DGGML_OPENMP=OFF \
    -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF \
    -DLLAMA_BUILD_SERVER=OFF -DLLAMA_BUILD_TOOLS=OFF -DLLAMA_CURL=OFF
cmake --build "$BUILD_DIR" --target llama -j "${LUMINA_BUILD_JOBS:-8}"

mkdir -p "$OUTPUT_DIR"
ARCHIVES=(
    "$BUILD_DIR/src/libllama.a"
    "$BUILD_DIR/ggml/src/libggml.a"
    "$BUILD_DIR/ggml/src/libggml-base.a"
    "$BUILD_DIR/ggml/src/libggml-cpu.a"
    "$BUILD_DIR/ggml/src/ggml-metal/libggml-metal.a"
    "$BUILD_DIR/ggml/src/ggml-blas/libggml-blas.a"
)
LINK_ARGS=()
for archive in "${ARCHIVES[@]}"; do
    LINK_ARGS+=("-Wl,-force_load,$archive")
done
xcrun --sdk iphoneos clang++ -std=c++17 -O3 -dynamiclib \
    -target "arm64-apple-ios$IOS_VERSION" \
    -isysroot "$(xcrun --sdk iphoneos --show-sdk-path)" \
    "$ROOT_DIR/app/NativeEngines/MiniCPMV46/LuminaMiniCPMV46GGUFEngine.cpp" \
    -I"$LLAMA_DIR/include" -I"$LLAMA_DIR/ggml/include" \
    "${LINK_ARGS[@]}" -framework Foundation -framework Metal -framework Accelerate \
    -Wl,-install_name,@rpath/libLuminaMiniCPMV46GGUFEngine.dylib \
    -o "$OUTPUT_DIR/libLuminaMiniCPMV46GGUFEngine.dylib"

if [[ -n "${LUMINA_CODESIGN_IDENTITY:-}" ]]; then
    codesign --force --sign "$LUMINA_CODESIGN_IDENTITY" \
        "$OUTPUT_DIR/libLuminaMiniCPMV46GGUFEngine.dylib"
fi
xcrun vtool -show-build "$OUTPUT_DIR/libLuminaMiniCPMV46GGUFEngine.dylib"
