#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "[Lumina] Cleaning build artifacts while preserving model assets"

rm -rf \
  "$ROOT_DIR/.build" \
  "$ROOT_DIR/.swiftpm" \
  "$ROOT_DIR/DerivedData" \
  "$ROOT_DIR/LuminaAgentRuntime/.build" \
  "$ROOT_DIR/LuminaAgentRuntime/.swiftpm" \
  "$ROOT_DIR/app/.build" \
  "$ROOT_DIR/app/.swiftpm" \
  "$ROOT_DIR/app/DerivedData" \
  "$ROOT_DIR/app/Reports" \
  "$ROOT_DIR/app/Lumina.xcodeproj/project.xcworkspace/xcshareddata/swiftpm" \
  "$ROOT_DIR/app/Lumina.xcodeproj/project.xcworkspace/xcuserdata"

find "$ROOT_DIR" -name "*.xcresult" -prune -exec rm -rf {} +
find "$ROOT_DIR" -name "Package.resolved" -type f -delete
find "$ROOT_DIR/scripts" -type d -name "__pycache__" -prune -exec rm -rf {} +

echo "[Lumina] Preserved model directory: $ROOT_DIR/app/Resources/Models"
