#!/usr/bin/env bash
# Real local MiniCPM + production prompt/runtime policy, with isolated PIM tools.
# Optional: LUMINA_TOOL_CALL_REGRESSION_CASES=reminder,notification,calendar_update,cross_domain
#           LUMINA_TOOL_CALL_REGRESSION_REPETITIONS=1 LUMINA_REGRESSION_TIMEOUT=1800
#           LUMINA_TOOL_CALL_REGRESSION_ENGINE_CHECK=1 (native cancel/recovery/budget smoke tests)
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_ROOT="${LUMINA_REGRESSION_RUN_ROOT:-$ROOT_DIR/.build/tool-calling-catalyst}"
DERIVED_DATA="${LUMINA_DERIVED_DATA:-$ROOT_DIR/.build/DerivedData-ToolCallingCatalyst}"
SOURCE_MODEL="${LUMINA_MINICPMV46_ORIGINAL_MODEL:-${LUMINA_MINICPMV46_MODEL:-$ROOT_DIR/model/bundles/original/MiniCPMV46ReActModel}}"
MODEL_DIR="$RUN_ROOT/model"
LLAMA_DIR="${LUMINA_LLAMA_CPP_DIR:-$ROOT_DIR/.build/vendor/llama.cpp}"
LLAMA_BUILD="$RUN_ROOT/llama-build"
PACKAGE_DIR="${LUMINA_SOURCE_PACKAGES_DIR:-$RUN_ROOT/SourcePackages}"
MACABI_VERSION="${LUMINA_CATALYST_DEPLOYMENT_TARGET:-26.0}"
TARGET_TRIPLE="arm64-apple-ios${MACABI_VERSION}-macabi"
REPORT="${LUMINA_TOOL_CALL_REGRESSION_REPORT:-$RUN_ROOT/report.json}"
APP_BUNDLE="$DERIVED_DATA/Build/Products/Debug-maccatalyst/Lumina.app"
export LUMINA_REGRESSION_TIMEOUT="${LUMINA_REGRESSION_TIMEOUT:-1800}"

for command in cmake xcodebuild xcrun python3 codesign; do
    command -v "$command" >/dev/null || { echo "Missing required command: $command" >&2; exit 2; }
done
[[ "$(uname -m)" == "arm64" ]] || { echo 'This local model test requires Apple silicon.' >&2; exit 2; }
[[ -f "$LLAMA_DIR/CMakeLists.txt" ]] || { echo "Missing existing llama.cpp checkout: $LLAMA_DIR" >&2; exit 2; }
[[ -f "$SOURCE_MODEL/model.gguf" && -f "$SOURCE_MODEL/model_config.json" ]] || {
    echo "Missing downloaded MiniCPM bundle: $SOURCE_MODEL" >&2
    exit 2
}
mkdir -p "$RUN_ROOT" "$MODEL_DIR" "$(dirname "$REPORT")"
# Seed a separate package cache from the already resolved local package checkout.
# This keeps the test usable offline and avoids contending with Swift package tests.
if [[ ! -f "$PACKAGE_DIR/workspace-state.json" && -f "$ROOT_DIR/app/.build/workspace-state.json" ]]; then
    mkdir -p "$PACKAGE_DIR"
    cp -R "$ROOT_DIR/app/.build/checkouts" "$ROOT_DIR/app/.build/repositories" "$PACKAGE_DIR/"
    cp "$ROOT_DIR/app/.build/workspace-state.json" "$PACKAGE_DIR/workspace-state.json"
fi
# Link only model data. The repository's iPhone engine must never be loaded by Catalyst.
python3 - "$SOURCE_MODEL" "$MODEL_DIR" <<'PY'
from pathlib import Path
import sys
source, destination = map(lambda value: Path(value).resolve(), sys.argv[1:])
if source == destination:
    raise SystemExit('Source model and isolated Catalyst model directory must differ.')
for item in source.iterdir():
    if item.name.endswith('.dylib'):
        continue
    target = destination / item.name
    if target.is_symlink():
        target.unlink()
    if not target.exists():
        target.symlink_to(item, target_is_directory=item.is_dir())
PY

