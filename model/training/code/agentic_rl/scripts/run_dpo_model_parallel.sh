#!/usr/bin/env bash
set -euo pipefail

ROOT="${ROOT:-/root/rivermind-data/lumina-agentic-training}"
CODE_DIR="${CODE_DIR:-${ROOT}/code/agentic_rl}"
export HF_ENDPOINT="${HF_ENDPOINT:-https://hf-mirror.com}"
export LUMINA_TRAINING_DATA_ROOT="${LUMINA_TRAINING_DATA_ROOT:-${ROOT}/data}"
export CUDA_VISIBLE_DEVICES="${CUDA_VISIBLE_DEVICES:-0,1}"
export PYTORCH_CUDA_ALLOC_CONF="${PYTORCH_CUDA_ALLOC_CONF:-expandable_segments:True}"

cd "${CODE_DIR}"
uv run python -m lumina_agentic_rl.train_dpo --config configs/dpo_lora_model_parallel.yaml
