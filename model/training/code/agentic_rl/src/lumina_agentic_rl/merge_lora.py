from __future__ import annotations

import argparse
from pathlib import Path

import torch


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Merge a Lumina LoRA adapter into MiniCPM-V HF weights.")
    parser.add_argument("--base-model", required=True, type=Path)
    parser.add_argument("--adapter", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    return parser.parse_args()


def main() -> None:
    from peft import PeftModel
    from transformers import AutoModelForImageTextToText, AutoProcessor

    args = parse_args()
    args.output.mkdir(parents=True, exist_ok=True)

    model = AutoModelForImageTextToText.from_pretrained(
        args.base_model,
        torch_dtype=torch.bfloat16,
        device_map="auto",
        trust_remote_code=True,
    )
    model = PeftModel.from_pretrained(model, args.adapter)
    merged = model.merge_and_unload()
    merged.save_pretrained(args.output, safe_serialization=True)

    processor = AutoProcessor.from_pretrained(args.base_model, trust_remote_code=True)
    processor.save_pretrained(args.output)


if __name__ == "__main__":
    main()
