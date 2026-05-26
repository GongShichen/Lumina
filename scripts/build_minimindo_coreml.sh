#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"
REPO="${LUMINA_MINIMINDO_REPO:-jingyaogong/minimind-3o}"
CONTEXT_LENGTH="${LUMINA_MINIMINDO_CONTEXT_LENGTH:-12000}"
OUTPUT_DIR="${LUMINA_MINIMINDO_OUTPUT_DIR:-$ROOT_DIR/Resources/Models/MiniMindOReActModel}"
HF_DIR="${LUMINA_MINIMINDO_HF_DIR:-}"
SKIP_COMPILE="${LUMINA_MINIMINDO_SKIP_COMPILE:-0}"

if ! "$PYTHON_BIN" - <<'PY' >/dev/null 2>&1
import coremltools, torch, transformers, huggingface_hub
PY
then
  cat >&2 <<EOF
[Lumina] Missing MiniMind-o conversion dependencies.
Install them in a conversion environment, for example:
  $PYTHON_BIN -m pip install coremltools torch transformers huggingface_hub accelerate
EOF
  exit 2
fi

args=(
  "$ROOT_DIR/scripts/convert_minimindo_coreml.py"
  --repo "$REPO"
  --output "$OUTPUT_DIR"
  --context-length "$CONTEXT_LENGTH"
)

if [[ -n "$HF_DIR" ]]; then
  args+=(--hf-dir "$HF_DIR")
fi
if [[ "$SKIP_COMPILE" == "1" ]]; then
  args+=(--skip-compile)
fi

echo "[Lumina] Building MiniMind-o Core ML bundle"
echo "  repo:    $REPO"
echo "  context: $CONTEXT_LENGTH"
echo "  output:  $OUTPUT_DIR"
"$PYTHON_BIN" "${args[@]}"

if [[ "${LUMINA_MINIMINDO_KEEP_MLPACKAGE:-0}" != "1" && -d "$OUTPUT_DIR/model.mlmodelc" ]]; then
  rm -rf "$OUTPUT_DIR/model.mlpackage"
fi

"$ROOT_DIR/scripts/validate_minimindo_bundle.py" "$OUTPUT_DIR" --expected-context "$CONTEXT_LENGTH"
echo "[Lumina] MiniMind-o Core ML bundle ready at $OUTPUT_DIR"
