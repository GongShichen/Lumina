#!/usr/bin/env python3
"""Build MiniCPM SFT/DPO data without adding semantic training content."""

from __future__ import annotations

import argparse
import ast
import hashlib
import json
import random
import re
import subprocess
import tempfile
import time
import urllib.parse
import urllib.request
from collections import Counter, defaultdict
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import pyarrow.parquet as pq


DATASETS_SERVER = "https://datasets-server.huggingface.co"
PARQUET_INDEX: dict[str, list[str]] = {}
HF_DOWNLOAD_MIRROR: str | None = None
TRANSPORT_NAME = re.compile(r"^[^\s<>/=]+$")
RESERVED_SOURCE_TOKENS = ("<|im_start|>", "<|im_end|>", "<|endoftext|>")

TOKENIZER_SPECIAL_TOKENS = {
    "bos_token": "<|im_start|>",
    "eos_token": "<|im_end|>",
    "pad_token": "<|endoftext|>",
    "unk_token": "<unk>",
    "image_start_token": "<image>",
    "image_end_token": "</image>",
    "image_id_start_token": "<image_id>",
    "image_id_end_token": "</image_id>",
    "image_token": "<|image_pad|>",
    "slice_start_token": "<slice>",
    "slice_end_token": "</slice>",
    "vision_bos_token": "<|vision_start|>",
    "vision_eos_token": "<|vision_end|>",
    "video_token": "<|video_pad|>",
    "audio_bos_token": "<|audio_start|>",
    "audio_eos_token": "<|audio_end|>",
    "audio_token": "<|audio_pad|>",
}


def compact_json(value: Any) -> str:
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"), default=str)


def stable_hash(value: Any) -> str:
    return hashlib.sha256(compact_json(value).encode("utf-8")).hexdigest()


def parse_json(value: Any) -> Any:
    if not isinstance(value, str):
        return value
    try:
        return json.loads(value)
    except json.JSONDecodeError:
        try:
            return ast.literal_eval(value)
        except Exception:
            return value


def source_text(value: Any) -> str | None:
    if not isinstance(value, str) or not value.strip():
        return None
    if any(token in value for token in RESERVED_SOURCE_TOKENS):
        return None
    return value


def contains_cjk(text: str) -> bool:
    return any("\u4e00" <= char <= "\u9fff" for char in text)


def get_json(path: str, params: dict[str, Any]) -> dict[str, Any]:
    url = f"{DATASETS_SERVER}{path}?{urllib.parse.urlencode(params)}"
    last_error: Exception | None = None
    for attempt in range(8):
        try:
            with urllib.request.urlopen(url, timeout=30) as response:
                return json.loads(response.read().decode("utf-8"))
        except Exception as error:
            last_error = error
            time.sleep(1.25 * (attempt + 1))
    raise RuntimeError(f"failed to fetch {url}: {last_error}")


def parquet_urls(dataset: str, config: str, split: str) -> list[str]:
    key = f"{dataset}|{config}|{split}"
    if PARQUET_INDEX.get(key):
        return PARQUET_INDEX[key]
    payload = get_json("/parquet", {"dataset": dataset})
    urls = [
        item["url"]
        for item in payload.get("parquet_files", [])
        if item.get("config") == config and item.get("split") == split and item.get("url")
    ]
    if not urls:
        raise RuntimeError(f"no parquet files for {dataset}:{config}:{split}")
    return urls


def download(url: str, cache_dir: Path) -> Path:
    if HF_DOWNLOAD_MIRROR and url.startswith("https://huggingface.co"):
        url = HF_DOWNLOAD_MIRROR.rstrip("/") + url.removeprefix("https://huggingface.co")
    path = cache_dir / f"{hashlib.sha1(url.encode()).hexdigest()}.parquet"
    if path.exists() and path.stat().st_size:
        return path
    last_error: Exception | None = None
    for attempt in range(6):
        try:
            with urllib.request.urlopen(url, timeout=180) as response:
                path.write_bytes(response.read())
            return path
        except Exception as error:
            last_error = error
            path.unlink(missing_ok=True)
            time.sleep(2 * (attempt + 1))
    try:
        subprocess.run(
            ["curl", "-L", "--retry", "10", "--retry-all-errors", "--fail", "-o", str(path), url],
            check=True,
        )
        return path
    except Exception as error:
        path.unlink(missing_ok=True)
        raise RuntimeError(f"failed to download {url}: {last_error}; curl={error}") from error