SDK_ROOT="$(xcrun --sdk macosx --show-sdk-path)"
IOS_SUPPORT="$SDK_ROOT/System/iOSSupport"
CATALYST_C_FLAGS="-target $TARGET_TRIPLE -isystem $IOS_SUPPORT/usr/include -iframework $IOS_SUPPORT/System/Library/Frameworks"
echo "Building Mac Catalyst model engine (log: $RUN_ROOT/engine-build.log)"
cmake -S "$LLAMA_DIR" -B "$LLAMA_BUILD" \
    -DCMAKE_SYSTEM_NAME=Darwin -DCMAKE_OSX_SYSROOT="$SDK_ROOT" \
    -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET= \
    -DCMAKE_C_COMPILER="$(xcrun --sdk macosx --find clang)" \
    -DCMAKE_CXX_COMPILER="$(xcrun --sdk macosx --find clang++)" \
    -DCMAKE_C_FLAGS="$CATALYST_C_FLAGS" -DCMAKE_CXX_FLAGS="$CATALYST_C_FLAGS" \
    -DCMAKE_OBJC_FLAGS="$CATALYST_C_FLAGS" -DCMAKE_OBJCXX_FLAGS="$CATALYST_C_FLAGS" \
    -DCMAKE_ASM_FLAGS="-target $TARGET_TRIPLE" \
    -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
    -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON \
    -DGGML_ACCELERATE=ON -DGGML_OPENMP=OFF \
    -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF \
    -DLLAMA_BUILD_SERVER=OFF -DLLAMA_BUILD_TOOLS=OFF -DLLAMA_CURL=OFF \
    >"$RUN_ROOT/engine-build.log" 2>&1
cmake --build "$LLAMA_BUILD" --target llama -j "${LUMINA_BUILD_JOBS:-8}" >>"$RUN_ROOT/engine-build.log" 2>&1

ARCHIVES=(
    "$LLAMA_BUILD/src/libllama.a"
    "$LLAMA_BUILD/ggml/src/libggml.a"
    "$LLAMA_BUILD/ggml/src/libggml-base.a"
    "$LLAMA_BUILD/ggml/src/libggml-cpu.a"
    "$LLAMA_BUILD/ggml/src/ggml-metal/libggml-metal.a"
    "$LLAMA_BUILD/ggml/src/ggml-blas/libggml-blas.a"
)
LINK_ARGS=()
for archive in "${ARCHIVES[@]}"; do
    [[ -f "$archive" ]] || { echo "Missing Catalyst archive: $archive" >&2; exit 2; }
    LINK_ARGS+=("-Wl,-force_load,$archive")
done
xcrun --sdk macosx clang++ -std=c++17 -O3 -dynamiclib \
    -target "$TARGET_TRIPLE" -isysroot "$SDK_ROOT" \
    -isystem "$IOS_SUPPORT/usr/include" -iframework "$IOS_SUPPORT/System/Library/Frameworks" \
    "$ROOT_DIR/app/NativeEngines/MiniCPMV46/LuminaMiniCPMV46GGUFEngine.cpp" \
    -I"$LLAMA_DIR/include" -I"$LLAMA_DIR/ggml/include" \
    "${LINK_ARGS[@]}" -framework Foundation -framework Metal -framework MetalKit -framework Accelerate \
    -Wl,-install_name,@rpath/libLuminaMiniCPMV46GGUFEngine.dylib \
    -o "$MODEL_DIR/libLuminaMiniCPMV46GGUFEngine.dylib" >>"$RUN_ROOT/engine-build.log" 2>&1
codesign --force --sign - "$MODEL_DIR/libLuminaMiniCPMV46GGUFEngine.dylib"
xcrun vtool -show-build "$MODEL_DIR/libLuminaMiniCPMV46GGUFEngine.dylib" >"$RUN_ROOT/engine-platform.txt"
python3 - "$RUN_ROOT/engine-platform.txt" <<'PY'
from pathlib import Path
import sys
if 'MACCATALYST' not in Path(sys.argv[1]).read_text():
    raise SystemExit('Native engine is not a Mac Catalyst dylib.')
PY

