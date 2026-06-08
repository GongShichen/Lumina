from __future__ import annotations

import argparse
from pathlib import Path

from .config import load_config, supported_dataclass_kwargs
from .train_common import ChatTemplateCollator, SFTDataset, init_swanlab, load_processor, load_q_lora_model, resolve_data_path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Train Lumina ReAct behavior cloning with TRL SFTTrainer.")
    parser.add_argument("--config", required=True, type=Path)
    return parser.parse_args()


def main() -> None:
    from transformers import Trainer, TrainingArguments

    args = parse_args()
    cfg = load_config(args.config)
    train_file = resolve_data_path(cfg["data"]["train_file"], config_path=args.config)
    dataset = SFTDataset(train_file)
    if len(dataset) == 0:
        raise SystemExit(f"SFT dataset is empty: {train_file}")
    eval_dataset = None
    if cfg.get("data", {}).get("eval_file"):
        eval_file = resolve_data_path(cfg["data"]["eval_file"], config_path=args.config)
        eval_dataset = SFTDataset(eval_file)

    model = load_q_lora_model(cfg.get("model", {}), cfg.get("lora", {}), train=True)
    processor = load_processor(cfg["model"]["name_or_path"])
    init_swanlab("lumina-agentic-sft", cfg.get("training", {}).get("run_name"), cfg)

    training_args = TrainingArguments(**supported_dataclass_kwargs(TrainingArguments, cfg.get("training", {})))
    collator = ChatTemplateCollator(
        processor,
        max_length=int(cfg.get("training", {}).get("max_length", 4096)),
        downsample_mode=cfg.get("data", {}).get("downsample_mode", "16x"),
        max_slice_nums=int(cfg.get("data", {}).get("max_slice_nums", 9)),
    )
    trainer = Trainer(
        model=model,
        args=training_args,
        train_dataset=dataset,
        eval_dataset=eval_dataset,
        data_collator=collator,
    )
    trainer.train()
    trainer.save_model(cfg["training"]["output_dir"])
    processor.save_pretrained(cfg["training"]["output_dir"])


if __name__ == "__main__":
    main()