def read_rows(
    dataset: str,
    config: str,
    split: str,
    *,
    cache_dir: Path,
    columns: list[str] | None = None,
    limit: int | None = None,
    max_files: int | None = None,
) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    for index, url in enumerate(parquet_urls(dataset, config, split)):
        if max_files is not None and index >= max_files:
            break
        print(f"read {dataset}:{config}:{split} file={index}", flush=True)
        table = pq.read_table(download(url, cache_dir), columns=columns)
        for row in table.to_pylist():
            rows.append(row)
            if limit is not None and len(rows) >= limit:
                return rows
    return rows


def role_name(value: Any) -> str | None:
    mapping = {
        "system": "system",
        "user": "user",
        "human": "user",
        "assistant": "assistant",
        "gpt": "assistant",
        "tool": "tool",
        "function": "tool",
        "function_observation": "tool",
        "observation": "tool",
    }
    return mapping.get(str(value).lower())


def render_argument(value: Any) -> str | None:
    rendered = value if isinstance(value, str) else compact_json(value)
    if not isinstance(rendered, str):
        return None
    if any(token in rendered for token in ("</parameter>", "</function>", "</tool_call>")):
        return None
    return rendered


def render_tool_calls(calls: list[dict[str, Any]]) -> str | None:
    blocks: list[str] = []
    for call in calls:
        name = call.get("name")
        arguments = call.get("arguments", {})
        if not isinstance(name, str) or not TRANSPORT_NAME.fullmatch(name) or not isinstance(arguments, dict):
            return None
        lines = ["<tool_call>", f"<function={name}>"]
        for key, value in arguments.items():
            if not isinstance(key, str) or not TRANSPORT_NAME.fullmatch(key):
                return None
            rendered = render_argument(value)
            if rendered is None:
                return None
            lines.extend([f"<parameter={key}>", rendered, "</parameter>"])
        lines.extend(["</function>", "</tool_call>"])
        blocks.append("\n".join(lines))
    return "\n".join(blocks) if blocks else None


def normalize_source_tool(raw: Any) -> tuple[str, set[str], set[str]] | None:
    if not isinstance(raw, dict):
        return None
    body = raw.get("function") if isinstance(raw.get("function"), dict) else raw
    name = body.get("name")
    parameters = parse_json(body.get("parameters", {}))
    if not isinstance(name, str) or not isinstance(parameters, dict):
        return None
    properties = parse_json(parameters.get("properties", {}))
    required = parameters.get("required", [])
    if not isinstance(properties, dict) or not isinstance(required, list):
        return None
    return name, set(properties), {item for item in required if isinstance(item, str)}


def calls_match_source_tools(calls: list[dict[str, Any]], tools: list[Any]) -> bool:
    contracts = {item[0]: item[1:] for raw in tools for item in [normalize_source_tool(raw)] if item}
    for call in calls:
        arguments = call.get("arguments")
        contract = contracts.get(call.get("name"))
        if contract is None or not isinstance(arguments, dict):
            return False
        allowed, required = contract
        if set(arguments) - allowed or any(key not in arguments for key in required):
            return False
        if any(value is None or (isinstance(value, str) and not value.strip()) for key, value in arguments.items() if key in required):
            return False
    return bool(calls)


def structured_calls(message: dict[str, Any]) -> list[dict[str, Any]] | None:
    raw_calls = message.get("tool_calls")
    if raw_calls is None and isinstance(message.get("function_call"), dict):
        raw_calls = [{"function": message["function_call"]}]
    if not isinstance(raw_calls, list):
        return []
    calls: list[dict[str, Any]] = []
    for raw in raw_calls:
        function = raw.get("function") if isinstance(raw, dict) else None
        if not isinstance(function, dict):
            return None
        name = function.get("name")
        arguments = parse_json(function.get("arguments", {}))
        if not isinstance(name, str) or not isinstance(arguments, dict):
            return None
        calls.append({"name": name, "arguments": arguments})
    return calls


