from __future__ import annotations

import argparse
from pathlib import Path

from .io import print_summary, summarize, validate_trajectories


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Validate Lumina Agentic RL JSONL trajectories.")
    parser.add_argument("--input", required=True, type=Path)
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    records, issues = validate_trajectories(args.input)
    for issue in issues:
        print(f"{args.input}:{issue.line}: {issue.error}")
    print_summary(summarize(records) | {"invalid": len(issues)})
    if issues:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
