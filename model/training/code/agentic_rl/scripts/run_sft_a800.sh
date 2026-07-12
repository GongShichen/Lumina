#!/usr/bin/env bash
set -euo pipefail

ROOT="${ROOT:-/root/rivermind-data/lumina-agentic-training}"
CODE_DIR="${CODE_DIR:-${ROOT}/code/agentic_rl}"
export HF_ENDPOINT="${HF_ENDPOINT:-https://hf-mirror.com}"
export LUMINA_TRAINING_DATA_ROOT="${LUMINA_TRAINING_DATA_ROOT:-${ROOT}/data}"
export CUDA_VISIBLE_DEVICES="${CUDA_VISIBLE_DEVICES:-0}"
export PYTORCH_CUDA_ALLOC_CONF="${PYTORCH_CUDA_ALLOC_CONF:-expandable_segments:True}"
export HF_HOME="${HF_HOME:-${ROOT}/cache/huggingface}"
export TRITON_CACHE_DIR="${TRITON_CACHE_DIR:-${ROOT}/cache/triton}"
mkdir -p "${HF_HOME}" "${TRITON_CACHE_DIR}"
SWANLAB_ENV_FILE="${SWANLAB_ENV_FILE:-${ROOT}/.secrets/swanlab.env}"
if [[ -f "${SWANLAB_ENV_FILE}" ]]; then
  set -a
  source "${SWANLAB_ENV_FILE}"
  set +a
fi

cd "${CODE_DIR}"
uv run --no-sync accelerate launch --config_file configs/accelerate_a800.yaml \
  -m lumina_agentic_rl.train_sft --config configs/sft_lora.yaml
