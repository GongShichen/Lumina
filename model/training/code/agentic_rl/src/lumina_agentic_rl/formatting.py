from __future__ import annotations

from typing import Any

from .schema import TrajectoryRecord, TrajectoryStep


def _escape_transport_text(value: Any) -> str:
    text = "" if value is None else str(value)
    return (
        text.replace("&", "&amp;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
    )


def _tool_transport(step: TrajectoryStep) -> str:
    name = _escape_transport_text(step.tool_name or "")
    parameters = step.parameters or {}
    blocks = [f"<think>{_escape_transport_text(step.content or '')}</think>", "<tool_call>", f"<function={name}>"]
    if isinstance(parameters, dict):
        for key in sorted(parameters):
            value = parameters[key]
            if isinstance(value, (dict, list)):
                rendered = json_dumps(value)
            else:
                rendered = "" if value is None else str(value)
            blocks.append(f"<parameter={_escape_transport_text(key)}>{_escape_transport_text(rendered)}</parameter>")
    blocks.extend(["</function>", "</tool_call>"])
    return "\n".join(blocks)


def json_dumps(value: Any) -> str:
    import json

    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def react_transport_for_step(step: TrajectoryStep) -> str | None:
    if step.type == "tool_use":
        return _tool_transport(step)
    if step.type == "result":
        return _escape_transport_text(step.content or "")
    if step.type == "reasoning":
        return f"<think>{_escape_transport_text(step.content or '')}</think>"
    return None


def assistant_targets(record: TrajectoryRecord, include_thought: bool = False) -> list[str]:
    targets: list[str] = []
    for step in record.steps:
        if step.type == "observation":
            continue
        if step.type == "reasoning" and not include_thought:
            continue
        payload = react_transport_for_step(step)
        if payload is not None:
            targets.append(payload)
    return targets
