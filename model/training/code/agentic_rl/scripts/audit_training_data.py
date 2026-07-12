#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
from collections import Counter, defaultdict
from pathlib import Path
from typing import Any


def canonical_hash(value: Any) -> str:
    payload = json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser(description="Independent split, source, and dedup audit.")
    parser.add_argument("--root", type=Path, required=True)
    args = parser.parse_args()

    errors: list[str] = []
    counts: Counter[str] = Counter()
    categories: Counter[tuple[str, str]] = Counter()
    languages: Counter[tuple[str, str]] = Counter()
    seen_ids: set[str] = set()
    prompt_kinds: defaultdict[str, set[str]] = defaultdict(set)
    group_splits: defaultdict[str, set[str]] = defaultdict(set)
    sources: defaultdict[str, set[str]] = defaultdict(set)

    for path in sorted((args.root / "splits").glob("*.jsonl")):
        kind = "sft" if path.name.startswith("sft_") else "dpo"
        split = path.stem
        split_prompts: set[str] = set()
        with path.open(encoding="utf-8") as handle:
            for line_number, line in enumerate(handle, 1):
                record = json.loads(line)
                counts[path.name] += 1
                record_id = str(record.get("id", ""))
                if not record_id or record_id in seen_ids:
                    errors.append(f"{path}:{line_number}: missing or duplicate id {record_id!r}")
                seen_ids.add(record_id)

                metadata = record.get("metadata", {})
                category = str(metadata.get("category", ""))
                language = str(metadata.get("language", ""))
                categories[(kind, category)] += 1
                languages[(kind, language)] += 1
                sources[kind].add(str(metadata.get("source", "")))
                group_splits[str(metadata.get("sourceGroupId", ""))].add(split)
                if metadata.get("truncatedSourceCells") is not False:
                    errors.append(f"{path}:{line_number}: truncatedSourceCells must be false")
                if category == "intent":
                    errors.append(f"{path}:{line_number}: short-label intent data is forbidden")

                prompt_hash = canonical_hash(record.get("prompt") or record.get("messages"))
                if prompt_hash in split_prompts:
                    errors.append(f"{path}:{line_number}: exact prompt duplicate within split")
                split_prompts.add(prompt_hash)
                prompt_kinds[prompt_hash].add(kind)

                if kind == "dpo" and record.get("chosen") == record.get("rejected"):
                    errors.append(f"{path}:{line_number}: chosen equals rejected")
                if metadata.get("contentProvenance") != "public_source_native":
                    errors.append(f"{path}:{line_number}: non-native content provenance")
                if metadata.get("generatedSemanticContent") is not False:
                    errors.append(f"{path}:{line_number}: generated semantic content")
                lowered = line.lower()
                if "minicpm-v4.6" in lowered or "minicpm-v-4.6" in lowered:
                    errors.append(f"{path}:{line_number}: model identity leaked into content")

    source_overlap = sorted(sources["sft"] & sources["dpo"])
    if source_overlap:
        errors.append(f"SFT/DPO source overlap: {source_overlap}")
    leaking_groups = sorted(group for group, splits in group_splits.items() if len(splits) > 1)
    if leaking_groups:
        errors.append(f"source groups cross splits: {leaking_groups[:10]}")
    cross_kind_prompts = sum(1 for kinds in prompt_kinds.values() if len(kinds) > 1)
    if cross_kind_prompts:
        errors.append(f"SFT/DPO exact prompt overlap: {cross_kind_prompts}")

    report = {
        "status": "PASS" if not errors else "FAIL",
        "errors": len(errors),
        "counts": dict(counts),
        "categories": {f"{kind}:{category}": count for (kind, category), count in categories.items()},
        "languages": {f"{kind}:{language}": count for (kind, language), count in languages.items()},
        "sftSources": len(sources["sft"]),
        "dpoSources": len(sources["dpo"]),
        "uniqueIds": len(seen_ids),
        "sourceGroups": len(group_splits),
    }
    print(json.dumps(report, ensure_ascii=False, indent=2))
    if errors:
        print("\nFirst errors:")
        print("\n".join(errors[:100]))
        raise SystemExit(1)


if __name__ == "__main__":
    main()
