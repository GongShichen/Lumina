#!/usr/bin/env python3
"""Rebuild source-derived records and verify every emitted sample byte-for-byte."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any

import build_native_public_training_data as native


def expected_records(cache_dir: Path) -> dict[str, dict[str, Any]]:
    sft: list[dict[str, Any]] = []
    dpo: list[dict[str, Any]] = []

    native.build_xlam(sft, native.read_rows("NobodyExistsOnTheInternet/xlam-function-calling-60k", "default", "train", cache_dir=cache_dir, columns=["query", "tools", "answers", "id"], limit=20000))
    for config in ("simple", "multiple", "parallel", "parallel_multiple"):
        native.build_bfcl(sft, native.read_rows("minpeter/bfcl-v1-non-live-ast-parsed", config, "train", cache_dir=cache_dir, columns=["messages", "tools"], limit=2000), f"minpeter/bfcl-v1-non-live-ast-parsed:{config}:train")
    native.build_pyromind(sft, native.read_rows("pyromind/agentic-tool-call-dataset-12k", "short", "train", cache_dir=cache_dir, columns=["messages"], limit=12000))
    native.build_toolace(sft, native.read_rows("lockon/ToolACE", "default", "train", cache_dir=cache_dir, columns=["system", "conversations"]))
    native.build_hotpot(sft, native.read_rows("hotpotqa/hotpot_qa", "distractor", "train", cache_dir=cache_dir, columns=["id", "question", "answer", "context"], limit=10000, max_files=1))
    native.build_cmrc(sft, native.read_rows("hfl/cmrc2018", "default", "train", cache_dir=cache_dir, columns=["id", "context", "question", "answers"], limit=10000))

    native.build_ultrainteract(dpo, native.read_rows("openbmb/UltraInteract_pair", "default", "train", cache_dir=cache_dir, columns=["task", "dataset", "trajectory", "chosen", "rejected", "id", "parent_id"], limit=180000), 40000)
    native.build_bilingual_dpo(dpo, native.read_rows("llamafactory/DPO-En-Zh-20k", "en", "train", cache_dir=cache_dir), "llamafactory/DPO-En-Zh-20k:en:train", "en")
    native.build_bilingual_dpo(dpo, native.read_rows("llamafactory/DPO-En-Zh-20k", "zh", "train", cache_dir=cache_dir), "llamafactory/DPO-En-Zh-20k:zh:train", "zh")

    records = native.dedupe(sft) + native.dedupe(dpo)
    return {record["id"]: record for record in records}


def main() -> None:
    parser = argparse.ArgumentParser(description="Verify that all training content is reconstructed from public source rows.")
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--cache-dir", type=Path, required=True)
    parser.add_argument("--parquet-index", type=Path, required=True)
    parser.add_argument("--hf-download-mirror")
    args = parser.parse_args()

    native.PARQUET_INDEX = json.loads(args.parquet_index.read_text(encoding="utf-8"))
    native.HF_DOWNLOAD_MIRROR = args.hf_download_mirror
    expected = expected_records(args.cache_dir)

    errors: list[str] = []
    checked = 0
    for path in sorted((args.root / "splits").glob("*.jsonl")):
        with path.open(encoding="utf-8") as handle:
            for line_number, line in enumerate(handle, 1):
                actual = json.loads(line)
                source_record = expected.get(actual.get("id"))
                if source_record is None:
                    errors.append(f"{path}:{line_number}: record id is absent from public source reconstruction")
                elif actual != source_record:
                    errors.append(f"{path}:{line_number}: record differs from public source reconstruction")
                checked += 1

    report = {
        "status": "PASS" if not errors else "FAIL",
        "checkedOutputRecords": checked,
        "reconstructedPublicRecords": len(expected),
        "errors": len(errors),
    }
    print(json.dumps(report, ensure_ascii=False, indent=2))
    if errors:
        print("\nFirst errors:")
        print("\n".join(errors[:100]))
        raise SystemExit(1)


if __name__ == "__main__":
    main()
