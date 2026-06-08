#!/usr/bin/env bash
set -euo pipefail

export HF_ENDPOINT="${HF_ENDPOINT:-https://hf-mirror.com}"
MODEL_ID="${MODEL_ID:-openbmb/MiniCPM-V-4.6}"
OUT_DIR="${OUT_DIR:-/root/rivermind-data/lumina-agentic-training/models/base/openbmb-MiniCPM-V-4.6}"

mkdir -p "${OUT_DIR}"
uv run hf download "${MODEL_ID}" \
  --local-dir "${OUT_DIR}" \
  --include "*.safetensors" \
  --include "*.json" \
  --include "*.txt" \
  --include "*.model" \
  --include "*.py" \
  --include "*.jinja" \
  --include "*.tiktoken" \
  --include "*.md"
