from __future__ import annotations

import argparse
import json
import shutil
from pathlib import Path

from .config import load_config, supported_dataclass_kwargs
from .train_common import (
    ChatTemplateCollator,
    SFTDataset,
    completion_only_cross_entropy,
    init_swanlab,
    load_processor,
    load_q_lora_model,
    resolve_data_path,
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Train Lumina ReAct behavior cloning with TRL SFTTrainer.")
    parser.add_argument("--config", required=True, type=Path)
    return parser.parse_args()


def main() -> None:
    from transformers import EarlyStoppingCallback, Trainer, TrainingArguments

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
    init_swanlab("lumina-agentic-sft", cfg.get("training", {}).get("run_name"), cfg, required=True)

    training_args = TrainingArguments(**supported_dataclass_kwargs(TrainingArguments, cfg.get("training", {})))
    collator = ChatTemplateCollator(
        processor,
        max_length=int(cfg.get("training", {}).get("max_length", 4096)),
        downsample_mode=cfg.get("data", {}).get("downsample_mode", "16x"),
        max_slice_nums=int(cfg.get("data", {}).get("max_slice_nums", 9)),
    )
    training_cfg = cfg.get("training", {})
    callbacks = []
    early_stopping_patience = int(training_cfg.get("early_stopping_patience", 0))
    if early_stopping_patience > 0:
        callbacks.append(
            EarlyStoppingCallback(
                early_stopping_patience=early_stopping_patience,
                early_stopping_threshold=float(training_cfg.get("early_stopping_threshold", 0.0)),
            )
        )
    class CompletionOnlyTrainer(Trainer):
        def compute_loss(self, model, inputs, return_outputs=False, num_items_in_batch=None):
            labels = inputs.pop("labels")
            loss = completion_only_cross_entropy(model, inputs, labels)
            return (loss, {"loss": loss}) if return_outputs else loss

    trainer = CompletionOnlyTrainer(
        model=model,
        args=training_args,
        train_dataset=dataset,
        eval_dataset=eval_dataset,
        data_collator=collator,
        callbacks=callbacks,
    )
    trainer.train()
    output_dir = Path(cfg["training"]["output_dir"])
    trainer.save_model(output_dir)
    processor.save_pretrained(output_dir)
    best_checkpoint = trainer.state.best_model_checkpoint
    (output_dir / "best_checkpoint.json").write_text(
        json.dumps(
            {
                "loadedAtEnd": bool(training_args.load_best_model_at_end),
                "sourceCheckpoint": Path(best_checkpoint).name if best_checkpoint else None,
                "bestMetric": trainer.state.best_metric,
                "globalStep": trainer.state.global_step,
            },
            indent=2,
            sort_keys=True,
        )
        + "\n",
        encoding="utf-8",
    )
    for checkpoint_dir in output_dir.glob("checkpoint-*"):
        if checkpoint_dir.is_dir():
            shutil.rmtree(checkpoint_dir)


if __name__ == "__main__":
    main()
