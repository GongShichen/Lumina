#!/usr/bin/env bash
set -euo pipefail

swift test
bash scripts/check_filename_alignment.sh
xcodebuild -project Lumina.xcodeproj -list >/dev/null

xcodebuild -project Lumina.xcodeproj -scheme AgentRuntime -destination 'platform=macOS,variant=Mac Catalyst' build
xcodebuild -project Lumina.xcodeproj -scheme PersonalMemory -destination 'platform=macOS,variant=Mac Catalyst' build
xcodebuild -project Lumina.xcodeproj -scheme LuminaModelRuntime -destination 'platform=macOS,variant=Mac Catalyst' build
xcodebuild -project Lumina.xcodeproj -scheme LuminaMarkdownUI -destination 'platform=macOS,variant=Mac Catalyst' build
xcodebuild -project Lumina.xcodeproj -scheme LuminaAppCore -destination 'platform=macOS,variant=Mac Catalyst' build
xcodebuild -project Lumina.xcodeproj -scheme Lumina -destination 'platform=macOS,variant=Mac Catalyst' CODE_SIGNING_ALLOWED=NO build