# This override applies to this build only; source entitlements and iPhone signing stay intact.
cat >"$RUN_ROOT/TestSigning.xcconfig" <<'XCCONFIG'
CODE_SIGNING_ALLOWED = NO
CODE_SIGN_ENTITLEMENTS =
CODE_SIGN_ENTITLEMENTS[sdk=macosx*] =
XCCONFIG
echo "Building Mac Catalyst app (log: $RUN_ROOT/app-build.log)"
xcodebuild -project "$ROOT_DIR/app/Lumina.xcodeproj" -scheme Lumina \
    -configuration Debug -destination 'platform=macOS,variant=Mac Catalyst,arch=arm64' \
    -derivedDataPath "$DERIVED_DATA" -xcconfig "$RUN_ROOT/TestSigning.xcconfig" \
    -clonedSourcePackagesDirPath "$PACKAGE_DIR" -disableAutomaticPackageResolution -skipPackageUpdates \
    CODE_SIGNING_ALLOWED=NO build >"$RUN_ROOT/app-build.log" 2>&1
[[ -d "$APP_BUNDLE" ]] || { echo "Built Catalyst app not found: $APP_BUNDLE" >&2; exit 2; }
# Keep the resulting normal App usable without the regression-only model override.
BUNDLED_ENGINE="$APP_BUNDLE/Contents/Resources/Models/MiniCPMV46ReActModel/libLuminaMiniCPMV46GGUFEngine.dylib"
if [[ -d "$(dirname "$BUNDLED_ENGINE")" ]]; then
    cp "$MODEL_DIR/libLuminaMiniCPMV46GGUFEngine.dylib" "$BUNDLED_ENGINE"
fi
codesign --force --deep --sign - "$APP_BUNDLE"

export LUMINA_TOOL_CALL_REGRESSION=1
export LUMINA_TOOL_CALL_REGRESSION_REPORT="$REPORT"
export LUMINA_MINICPMV46_ORIGINAL_MODEL="$MODEL_DIR"
export LUMINA_MINICPMV46_MODEL="$MODEL_DIR"
export LUMINA_MINICPMV46_BACKEND=metal
export LUMINA_MINICPMV46_ENGINE="$MODEL_DIR/libLuminaMiniCPMV46GGUFEngine.dylib"
echo "Running isolated local-model regression (report: $REPORT)"
# Executing the Catalyst executable directly preserves scoped environment variables and exit status.
python3 - "$APP_BUNDLE/Contents/MacOS/Lumina" "$REPORT" "$RUN_ROOT/run.log" <<'PY'
import json
import os
from pathlib import Path
import subprocess
import sys

executable, report_path, log_path = sys.argv[1:]
report = Path(report_path)
if report.exists():
    report.unlink()
with open(log_path, 'w') as log:
    try:
        run = subprocess.run([executable], env=os.environ.copy(), stdout=log, stderr=subprocess.STDOUT,
                             timeout=int(os.environ['LUMINA_REGRESSION_TIMEOUT']))
    except subprocess.TimeoutExpired:
        print(f'Catalyst regression timed out. Partial report: {report_path}; log: {log_path}', file=sys.stderr)
        raise SystemExit(124)
if not report.exists():
    print(f'No regression report was produced (exit {run.returncode}); see {log_path}', file=sys.stderr)
    raise SystemExit(run.returncode or 2)
data = json.loads(report.read_text())
engine_passed = True
if os.environ.get('LUMINA_TOOL_CALL_REGRESSION_ENGINE_CHECK') == '1':
    engine_path = report.parent / 'engine-check.json'
    if engine_path.exists():
        engine = json.loads(engine_path.read_text())
        engine_passed = bool(engine.get('finishedAt') and engine.get('passed'))
        for check in engine['checks']:
            print(f"engine/{check['name']}: {'PASS' if check['passed'] else 'FAIL'}; elapsed={check['elapsedMilliseconds']:.1f}ms")
            if not check['passed']:
                print(f"  {check['detail']}")
        print(f'Engine report: {engine_path}')
    else:
        engine_passed = False
        print(f'Missing native engine check report: {engine_path}', file=sys.stderr)
for case in data['cases']:
    print(f"{case['scenario']['id']} #{case['repetition']}: {'PASS' if case['passed'] else 'FAIL'}; "
          f"iterations={case['iterations']}, promptTokens={case['promptTokens']}, "
          f"elapsed={case['elapsedMilliseconds'] / 1000:.1f}s")
    for failure in case['failures']:
        print(f'  {failure}')
print(f'Report: {report_path}\nLog: {log_path}')
raise SystemExit(0 if run.returncode == 0 and data.get('finishedAt') and data['passed'] and engine_passed else 1)
PY
