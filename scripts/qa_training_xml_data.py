#!/usr/bin/env python3
"""QA gate for Lumina XML-tag SFT/DPO training data."""

from __future__ import annotations

import argparse
import json
import re
from collections import Counter
from pathlib import Path
from typing import Any


FORBIDDEN_PROMPT_SNIPPETS = [
    '"call_template"',
    '"xml_call_template"',
    "schema_version",
    "step_id",
    "final_answer",
    "Return one JSON object only",
    "valid Lumina ReAct JSON",
    "Forbidden keys/values: tool_call, function, args, arguments, input, targetReference, action, toolUse, name.",
]

ASSISTANT_XML_PATTERN = re.compile(
    r'^<thought>(?P<thought>.*?)</thought>'
    r'(?P<body>'
    r'<tool_use\s+[^>]*name="(?P<tool>[^"]+)"[^>]*>(?P<params>\{.*\})</tool_use>'
    r'|<ask_user>(?P<ask>\{.*\})</ask_user>'
    r'|<result>(?P<result>.*)</result>'
    r'|<cannot_complete>(?P<cannot>.*)</cannot_complete>'
    r'|'
    r')$',
    re.S,
)

TOOL_NAME_PATTERN = re.compile(r'<tool_use\s+[^>]*name="([^"]+)"')
CONFIRMATION_PATTERN = re.compile(r'<tool_use\s+[^>]*requires_confirmation="([^"]+)"')


def main() -> None:
    parser = argparse.ArgumentParser(description="Validate Lumina XML training JSONL files.")
    parser.add_argument("--root", type=Path, default=Path("TrainingData"))
    args = parser.parse_args()

    root = args.root
    paths = sorted(root.glob("lumina_react_*.jsonl")) + sorted((root / "splits").glob("*.jsonl"))
    if not paths:
        raise SystemExit(f"No training JSONL files found under {root}")

    allowed_params = collect_allowed_params(paths)
    errors: list[str] = []
    counts: Counter[str] = Counter()
    record_count = 0
    dpo_pairs = 0

    for path in paths:
        for line_number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            if not line.strip():
                continue
            record_count += 1
            try:
                record = json.loads(line)
            except json.JSONDecodeError as error:
                errors.append(f"{path}:{line_number}: invalid JSONL record: {error}")
                continue

            check_metadata(path, line_number, record, errors)
            check_prompts(path, line_number, record, errors)
            dpo_pairs += check_assistant_targets(path, line_number, record, allowed_params, counts, errors)

    summary = {
        "root": str(root),
        "files": len(paths),
        "records": record_count,
        "dpoAssistantPairs": dpo_pairs,
        "assistantCounts": dict(sorted(counts.items())),
        "knownToolSchemas": len(allowed_params),
        "errors": len(errors),
    }
    print(json.dumps(summary, ensure_ascii=False, indent=2))
    if errors:
        print("\nFirst errors:")
        for error in errors[:50]:
            print(error)
        raise SystemExit(1)


def collect_allowed_params(paths: list[Path]) -> dict[str, set[str]]:
    allowed: dict[str, set[str]] = {}
    for path in paths:
        for line in path.read_text(encoding="utf-8").splitlines():
            if not line.strip():
                continue
            record = json.loads(line)
            for content in non_assistant_contents(record):
                for schema in focused_schemas(content):
                    name = schema.get("name")
                    if not isinstance(name, str):
                        continue
                    params = allowed.setdefault(name, set())
                    for parameter in schema.get("parameters", []):
                        if isinstance(parameter, dict) and isinstance(parameter.get("name"), str):
                            params.add(parameter["name"])
    return allowed


def check_metadata(path: Path, line_number: int, record: dict[str, Any], errors: list[str]) -> None:
    metadata = record.get("metadata", {})
    if isinstance(metadata, dict):
        if metadata.get("assistantDialect") != "xml_tags":
            errors.append(f"{path}:{line_number}: metadata.assistantDialect is not xml_tags")
        if metadata.get("assistantEnvelope") != "xml_tags":
            errors.append(f"{path}:{line_number}: metadata.assistantEnvelope is not xml_tags")


def check_prompts(path: Path, line_number: int, record: dict[str, Any], errors: list[str]) -> None:
    for content in non_assistant_contents(record):
        for snippet in FORBIDDEN_PROMPT_SNIPPETS:
            if snippet in content:
                errors.append(f"{path}:{line_number}: prompt contains forbidden snippet {snippet!r}")
        if '"xml_tool_use_template"' not in content and "Focused tool schemas: none" not in content:
            if "Focused tool schemas:" in content:
                errors.append(f"{path}:{line_number}: focused schema lacks xml_tool_use_template")


