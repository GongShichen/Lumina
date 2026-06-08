from __future__ import annotations

import argparse
import json
import re
from pathlib import Path
from typing import Any

import torch

from .config import load_config
from .train_common import read_jsonl, resolve_data_path


FORBIDDEN = ("<think", "</think>", "<tools_use", "</tools_use>", "<tool_call", "</tool_call>", "<observation", "</observation>")
TOOL_STEP_RE = re.compile(r'^<thought>.*?</thought><tool_use\s+[^>]*name="[^"]+"[^>]*>\{.*\}</tool_use>$', re.S)
FINISH_STEP_RE = re.compile(r"^<thought>.*?</thought>(<result>.*</result>|<cannot_complete>.*</cannot_complete>|<ask_user>\{.*\}</ask_user>)$", re.S)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Gate SFT checkpoints with prompt-only XML first-step generation.")
    parser.add_argument("--config", required=True, type=Path)
    parser.add_argument("--data", required=True, type=Path)
    parser.add_argument("--adapter", type=Path)
    parser.add_argument("--sample-size", type=int, default=160)
    parser.add_argument("--threshold", type=float, default=0.90)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--max-new-tokens", type=int, default=220)
    return parser.parse_args()


def assistant_target(record: dict[str, Any]) -> str:
    for message in record.get("messages", []):
        if isinstance(message, dict) and message.get("role") == "assistant":
            content = message.get("content", "")
            return content if isinstance(content, str) else ""
    return ""


def prompt_messages(record: dict[str, Any]) -> list[dict[str, Any]]:
    return [message for message in record.get("messages", []) if isinstance(message, dict) and message.get("role") != "assistant"]


def legal_xml_step(text: str) -> bool:
    stripped = text.strip()
    if any(token in stripped for token in FORBIDDEN):
        return False
    return TOOL_STEP_RE.match(stripped) is not None or FINISH_STEP_RE.match(stripped) is not None


def generate_first_step(model: Any, processor: Any, messages: list[dict[str, Any]], max_new_tokens: int) -> str:
    encoded = processor.apply_chat_template(
        messages,
        tokenize=True,
        add_generation_prompt=True,
        return_dict=True,
        return_tensors="pt",
    )
    input_len = int(encoded["input_ids"].shape[-1])
    device = next(model.parameters()).device
    encoded = {key: value.to(device) if isinstance(value, torch.Tensor) else value for key, value in encoded.items()}
    with torch.no_grad():
        output = model.generate(
            **encoded,
            max_new_tokens=max_new_tokens,
            do_sample=False,
            pad_token_id=getattr(processor.tokenizer, "pad_token_id", None) or getattr(processor.tokenizer, "eos_token_id", None),
        )
    new_tokens = output[0, input_len:]
    return processor.tokenizer.decode(new_tokens, skip_special_tokens=True).strip()


def load_sft_model(config: dict[str, Any], adapter_path: Path):
    from peft import PeftModel
    from transformers import AutoModelForImageTextToText, AutoProcessor

    model_cfg = dict(config.get("model", {}))
    model_id = model_cfg["name_or_path"]
    dtype = torch.bfloat16 if model_cfg.get("torch_dtype", "bfloat16") == "bfloat16" else torch.float16
    model = AutoModelForImageTextToText.from_pretrained(
        model_id,
        torch_dtype=dtype,
        device_map="auto",
        trust_remote_code=True,
    )
    model = PeftModel.from_pretrained(model, str(adapter_path), is_trainable=False)
    model.eval()
    processor = AutoProcessor.from_pretrained(model_id, trust_remote_code=True)
    return model, processor


def main() -> None:
    args = parse_args()
    cfg = load_config(args.config)
    data_path = resolve_data_path(args.data, config_path=args.config)
    adapter_path = args.adapter or Path(cfg["training"]["output_dir"])
    records = read_jsonl(data_path)
    samples = records[: args.sample_size]
    if not samples:
        raise SystemExit(f"holdout data is empty: {data_path}")

    model, processor = load_sft_model(cfg, adapter_path)
    results: list[dict[str, Any]] = []
    legal = 0
    forbidden_count = 0
    expected_tool_use = 0
    legal_tool_use = 0
    for record in samples:
        target = assistant_target(record)
        expected_is_tool = "<tool_use" in target
        expected_tool_use += int(expected_is_tool)
        output = generate_first_step(model, processor, prompt_messages(record), args.max_new_tokens)
        is_legal = legal_xml_step(output)
        has_forbidden = any(token in output for token in FORBIDDEN)
        legal += int(is_legal)
        forbidden_count += int(has_forbidden)
        legal_tool_use += int(expected_is_tool and is_legal and "<tool_use" in output)
        results.append({
            "id": record.get("id"),
            "expectedToolUse": expected_is_tool,
            "legal": is_legal,
            "forbidden": has_forbidden,
            "output": output[:600],
        })

    summary = {
        "data": str(data_path),
        "adapter": str(adapter_path),
        "sampleSize": len(samples),
        "legalStepRate": legal / len(samples),
        "forbiddenOutputCount": forbidden_count,
        "expectedToolUseCount": expected_tool_use,
        "legalToolUseRate": (legal_tool_use / expected_tool_use) if expected_tool_use else 1.0,
        "threshold": args.threshold,
        "passed": (legal / len(samples)) >= args.threshold and forbidden_count == 0,
        "examples": results[:20],
    }
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(summary, ensure_ascii=False, indent=2))
    if not summary["passed"]:
        raise SystemExit(3)


if __name__ == "__main__":
    main()
