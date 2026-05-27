#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DERIVED_DATA="$ROOT_DIR/.build/DerivedData"
CMAKE_BUILD_DIR="$ROOT_DIR/.build/lumina-runtime"
APP_PROJECT="$ROOT_DIR/app/Lumina.xcodeproj"
APP_PATH="$DERIVED_DATA/Build/Products/Debug-maccatalyst/Lumina.app"

for arg in "$@"; do
  case "$arg" in
    --clean)
      "$ROOT_DIR/scripts/clean_build_artifacts.sh"
      ;;
    *)
      echo "Usage: bash setup.sh [--clean]" >&2
      exit 2
      ;;
  esac
done

echo "[Lumina] Building LuminaAgentRuntime Swift package"
swift build --package-path "$ROOT_DIR/LuminaAgentRuntime"
swift test --package-path "$ROOT_DIR/LuminaAgentRuntime"

echo "[Lumina] Building portable runtime core with CMake"
cmake -S "$ROOT_DIR/LuminaAgentRuntime" -B "$CMAKE_BUILD_DIR" -DLUMINA_BUILD_LINUX_SAMPLE=ON
cmake --build "$CMAKE_BUILD_DIR" --target lumina_agent_runtime_core lumina_agent_runtime_core_static lumina_runtime_linux_fake_conformance
"$CMAKE_BUILD_DIR/lumina_runtime_linux_fake_conformance"

echo "[Lumina] Verifying App uses local runtime source dependency"
grep -q '.package(path: "../LuminaAgentRuntime")' "$ROOT_DIR/app/Package.swift"
grep -q 'relativePath = ../LuminaAgentRuntime;' "$ROOT_DIR/app/Lumina.xcodeproj/project.pbxproj"

echo "[Lumina] Building App Swift package tests"
swift test --package-path "$ROOT_DIR/app"

echo "[Lumina] Building Mac Catalyst App"
xcodebuild \
  -project "$APP_PROJECT" \
  -scheme Lumina \
  -destination 'platform=macOS,variant=Mac Catalyst' \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=NO \
  build

if [[ -n "${ANDROID_NDK_HOME:-}" ]]; then
  echo "[Lumina] Android NDK detected at $ANDROID_NDK_HOME; JNI build entry is available through LuminaAgentRuntime/CMakeLists.txt"
else
  echo "[Lumina] Android NDK not detected; skipping Android JNI build"
fi

if [[ -n "${OHOS_NDK_HOME:-${HARMONYOS_NDK_HOME:-}}" ]]; then
  echo "[Lumina] HarmonyOS NDK detected; native binding sources are ready under LuminaAgentRuntime/Bindings/HarmonyOS"
else
  echo "[Lumina] HarmonyOS NDK not detected; skipping HarmonyOS native build"
fi

echo "[Lumina] Setup complete"
echo "[Lumina] Open the app with:"
echo "  open \"$APP_PATH\""
