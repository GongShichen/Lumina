#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
import re
from collections import defaultdict
from pathlib import Path
from typing import Any


ASK_USER_TOOL = "ask_user"
MEMORY_TOOLS = {"memory.ingest_text", "memory.recent", "memory.stats", "memory.delete", "local.search", "media.import", "webpage.save_to_memory", "subscription.refresh"}


def main() -> None:
    parser = argparse.ArgumentParser(description="Split Lumina SFT and DPO datasets into stable train/test files.")
    parser.add_argument("--sft", type=Path, default=Path("TrainingData/lumina_react_sft_1200.jsonl"))
    parser.add_argument("--dpo", type=Path, default=Path("TrainingData/lumina_react_dpo_2400.jsonl"))
    parser.add_argument("--output", type=Path, default=Path("TrainingData/splits"))
    parser.add_argument("--test-ratio", type=float, default=0.10)
    parser.add_argument("--seed", type=str, default="20260526")
    parser.add_argument("--manifest", type=Path, default=Path("TrainingData/manifest.json"))
    args = parser.parse_args()

    args.output.mkdir(parents=True, exist_ok=True)
    sft_records = read_jsonl(args.sft)
    dpo_records = read_jsonl(args.dpo)

    split_specs = {
        "sft_general": split_records(sft_records, args.test_ratio, args.seed, "sft_general", filter_name="general"),
        "sft_evaluation": split_records([record for record in sft_records if is_evaluation_record(record, "sft")], args.test_ratio, args.seed, "sft_evaluation", filter_name="evaluation"),
        "dpo_general": split_records(dpo_records, args.test_ratio, args.seed, "dpo_general", filter_name="general"),
        "dpo_evaluation": split_records([record for record in dpo_records if is_evaluation_record(record, "dpo")], args.test_ratio, args.seed, "dpo_evaluation", filter_name="evaluation"),
    }

    summary: dict[str, Any] = {
        "schemaVersion": "lumina-training-splits-v8",
        "seed": args.seed,
        "testRatio": args.test_ratio,
        "splits": {},
        "promptShape": "LuminaAppReActPromptBuilder-2026-05-31-xml-tags",
        "runtimeTraceFormat": "compactTraceContext-v5-runtime-observation-json-with-actions-xml-targets",
        "assistantEnvelope": "xml_tags",
        "assistantDialect": "xml_tags",
    }
    for name, split in split_specs.items():
        train_path = args.output / f"{name}_train.jsonl"
        test_path = args.output / f"{name}_test.jsonl"
        write_jsonl(train_path, split["train"])
        write_jsonl(test_path, split["test"])
        summary["splits"][name] = {
            "trainPath": str(train_path),
            "testPath": str(test_path),
            "trainRecords": len(split["train"]),
            "testRecords": len(split["test"]),
            "filter": split["filter"],
            "profile": "evaluation-runtime-compatible" if name.endswith("evaluation") else "general-app",
        }

    summary_path = args.output / "split_manifest.json"
    summary_path.write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    update_manifest(args.manifest, summary)
    print(json.dumps(summary["splits"], ensure_ascii=False, indent=2))


def read_jsonl(path: Path) -> list[dict[str, Any]]:
    return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]


def write_jsonl(path: Path, records: list[dict[str, Any]]) -> None:
    path.write_text("".join(json.dumps(record, ensure_ascii=False, separators=(",", ":")) + "\n" for record in records), encoding="utf-8")


def split_records(records: list[dict[str, Any]], test_ratio: float, seed: str, namespace: str, filter_name: str) -> dict[str, Any]:
    buckets: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for record in records:
        buckets[bucket_key(record)].append(record)

    train: list[dict[str, Any]] = []
    test: list[dict[str, Any]] = []
    for key, bucket in sorted(buckets.items()):
        ordered = sorted(bucket, key=lambda record: stable_score(seed, namespace, record["id"]))
        test_count = target_test_count(len(ordered), test_ratio)
        test.extend(ordered[:test_count])
        train.extend(ordered[test_count:])

    train.sort(key=lambda record: record["id"])
    test.sort(key=lambda record: record["id"])
    return {"train": train, "test": test, "filter": filter_name}


def target_test_count(count: int, ratio: float) -> int:
    if count <= 1:
        return 0
    return max(1, min(count - 1, round(count * ratio)))


def stable_score(seed: str, namespace: str, record_id: str) -> str:
    return hashlib.sha256(f"{seed}:{namespace}:{record_id}".encode("utf-8")).hexdigest()


def bucket_key(record: dict[str, Any]) -> str:
    metadata = record.get("metadata", {})
    modalities = ",".join(sorted(metadata.get("modalities", ["text"])))
    category = metadata.get("category", "unknown")
    special = "standard"
    chosen_tool = chosen_tool_name(record)
    if chosen_tool == ASK_USER_TOOL:
        special = "ask_user"
    elif chosen_tool in MEMORY_TOOLS:
        special = "memory"
    return f"{category}|{modalities}|{special}"


def is_evaluation_record(record: dict[str, Any], kind: str) -> bool:
    metadata = record.get("metadata", {})
    if metadata.get("askUserDisabled") is False or metadata.get("memoryAccessDisabled") is False:
        return False
    chosen = chosen_tool_name(record)
    if chosen == ASK_USER_TOOL or chosen in MEMORY_TOOLS:
        return False
    content = assistant_content(record, kind)
    return all(tool not in content for tool in MEMORY_TOOLS)


def chosen_tool_name(record: dict[str, Any]) -> str | None:
    content = assistant_content(record, "dpo" if "chosen" in record else "sft")
    xml_tool = xml_tool_name(content)
    if xml_tool is not None:
        return xml_tool
    try:
        payload = json.loads(content)
    except json.JSONDecodeError:
        return None
    if payload.get("type") == "tool_use":
        return payload.get("tool_name")
    if payload.get("type") == "ask_user":
        return "ask_user"
    return None


def xml_tool_name(content: str) -> str | None:
    match = re.search(r'<tool_use\s+[^>]*name="([^"]+)"', content)
    if match:
        return match.group(1)
    if "<ask_user>" in content:
        return ASK_USER_TOOL
    return None


def assistant_content(record: dict[str, Any], kind: str) -> str:
    if kind == "dpo":
        chosen = record["chosen"]
        if isinstance(chosen, list):
            for message in chosen:
                if message.get("role") != "assistant":
                    continue
                content = message.get("content", "")
                if xml_tool_name(content) is not None:
                    return content
                try:
                    payload = json.loads(content)
                except json.JSONDecodeError:
                    continue
                if payload.get("type") in {"tool_use", "ask_user", "multi_tool_use"}:
                    return content
            for message in reversed(chosen):
                if message.get("role") == "assistant":
                    return message.get("content", "")
            return ""
        return chosen["content"]
    for message in reversed(record["messages"]):
        if message.get("role") == "assistant":
            return message.get("content", "")
    return ""


def update_manifest(path: Path, split_summary: dict[str, Any]) -> None:
    if not path.exists():
        return
    manifest = json.loads(path.read_text(encoding="utf-8"))
    manifest["splits"] = split_summary
    path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
