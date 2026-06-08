from __future__ import annotations

import json
from collections.abc import Iterable
from pathlib import Path
from typing import Any

from pydantic import ValidationError

from .schema import TrajectoryRecord, ValidationIssue


def read_jsonl(path: str | Path) -> list[dict[str, Any]]:
    records: list[dict[str, Any]] = []
    with Path(path).open("r", encoding="utf-8") as handle:
        for line_no, line in enumerate(handle, start=1):
            stripped = line.strip()
            if not stripped:
                continue
            try:
                records.append(json.loads(stripped))
            except json.JSONDecodeError as error:
                raise ValueError(f"{path}:{line_no}: invalid JSON: {error}") from error
    return records


def load_trajectories(path: str | Path) -> list[TrajectoryRecord]:
    valid, issues = validate_trajectories(path)
    if issues:
        first = issues[0]
        raise ValueError(f"{path}:{first.line}: {first.error}")
    return valid


def validate_trajectories(path: str | Path) -> tuple[list[TrajectoryRecord], list[ValidationIssue]]:
    valid: list[TrajectoryRecord] = []
    issues: list[ValidationIssue] = []
    with Path(path).open("r", encoding="utf-8") as handle:
        for line_no, line in enumerate(handle, start=1):
            stripped = line.strip()
            if not stripped:
                continue
            try:
                payload = json.loads(stripped)
                valid.append(TrajectoryRecord.model_validate(payload))
            except (json.JSONDecodeError, ValidationError, ValueError) as error:
                issues.append(ValidationIssue(line=line_no, error=str(error)))
    return valid, issues


def write_jsonl(path: str | Path, records: Iterable[dict[str, Any]]) -> int:
    output = Path(path)
    output.parent.mkdir(parents=True, exist_ok=True)
    count = 0
    with output.open("w", encoding="utf-8") as handle:
        for record in records:
            handle.write(json.dumps(record, ensure_ascii=False, sort_keys=True))
            handle.write("\n")
            count += 1
    return count


def write_json(path: str | Path, payload: Any) -> None:
    output = Path(path)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True), encoding="utf-8")


def summarize(records: list[TrajectoryRecord]) -> dict[str, Any]:
    completed = len(records)
    succeeded = sum(1 for record in records if record.outcome.status == "succeeded")
    average_reward = sum(record.outcome.reward for record in records) / completed if completed else 0.0
    return {
        "records": completed,
        "succeeded": succeeded,
        "failed": completed - succeeded,
        "average_reward": average_reward,
        "categories": sorted({record.task.category for record in records}),
    }


def print_summary(summary: dict[str, Any]) -> None:
    try:
        from rich.console import Console
        from rich.table import Table

        table = Table(title="Lumina Agentic RL")
        table.add_column("Metric")
        table.add_column("Value")
        for key, value in summary.items():
            table.add_row(key, json.dumps(value, ensure_ascii=False) if isinstance(value, list) else str(value))
        Console().print(table)
    except Exception:
        print(json.dumps(summary, ensure_ascii=False, indent=2, sort_keys=True))