def convert_structured_messages(raw_messages: Any) -> list[dict[str, str]] | None:
    raw_messages = parse_json(raw_messages)
    if not isinstance(raw_messages, list):
        return None
    messages: list[dict[str, str]] = []
    for raw_item in raw_messages:
        item = parse_json(raw_item)
        if not isinstance(item, dict):
            return None
        role = role_name(item.get("role", item.get("from")))
        if role is None:
            return None
        content = item.get("content", item.get("value", ""))
        if not isinstance(content, str):
            content = compact_json(content)
        if any(token in content for token in RESERVED_SOURCE_TOKENS):
            return None
        calls = structured_calls(item) if role == "assistant" else []
        if calls is None:
            return None
        if calls:
            transport = render_tool_calls(calls)
            if transport is None:
                return None
            content = content.rstrip()
            content = f"{content}\n{transport}" if content else transport
        if not content.strip():
            return None
        messages.append({"role": role, "content": content})
    if not any(message["role"] == "user" for message in messages):
        return None
    if not any(message["role"] == "assistant" for message in messages):
        return None
    return messages


def parse_function_expression(expression: str) -> dict[str, Any] | None:
    try:
        node = ast.parse(expression, mode="eval").body
    except SyntaxError:
        match = re.fullmatch(r"(?P<name>[^()]+)\((?P<args>.*)\)", expression.strip(), re.S)
        if not match:
            return None
        name = match.group("name").strip()
        try:
            node = ast.parse(f"f({match.group('args')})", mode="eval").body
        except SyntaxError:
            return None
    else:
        if isinstance(node, ast.Call):
            if isinstance(node.func, ast.Name):
                name = node.func.id
            elif isinstance(node.func, ast.Attribute):
                name = ast.unparse(node.func)
            else:
                return None
        else:
            return None
    if not isinstance(node, ast.Call):
        return None
    arguments: dict[str, Any] = {}
    for index, argument in enumerate(node.args):
        try:
            arguments[f"arg{index}"] = ast.literal_eval(argument)
        except Exception:
            return None
    for keyword in node.keywords:
        if keyword.arg is None:
            return None
        try:
            arguments[keyword.arg] = ast.literal_eval(keyword.value)
        except Exception:
            return None
    return {"name": name, "arguments": arguments}


def toolace_assistant(value: str) -> str | None:
    stripped = value.strip()
    if not (stripped.startswith("[") and stripped.endswith("]")):
        return source_text(value)
    body = stripped[1:-1]
    expressions: list[str] = []
    start = 0
    depth = 0
    quote: str | None = None
    escaped = False
    for index, char in enumerate(body):
        if quote:
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == quote:
                quote = None
        elif char in ("'", '"'):
            quote = char
        elif char in "([{":
            depth += 1
        elif char in ")]}":
            depth -= 1
        elif char == "," and depth == 0:
            expressions.append(body[start:index].strip())
            start = index + 1
    expressions.append(body[start:].strip())
    calls = [parse_function_expression(expression) for expression in expressions if expression]
    if not calls or any(call is None for call in calls):
        return None
    return render_tool_calls([call for call in calls if call])


def provenance(source: str, row: dict[str, Any], mapping: dict[str, str], *, category: str, language: str, group: Any) -> dict[str, Any]:
    return {
        "source": source,
        "sourceGroupId": stable_hash({"source": source, "group": group}),
        "sourceRowSha256": stable_hash(row),
        "fieldMapping": mapping,
        "contentProvenance": "public_source_native",
        "generatedSemanticContent": False,
        "truncatedSourceCells": False,
        "category": category,
        "language": language,
        "modalities": ["text"],
    }


def add_sft(records: list[dict[str, Any]], *, source: str, row: dict[str, Any], messages: list[dict[str, str]], mapping: dict[str, str], category: str, language: str, group: Any) -> None:
    records.append(
        {
            "id": f"sft-{stable_hash({'source': source, 'row': row})[:20]}",
            "messages": messages,
            "metadata": provenance(source, row, mapping, category=category, language=language, group=group),
        }
    )


def add_dpo(records: list[dict[str, Any]], *, source: str, row: dict[str, Any], prompt: list[dict[str, str]], chosen: list[dict[str, str]], rejected: list[dict[str, str]], mapping: dict[str, str], category: str, language: str, group: Any) -> None:
    if chosen == rejected:
        return
    records.append(
        {
            "id": f"dpo-{stable_hash({'source': source, 'row': row})[:20]}",
            "prompt": prompt,
            "chosen": chosen,
            "rejected": rejected,
            "metadata": provenance(source, row, mapping, category=category, language=language, group=group),
        }
    )


