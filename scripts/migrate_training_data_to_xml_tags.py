#!/usr/bin/env python3
"""Migrate Lumina SFT/DPO assistant targets to the runtime XML-tag dialect."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
TRAINING_DIR = ROOT / "TrainingData"
PROMPT_SHAPE = "LuminaAppReActPromptBuilder-2026-05-31-xml-tags"
TRACE_FORMAT = "compactTraceContext-v5-runtime-observation-json-with-actions-xml-targets"


def main() -> None:
    paths = sorted(TRAINING_DIR.glob("lumina_react_*.jsonl")) + sorted((TRAINING_DIR / "splits").glob("*.jsonl"))
    record_count = 0
    for path in paths:
        records = [migrate_record(json.loads(line)) for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]
        write_jsonl(path, records)
        record_count += len(records)
    migrate_manifest(TRAINING_DIR / "manifest.json")
    migrate_manifest(TRAINING_DIR / "splits" / "split_manifest.json")
    print(json.dumps({"updatedFiles": len(paths), "updatedRecords": record_count}, ensure_ascii=False))


def migrate_record(record: dict[str, Any]) -> dict[str, Any]:
    migrated = migrate_value(record, role=None)
    if isinstance(migrated, dict):
        schema = migrated.get("schemaVersion")
        if isinstance(schema, str):
            migrated["schemaVersion"] = (
                schema.replace("lumina-runtime-sft-v7", "lumina-runtime-sft-v8")
                .replace("lumina-runtime-dpo-v7", "lumina-runtime-dpo-v8")
            )
        metadata = migrated.setdefault("metadata", {})
        if isinstance(metadata, dict):
            metadata["promptShape"] = PROMPT_SHAPE
            metadata["runtimeTraceFormat"] = TRACE_FORMAT
            metadata["assistantDialect"] = "xml_tags"
            if "reactTypes" in metadata:
                metadata["reactTypes"] = ["xml_tool_use" if value == "tool_use" else f"xml_{value}" for value in metadata["reactTypes"]]
    return migrated


def migrate_value(value: Any, role: str | None) -> Any:
    if isinstance(value, str):
        return migrate_assistant_content(value) if role == "assistant" else migrate_prompt_text(value)
    if isinstance(value, list):
        return [migrate_value(item, role=None) for item in value]
    if isinstance(value, dict):
        current_role = value.get("role") if isinstance(value.get("role"), str) else role
        return {key: migrate_value(item, role=current_role if key == "content" else None) for key, item in value.items()}
    return value


def migrate_assistant_content(content: str) -> str:
    if content.lstrip().startswith("<thought>"):
        return content
    try:
        payload = json.loads(content)
    except json.JSONDecodeError:
        return content
    if not isinstance(payload, dict):
        return content
    step_type = payload.get("type")
    thought = str(payload.get("thought") or "")
    if step_type == "tool_use":
        tool_name = payload.get("tool_name")
        parameters = payload.get("parameters", {})
        if not isinstance(tool_name, str) or not isinstance(parameters, dict):
            return content
        requires = payload.get("requires_confirmation", False)
        params = json.dumps(parameters, ensure_ascii=False, separators=(",", ":"))
        return f'<thought>{xml_text(thought)}</thought><tool_use name="{tool_name}" requires_confirmation="{str(bool(requires)).lower()}">{params}</tool_use>'
    if step_type == "ask_user":
        ask_payload = {
            "reason": payload.get("reason", ""),
            "questions": payload.get("questions", []),
            "sensitivity": payload.get("sensitivity", "normal"),
            "timeout_seconds": payload.get("timeout_seconds", payload.get("timeoutSeconds", 0)),
            "allow_custom_answer": payload.get("allow_custom_answer", True),
        }
        return f'<thought>{xml_text(thought)}</thought><ask_user>{json.dumps(ask_payload, ensure_ascii=False, separators=(",", ":"))}</ask_user>'
    if step_type == "result":
        return f'<thought>{xml_text(thought)}</thought><result>{xml_text(str(payload.get("content") or ""))}</result>'
    if step_type == "cannot_complete":
        return f'<thought>{xml_text(thought)}</thought><cannot_complete>{xml_text(str(payload.get("reason") or ""))}</cannot_complete>'
    if step_type == "reasoning":
        return f'<thought>{xml_text(thought)}</thought>'
    return content


def migrate_prompt_text(text: str) -> str:
    migrated = text
    replacements = {
        "CRITICAL OUTPUT CONTRACT: Return one JSON object only. No prose.": "CRITICAL OUTPUT CONTRACT: Return one XML-tag ReAct step only. No prose.",
        "The only valid ReAct JSON shapes are:": "The only valid ReAct XML shapes are:",
        '{"type":"tool_use","thought":"...","tool_name":"tool.name","parameters":{},"requires_confirmation":false}': '<thought>why</thought><tool_use name="tool.name" requires_confirmation="false">{}</tool_use>',
        '{"type":"result","thought":"...","content":"markdown"}': '<thought>done</thought><result>markdown</result>',
        'type is only "tool_use" or "result".': 'Use only <tool_use>, <result>, <cannot_complete>, or <ask_user> XML tags.',
        "For tools, use exactly these top-level keys: type, thought, tool_name, parameters, requires_confirmation.": 'For tools, put JSON parameters inside <tool_use name="exact.tool" requires_confirmation="true|false">...</tool_use>.',
        "If you want a tool, type must be \"tool_use\"; the exact tool goes in tool_name; inputs go in parameters.": "If you want a tool, use <tool_use>; the exact tool goes in the name attribute; inputs are the JSON object inside the tag.",
        "No markdown fences.": "No markdown fences. No JSON ReAct object.",
        "Output exactly one valid Lumina ReAct JSON object and nothing else.": "Output exactly one valid Lumina XML ReAct step and nothing else.",
        "output a result object": "output a <result> tag",
        "result object": "<result> tag",
        "standard tool_use object": "XML tool_use tag",
        "standard ReAct JSON": "XML ReAct",
        "standard Lumina ReAct JSON": "Lumina XML ReAct",
        "schema_version/step_id assistant envelope": "XML-tag assistant envelope",
        "LuminaAppReActPromptBuilder-2026-05-31-result-json": PROMPT_SHAPE,
        "compactTraceContext-v4-runtime-observation-json-with-actions": TRACE_FORMAT,
    }
    for old, new in replacements.items():
        migrated = migrated.replace(old, new)
    migrated = convert_valid_output_lines(migrated)
    return migrated


def convert_valid_output_lines(text: str) -> str:
    lines = []
    prefix = "Valid output exactly: "
    for line in text.splitlines():
        stripped = line.strip()
        if stripped.startswith(prefix):
            candidate = stripped[len(prefix):]
            xml = migrate_assistant_content(candidate)
            if xml != candidate:
                indent = line[: len(line) - len(line.lstrip())]
                line = f"{indent}{prefix}{xml}"
        lines.append(line)
    return "\n".join(lines)


def xml_text(value: str) -> str:
    return (
        value
        .replace("</thought>", "")
        .replace("</result>", "")
        .replace("</cannot_complete>", "")
        .replace("</ask_user>", "")
        .replace("</tool_use>", "")
    )


def migrate_manifest(path: Path) -> None:
    if not path.exists():
        return
    manifest = migrate_value(json.loads(path.read_text(encoding="utf-8")), role=None)
    if isinstance(manifest, dict):
        migrate_manifest_metadata(manifest)
    path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def migrate_manifest_metadata(manifest: dict[str, Any]) -> None:
    schema = manifest.get("schemaVersion")
    if schema == "lumina-training-data-v9":
        manifest["schemaVersion"] = "lumina-training-data-v10"
    elif schema == "lumina-training-splits-v8":
        manifest["schemaVersion"] = "lumina-training-splits-v9"
    manifest["promptShape"] = PROMPT_SHAPE
    manifest["runtimeTraceFormat"] = TRACE_FORMAT
    manifest["assistantDialect"] = "xml_tags"
    notes = manifest.setdefault("notes", [])
    if isinstance(notes, list):
        note = "Migrated assistant targets from canonical JSON to runtime xml_tags dialect."
        if note not in notes:
            notes.append(note)
    nested = manifest.get("splits")
    if isinstance(nested, dict):
        migrate_manifest_metadata(nested)


def write_jsonl(path: Path, records: list[dict[str, Any]]) -> None:
    path.write_text("".join(json.dumps(record, ensure_ascii=False, separators=(",", ":")) + "\n" for record in records), encoding="utf-8")


if __name__ == "__main__":
    main()
