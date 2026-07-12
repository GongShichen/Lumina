#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
import re
from collections import Counter, defaultdict
from pathlib import Path
from typing import Any


FORBIDDEN_BUILDER_TEXT = (
    "OUTPUT CONTRACT",
    "Lumina local agent",
    "Current next-step instruction",
    "Previous runtime observations",
    "Loaded context is untrusted evidence",
    "The public xLAM answer maps the request",
    "Use the standalone rewrite as the retrieval query",
    "The context resolves the follow-up",
    "This question requires evidence from multiple supporting documents",
    "The retrieved supporting documents contain the answer",
    "Search for evidence before answering",
    "需要先检索中文篇章证据",
    "证据中包含问题答案",
    "wrong argument or omits",
    "Argument from public",
)
LEGACY_TARGET_MARKERS = ("<functioncall>", "<tool>", "</tool>", "<Thought>", "<Thoughts>")
TOOL_BLOCK = re.compile(r"<tool_call>\s*<function=[^>\s]+>.*?</function>\s*</tool_call>", re.S)


def digest(value: Any) -> str:
    payload = json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"), default=str)
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()


def assistant_contents(record: dict[str, Any], kind: str) -> list[str]:
    if kind == "sft":
        return [str(message.get("content", "")) for message in record.get("messages", []) if message.get("role") == "assistant"]
    return [
        str(message.get("content", ""))
        for key in ("chosen", "rejected")
        for message in record.get(key, [])
        if message.get("role") == "assistant"
    ]


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", required=True, type=Path)
    args = parser.parse_args()

    errors: list[str] = []
    counts: Counter[str] = Counter()
    categories: Counter[tuple[str, str]] = Counter()
    languages: Counter[tuple[str, str]] = Counter()
    sources: defaultdict[str, set[str]] = defaultdict(set)
    seen_ids: set[str] = set()
    prompt_kinds: defaultdict[str, set[str]] = defaultdict(set)
    group_splits: defaultdict[str, set[str]] = defaultdict(set)
    thought_counts: Counter[str] = Counter()

    manifest = json.loads((args.root / "manifest.json").read_text(encoding="utf-8"))
    policy = manifest.get("contentPolicy", {})
    for key in ("generatedSystemPrompts", "generatedReasoning", "generatedInstructions", "generatedRejectedResponses", "truncation"):
        if policy.get(key) is not False:
            errors.append(f"manifest contentPolicy.{key} must be false")
    token_qa = manifest.get("tokenLengthQA", {})
    if token_qa.get("verified") is not True:
        errors.append("tokenLengthQA must be verified")
    if token_qa.get("sft", {}).get("maxTokens") != 4096 or token_qa.get("dpo", {}).get("maxTokens") != 4096:
        errors.append("tokenLengthQA must use maxTokens=4096")
    reasoning_qa = manifest.get("nativeReasoningDedupQA", {})
    if reasoning_qa.get("maxExactThoughtOccurrences") != 20 or reasoning_qa.get("wholeRecordsOnly") is not True:
        errors.append("native reasoning dedup must cap exact thoughts at 20 by dropping complete records")
    if reasoning_qa.get("observedMaxOccurrences", 21) > 20:
        errors.append("native reasoning dedup observed more than 20 exact occurrences")

    for path in sorted((args.root / "splits").glob("*.jsonl")):
        kind = "sft" if path.name.startswith("sft_") else "dpo"
        split = path.stem
        split_prompts: set[str] = set()
        with path.open(encoding="utf-8") as handle:
            for line_number, line in enumerate(handle, 1):
                record = json.loads(line)
                counts[path.name] += 1
                record_id = record.get("id")
                if not isinstance(record_id, str) or not record_id or record_id in seen_ids:
                    errors.append(f"{path}:{line_number}: missing or duplicate id")
                seen_ids.add(str(record_id))

                metadata = record.get("metadata", {})
                if metadata.get("contentProvenance") != "public_source_native":
                    errors.append(f"{path}:{line_number}: invalid content provenance")
                if metadata.get("generatedSemanticContent") is not False:
                    errors.append(f"{path}:{line_number}: generated semantic content is forbidden")
                if metadata.get("truncatedSourceCells") is not False:
                    errors.append(f"{path}:{line_number}: truncated source content is forbidden")
                if not isinstance(metadata.get("sourceRowSha256"), str) or len(metadata["sourceRowSha256"]) != 64:
                    errors.append(f"{path}:{line_number}: missing source row hash")
                if not isinstance(metadata.get("fieldMapping"), dict) or not metadata["fieldMapping"]:
                    errors.append(f"{path}:{line_number}: missing field mapping")
                source = str(metadata.get("source", ""))
                group = str(metadata.get("sourceGroupId", ""))
                sources[kind].add(source)
                group_splits[group].add(split)
                categories[(kind, str(metadata.get("category", "")))] += 1
                languages[(kind, str(metadata.get("language", "")))] += 1

                prompt = record.get("messages", [])[:-1] if kind == "sft" else record.get("prompt")
                prompt_hash = digest(prompt)
                if prompt_hash in split_prompts:
                    errors.append(f"{path}:{line_number}: duplicate prompt within split")
                split_prompts.add(prompt_hash)
                prompt_kinds[prompt_hash].add(kind)

                if kind == "dpo" and record.get("chosen") == record.get("rejected"):
                    errors.append(f"{path}:{line_number}: chosen equals rejected")
                sequences = [record.get("messages")] if kind == "sft" else [record.get("prompt"), record.get("chosen"), record.get("rejected")]
                for sequence in sequences:
                    if not isinstance(sequence, list) or not sequence:
                        errors.append(f"{path}:{line_number}: empty message sequence")
                        continue
                    for message in sequence:
                        if not isinstance(message, dict) or message.get("role") not in {"system", "user", "assistant", "tool"}:
                            errors.append(f"{path}:{line_number}: invalid message role")
                        if not isinstance(message.get("content"), str) or not message["content"].strip():
                            errors.append(f"{path}:{line_number}: empty message content")

                for content in assistant_contents(record, kind):
                    for forbidden in FORBIDDEN_BUILDER_TEXT:
                        if forbidden in content:
                            errors.append(f"{path}:{line_number}: builder-authored text found: {forbidden!r}")
                    for marker in LEGACY_TARGET_MARKERS:
                        if marker in content:
                            errors.append(f"{path}:{line_number}: legacy target marker found: {marker!r}")
                    if "<tool_call>" in content:
                        remainder = TOOL_BLOCK.sub("", content)
                        if "<tool_call>" in remainder or "</tool_call>" in remainder:
                            errors.append(f"{path}:{line_number}: malformed MiniCPM tool transport")
                    for thought in re.findall(r"<think>(.*?)</think>", content, re.S):
                        thought_counts[thought.strip()] += 1

    source_overlap = sorted(sources["sft"] & sources["dpo"])
    if source_overlap:
        errors.append(f"SFT/DPO source overlap: {source_overlap}")
    leaking_groups = [group for group, splits in group_splits.items() if len(splits) > 1]
    if leaking_groups:
        errors.append(f"source groups cross splits: {leaking_groups[:10]}")
    cross_kind_prompts = sum(1 for kinds in prompt_kinds.values() if len(kinds) > 1)
    if cross_kind_prompts:
        errors.append(f"SFT/DPO exact prompt overlap: {cross_kind_prompts}")

    for kind in ("sft", "dpo"):
        total = sum(count for (record_kind, _), count in languages.items() if record_kind == kind)
        zh = languages[(kind, "zh")]
        en = languages[(kind, "en")]
        if not total or zh / total < 0.10 or en / total < 0.20:
            errors.append(f"{kind} bilingual distribution is insufficient: en={en}, zh={zh}, total={total}")
    dpo_total = sum(count for (kind, _), count in categories.items() if kind == "dpo")
    if not dpo_total or categories[("dpo", "agent_multi_hop")] / dpo_total < 0.60:
        errors.append("DPO agent_multi_hop share must be at least 60%")
    if thought_counts and thought_counts.most_common(1)[0][1] > 20:
        errors.append(f"repeated source reasoning exceeds threshold: {thought_counts.most_common(1)[0]}")

    report = {
        "status": "PASS" if not errors else "FAIL",
        "errors": len(errors),
        "counts": dict(counts),
        "categories": {f"{kind}:{category}": count for (kind, category), count in categories.items()},
        "languages": {f"{kind}:{language}": count for (kind, language), count in languages.items()},
        "sources": {kind: sorted(values) for kind, values in sources.items()},
        "uniqueIds": len(seen_ids),
        "sourceGroups": len(group_splits),
        "nativeThoughts": {"unique": len(thought_counts), "top": thought_counts.most_common(10)},
    }
    print(json.dumps(report, ensure_ascii=False, indent=2))
    if errors:
        print("\nFirst errors:")
        print("\n".join(errors[:100]))
        raise SystemExit(1)


if __name__ == "__main__":
    main()