def build_xlam(records: list[dict[str, Any]], rows: list[dict[str, Any]]) -> None:
    source = "NobodyExistsOnTheInternet/xlam-function-calling-60k:default:train"
    for row in rows:
        query = source_text(row.get("query"))
        tools = parse_json(row.get("tools"))
        answers = parse_json(row.get("answers"))
        if query is None or not isinstance(tools, list) or not isinstance(answers, list):
            continue
        calls: list[dict[str, Any]] = []
        for answer in answers:
            if not isinstance(answer, dict):
                calls = []
                break
            arguments = parse_json(answer.get("arguments", {}))
            if not isinstance(answer.get("name"), str) or not isinstance(arguments, dict):
                calls = []
                break
            calls.append({"name": answer["name"], "arguments": arguments})
        output = render_tool_calls(calls)
        if output is None or not calls_match_source_tools(calls, tools):
            continue
        messages = [
            {"role": "system", "content": compact_json(tools)},
            {"role": "user", "content": query},
            {"role": "assistant", "content": output},
        ]
        add_sft(records, source=source, row=row, messages=messages, mapping={"messages[0].content": "tools", "messages[1].content": "query", "messages[2].content": "answers->MiniCPM transport"}, category="tool", language="zh" if contains_cjk(query) else "en", group=row.get("id") or stable_hash(row))


def build_bfcl(records: list[dict[str, Any]], rows: list[dict[str, Any]], source: str) -> None:
    for row in rows:
        raw_messages = parse_json(row.get("messages"))
        tools = parse_json(row.get("tools"))
        if not isinstance(raw_messages, list) or not isinstance(tools, list):
            continue
        messages: list[dict[str, str]] = [{"role": "system", "content": compact_json(tools)}]
        valid = True
        for item in raw_messages:
            if not isinstance(item, dict):
                valid = False
                break
            role = role_name(item.get("role"))
            if role is None:
                valid = False
                break
            if role == "assistant":
                calls = structured_calls(item)
                if calls is None or not calls or not calls_match_source_tools(calls, tools):
                    valid = False
                    break
                content = render_tool_calls(calls)
            else:
                content = source_text(item.get("content"))
            if content is None:
                valid = False
                break
            messages.append({"role": role, "content": content})
        if not valid:
            continue
        user_text = "\n".join(message["content"] for message in messages if message["role"] == "user")
        add_sft(records, source=source, row=row, messages=messages, mapping={"messages[0].content": "tools", "messages[1:].content": "messages; tool_calls->MiniCPM transport"}, category="tool", language="zh" if contains_cjk(user_text) else "en", group=stable_hash(row))


def build_pyromind(records: list[dict[str, Any]], rows: list[dict[str, Any]]) -> None:
    source = "pyromind/agentic-tool-call-dataset-12k:short:train"
    for row in rows:
        messages = convert_structured_messages(row.get("messages"))
        if messages is None or sum(message["role"] == "assistant" for message in messages) < 2:
            continue
        visible = "\n".join(message["content"] for message in messages if message["role"] == "user")
        add_sft(records, source=source, row=row, messages=messages, mapping={"messages": "messages; structured tool_calls->MiniCPM transport"}, category="agent_tool", language="zh" if contains_cjk(visible) else "en", group=stable_hash(row))


def build_toolace(records: list[dict[str, Any]], rows: list[dict[str, Any]]) -> None:
    source = "lockon/ToolACE:default:train"
    for row in rows:
        system = source_text(row.get("system"))
        conversations = parse_json(row.get("conversations"))
        if system is None or not isinstance(conversations, list):
            continue
        messages: list[dict[str, str]] = [{"role": "system", "content": system}]
        valid = True
        for item in conversations:
            if not isinstance(item, dict):
                valid = False
                break
            role = role_name(item.get("from"))
            value = item.get("value")
            if role is None or not isinstance(value, str):
                valid = False
                break
            content = toolace_assistant(value) if role == "assistant" else source_text(value)
            if content is None:
                valid = False
                break
            messages.append({"role": role, "content": content})
        if not valid or sum(message["role"] == "assistant" for message in messages) < 1:
            continue
        user_text = "\n".join(message["content"] for message in messages if message["role"] == "user")
        category = "agent_tool" if sum(message["role"] == "assistant" for message in messages) > 1 else "tool"
        add_sft(records, source=source, row=row, messages=messages, mapping={"messages[0].content": "system", "messages[1:].content": "conversations.value; function expressions->MiniCPM transport"}, category=category, language="zh" if contains_cjk(user_text) else "en", group=stable_hash(row))


