#!/usr/bin/env python3
"""Fetch a small Hugging Face Dataset Viewer Parquet URL index."""

from __future__ import annotations

import argparse
import json
import time
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any


DATASETS_SERVER = "https://datasets-server.huggingface.co"


def fetch(dataset: str) -> dict[str, Any]:
    url = f"{DATASETS_SERVER}/parquet?{urllib.parse.urlencode({'dataset': dataset})}"
    last_error: Exception | None = None
    for attempt in range(8):
        try:
            with urllib.request.urlopen(url, timeout=60) as response:
                return json.loads(response.read().decode("utf-8"))
        except Exception as error:
            last_error = error
            time.sleep(1.5 * (attempt + 1))
    raise RuntimeError(f"failed to fetch Parquet index for {dataset}: {last_error}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("datasets", nargs="+")
    args = parser.parse_args()

    index: dict[str, list[str]] = {}
    for dataset in sorted(set(args.datasets)):
        payload = fetch(dataset)
        for item in payload.get("parquet_files", []):
            config = item.get("config")
            split = item.get("split")
            url = item.get("url")
            if not all(isinstance(value, str) and value for value in (config, split, url)):
                continue
            index.setdefault(f"{dataset}|{config}|{split}", []).append(url)
        print(f"indexed {dataset}", flush=True)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(index, indent=2, sort_keys=True) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
