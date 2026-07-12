from __future__ import annotations

import argparse
import json
import re
from collections import defaultdict
from pathlib import Path
from typing import Any

import torch

from .config import load_config
from .train_common import read_jsonl, resolve_data_path


NON_MINICPM_TOOL_MARKERS = (
    "<thought>",
    "</thought>",
    "<tool_use",
    "</tool_use>",
    "<result>",
    "</result>",
    "<cannot_complete>",
    "</cannot_complete>",
    "<observation",
    "</observation>",
    "tool_response",
)
THINK_RE = re.compile(r"<think>.*?</think>", re.S)
TOOL_CALL_RE = re.compile(
    r"<tool_call>\s*<function=(?P<name>[^>\s]+)>\s*"
    r"(?:<parameter=[^>\s]+>.*?</parameter>\s*)*</function>\s*</tool_call>",
    re.S,
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Gate SFT checkpoints with MiniCPM-V4.6 first-step generation.")
    parser.add_argument("--config", required=True, type=Path)
    parser.add_argument("--data", required=True, type=Path)
    parser.add_argument("--adapter", type=Path)
    parser.add_argument("--sample-size", type=int, default=160)
    parser.add_argument("--threshold", type=float, default=0.90)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--max-new-tokens", type=int, default=1024)
    return parser.parse_args()


def assistant_target(record: dict[str, Any]) -> str:
    for message in record.get("messages", []):
        if isinstance(message, dict) and message.get("role") == "assistant":
            content = message.get("content", "")
            return content if isinstance(content, str) else ""
    return ""


def prompt_messages(record: dict[str, Any]) -> list[dict[str, Any]]:
    return [message for message in record.get("messages", []) if isinstance(message, dict) and message.get("role") != "assistant"]


def stratified_samples(records: list[dict[str, Any]], sample_size: int) -> list[dict[str, Any]]:
    buckets: dict[tuple[str, str, str], list[dict[str, Any]]] = defaultdict(list)
    for record in records:
        metadata = record.get("metadata") if isinstance(record.get("metadata"), dict) else {}
        key = (
            str(metadata.get("category") or "unknown"),
            str(metadata.get("language") or "unknown"),
            str(metadata.get("expectedAction") or "unknown"),
        )
        buckets[key].append(record)
    selected: list[dict[str, Any]] = []
    offsets = {key: 0 for key in buckets}
    keys = sorted(buckets)
    while len(selected) < sample_size:
        added = False
        for key in keys:
            offset = offsets[key]
            if offset >= len(buckets[key]):
                continue
            selected.append(buckets[key][offset])
            offsets[key] += 1
            added = True
            if len(selected) >= sample_size:
                break
        if not added:
            break
    return selected


def legal_minicpm_step(text: str) -> bool:
    stripped = text.strip()
    without_think = THINK_RE.sub("", stripped, count=1).strip()
    tool_matches = list(TOOL_CALL_RE.finditer(without_think))
    if tool_matches:
        return not TOOL_CALL_RE.sub("", without_think).strip()
    return bool(without_think) and "<tool_call" not in without_think and "</tool_call>" not in without_think


def tool_names(text: str) -> list[str]:
    without_think = THINK_RE.sub("", text.strip(), count=1).strip()
    matches = list(TOOL_CALL_RE.finditer(without_think))
    if not matches or TOOL_CALL_RE.sub("", without_think).strip():
        return []
    return [match.group("name") for match in matches]


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
    samples = stratified_samples(records, args.sample_size)
    if not samples:
        raise SystemExit(f"holdout data is empty: {data_path}")

    model, processor = load_sft_model(cfg, adapter_path)
    results: list[dict[str, Any]] = []
    legal = 0
    non_minicpm_marker_count = 0
    expected_tool_use = 0
    legal_tool_use = 0
    tool_decision_correct = 0
    tool_name_sequence_correct = 0
    by_category: dict[str, dict[str, int]] = defaultdict(lambda: {
        "samples": 0,
        "legal": 0,
        "decisionCorrect": 0,
        "expectedToolUse": 0,
        "toolNameSequenceCorrect": 0,
    })
    for record in samples:
        target = assistant_target(record)
        metadata = record.get("metadata") if isinstance(record.get("metadata"), dict) else {}
        expected_action = metadata.get("expectedAction")
        expected_is_tool = expected_action == "tool_call" if expected_action in {"tool_call", "direct_answer"} else "<tool_call" in target
        expected_tool_use += int(expected_is_tool)
        target_tokens = len(processor.tokenizer.encode(target, add_special_tokens=False))
        output = generate_first_step(model, processor, prompt_messages(record), max(args.max_new_tokens, target_tokens + 64))
        is_legal = legal_minicpm_step(output)
        expected_names = tool_names(target)
        output_names = tool_names(output)
        output_is_tool = bool(output_names)
        decision_correct = expected_is_tool == output_is_tool
        names_correct = bool(expected_names) and expected_names == output_names
        has_non_minicpm_marker = any(token in output for token in NON_MINICPM_TOOL_MARKERS)
        legal += int(is_legal)
        non_minicpm_marker_count += int(has_non_minicpm_marker)
        legal_tool_use += int(expected_is_tool and is_legal and output_is_tool)
        tool_decision_correct += int(decision_correct)
        tool_name_sequence_correct += int(names_correct)
        category = str(metadata.get("category") or "unknown")
        category_metrics = by_category[category]
        category_metrics["samples"] += 1
        category_metrics["legal"] += int(is_legal)
        category_metrics["decisionCorrect"] += int(decision_correct)
        category_metrics["expectedToolUse"] += int(expected_is_tool)
        category_metrics["toolNameSequenceCorrect"] += int(names_correct)
        results.append({
            "id": record.get("id"),
            "category": category,
            "expectedAction": "tool_call" if expected_is_tool else "direct_answer",
            "expectedToolUse": expected_is_tool,
            "legal": is_legal,
            "toolDecisionCorrect": decision_correct,
            "expectedToolNames": expected_names,
            "outputToolNames": output_names,
            "toolNameSequenceCorrect": names_correct if expected_is_tool else None,
            "nonMiniCPMMarker": has_non_minicpm_marker,
            "output": output,
        })

    legal_rate = legal / len(samples)
    legal_tool_use_rate = (legal_tool_use / expected_tool_use) if expected_tool_use else 1.0
    tool_decision_accuracy = tool_decision_correct / len(samples)
    tool_name_sequence_accuracy = (tool_name_sequence_correct / expected_tool_use) if expected_tool_use else 1.0
    summary = {
        "data": str(data_path),
        "adapter": str(adapter_path),
        "sampleSize": len(samples),
        "legalStepRate": legal_rate,
        "nonMiniCPMMarkerCount": non_minicpm_marker_count,
        "expectedToolUseCount": expected_tool_use,
        "legalToolUseRate": legal_tool_use_rate,
        "toolDecisionAccuracy": tool_decision_accuracy,
        "toolNameSequenceAccuracy": tool_name_sequence_accuracy,
        "byCategory": dict(sorted(by_category.items())),
        "threshold": args.threshold,
        "passed": (
            legal_rate >= args.threshold
            and tool_decision_accuracy >= args.threshold
            and tool_name_sequence_accuracy >= args.threshold
        ),
        "examples": results,
    }
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(summary, ensure_ascii=False, indent=2))
    if not summary["passed"]:
        raise SystemExit(3)


if __name__ == "__main__":
    main()
