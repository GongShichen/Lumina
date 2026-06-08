#!/usr/bin/env python3
"""QA gate for Lumina XML-tag SFT/DPO training data."""

from __future__ import annotations

import argparse
import json
import re
from collections import Counter
from pathlib import Path
from typing import Any, NamedTuple


FORBIDDEN_PROMPT_SNIPPETS = [
    '"call_template"',
    '"xml_call_template"',
    '"xml_tool_use_template"',
    '"required_parameters"',
    "schema_version",
    "step_id",
    "final_answer",
    "Return one JSON object only",
    "Return exactly one JSON object",
    "valid Lumina ReAct JSON",
    "<parameters>",
    "<observation>",
    "<tool_use parameters",
    "<tools_use>",
    "</tools_use>",
    "<think>",
    "</think>",
    "<tool_call",
    "</tool_call>",
    "ID_FROM_OBSERVATION",
    "EVENT_ID_FROM_OBSERVATION",
    "Forbidden keys/values: tool_call, function, args, arguments, input, targetReference, action, toolUse, name.",
]

FORBIDDEN_CHOSEN_SNIPPETS = [
    "<parameters>",
    "<observation>",
    "<tool_use parameters",
    "<tools_use>",
    "</tools_use>",
    "<think>",
    "</think>",
    "<tool_call",
    "</tool_call>",
    "Return exactly one JSON object",
    "JSON reasoning",
    "required_parameters",
    "ID_FROM_OBSERVATION",
    "EVENT_ID_FROM_OBSERVATION",
    "ID_FROM_RUNTIME_RESULT",
    "REQUIRED_STRING",
    "YYYY-MM-DD",
]

FORBIDDEN_TRAINING_SNIPPETS = [
    "/Users/gsc/Documents/BenchmarkReports",
    "BenchmarkReports",
    "LuminaBenchmark",
    "LuminaTest",
    "benchmark #",
    "expectedTools",
    "expected_tools",
]

PLACEHOLDER_VALUE_PATTERN = re.compile(
    r"ID_FROM|EVENT_ID_FROM|REQUIRED_|YYYY-MM-DD|keyword from user request|id from runtime result",
    re.I,
)

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
COMPACT_TOOL_LINE_PATTERN = re.compile(
    r"^tool (?P<name>[^ |]+) \| (?P<effect>read|write) \| required: (?P<required>[^|]+) \| params: (?P<params>\{.*\})$"
)


class ToolContract(NamedTuple):
    allowed: set[str]
    required: set[str]


def main() -> None:
    parser = argparse.ArgumentParser(description="Validate Lumina XML training JSONL files.")
    parser.add_argument("--root", type=Path, default=Path("TrainingData"))
    args = parser.parse_args()

    root = args.root
    paths = sorted(root.glob("lumina_react_*.jsonl")) + sorted((root / "splits").glob("*.jsonl"))
    if not paths:
        raise SystemExit(f"No training JSONL files found under {root}")

    errors: list[str] = []
    check_manifest(root, errors)
    check_split_manifest(root, errors)
    scan_for_leakage(paths, errors)

    contracts = collect_tool_contracts(paths, errors)
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
            dpo_pairs += check_assistant_targets(path, line_number, record, contracts, counts, errors)

    summary = {
        "root": str(root),
        "files": len(paths),
        "records": record_count,
        "dpoAssistantPairs": dpo_pairs,
        "assistantCounts": dict(sorted(counts.items())),
        "knownToolSchemas": len(contracts),
        "errors": len(errors),
    }
    print(json.dumps(summary, ensure_ascii=False, indent=2))
    if errors:
        print("\nFirst errors:")
        for error in errors[:80]:
            print(error)
        raise SystemExit(1)


