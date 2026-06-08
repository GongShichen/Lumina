#!/usr/bin/env bash
set -euo pipefail

ROOT="${ROOT:-/root/rivermind-data/lumina-agentic-training}"
CODE_DIR="${CODE_DIR:-${ROOT}/code/agentic_rl}"
export HF_ENDPOINT="${HF_ENDPOINT:-https://hf-mirror.com}"
export LUMINA_TRAINING_DATA_ROOT="${LUMINA_TRAINING_DATA_ROOT:-${ROOT}/data}"
export CUDA_VISIBLE_DEVICES="${CUDA_VISIBLE_DEVICES:-0,1}"
export PYTORCH_CUDA_ALLOC_CONF="${PYTORCH_CUDA_ALLOC_CONF:-expandable_segments:True}"
ACCELERATE_CONFIG="${ACCELERATE_CONFIG:-configs/accelerate_multi_gpu.yaml}"
ACCELERATE_NUM_PROCESSES="${ACCELERATE_NUM_PROCESSES:-$(python3 - <<'PY'
import os
visible = [item.strip() for item in os.environ.get("CUDA_VISIBLE_DEVICES", "").split(",") if item.strip()]
print(len(visible) or 1)
PY
)}"

cd "${CODE_DIR}"

uv run accelerate launch --config_file "${ACCELERATE_CONFIG}" --num_processes "${ACCELERATE_NUM_PROCESSES}" \
  -m lumina_agentic_rl.train_sft --config configs/sft_lora.yaml

uv run accelerate launch --config_file "${ACCELERATE_CONFIG}" --num_processes "${ACCELERATE_NUM_PROCESSES}" \
  -m lumina_agentic_rl.train_dpo --config configs/dpo_lora.yaml
