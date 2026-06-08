from __future__ import annotations

import json

from lumina_agentic_rl.formatting import assistant_targets
from lumina_agentic_rl.rewards import compute_reward
from lumina_agentic_rl.schema import TrajectoryRecord


def minimal_record(**overrides: object) -> dict[str, object]:
    payload: dict[str, object] = {
        "id": "rl-001-run",
        "schemaVersion": "lumina.agentic_rl.v1",
        "createdAt": "2026-05-25T12:00:00Z",
        "task": {
            "id": "rl-001",
            "instruction": "请读取本机时间并回答。",
            "category": "time",
            "expectedTools": ["device.current_time"],
            "difficulty": "medium",
            "cleanupPrefixes": ["LuminaTest"],
        },
        "environment": {
            "app": "Lumina",
            "runtime": "ReAct",
            "schemaVersion": "standard_tool_use_final_answer",
            "localOnly": True,
        },
        "messages": [
            {"role": "user", "content": "请读取本机时间并回答。"},
            {"role": "assistant", "content": "现在是测试时间。"},
        ],
        "steps": [
            {
                "type": "action",
                "content": "Need current time.",
                "toolName": "device.current_time",
                "parameters": {},
                "elapsedMilliseconds": 10.0,
            },
            {
                "type": "observation",
                "content": "已读取本机时间。",
                "toolName": "device.current_time",
                "observationStatus": "succeeded",
                "elapsedMilliseconds": 5.0,
            },
            {
                "type": "final",
                "content": "现在是测试时间。",
                "elapsedMilliseconds": 4.0,
            },
        ],
        "actualTools": ["device.current_time"],
        "outcome": {
            "status": "succeeded",
            "reward": 1.0,
            "toolPrecision": 1.0,
            "toolRecall": 1.0,
            "toolF1": 1.0,
            "activeRuntimeMilliseconds": 19.0,
            "wallClockMilliseconds": 19.0,
            "confirmationWaitMilliseconds": 0.0,
            "systemPermissionWaitMilliseconds": 0.0,
            "totalMilliseconds": 19.0,
            "stepGenerationMilliseconds": 14.0,
            "toolMilliseconds": 5.0,
            "memoryAccessDisabled": True,
            "failureSummary": None,
        },
        "modelMetrics": [],
    }
    payload.update(overrides)
    return payload


def test_schema_and_reward_match_swift_formula() -> None:
    record = TrajectoryRecord.model_validate(minimal_record())
    assert record.schema_version == "lumina.agentic_rl.v1"
    assert compute_reward(record) == 1.0


def test_observation_is_not_exported_as_assistant_target() -> None:
    record = TrajectoryRecord.model_validate(minimal_record())
    targets = assistant_targets(record, include_thought=True)
    assert targets
    for target in targets:
        assert json.loads(target)["type"] != "observation"
