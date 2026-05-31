#!/usr/bin/env python3
"""Migrate generated Lumina SFT/DPO JSONL to the current ReAct result schema."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
TRAINING_DIR = ROOT / "TrainingData"
PROMPT_SHAPE = "LuminaAppReActPromptBuilder-2026-05-31-result-json"
TRACE_FORMAT = "compactTraceContext-v4-runtime-observation-json-with-actions"


def main() -> None:
    paths = sorted(TRAINING_DIR.glob("lumina_react_*.jsonl")) + sorted((TRAINING_DIR / "splits").glob("*.jsonl"))
    updated_records = 0
    for path in paths:
        records = [migrate_record(json.loads(line)) for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]
        write_jsonl(path, records)
        updated_records += len(records)

    migrate_manifest(TRAINING_DIR / "manifest.json")
    migrate_manifest(TRAINING_DIR / "splits" / "split_manifest.json")
    print(json.dumps({"updatedFiles": len(paths), "updatedRecords": updated_records}, ensure_ascii=False))


def migrate_record(record: dict[str, Any]) -> dict[str, Any]:
    migrated = migrate_value(record)
    if isinstance(migrated, dict):
        schema = migrated.get("schemaVersion")
        if isinstance(schema, str):
            migrated["schemaVersion"] = (
                schema.replace("lumina-runtime-sft-v6", "lumina-runtime-sft-v7")
                .replace("lumina-runtime-dpo-v6", "lumina-runtime-dpo-v7")
            )
        metadata = migrated.setdefault("metadata", {})
        if isinstance(metadata, dict):
            metadata["promptShape"] = PROMPT_SHAPE
            metadata["runtimeTraceFormat"] = TRACE_FORMAT
            if "reactTypes" in metadata:
                metadata["reactTypes"] = ["result" if value == "final_answer" else value for value in metadata["reactTypes"]]
    return migrated


def migrate_value(value: Any) -> Any:
    if isinstance(value, str):
        return migrate_text(value)
    if isinstance(value, list):
        return [migrate_value(item) for item in value]
    if isinstance(value, dict):
        return {key: migrate_value(item) for key, item in value.items()}
    return value


def migrate_text(text: str) -> str:
    replacements = {
        '"type":"final_answer"': '"type":"result"',
        '"type\\":\\"final_answer\\"': '"type\\":\\"result\\"',
        "type is only \"tool_use\" or \"final_answer\"": "type is only \"tool_use\" or \"result\"",
        "output final_answer": "output result",
        "Output final_answer": "Output result",
        "explain the missing info in final_answer": "explain the missing info in result",
        "final_answer uses content": "result uses content",
        "LuminaAppReActPromptBuilder-2026-05-28-runtime-json": PROMPT_SHAPE,
        "compactTraceContext-v3-runtime-observation-json-with-actions": TRACE_FORMAT,
        "compactTraceContext-v3-runtime-observation-json": TRACE_FORMAT,
    }
    migrated = text
    for old, new in replacements.items():
        migrated = migrated.replace(old, new)
    return migrated.replace("final_answer", "result")


def migrate_manifest(path: Path) -> None:
    if not path.exists():
        return
    manifest = migrate_value(json.loads(path.read_text(encoding="utf-8")))
    if isinstance(manifest, dict):
        migrate_manifest_metadata(manifest)
    path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def migrate_manifest_metadata(manifest: dict[str, Any]) -> None:
    schema = manifest.get("schemaVersion")
    if schema == "lumina-training-data-v8":
        manifest["schemaVersion"] = "lumina-training-data-v9"
    elif schema == "lumina-training-splits-v7":
        manifest["schemaVersion"] = "lumina-training-splits-v8"
    manifest["promptShape"] = PROMPT_SHAPE
    manifest["runtimeTraceFormat"] = TRACE_FORMAT
    notes = manifest.setdefault("notes", [])
    if isinstance(notes, list):
        note = "Migrated assistant and prompt contracts from legacy final_answer to current result ReAct schema."
        if note not in notes:
            notes.append(note)
    nested = manifest.get("splits")
    if isinstance(nested, dict):
        migrate_manifest_metadata(nested)


def write_jsonl(path: Path, records: list[dict[str, Any]]) -> None:
    path.write_text("".join(json.dumps(record, ensure_ascii=False, separators=(",", ":")) + "\n" for record in records), encoding="utf-8")


if __name__ == "__main__":
    main()
