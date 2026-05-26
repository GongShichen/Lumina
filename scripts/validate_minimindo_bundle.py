#!/usr/bin/env python3
import argparse
import json
from pathlib import Path


def read_json(path: Path) -> dict:
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def main() -> None:
    parser = argparse.ArgumentParser(description="Validate Lumina MiniMind-o Core ML bundle.")
    parser.add_argument("bundle", type=Path)
    parser.add_argument("--expected-context", type=int, default=12000)
    args = parser.parse_args()

    root = args.bundle
    if not root.exists():
        raise SystemExit(f"MiniMind-o bundle does not exist: {root}")

    config_path = root / "model_config.json"
    tokenizer_path = root / "hf_model" / "tokenizer.json"
    compiled_path = root / "model.mlmodelc"
    package_path = root / "model.mlpackage"

    missing = []
    if not config_path.exists():
        missing.append("model_config.json")
    if not tokenizer_path.exists():
        missing.append("hf_model/tokenizer.json")
    if not compiled_path.exists() and not package_path.exists():
        missing.append("model.mlmodelc or model.mlpackage")
    if missing:
        raise SystemExit("MiniMind-o bundle is incomplete. Missing: " + ", ".join(missing))

    config = read_json(config_path)
    architecture = config.get("architecture") or config.get("model_type")
    if not isinstance(architecture, str) or not architecture.startswith("minimind"):
        raise SystemExit(f"Unexpected MiniMind-o architecture: {architecture!r}")

    context = config.get("context_length") or config.get("max_position_embeddings")
    if context != args.expected_context:
        raise SystemExit(
            f"MiniMind-o context_length is {context}, expected {args.expected_context}. "
            "Rebuild the Core ML bundle instead of editing only app code."
        )

    print(
        "[Lumina] MiniMind-o bundle OK: "
        f"architecture={architecture}, context={context}, "
        f"model={'compiled' if compiled_path.exists() else 'mlpackage'}, tokenizer=hf_model/tokenizer.json"
    )


if __name__ == "__main__":
    main()
