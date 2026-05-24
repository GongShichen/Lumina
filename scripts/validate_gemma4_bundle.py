#!/usr/bin/env python3
from __future__ import annotations

import argparse
import ast
import json
import struct
from pathlib import Path


def npy_first_dimension(path: Path) -> int:
    with path.open("rb") as f:
        magic = f.read(6)
        if magic != b"\x93NUMPY":
            raise ValueError(f"{path.name} is not a .npy file")
        major, _minor = struct.unpack("BB", f.read(2))
        if major == 1:
            header_len = struct.unpack("<H", f.read(2))[0]
        else:
            header_len = struct.unpack("<I", f.read(4))[0]
        header = f.read(header_len).decode("ascii")
    shape = ast.literal_eval(header)["shape"]
    return int(shape[0])


def shape_numbers(shape: str) -> list[int]:
    return [int(part.strip()) for part in shape.strip("[]").split(",") if part.strip()]


def context_from_entry(entry: dict) -> int | None:
    name = entry.get("name")
    shape = entry.get("shape")
    if not isinstance(name, str) or not isinstance(shape, str):
        return None
    numbers = shape_numbers(shape)
    if name == "causal_mask_full":
        return numbers[-1]
    if name in {"kv_cache_full", "kv_cache_unified", "kv14_k", "kv14_v"} and len(numbers) >= 3:
        return numbers[-2]
    return None


def collect_metadata_contexts(metadata: dict, prefix: str) -> dict[str, int]:
    contexts: dict[str, int] = {}
    for schema_name in ("inputSchema", "outputSchema", "stateSchema"):
        for entry in metadata.get(schema_name, []) or []:
            context = context_from_entry(entry)
            if context is not None:
                contexts[f"{prefix}.{schema_name}.{entry['name']}"] = context
    for function in metadata.get("functions", []) or []:
        function_name = function.get("name", "function")
        for schema_name in ("inputSchema", "outputSchema", "stateSchema"):
            for entry in function.get(schema_name, []) or []:
                context = context_from_entry(entry)
                if context is not None:
                    contexts[f"{prefix}.{function_name}.{schema_name}.{entry['name']}"] = context
    return contexts


def validate(bundle: Path, expected_context: int) -> None:
    config = json.loads((bundle / "model_config.json").read_text())
    context = int(config["context_length"])
    if context != expected_context:
        raise SystemExit(f"context_length={context}, expected {expected_context}")

    mismatches: dict[str, int] = {}
    for chunk in ("chunk_1.mlmodelc", "chunk_2.mlmodelc", "chunk_3.mlmodelc"):
        metadata_path = bundle / chunk / "metadata.json"
        metadata_root = json.loads(metadata_path.read_text())
        metadata = metadata_root[0]
        for key, value in collect_metadata_contexts(metadata, chunk).items():
            if value != context:
                mismatches[key] = value
    if mismatches:
        detail = ", ".join(f"{k}={v}" for k, v in sorted(mismatches.items()))
        raise SystemExit(f"Core ML metadata context mismatch: {detail}")

    short_ropes: dict[str, int] = {}
    for name in ("cos_full.npy", "sin_full.npy", "cos_sliding.npy", "sin_sliding.npy"):
        length = npy_first_dimension(bundle / name)
        if length < context:
            short_ropes[name] = length
    if short_ropes:
        detail = ", ".join(f"{k}={v}" for k, v in sorted(short_ropes.items()))
        raise SystemExit(f"RoPE table shorter than context {context}: {detail}")

    print(f"[Lumina] Gemma4 bundle OK: context={context}, rope>=context, metadata matches")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("bundle", type=Path)
    parser.add_argument("--expected-context", type=int, default=12000)
    args = parser.parse_args()
    validate(args.bundle, args.expected_context)


if __name__ == "__main__":
    main()
