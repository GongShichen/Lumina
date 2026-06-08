from __future__ import annotations

import argparse
import json
import shutil
from pathlib import Path

import torch
from safetensors.torch import load_file, save_file


COPY_FILES = (
    "adapter_config.json",
    "README.md",
    "processor_config.json",
    "tokenizer.json",
    "tokenizer_config.json",
    "chat_template.jinja",
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Interpolate two compatible LoRA adapters.")
    parser.add_argument("--base-adapter", required=True, type=Path, help="Adapter to preserve at lambda=0.")
    parser.add_argument("--target-adapter", required=True, type=Path, help="Adapter to reach at lambda=1.")
    parser.add_argument("--lambda", dest="lam", required=True, type=float, help="Interpolation factor.")
    parser.add_argument("--output", required=True, type=Path)
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    if not (0.0 <= args.lam <= 1.0):
        raise SystemExit("--lambda must be in [0, 1]")

    base_weights = load_file(str(args.base_adapter / "adapter_model.safetensors"))
    target_weights = load_file(str(args.target_adapter / "adapter_model.safetensors"))
    base_keys = set(base_weights)
    target_keys = set(target_weights)
    if base_keys != target_keys:
        raise SystemExit(
            "adapter tensor keys differ: "
            f"base_only={len(base_keys - target_keys)} target_only={len(target_keys - base_keys)}"
        )

    mixed: dict[str, torch.Tensor] = {}
    for key in sorted(base_keys):
        base_tensor = base_weights[key]
        target_tensor = target_weights[key]
        if base_tensor.shape != target_tensor.shape:
            raise SystemExit(f"shape mismatch for {key}: {base_tensor.shape} vs {target_tensor.shape}")
        mixed[key] = (base_tensor.float() + args.lam * (target_tensor.float() - base_tensor.float())).to(base_tensor.dtype)

    if args.output.exists():
        shutil.rmtree(args.output)
    args.output.mkdir(parents=True)
    save_file(mixed, str(args.output / "adapter_model.safetensors"))

    for filename in COPY_FILES:
        source = args.target_adapter / filename
        if source.exists():
            shutil.copy2(source, args.output / filename)

    manifest = {
        "base_adapter": str(args.base_adapter),
        "target_adapter": str(args.target_adapter),
        "lambda": args.lam,
        "tensor_count": len(mixed),
        "method": "base + lambda * (target - base)",
    }
    (args.output / "interpolation_manifest.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )


if __name__ == "__main__":
    main()
