#!/usr/bin/env python3
import argparse
import json
from pathlib import Path


def main() -> None:
    parser = argparse.ArgumentParser(description="Validate Lumina MiniCPM-V 4.6 GGUF bundle.")
    parser.add_argument("bundle", type=Path)
    parser.add_argument("--expected-context", type=int, default=16000)
    args = parser.parse_args()

    root = args.bundle
    if not root.exists():
        raise SystemExit(f"MiniCPM-V 4.6 bundle does not exist: {root}")

    config_path = root / "model_config.json"
    if not config_path.exists():
        raise SystemExit("MiniCPM-V 4.6 bundle is missing model_config.json")
    config = json.loads(config_path.read_text(encoding="utf-8"))

    missing = []
    for relative in [config.get("text_model", "model.gguf"), config.get("vision_projector", "mmproj-model-f16.gguf")]:
        if relative and not (root / relative).exists():
            missing.append(relative)
    if missing:
        raise SystemExit("MiniCPM-V 4.6 bundle is incomplete. Missing: " + ", ".join(missing))

    architecture = config.get("architecture")
    if not isinstance(architecture, str) or not architecture.startswith("minicpm"):
        raise SystemExit(f"Unexpected MiniCPM-V 4.6 architecture: {architecture!r}")

    context = int(config.get("context_length", 0))
    if context != args.expected_context:
        raise SystemExit(
            f"MiniCPM-V 4.6 context_length is {context}, expected {args.expected_context}."
        )

    print(
        "[Lumina] MiniCPM-V 4.6 bundle OK: "
        f"context={context}, model={config.get('text_model')}, quant={config.get('quantization')}"
    )


if __name__ == "__main__":
    main()
