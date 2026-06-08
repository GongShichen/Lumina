# Lumina Agentic SFT+DPO

Local training data lives in `../../data/TrainingData/`.

Generic multi-GPU run:

```bash
cd agentic_rl
uv sync
CUDA_VISIBLE_DEVICES=0,1,2,3 uv run accelerate launch \
  --config_file configs/accelerate_multi_gpu.yaml \
  --num_processes 4 \
  -m lumina_agentic_rl.train_sft \
  --config configs/sft_lora.yaml

CUDA_VISIBLE_DEVICES=0,1,2,3 uv run accelerate launch \
  --config_file configs/accelerate_multi_gpu.yaml \
  --num_processes 4 \
  -m lumina_agentic_rl.train_dpo \
  --config configs/dpo_lora.yaml
```

Set `CUDA_VISIBLE_DEVICES` to the GPU IDs you want to use, and set `--num_processes` to the same count. The default configs use LoRA, bf16, DDP, gradient checkpointing, and the general train/test splits.