def build_hotpot(records: list[dict[str, Any]], rows: list[dict[str, Any]]) -> None:
    source = "hotpotqa/hotpot_qa:distractor:train"
    for row in rows:
        question = source_text(row.get("question"))
        answer = source_text(row.get("answer"))
        context = row.get("context")
        if question is None or answer is None or not isinstance(context, dict):
            continue
        prompt_value = compact_json({"question": question, "context": context})
        messages = [{"role": "user", "content": prompt_value}, {"role": "assistant", "content": answer}]
        add_sft(records, source=source, row=row, messages=messages, mapping={"messages[0].content": "JSON(question,context)", "messages[1].content": "answer"}, category="multi_hop", language="en", group=row.get("id") or stable_hash(row))


def build_cmrc(records: list[dict[str, Any]], rows: list[dict[str, Any]]) -> None:
    source = "hfl/cmrc2018:default:train"
    for row in rows:
        question = source_text(row.get("question"))
        context = source_text(row.get("context"))
        answers = row.get("answers")
        texts = answers.get("text") if isinstance(answers, dict) else None
        answer = source_text(texts[0]) if isinstance(texts, list) and texts else None
        if question is None or context is None or answer is None:
            continue
        prompt_value = compact_json({"question": question, "context": context})
        messages = [{"role": "user", "content": prompt_value}, {"role": "assistant", "content": answer}]
        add_sft(records, source=source, row=row, messages=messages, mapping={"messages[0].content": "JSON(question,context)", "messages[1].content": "answers.text[0]"}, category="multi_hop", language="zh", group=row.get("id") or stable_hash(row))


def sharegpt_messages(value: Any) -> list[dict[str, str]] | None:
    value = parse_json(value)
    if not isinstance(value, list):
        return None
    messages: list[dict[str, str]] = []
    for item in value:
        if not isinstance(item, dict):
            return None
        role = role_name(item.get("from", item.get("role")))
        content = source_text(item.get("value", item.get("content")))
        if role is None or content is None:
            return None
        messages.append({"role": role, "content": content})
    return messages


def completion_messages(value: Any) -> list[dict[str, str]] | None:
    if isinstance(value, str):
        content = source_text(value)
        return [{"role": "assistant", "content": content}] if content else None
    if isinstance(value, dict):
        value = [value]
    messages = sharegpt_messages(value)
    if messages is None:
        return None
    assistant = [message for message in messages if message["role"] == "assistant"]
    return assistant if assistant else None


def build_ultrainteract(records: list[dict[str, Any]], rows: list[dict[str, Any]], limit: int) -> None:
    source = "openbmb/UltraInteract_pair:default:train"
    for row in rows:
        trajectory = sharegpt_messages(row.get("trajectory"))
        chosen = completion_messages(row.get("chosen"))
        rejected = completion_messages(row.get("rejected"))
        if trajectory is None or chosen is None or rejected is None or len(trajectory) < 2:
            continue
        language = "zh" if contains_cjk("\n".join(message["content"] for message in trajectory)) else "en"
        add_dpo(records, source=source, row=row, prompt=trajectory, chosen=chosen, rejected=rejected, mapping={"prompt": "trajectory", "chosen": "chosen", "rejected": "rejected"}, category="agent_multi_hop", language=language, group=row.get("parent_id") or stable_hash(trajectory))
        if len(records) >= limit:
            return


def build_bilingual_dpo(records: list[dict[str, Any]], rows: list[dict[str, Any]], source: str, language: str) -> None:
    for row in rows:
        prompt = sharegpt_messages(row.get("conversations"))
        chosen = completion_messages(row.get("chosen"))
        rejected = completion_messages(row.get("rejected"))
        if prompt is None or chosen is None or rejected is None:
            continue
        add_dpo(records, source=source, row=row, prompt=prompt, chosen=chosen, rejected=rejected, mapping={"prompt": "conversations", "chosen": "chosen", "rejected": "rejected"}, category="preference", language=language, group=stable_hash(prompt))