def check_assistant_targets(
    path: Path,
    line_number: int,
    record: dict[str, Any],
    allowed_params: dict[str, set[str]],
    counts: Counter[str],
    errors: list[str],
) -> int:
    if "messages" in record:
        for message in record["messages"]:
            if message.get("role") == "assistant":
                check_xml_assistant(path, line_number, message.get("content", ""), allowed_params, counts, errors)
        return 0

    chosen = assistant_messages(record.get("chosen"))
    rejected = assistant_messages(record.get("rejected"))
    for chosen_message in chosen:
        check_xml_assistant(path, line_number, chosen_message.get("content", ""), allowed_params, counts, errors)
    for chosen_message, rejected_message in zip(chosen, rejected):
        if chosen_message.get("content") == rejected_message.get("content"):
            errors.append(f"{path}:{line_number}: DPO chosen and rejected assistant messages are identical")
    return min(len(chosen), len(rejected))


def check_xml_assistant(
    path: Path,
    line_number: int,
    content: str,
    allowed_params: dict[str, set[str]],
    counts: Counter[str],
    errors: list[str],
) -> None:
    if content.lstrip().startswith("{"):
        errors.append(f"{path}:{line_number}: assistant target is JSON, expected XML")
        return
    match = ASSISTANT_XML_PATTERN.match(content)
    if not match:
        errors.append(f"{path}:{line_number}: assistant target is not supported XML: {content[:160]}")
        return
    if "<tool_use" in content:
        counts["tool_use"] += 1
        tool_name = match.group("tool")
        confirmation = CONFIRMATION_PATTERN.search(content)
        if confirmation is None or confirmation.group(1) not in {"true", "false"}:
            errors.append(f"{path}:{line_number}: tool_use missing boolean requires_confirmation")
        try:
            params = json.loads(match.group("params"))
        except json.JSONDecodeError as error:
            errors.append(f"{path}:{line_number}: tool_use parameters are not JSON object: {error}")
            return
        if not isinstance(params, dict):
            errors.append(f"{path}:{line_number}: tool_use parameters are not an object")
            return
        if tool_name in allowed_params:
            unknown = sorted(set(params) - allowed_params[tool_name])
            if unknown:
                errors.append(f"{path}:{line_number}: unknown params for {tool_name}: {unknown}")
        return
    if "<ask_user>" in content:
        counts["ask_user"] += 1
        try:
            payload = json.loads(match.group("ask"))
        except json.JSONDecodeError as error:
            errors.append(f"{path}:{line_number}: ask_user payload is not JSON object: {error}")
            return
        if not isinstance(payload.get("questions"), list):
            errors.append(f"{path}:{line_number}: ask_user questions is not an array")
        return
    if "<result>" in content:
        counts["result"] += 1
        return
    if "<cannot_complete>" in content:
        counts["cannot_complete"] += 1
        return
    counts["reasoning"] += 1


def non_assistant_contents(record: dict[str, Any]) -> list[str]:
    contents: list[str] = []

    def collect(value: Any) -> None:
        if isinstance(value, list):
            for item in value:
                collect(item)
            return
        if isinstance(value, dict) and value.get("role") != "assistant" and isinstance(value.get("content"), str):
            contents.append(value["content"])

    if "messages" in record:
        collect(record["messages"])
    else:
        collect(record.get("prompt", []))
        collect(record.get("chosen", []))
        collect(record.get("rejected", []))
    return contents


def focused_schemas(content: str) -> list[dict[str, Any]]:
    marker = "Focused tool schemas: "
    start = content.find(marker)
    if start == -1:
        return []
    json_start = start + len(marker)
    end = content.find("\nLoaded context:", json_start)
    if end == -1:
        return []
    raw = content[json_start:end].strip()
    if raw == "none":
        return []
    try:
        schemas = json.loads(raw)
    except json.JSONDecodeError:
        return []
    return schemas if isinstance(schemas, list) else []


def assistant_messages(value: Any) -> list[dict[str, Any]]:
    if isinstance(value, dict):
        return [value] if value.get("role") == "assistant" else []
    if isinstance(value, list):
        return [item for item in value if isinstance(item, dict) and item.get("role") == "assistant"]
    return []


if __name__ == "__main__":
    main()
