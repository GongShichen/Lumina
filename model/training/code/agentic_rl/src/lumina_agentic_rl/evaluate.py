from __future__ import annotations

import argparse
import json
import re
from pathlib import Path
from typing import Any

from .formatting import assistant_targets
from .io import validate_trajectories
from .rewards import compute_reward, load_reward_config, tool_counts

NON_MINICPM_TARGET_PATTERN = re.compile(r'^\s*\{|"type"\s*:\s*"thought"|"type"\s*:\s*"final_answer"|<thought>|<tool_use|<result>', re.S)


def evaluate_file(input_path: Path, reward_config_path: Path | None = None) -> dict[str, Any]:
    records, issues = validate_trajectories(input_path)
    reward_config = load_reward_config(reward_config_path)

    true_positive = false_positive = false_negative = 0
    format_errors = 0
    rewards: list[float] = []
    for record in records:
        tp, fp, fn = tool_counts(record)
        true_positive += tp
        false_positive += fp
        false_negative += fn
        rewards.append(compute_reward(record, reward_config))
        for target in assistant_targets(record, include_thought=True):
            if NON_MINICPM_TARGET_PATTERN.search(target):
                format_errors += 1

    precision = _ratio(true_positive, true_positive + false_positive)
    recall = _ratio(true_positive, true_positive + false_negative)
    f1 = 0.0 if precision + recall == 0 else 2 * precision * recall / (precision + recall)
    return {
        "schema_pass": len(records),
        "schema_fail": len(issues),
        "tool_precision": precision,
        "tool_recall": recall,
        "tool_f1": f1,
        "average_reward": sum(rewards) / len(rewards) if rewards else 0.0,
        "format_errors": format_errors,
    }


def _ratio(numerator: int, denominator: int) -> float:
    return 0.0 if denominator == 0 else numerator / denominator


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Evaluate held-out Lumina Agentic RL trajectories.")
    parser.add_argument("--input", required=True, type=Path)
    parser.add_argument("--reward-config", type=Path)
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    print(json.dumps(evaluate_file(args.input, args.reward_config), ensure_ascii=False, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
