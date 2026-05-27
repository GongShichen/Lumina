#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA="${LUMINA_DERIVED_DATA:-$ROOT_DIR/.build/DerivedData}"

swift test --package-path "$ROOT_DIR/LuminaAgentRuntime"
swift test --package-path "$ROOT_DIR/app"
bash "$ROOT_DIR/scripts/check_filename_alignment.sh"

xcodebuild -project "$ROOT_DIR/app/Lumina.xcodeproj" -list >/dev/null
xcodebuild \
  -project "$ROOT_DIR/app/Lumina.xcodeproj" \
  -scheme Lumina \
  -destination 'platform=macOS,variant=Mac Catalyst' \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=NO \
  build