def dedupe(records: list[dict[str, Any]]) -> list[dict[str, Any]]:
    seen_records: set[str] = set()
    seen_prompts: set[str] = set()
    output: list[dict[str, Any]] = []
    for record in records:
        record_hash = stable_hash(record.get("messages") or {"prompt": record.get("prompt"), "chosen": record.get("chosen"), "rejected": record.get("rejected")})
        prompt_hash = stable_hash(record.get("messages", [])[:-1] or record.get("prompt"))
        if record_hash in seen_records or prompt_hash in seen_prompts:
            continue
        seen_records.add(record_hash)
        seen_prompts.add(prompt_hash)
        output.append(record)
    return output


def record_thoughts(record: dict[str, Any]) -> list[str]:
    sequences = [record["messages"]] if isinstance(record.get("messages"), list) else [record["prompt"], record["chosen"], record["rejected"]]
    return [
        thought.strip()
        for sequence in sequences
        for message in sequence
        if message.get("role") == "assistant"
        for thought in re.findall(r"<think>(.*?)</think>", message.get("content", ""), re.S)
        if thought.strip()
    ]


def cap_repeated_source_thoughts(
    sft: list[dict[str, Any]], dpo: list[dict[str, Any]], max_occurrences: int
) -> tuple[list[dict[str, Any]], list[dict[str, Any]], dict[str, Any]]:
    tagged = [("sft", record) for record in sft] + [("dpo", record) for record in dpo]
    tagged.sort(key=lambda item: stable_hash({"reasoningCapRecordId": item[1]["id"]}))
    occurrences: Counter[str] = Counter()
    kept_ids: set[str] = set()
    dropped_ids: list[str] = []
    for _, record in tagged:
        record_counts = Counter(record_thoughts(record))
        if any(occurrences[thought] + count > max_occurrences for thought, count in record_counts.items()):
            dropped_ids.append(record["id"])
            continue
        occurrences.update(record_counts)
        kept_ids.add(record["id"])
    return (
        [record for record in sft if record["id"] in kept_ids],
        [record for record in dpo if record["id"] in kept_ids],
        {
            "maxExactThoughtOccurrences": max_occurrences,
            "wholeRecordsOnly": True,
            "uniqueThoughts": len(occurrences),
            "observedMaxOccurrences": max(occurrences.values(), default=0),
            "droppedCompleteRecords": len(dropped_ids),
            "droppedIdsSha256": stable_hash(dropped_ids) if dropped_ids else None,
        },
    )


def split_records(records: list[dict[str, Any]], seed: int) -> tuple[list[dict[str, Any]], list[dict[str, Any]], list[dict[str, Any]]]:
    rng = random.Random(seed)
    grouped: defaultdict[str, defaultdict[str, list[dict[str, Any]]]] = defaultdict(lambda: defaultdict(list))
    for record in records:
        metadata = record["metadata"]
        grouped[metadata["source"]][metadata["sourceGroupId"]].append(record)
    train: list[dict[str, Any]] = []
    test: list[dict[str, Any]] = []
    evaluation: list[dict[str, Any]] = []
    for source_groups in grouped.values():
        group_ids = sorted(source_groups)
        rng.shuffle(group_ids)
        holdout = max(1, int(len(group_ids) * 0.1)) if len(group_ids) >= 10 else 0
        for group_id in group_ids[:holdout]:
            evaluation.extend(source_groups[group_id])
        for group_id in group_ids[holdout : holdout * 2]:
            test.extend(source_groups[group_id])
        for group_id in group_ids[holdout * 2 :]:
            train.extend(source_groups[group_id])
    for part in (train, test, evaluation):
        rng.shuffle(part)
    return train, test, evaluation


def record_sequences(record: dict[str, Any]) -> list[list[dict[str, Any]]]:
    if isinstance(record.get("messages"), list):
        return [record["messages"]]
    return [record["prompt"] + record["chosen"], record["prompt"] + record["rejected"]]


