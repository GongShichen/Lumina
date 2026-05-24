#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTEXT_LENGTH="${LUMINA_GEMMA4_CONTEXT_LENGTH:-12000}"
VENV_DIR="${LUMINA_GEMMA4_CONVERT_VENV:-$ROOT_DIR/.venv-gemma4-convert}"
PYTHON_BIN="$VENV_DIR/bin/python"
CONVERSION_REQUIREMENTS="$ROOT_DIR/.build/checkouts/CoreML-LLM/conversion/requirements.txt"

if [[ ! -f "$CONVERSION_REQUIREMENTS" ]]; then
  echo "[Lumina] Missing CoreML-LLM conversion requirements at $CONVERSION_REQUIREMENTS" >&2
  echo "[Lumina] Run swift package resolve first, then retry." >&2
  exit 1
fi

if [[ ! -x "$PYTHON_BIN" ]]; then
  if command -v uv >/dev/null 2>&1; then
    echo "[Lumina] Creating conversion environment with uv: $VENV_DIR"
    uv venv "$VENV_DIR"
  else
    echo "[Lumina] Creating conversion environment with python3 -m venv: $VENV_DIR"
    python3 -m venv "$VENV_DIR"
  fi
fi

if ! "$PYTHON_BIN" - <<'PY' >/dev/null 2>&1
import coremltools, torch, safetensors, huggingface_hub, numpy
PY
then
  if command -v uv >/dev/null 2>&1; then
    echo "[Lumina] Installing conversion dependencies with uv"
    uv pip install --python "$PYTHON_BIN" -r "$CONVERSION_REQUIREMENTS"
  else
    echo "[Lumina] Installing conversion dependencies with pip"
    "$PYTHON_BIN" -m ensurepip --upgrade
    "$PYTHON_BIN" -m pip install -r "$CONVERSION_REQUIREMENTS"
  fi
fi

echo "[Lumina] Building Gemma4 stateful Core ML planner with context=$CONTEXT_LENGTH"
PYTHON_BIN="$PYTHON_BIN" \
LUMINA_GEMMA4_CONTEXT_LENGTH="$CONTEXT_LENGTH" \
"$ROOT_DIR/scripts/build_gemma4_stateful_context.sh"

echo "[Lumina] Verifying installed Gemma4 planner"
"$ROOT_DIR/scripts/validate_gemma4_bundle.py" \
  "$ROOT_DIR/Resources/Models/Gemma4Planner" \
  --expected-context "$CONTEXT_LENGTH"
