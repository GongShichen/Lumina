from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Any

import yaml

from .schema import TrajectoryRecord


@dataclass(frozen=True)
class RewardConfig:
    success_base: float = 0.35
    tool_f1_weight: float = 0.65
    latency_penalty_weight: float = 0.0
    latency_penalty_after_ms: float = 120_000.0
    memory_enabled_penalty: float = 0.0
    unknown_tool_penalty: float = 0.0
    minimum_reward: float = 0.0
    maximum_reward: float = 1.0

    @classmethod
    def from_mapping(cls, payload: dict[str, Any] | None) -> "RewardConfig":
        if not payload:
            return cls()
        known = {field for field in cls.__dataclass_fields__}
        return cls(**{key: value for key, value in payload.items() if key in known})


def load_reward_config(path: str | Path | None) -> RewardConfig:
    if path is None:
        return RewardConfig()
    payload = yaml.safe_load(Path(path).read_text(encoding="utf-8")) or {}
    return RewardConfig.from_mapping(payload.get("reward", payload))


def tool_counts(record: TrajectoryRecord) -> tuple[int, int, int]:
    expected = set(record.task.expected_tools)
    actual = set(record.actual_tools)
    true_positive = len(expected.intersection(actual))
    false_positive = len(actual.difference(expected))
    false_negative = len(expected.difference(actual))
    return true_positive, false_positive, false_negative


def tool_scores(record: TrajectoryRecord) -> dict[str, float]:
    true_positive, false_positive, false_negative = tool_counts(record)
    precision = _ratio(true_positive, true_positive + false_positive)
    recall = _ratio(true_positive, true_positive + false_negative)
    f1 = 0.0 if precision + recall == 0 else 2 * precision * recall / (precision + recall)
    return {"precision": precision, "recall": recall, "f1": f1}


def compute_reward(record: TrajectoryRecord, config: RewardConfig | None = None) -> float:
    config = config or RewardConfig()
    if record.outcome.status != "succeeded":
        return 0.0

    scores = tool_scores(record)
    reward = config.success_base + config.tool_f1_weight * scores["f1"]

    if config.latency_penalty_weight > 0 and record.outcome.total_milliseconds > config.latency_penalty_after_ms:
        over = record.outcome.total_milliseconds - config.latency_penalty_after_ms
        reward -= config.latency_penalty_weight * (over / config.latency_penalty_after_ms)

    if config.memory_enabled_penalty > 0 and not record.outcome.memory_access_disabled:
        reward -= config.memory_enabled_penalty

    if config.unknown_tool_penalty > 0:
        unknown_count = len(set(record.actual_tools).difference(record.task.expected_tools))
        reward -= config.unknown_tool_penalty * unknown_count

    return min(config.maximum_reward, max(config.minimum_reward, reward))


def _ratio(numerator: int, denominator: int) -> float:
    return 0.0 if denominator == 0 else numerator / denominator