def encoded_length(processor: Any, messages: list[dict[str, Any]]) -> int:
    encoded = processor.apply_chat_template(
        messages,
        tokenize=True,
        add_generation_prompt=False,
        return_dict=True,
        return_tensors="pt",
        processor_kwargs={"truncation": False, "downsample_mode": "16x", "max_slice_nums": 9},
    )
    return int(encoded["input_ids"].shape[-1])


def filter_lengths(records: list[dict[str, Any]], processor: Any, max_tokens: int, kind: str) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    kept: list[dict[str, Any]] = []
    lengths: list[int] = []
    dropped: list[str] = []
    for index, record in enumerate(records, 1):
        length = max(encoded_length(processor, sequence) for sequence in record_sequences(record))
        lengths.append(length)
        if length <= max_tokens:
            kept.append(record)
        else:
            dropped.append(record["id"])
        if index % 5000 == 0:
            print(f"token QA {kind}: {index}/{len(records)}", flush=True)
    ordered = sorted(lengths)
    percentile = lambda fraction: ordered[min(len(ordered) - 1, int((len(ordered) - 1) * fraction))] if ordered else 0
    return kept, {
        "checked": len(records),
        "kept": len(kept),
        "droppedCompleteRecords": len(dropped),
        "maxTokens": max_tokens,
        "p50Tokens": percentile(0.5),
        "p95Tokens": percentile(0.95),
        "p99Tokens": percentile(0.99),
        "observedMaxTokens": max(ordered, default=0),
        "droppedIdsSha256": stable_hash(dropped) if dropped else None,
    }


def summary(records: list[dict[str, Any]]) -> dict[str, Any]:
    return {
        "records": len(records),
        "sources": dict(Counter(record["metadata"]["source"] for record in records)),
        "categories": dict(Counter(record["metadata"]["category"] for record in records)),
        "languages": dict(Counter(record["metadata"]["language"] for record in records)),
        "sourceGroups": len({record["metadata"]["sourceGroupId"] for record in records}),
    }


