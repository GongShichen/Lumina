#!/usr/bin/env bash
set -euo pipefail

MODEL_ID="${MODEL_ID:-OpenBMB/MiniCPM-V-4.6}"
OUT_DIR="${OUT_DIR:-/root/rivermind-data/lumina-agentic-training/models/base/openbmb-MiniCPM-V-4.6}"

mkdir -p "${OUT_DIR}"
MODEL_ID="${MODEL_ID}" OUT_DIR="${OUT_DIR}" uv run python - <<'PY'
import os

from modelscope.hub.snapshot_download import snapshot_download

snapshot_download(os.environ["MODEL_ID"], local_dir=os.environ["OUT_DIR"])
PY