def check_manifest(root: Path, errors: list[str]) -> None:
    manifest_path = root / "manifest.json"
    if not manifest_path.exists():
        errors.append(f"{manifest_path}: missing manifest")
        return
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as error:
        errors.append(f"{manifest_path}: invalid JSON: {error}")
        return
    if manifest.get("benchmarkTraceUsedForTraining") is not False:
        errors.append(f"{manifest_path}: benchmarkTraceUsedForTraining must be false")
    policy = manifest.get("benchmarkTracePolicy")
    if not isinstance(policy, str) or "only for aggregate diagnostics" not in policy:
        errors.append(f"{manifest_path}: benchmarkTracePolicy must document aggregate-only usage")
    if manifest.get("assistantDialect") != "xml_tags":
        errors.append(f"{manifest_path}: assistantDialect must be xml_tags")
    if manifest.get("assistantEnvelope") != "xml_tags":
        errors.append(f"{manifest_path}: assistantEnvelope must be xml_tags")


def check_split_manifest(root: Path, errors: list[str]) -> None:
    split_path = root / "splits" / "split_manifest.json"
    if not split_path.exists():
        errors.append(f"{split_path}: missing split manifest")
        return
    try:
        split_manifest = json.loads(split_path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as error:
        errors.append(f"{split_path}: invalid JSON: {error}")
        return
    if split_manifest.get("assistantDialect") != "xml_tags":
        errors.append(f"{split_path}: assistantDialect must be xml_tags")
    if split_manifest.get("assistantEnvelope") != "xml_tags":
        errors.append(f"{split_path}: assistantEnvelope must be xml_tags")


def scan_for_leakage(paths: list[Path], errors: list[str]) -> None:
    for path in paths:
        text = path.read_text(encoding="utf-8")
        for snippet in FORBIDDEN_TRAINING_SNIPPETS:
            if snippet in text:
                errors.append(f"{path}: contains forbidden benchmark/leakage snippet {snippet!r}")


def collect_tool_contracts(paths: list[Path], errors: list[str]) -> dict[str, ToolContract]:
    allowed: dict[str, set[str]] = {}
    required: dict[str, set[str]] = {}
    for path in paths:
        for line_number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            if not line.strip():
                continue
            record = json.loads(line)
            for content in non_assistant_contents(record):
                for line_text in focused_schema_lines(content):
                    parsed = parse_compact_schema_line(line_text)
                    if parsed is None:
                        errors.append(f"{path}:{line_number}: focused schema is not compact line format: {line_text[:160]}")
                        continue
                    name, required_names, parameter_names = parsed
                    allowed.setdefault(name, set()).update(parameter_names)
                    required.setdefault(name, set()).update(required_names)
    return {
        name: ToolContract(allowed=params, required=required.get(name, set()))
        for name, params in allowed.items()
    }


def parse_compact_schema_line(line: str) -> tuple[str, set[str], set[str]] | None:
    match = COMPACT_TOOL_LINE_PATTERN.match(line.strip())
    if match is None:
        return None
    raw_required = match.group("required").strip()
    required = set() if raw_required == "none" else {item.strip() for item in raw_required.split(",") if item.strip()}
    try:
        params = json.loads(match.group("params"))
    except json.JSONDecodeError:
        return None
    if not isinstance(params, dict):
        return None
    return match.group("name"), required, set(params.keys())


def check_metadata(path: Path, line_number: int, record: dict[str, Any], errors: list[str]) -> None:
    metadata = record.get("metadata", {})
    if isinstance(metadata, dict):
        if metadata.get("assistantDialect") != "xml_tags":
            errors.append(f"{path}:{line_number}: metadata.assistantDialect is not xml_tags")
        if metadata.get("assistantEnvelope") != "xml_tags":
            errors.append(f"{path}:{line_number}: metadata.assistantEnvelope is not xml_tags")
        if metadata.get("benchmarkTraceUsedForTraining") is not False:
            errors.append(f"{path}:{line_number}: metadata.benchmarkTraceUsedForTraining must be false")


def check_prompts(path: Path, line_number: int, record: dict[str, Any], errors: list[str]) -> None:
    for content in non_assistant_contents(record):
        for snippet in FORBIDDEN_PROMPT_SNIPPETS + FORBIDDEN_TRAINING_SNIPPETS:
            if snippet in content:
                errors.append(f"{path}:{line_number}: prompt contains forbidden snippet {snippet!r}")
        raw = focused_schema_block(content)
        if raw is None:
            errors.append(f"{path}:{line_number}: prompt missing Focused tool schemas block")
            continue
        if raw == "none":
            continue
        if raw.startswith("[") or raw.startswith("{"):
            errors.append(f"{path}:{line_number}: focused schema must be compact lines, not JSON")
        for line_text in raw.splitlines():
            if not line_text.strip():
                continue
            parsed = parse_compact_schema_line(line_text)
            if parsed is None:
                errors.append(f"{path}:{line_number}: invalid compact focused schema line: {line_text[:160]}")
                continue
            name, required, params = parsed
            if name == "ask_user":
                errors.append(f"{path}:{line_number}: evaluation focused schemas must not include ask_user")
            if not required.issubset(params):
                errors.append(f"{path}:{line_number}: focused schema required params not present for {name}: {sorted(required - params)}")


def check_assistant_targets(
    path: Path,
    line_number: int,
    record: dict[str, Any],
    contracts: dict[str, ToolContract],
    counts: Counter[str],
    errors: list[str],
) -> int:
    if "messages" in record:
        for message in record["messages"]:
            if message.get("role") == "assistant":
                check_xml_assistant(path, line_number, message.get("content", ""), contracts, counts, errors)
        return 0

    chosen = assistant_messages(record.get("chosen"))
    rejected = assistant_messages(record.get("rejected"))
    for chosen_message in chosen:
        check_xml_assistant(path, line_number, chosen_message.get("content", ""), contracts, counts, errors)
    for chosen_message, rejected_message in zip(chosen, rejected):
        if chosen_message.get("content") == rejected_message.get("content"):
            errors.append(f"{path}:{line_number}: DPO chosen and rejected assistant messages are identical")
    return min(len(chosen), len(rejected))


def check_xml_assistant(
    path: Path,
    line_number: int,
    content: str,
    contracts: dict[str, ToolContract],
    counts: Counter[str],
    errors: list[str],
) -> None:
    for snippet in FORBIDDEN_CHOSEN_SNIPPETS + FORBIDDEN_TRAINING_SNIPPETS:
        if snippet in content:
            errors.append(f"{path}:{line_number}: chosen assistant contains forbidden snippet {snippet!r}")
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
        contract = contracts.get(tool_name)
        if contract is not None:
            unknown = sorted(set(params) - contract.allowed)
            if unknown:
                errors.append(f"{path}:{line_number}: unknown params for {tool_name}: {unknown}")
            missing = sorted(name for name in contract.required if missing_required(params.get(name)))
            if missing:
                errors.append(f"{path}:{line_number}: missing/empty required params for {tool_name}: {missing}")
        for key, value in params.items():
            if contains_placeholder(value):
                errors.append(f"{path}:{line_number}: placeholder value for {tool_name}.{key}: {value!r}")
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


def missing_required(value: Any) -> bool:
    if value is None:
        return True
    if isinstance(value, str):
        return value.strip() == "" or contains_placeholder(value)
    if isinstance(value, (list, dict)):
        return len(value) == 0
    return False


def contains_placeholder(value: Any) -> bool:
    if isinstance(value, str):
        return PLACEHOLDER_VALUE_PATTERN.search(value) is not None
    if isinstance(value, list):
        return any(contains_placeholder(item) for item in value)
    if isinstance(value, dict):
        return any(contains_placeholder(item) for item in value.values())
    return False


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


def focused_schema_block(content: str) -> str | None:
    marker = "Focused tool schemas: "
    start = content.find(marker)
    if start == -1:
        return None
    block_start = start + len(marker)
    end = content.find("\nLoaded context:", block_start)
    if end == -1:
        return None
    return content[block_start:end].strip()


def focused_schema_lines(content: str) -> list[str]:
    raw = focused_schema_block(content)
    if raw is None or raw == "none":
        return []
    return [line.strip() for line in raw.splitlines() if line.strip()]


def assistant_messages(value: Any) -> list[dict[str, Any]]:
    if isinstance(value, dict):
        return [value] if value.get("role") == "assistant" else []
    if isinstance(value, list):
        return [item for item in value if isinstance(item, dict) and item.get("role") == "assistant"]
    return []


if __name__ == "__main__":
    main()
