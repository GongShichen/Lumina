#!/usr/bin/env bash
set -euo pipefail

ROOT="${ROOT:-/root/rivermind-data/lumina-agentic-training}"
CODE_DIR="${CODE_DIR:-${ROOT}/code/agentic_rl}"
BASE_MODEL="${BASE_MODEL:-${ROOT}/models/base/openbmb-MiniCPM-V-4.6}"
ADAPTER="${ADAPTER:-${ROOT}/runs/dpo-lora}"
MERGED="${MERGED:-${ROOT}/artifacts/merged-hf/MiniCPM-V-4.6-AgenticSFTDPO}"
CONVERT_HF="${CONVERT_HF:-${ROOT}/artifacts/merged-hf/MiniCPM-V-4.6-AgenticSFTDPO-gguf-input}"
LLAMA_CPP="${LLAMA_CPP:-${ROOT}/llama.cpp}"
GGUF_F16="${GGUF_F16:-${ROOT}/artifacts/MiniCPMV46ReActModel-AgenticSFTDPO-F16.gguf}"
BUNDLE="${BUNDLE:-${ROOT}/artifacts/MiniCPMV46ReActModel-AgenticSFTDPO-Q8}"
PROJECTOR_GGUF="${PROJECTOR_GGUF:-}"

if [[ -x /usr/local/cuda/bin/nvcc ]]; then
  export CUDACXX="${CUDACXX:-/usr/local/cuda/bin/nvcc}"
  export CUDA_HOME="${CUDA_HOME:-/usr/local/cuda}"
  export CUDA_PATH="${CUDA_PATH:-/usr/local/cuda}"
  export PATH="/usr/local/cuda/bin:${PATH}"
fi

cd "${CODE_DIR}"
uv run python -m lumina_agentic_rl.merge_lora \
  --base-model "${BASE_MODEL}" \
  --adapter "${ADAPTER}" \
  --output "${MERGED}"

rm -rf "${CONVERT_HF}"
mkdir -p "${CONVERT_HF}"
(cd "${MERGED}" && tar -cf - .) | (cd "${CONVERT_HF}" && tar -xf -)

uv run python - "${CONVERT_HF}/config.json" <<'PY'
from __future__ import annotations

import json
import sys
from pathlib import Path

config_path = Path(sys.argv[1])
config = json.loads(config_path.read_text(encoding="utf-8"))
text_config = config.get("text_config") or {}

# MiniCPM-V 4.6 config may advertise one MTP/next-token-prediction layer even
# when the saved HF checkpoint has only the 24 main decoder layers. llama.cpp
# then writes qwen35.block_count=25 and produces a GGUF that asks for blk.24.*
# tensors that do not exist. Disable the absent MTP layer in the temporary
# conversion copy only; the merged HF model remains unchanged.
if int(text_config.get("mtp_num_hidden_layers") or 0) > 0:
    text_config["mtp_num_hidden_layers"] = 0
    text_config["mtp_use_dedicated_embeddings"] = False
    config["text_config"] = text_config
    config_path.write_text(
        json.dumps(config, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
PY

if [[ ! -d "${LLAMA_CPP}" ]]; then
  git clone --depth 1 https://github.com/ggml-org/llama.cpp "${LLAMA_CPP}"
fi

cmake -S "${LLAMA_CPP}" -B "${LLAMA_CPP}/build" -DGGML_CUDA=ON -DCMAKE_BUILD_TYPE=Release
cmake --build "${LLAMA_CPP}/build" --config Release -j"$(nproc)"

uv run python "${LLAMA_CPP}/convert_hf_to_gguf.py" "${CONVERT_HF}" --outfile "${GGUF_F16}" --outtype f16

mkdir -p "${BUNDLE}"
"${LLAMA_CPP}/build/bin/llama-quantize" "${GGUF_F16}" "${BUNDLE}/model.gguf" Q8_0
cp "${MERGED}/config.json" "${BUNDLE}/hf_config.json"
cp "${MERGED}/tokenizer_config.json" "${BUNDLE}/tokenizer_config.json" 2>/dev/null || true
cp "${MERGED}/chat_template.jinja" "${BUNDLE}/chat_template.jinja" 2>/dev/null || true

if [[ -n "${PROJECTOR_GGUF}" && -f "${PROJECTOR_GGUF}" ]]; then
  cp "${PROJECTOR_GGUF}" "${BUNDLE}/mmproj-model-f16.gguf"
elif [[ -f "${BASE_MODEL}/mmproj-model-f16.gguf" ]]; then
  cp "${BASE_MODEL}/mmproj-model-f16.gguf" "${BUNDLE}/mmproj-model-f16.gguf"
elif [[ -f "${ROOT}/models/gguf/openbmb-MiniCPM-V-4_6-gguf/mmproj-model-f16.gguf" ]]; then
  cp "${ROOT}/models/gguf/openbmb-MiniCPM-V-4_6-gguf/mmproj-model-f16.gguf" "${BUNDLE}/mmproj-model-f16.gguf"
else
  echo "Warning: mmproj-model-f16.gguf was not found; set PROJECTOR_GGUF to package multimodal projector." >&2
fi

cat > "${BUNDLE}/model_config.json" <<'JSON'
{
  "model_name": "MiniCPM-V 4.6 Agentic SFT+DPO",
  "architecture": "minicpm-v-4_6",
  "context_length": 16000,
  "quantization": "Q8_0",
  "text_model": "model.gguf",
  "vision_projector": "mmproj-model-f16.gguf",
  "source_repo": "openbmb/MiniCPM-V-4.6",
  "base_model_preserved": true,
  "training": "BF16 XML ReAct SFT then standard DPO",
  "runtime": "LuminaModelRuntimeCore native C++"
}
JSON

find "${BUNDLE}" -maxdepth 1 -type f -print
