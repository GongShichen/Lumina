#!/usr/bin/env bash
set -euo pipefail

ROOT="${ROOT:-/root/rivermind-data/lumina-agentic-training}"
CODE_DIR="${CODE_DIR:-${ROOT}/code/agentic_rl}"
MODEL_ID="${MODEL_ID:-OpenBMB/MiniCPM-V-4.6}"
MODEL_DIR="${MODEL_DIR:-${ROOT}/models/base/openbmb-MiniCPM-V-4.6}"
export LUMINA_TRAINING_DATA_ROOT="${LUMINA_TRAINING_DATA_ROOT:-${ROOT}/data}"
export CUDA_VISIBLE_DEVICES="${CUDA_VISIBLE_DEVICES:-0,1,2,3}"
export PYTORCH_CUDA_ALLOC_CONF="${PYTORCH_CUDA_ALLOC_CONF:-expandable_segments:True}"
export HF_HOME="${HF_HOME:-${ROOT}/cache/huggingface}"
export MODELSCOPE_CACHE="${MODELSCOPE_CACHE:-${ROOT}/cache/modelscope}"
export UV_CACHE_DIR="${UV_CACHE_DIR:-${ROOT}/cache/uv}"
export SWANLAB_MODE="${SWANLAB_MODE:-cloud}"
ACCELERATE_CONFIG="${ACCELERATE_CONFIG:-configs/accelerate_multi_gpu.yaml}"
ACCELERATE_NUM_PROCESSES="${ACCELERATE_NUM_PROCESSES:-$(python3 - <<'PY'
import os
visible = [item.strip() for item in os.environ.get("CUDA_VISIBLE_DEVICES", "").split(",") if item.strip()]
print(len(visible) or 1)
PY
)}"

if [ -z "${SWANLAB_API_KEY:-}" ]; then
  echo "SWANLAB_API_KEY is required for cloud logging." >&2
  exit 2
fi

mkdir -p "${ROOT}/logs" "${ROOT}/runs" "${ROOT}/models/base" "${HF_HOME}" "${MODELSCOPE_CACHE}" "${UV_CACHE_DIR}"
cd "${CODE_DIR}"

uv sync --frozen

MODEL_ID="${MODEL_ID}" MODEL_DIR="${MODEL_DIR}" MODELSCOPE_CACHE="${MODELSCOPE_CACHE}" \
  uv run --with modelscope python - <<'PY'
import inspect
import os
from pathlib import Path

try:
    from modelscope import snapshot_download
except ImportError:
    from modelscope.hub.snapshot_download import snapshot_download

model_id = os.environ["MODEL_ID"]
model_dir = Path(os.environ["MODEL_DIR"])
cache_dir = Path(os.environ["MODELSCOPE_CACHE"])
model_dir.parent.mkdir(parents=True, exist_ok=True)
cache_dir.mkdir(parents=True, exist_ok=True)

kwargs = {}
signature = inspect.signature(snapshot_download)
if "local_dir" in signature.parameters:
    kwargs["local_dir"] = str(model_dir)
if "cache_dir" in signature.parameters:
    kwargs["cache_dir"] = str(cache_dir)

downloaded = Path(snapshot_download(model_id, **kwargs)).resolve()
if not model_dir.exists():
    model_dir.symlink_to(downloaded, target_is_directory=True)
print(f"ModelScope model path: {model_dir.resolve()}")
PY

uv run python -m accelerate.commands.launch --config_file "${ACCELERATE_CONFIG}" --num_processes "${ACCELERATE_NUM_PROCESSES}" \
  -m lumina_agentic_rl.train_sft --config configs/sft_lora.yaml

find "${ROOT}/runs/sft-lora" -maxdepth 1 -type d -name 'checkpoint-*' -exec rm -rf {} +

uv run python -m lumina_agentic_rl.holdout_minicpm_first_step \
  --config configs/sft_lora.yaml \
  --data ../TrainingData/splits/sft_evaluation_test.jsonl \
  --adapter "${ROOT}/runs/sft-lora" \
  --sample-size 160 \
  --threshold 0.90 \
  --output "${ROOT}/runs/sft_holdout_first_step.json"

uv run python -m lumina_agentic_rl.train_dpo --config configs/dpo_lora_model_parallel.yaml

find "${ROOT}/runs/dpo-lora" -maxdepth 1 -type d -name 'checkpoint-*' -exec rm -rf {} +
