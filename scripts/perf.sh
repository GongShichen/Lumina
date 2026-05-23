#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPORT_DIR="$ROOT_DIR/Reports"
mkdir -p "$REPORT_DIR"

if [[ "${1:-}" == "--heavy" ]]; then
  export LUMINA_RUN_HEAVY_BENCHMARKS=1
fi
if [[ "${1:-}" == "--strict" || "${2:-}" == "--strict" ]]; then
  export LUMINA_STRICT_PERF=1
fi
if [[ "${1:-}" == "--model" || "${2:-}" == "--model" || "${3:-}" == "--model" ]]; then
  export LUMINA_RUN_MODEL_BENCHMARKS=1
fi

STARTED_AT="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
SWIFT_VERSION="$(swift --version | head -n 1)"
UNAME="$(uname -a)"
LOG_FILE="$REPORT_DIR/benchmark-latest.log"
JSON_FILE="$REPORT_DIR/benchmark-latest.json"
MD_FILE="$REPORT_DIR/benchmark-latest.md"

cd "$ROOT_DIR"
swift test --filter PerformanceTests | tee "$LOG_FILE"

cat > "$JSON_FILE" <<JSON
{
  "startedAt": "$STARTED_AT",
  "swiftVersion": "$SWIFT_VERSION",
  "system": "$UNAME",
  "strict": "${LUMINA_STRICT_PERF:-0}",
  "heavy": "${LUMINA_RUN_HEAVY_BENCHMARKS:-0}",
  "model": "${LUMINA_RUN_MODEL_BENCHMARKS:-0}",
  "log": "Reports/benchmark-latest.log"
}
JSON

cat > "$MD_FILE" <<MD
# Lumina Benchmark Report

- Started: \`$STARTED_AT\`
- Swift: \`$SWIFT_VERSION\`
- System: \`$UNAME\`
- Strict: \`${LUMINA_STRICT_PERF:-0}\`
- Heavy: \`${LUMINA_RUN_HEAVY_BENCHMARKS:-0}\`
- Model: \`${LUMINA_RUN_MODEL_BENCHMARKS:-0}\`
- Log: \`Reports/benchmark-latest.log\`

The XCTest log contains per-test pass/fail and skip details. Strict thresholds are enabled with \`LUMINA_STRICT_PERF=1\`.
MD

echo "Wrote $JSON_FILE"
echo "Wrote $MD_FILE"
