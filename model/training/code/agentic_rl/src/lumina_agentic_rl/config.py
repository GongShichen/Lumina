from __future__ import annotations

from pathlib import Path
from typing import Any

import yaml


def load_config(path: str | Path) -> dict[str, Any]:
    payload = yaml.safe_load(Path(path).read_text(encoding="utf-8")) or {}
    if not isinstance(payload, dict):
        raise ValueError(f"{path} must contain a YAML mapping")
    return payload


def supported_dataclass_kwargs(config_cls: type[Any], payload: dict[str, Any]) -> dict[str, Any]:
    fields = getattr(config_cls, "__dataclass_fields__", {})
    if not fields:
        return dict(payload)
    return {key: value for key, value in payload.items() if key in fields}