def write_jsonl(path: Path, records: list[dict[str, Any]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as handle:
        for record in records:
            handle.write(compact_json(record) + "\n")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--cache-dir", type=Path, default=Path(tempfile.gettempdir()) / "lumina_native_public_parquet")
    parser.add_argument("--processor-path", type=Path, required=True)
    parser.add_argument("--parquet-index", type=Path, required=True)
    parser.add_argument("--hf-download-mirror")
    parser.add_argument("--max-tokens", type=int, default=4096)
    parser.add_argument("--xlam-limit", type=int, default=20000)
    parser.add_argument("--pyromind-limit", type=int, default=12000)
    parser.add_argument("--hotpot-limit", type=int, default=10000)
    parser.add_argument("--cmrc-limit", type=int, default=10000)
    parser.add_argument("--ultrainteract-read-limit", type=int, default=180000)
    parser.add_argument("--ultrainteract-keep-limit", type=int, default=40000)
    args = parser.parse_args()

    global PARQUET_INDEX, HF_DOWNLOAD_MIRROR
    PARQUET_INDEX = json.loads(args.parquet_index.read_text(encoding="utf-8"))
    HF_DOWNLOAD_MIRROR = args.hf_download_mirror
    args.cache_dir.mkdir(parents=True, exist_ok=True)

    sft: list[dict[str, Any]] = []
    dpo: list[dict[str, Any]] = []
    build_xlam(sft, read_rows("NobodyExistsOnTheInternet/xlam-function-calling-60k", "default", "train", cache_dir=args.cache_dir, columns=["query", "tools", "answers", "id"], limit=args.xlam_limit))
    for config in ("simple", "multiple", "parallel", "parallel_multiple"):
        build_bfcl(sft, read_rows("minpeter/bfcl-v1-non-live-ast-parsed", config, "train", cache_dir=args.cache_dir, columns=["messages", "tools"], limit=2000), f"minpeter/bfcl-v1-non-live-ast-parsed:{config}:train")
    build_pyromind(sft, read_rows("pyromind/agentic-tool-call-dataset-12k", "short", "train", cache_dir=args.cache_dir, columns=["messages"], limit=args.pyromind_limit))
    build_toolace(sft, read_rows("lockon/ToolACE", "default", "train", cache_dir=args.cache_dir, columns=["system", "conversations"]))
    build_hotpot(sft, read_rows("hotpotqa/hotpot_qa", "distractor", "train", cache_dir=args.cache_dir, columns=["id", "question", "answer", "context"], limit=args.hotpot_limit, max_files=1))
    build_cmrc(sft, read_rows("hfl/cmrc2018", "default", "train", cache_dir=args.cache_dir, columns=["id", "context", "question", "answers"], limit=args.cmrc_limit))

    build_ultrainteract(dpo, read_rows("openbmb/UltraInteract_pair", "default", "train", cache_dir=args.cache_dir, columns=["task", "dataset", "trajectory", "chosen", "rejected", "id", "parent_id"], limit=args.ultrainteract_read_limit), args.ultrainteract_keep_limit)
    build_bilingual_dpo(dpo, read_rows("llamafactory/DPO-En-Zh-20k", "en", "train", cache_dir=args.cache_dir), "llamafactory/DPO-En-Zh-20k:en:train", "en")
    build_bilingual_dpo(dpo, read_rows("llamafactory/DPO-En-Zh-20k", "zh", "train", cache_dir=args.cache_dir), "llamafactory/DPO-En-Zh-20k:zh:train", "zh")

    sft = dedupe(sft)
    dpo = dedupe(dpo)
    if {record["metadata"]["source"] for record in sft} & {record["metadata"]["source"] for record in dpo}:
        raise RuntimeError("SFT/DPO sources overlap")
    sft, dpo, reasoning_dedup_qa = cap_repeated_source_thoughts(sft, dpo, 20)

    from transformers import AutoProcessor

    processor = AutoProcessor.from_pretrained(args.processor_path, trust_remote_code=True)
    sft, sft_length_qa = filter_lengths(sft, processor, args.max_tokens, "sft")
    dpo, dpo_length_qa = filter_lengths(dpo, processor, args.max_tokens, "dpo")
    if not sft or not dpo:
        raise RuntimeError("native SFT and DPO must both be non-empty")

    sft_train, sft_test, sft_eval = split_records(sft, 46)
    dpo_train, dpo_test, dpo_eval = split_records(dpo, 47)
    splits = {
        "sft_general_train.jsonl": sft_train,
        "sft_general_test.jsonl": sft_test,
        "sft_evaluation_test.jsonl": sft_eval,
        "dpo_general_train.jsonl": dpo_train,
        "dpo_general_test.jsonl": dpo_test,
        "dpo_evaluation_test.jsonl": dpo_eval,
    }
    for name, records in splits.items():
        write_jsonl(args.root / "splits" / name, records)

    sft_sources = sorted({record["metadata"]["source"] for record in sft})
    dpo_sources = sorted({record["metadata"]["source"] for record in dpo})
    manifest = {
        "createdAt": datetime.now(timezone.utc).isoformat(),
        "contentPolicy": {
            "semanticContent": "public source fields only",
            "allowedMechanicalTransforms": ["role tag mapping", "JSON serialization", "MiniCPM tool-call transport serialization"],
            "generatedSystemPrompts": False,
            "generatedReasoning": False,
            "generatedInstructions": False,
            "generatedRejectedResponses": False,
            "truncation": False,
        },
        "publicDataSources": {"sft": sft_sources, "dpo": dpo_sources},
        "sourceDisjoint": not bool(set(sft_sources) & set(dpo_sources)),
        "nativeReasoningDedupQA": reasoning_dedup_qa,
        "tokenLengthQA": {"verified": True, "processorIdentifier": args.processor_path.name, "sft": sft_length_qa, "dpo": dpo_length_qa},
        "summary": {name: summary(records) for name, records in splits.items()},
    }
    args.root.mkdir(parents=True, exist_ok=True)
    (args.root / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    (args.root / "minicpm_special_tokens.json").write_text(json.dumps({"tokenizerSpecialTokens": TOKENIZER_SPECIAL_TOKENS, "toolTransportTokens": ["<tool_call>", "</tool_call>", "<function=NAME>", "</function>", "<parameter=NAME>", "</parameter>"]}, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"sft": summary(sft), "dpo": summary(dpo), "splits": {name: len(records) for name, records in splits.items()}, "tokenLengthQA": manifest["tokenLengthQA"]}, ensure_ascii=False, indent=2), flush=True)


if __name__ == "__main__":
    main()
