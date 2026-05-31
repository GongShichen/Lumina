#!/usr/bin/env python3
"""Repair known XML-dialect training data quality issues."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
TRAINING_DIR = ROOT / "TrainingData"
PROMPT_SHAPE = "LuminaAppReActPromptBuilder-2026-05-31-xml-tags"
TRACE_FORMAT = "compactTraceContext-v5-runtime-observation-json-with-actions-xml-targets"
DUPLICATE_REJECTED = "<thought>没有等待真实运行结果就声称完成。</thought><result>已完成。</result>"


def main() -> None:
    paths = sorted(TRAINING_DIR.glob("lumina_react_*.jsonl")) + sorted((TRAINING_DIR / "splits").glob("*.jsonl"))
    changed = 0
    duplicate_pairs = 0
    for path in paths:
        records = []
        for line in path.read_text(encoding="utf-8").splitlines():
            if not line.strip():
                continue
            record, record_changed, record_duplicates = repair_record(json.loads(line))
            records.append(record)
            changed += int(record_changed)
            duplicate_pairs += record_duplicates
        write_jsonl(path, records)
    repair_manifest(TRAINING_DIR / "manifest.json")
    repair_manifest(TRAINING_DIR / "splits" / "split_manifest.json")
    print(json.dumps({"updatedFiles": len(paths), "changedRecords": changed, "duplicatePairsRepaired": duplicate_pairs}, ensure_ascii=False))


def repair_record(record: dict[str, Any]) -> tuple[dict[str, Any], bool, int]:
    original = json.dumps(record, ensure_ascii=False, sort_keys=True)
    duplicate_pairs = 0

    if "messages" in record:
        for message in record["messages"]:
            if message.get("role") == "assistant":
                message["content"] = repair_assistant_xml(message.get("content", ""))
            else:
                message["content"] = repair_prompt_text(message.get("content", ""))
    else:
        for message in record.get("prompt", []):
            message["content"] = repair_prompt_text(message.get("content", ""))
        repair_non_assistant_trajectory_prompts(record.get("chosen"))
        repair_non_assistant_trajectory_prompts(record.get("rejected"))
        repair_assistant_trajectory_xml(record.get("chosen"))
        repair_assistant_trajectory_xml(record.get("rejected"))
        duplicate_pairs += repair_dpo_duplicates(record)

    metadata = record.setdefault("metadata", {})
    if isinstance(metadata, dict):
        metadata["promptShape"] = PROMPT_SHAPE
        metadata["runtimeTraceFormat"] = TRACE_FORMAT
        metadata["assistantDialect"] = "xml_tags"
        metadata["assistantEnvelope"] = "xml_tags"
        if "reactTypes" in metadata:
            metadata["reactTypes"] = normalize_react_types(metadata["reactTypes"])

    changed = original != json.dumps(record, ensure_ascii=False, sort_keys=True)
    return record, changed, duplicate_pairs


def repair_prompt_text(text: str) -> str:
    repaired = text
    replacements = {
        "Forbidden keys/values: tool_call, function, args, arguments, input, targetReference, action, toolUse, name.": "Forbidden keys/values: tool_call, function, args, arguments, input, targetReference, action, toolUse.",
        "Use only tool_name from Tools(all).": "Use only tool names from Tools(all).",
        "No JSON ReAct object. No JSON ReAct object.": "No JSON ReAct object.",
        "result uses content.": "result content is inside <result>.",
        "use ask_user;": "use <ask_user>;",
        "standard tool_use object": "XML tool_use tag",
    }
    for old, new in replacements.items():
        repaired = repaired.replace(old, new)
    repaired = repair_focused_tool_schema_block(repaired)
    return repaired


def repair_non_assistant_trajectory_prompts(value: Any) -> None:
    if isinstance(value, list):
        for item in value:
            repair_non_assistant_trajectory_prompts(item)
        return
    if not isinstance(value, dict):
        return
    if value.get("role") != "assistant" and isinstance(value.get("content"), str):
        value["content"] = repair_prompt_text(value["content"])


def repair_assistant_trajectory_xml(value: Any) -> None:
    if isinstance(value, list):
        for item in value:
            repair_assistant_trajectory_xml(item)
        return
    if not isinstance(value, dict):
        return
    if value.get("role") == "assistant" and isinstance(value.get("content"), str):
        value["content"] = repair_assistant_xml(value["content"])


def repair_assistant_xml(content: str) -> str:
    open_tag = '<tool_use name="ask_user" requires_confirmation="false">'
    close_tag = "</tool_use>"
    if open_tag not in content:
        return content
    repaired = content
    while open_tag in repaired:
        start = repaired.find(open_tag)
        end = repaired.find(close_tag, start)
        if end == -1:
            break
        payload_start = start + len(open_tag)
        payload = repaired[payload_start:end]
        replacement = f"<ask_user>{payload}</ask_user>"
        repaired = repaired[:start] + replacement + repaired[end + len(close_tag):]
    return repaired


def repair_focused_tool_schema_block(text: str) -> str:
    marker = "Focused tool schemas: "
    start = text.find(marker)
    if start == -1:
        return text
    json_start = start + len(marker)
    end = text.find("\nLoaded context:", json_start)
    if end == -1:
        return text
    raw = text[json_start:end].strip()
    if raw == "none":
        return text
    try:
        schemas = json.loads(raw)
    except json.JSONDecodeError:
        return text
    if not isinstance(schemas, list):
        return text
    repaired = []
    for schema in schemas:
        if not isinstance(schema, dict):
            repaired.append(schema)
            continue
        schema = dict(schema)
        call_template = schema.pop("call_template", None)
        schema.pop("xml_call_template", None)
        if "xml_tool_use_template" not in schema:
            schema["xml_tool_use_template"] = xml_call_template(schema, call_template)
        repaired.append(schema)
    rendered = json.dumps(repaired, ensure_ascii=False, separators=(",", ":"), sort_keys=True)
    return text[:json_start] + rendered + text[end:]


def xml_call_template(schema: dict[str, Any], call_template: Any) -> str:
    name = schema.get("name", "tool.name")
    requires = bool(schema.get("requires_confirmation", False))
    parameters: dict[str, Any] = {}
    if isinstance(call_template, dict) and isinstance(call_template.get("parameters"), dict):
        parameters = call_template["parameters"]
    elif isinstance(schema.get("parameters"), list):
        for parameter in schema["parameters"]:
            if not isinstance(parameter, dict):
                continue
            parameters[parameter.get("name", "param")] = placeholder(parameter)
    params = json.dumps(parameters, ensure_ascii=False, separators=(",", ":"), sort_keys=True)
    return f'<thought>why this tool is needed</thought><tool_use name="{name}" requires_confirmation="{str(requires).lower()}">{params}</tool_use>'


def placeholder(parameter: dict[str, Any]) -> Any:
    name = parameter.get("name")
    param_type = parameter.get("type")
    required = parameter.get("required") is True
    if param_type == "number":
        return 0
    if param_type == "boolean" or param_type == "bool":
        return False
    if param_type == "array":
        return []
    if param_type == "object":
        return {}
    if param_type == "dateISO8601":
        return "YYYY-MM-DDTHH:mm:ssZZZZZ"
    if name == "query":
        return "keyword from user request"
    if name == "id":
        return "ID_FROM_OBSERVATION"
    return "REQUIRED_STRING" if required else "optional string"


def repair_dpo_duplicates(record: dict[str, Any]) -> int:
    chosen = record.get("chosen")
    rejected = record.get("rejected")
    if not isinstance(chosen, list) or not isinstance(rejected, list):
        return repair_single_dpo_duplicate(chosen, rejected, record)
    repaired = 0
    for chosen_message, rejected_message in zip(chosen, rejected):
        if chosen_message.get("role") == "assistant" and rejected_message.get("role") == "assistant":
            if chosen_message.get("content") == rejected_message.get("content"):
                rejected_message["content"] = DUPLICATE_REJECTED
                repaired += 1
    if repaired:
        metadata = record.setdefault("metadata", {})
        if isinstance(metadata, dict):
            metadata["duplicatePreferencePairsRepaired"] = repaired
            metadata["rejectionReason"] = "duplicate_pair_repaired_to_premature_result"
    return repaired


def repair_single_dpo_duplicate(chosen: Any, rejected: Any, record: dict[str, Any]) -> int:
    if not isinstance(chosen, dict) or not isinstance(rejected, dict):
        return 0
    if chosen.get("role") == "assistant" and rejected.get("role") == "assistant" and chosen.get("content") == rejected.get("content"):
        rejected["content"] = DUPLICATE_REJECTED
        metadata = record.setdefault("metadata", {})
        if isinstance(metadata, dict):
            metadata["duplicatePreferencePairsRepaired"] = 1
            metadata["rejectionReason"] = "duplicate_pair_repaired_to_premature_result"
        return 1
    return 0


def normalize_react_types(values: Any) -> list[str]:
    if not isinstance(values, list):
        return []
    normalized = []
    for value in values:
        if not isinstance(value, str):
            continue
        while value.startswith("xml_xml_"):
            value = "xml_" + value[len("xml_xml_"):]
        if value in {"tool_use", "result", "ask_user", "cannot_complete"}:
            value = "xml_" + value
        normalized.append(value)
    return normalized


def repair_manifest(path: Path) -> None:
    if not path.exists():
        return
    manifest = json.loads(path.read_text(encoding="utf-8"))
    repair_manifest_metadata(manifest)
    path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def repair_manifest_metadata(manifest: dict[str, Any]) -> None:
    manifest["promptShape"] = PROMPT_SHAPE
    manifest["runtimeTraceFormat"] = TRACE_FORMAT
    manifest["assistantDialect"] = "xml_tags"
    manifest["assistantEnvelope"] = "xml_tags"
    notes = manifest.setdefault("notes", [])
    if isinstance(notes, list):
        note = "Repaired XML prompt contradictions and duplicate DPO preference pairs."
        if note not in notes:
            notes.append(note)
    nested = manifest.get("splits")
    if isinstance(nested, dict):
        repair_manifest_metadata(nested)


def write_jsonl(path: Path, records: list[dict[str, Any]]) -> None:
    path.write_text("".join(json.dumps(record, ensure_ascii=False, separators=(",", ":")) + "\n" for record in records), encoding="utf-8")


if __name__ == "__main__":
    main()
