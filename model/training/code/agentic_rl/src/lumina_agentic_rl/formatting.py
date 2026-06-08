from __future__ import annotations

import json
from typing import Any

from .schema import TrajectoryRecord, TrajectoryStep


def react_json_for_step(step: TrajectoryStep) -> dict[str, Any] | None:
    if step.type == "action":
        return {
            "type": "tool_use",
            "thought": step.content or "",
            "tool_name": step.tool_name or "",
            "parameters": step.parameters or {},
            "requires_confirmation": False,
        }
    if step.type == "final":
        return {
            "type": "final_answer",
            "thought": "done",
            "content": step.content or "",
        }
    if step.type == "thought":
        return {
            "type": "thought",
            "thought": step.content or "",
        }
    return None


def assistant_targets(record: TrajectoryRecord, include_thought: bool = False) -> list[str]:
    targets: list[str] = []
    for step in record.steps:
        if step.type == "observation":
            continue
        if step.type == "thought" and not include_thought:
            continue
        payload = react_json_for_step(step)
        if payload is not None:
            targets.append(json.dumps(payload, ensure_ascii=False, sort_keys=True))
    return targets
