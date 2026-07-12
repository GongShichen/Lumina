# Lumina Agentic SFT+DPO

Local training data lives in `../../data/TrainingData/`.

The public-data build is intentionally focused on tool use, multi-step agents,
and multi-hop reasoning. Model-visible semantic content must come verbatim from
public source fields. The builder may only map role tags, serialize source JSON,
and convert source tool calls to MiniCPM transport tokens. It never creates system
prompts, instructions, reasoning, schemas, or rejected responses. Records are
split by `sourceGroupId`; source fields are never sliced, and records over 4096
MiniCPM tokens are dropped whole.

Remote data build (the Parquet index is metadata only; data downloads on the
training server):

```bash
python scripts/build_minicpm_training_data.py \
  --root /root/rivermind-data/lumina-agentic-training/data/TrainingData \
  --cache-dir /root/rivermind-data/lumina-agentic-training/cache/public_training_parquet \
  --processor-path /root/rivermind-data/lumina-agentic-training/models/base/openbmb-MiniCPM-V-4.6 \
  --max-tokens 4096 \
  --parquet-index configs/public_parquet_index.json \
  --hf-download-mirror https://hf-mirror.com

python scripts/qa_training_xml_data.py \
  --root /root/rivermind-data/lumina-agentic-training/data/TrainingData
```

Single A800 run:

```bash
cd agentic_rl
uv sync
scripts/run_sft_a800.sh

# Run only after the SFT result has passed evaluation.
scripts/run_dpo_a800.sh
```

The default configs use LoRA, bf16, gradient checkpointing, and the general
train/test splits. DPO keeps a reference model (`reference_free: false`) and
starts without 8-bit loading; enable `load_in_8bit` only if DPO runs out of
memory.
