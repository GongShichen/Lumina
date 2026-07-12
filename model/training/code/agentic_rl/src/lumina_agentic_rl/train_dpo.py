from __future__ import annotations

import argparse
import json
import shutil
from pathlib import Path
from typing import Any

import torch
import torch.nn.functional as F

from .config import load_config, supported_dataclass_kwargs
from .train_common import (
    ChatTemplateCollator,
    DPODataset,
    collate_encoded,
    completion_sequence_logps,
    init_swanlab,
    load_processor,
    load_q_lora_model,
    resolve_data_path,
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Train Lumina ReAct preference model with DPO.")
    parser.add_argument("--config", required=True, type=Path)
    return parser.parse_args()


class DPOCollator:
    def __init__(self, template_collator: ChatTemplateCollator) -> None:
        self.template_collator = template_collator
        self.pad_token_id = template_collator.pad_token_id

    def __call__(self, records) -> dict[str, torch.Tensor]:
        chosen = []
        rejected = []
        for record in records:
            chosen.append(self.template_collator.encode_pair(record.prompt, record.chosen))
            rejected.append(self.template_collator.encode_pair(record.prompt, record.rejected))
        chosen_batch = collate_encoded(chosen, self.pad_token_id, pad_to_length=self.template_collator.max_length)
        rejected_batch = collate_encoded(rejected, self.pad_token_id, pad_to_length=self.template_collator.max_length)
        return {
            **{f"chosen_{key}": value for key, value in chosen_batch.items()},
            **{f"rejected_{key}": value for key, value in rejected_batch.items()},
        }


def _prefixed(batch: dict[str, torch.Tensor], prefix: str) -> dict[str, torch.Tensor]:
    plen = len(prefix)
    return {key[plen:]: value for key, value in batch.items() if key.startswith(prefix)}


def _input_device(model) -> torch.device:
    if hasattr(model, "module"):
        model = model.module
    for dotted in (
        "base_model.model.model.language_model.embed_tokens",
        "base_model.model.language_model.embed_tokens",
        "model.language_model.embed_tokens",
        "language_model.embed_tokens",
    ):
        module = model
        for part in dotted.split("."):
            module = getattr(module, part, None)
            if module is None:
                break
        if module is not None:
            try:
                return next(module.parameters()).device
            except StopIteration:
                pass
    if hasattr(model, "get_input_embeddings"):
        embeddings = model.get_input_embeddings()
        try:
            return next(embeddings.parameters()).device
        except StopIteration:
            pass
    return next(model.parameters()).device


def _move_tensors(payload: Any, device: torch.device) -> Any:
    if isinstance(payload, torch.Tensor):
        return payload.to(device)
    if isinstance(payload, dict):
        return {key: _move_tensors(value, device) for key, value in payload.items()}
    if isinstance(payload, list):
        return [_move_tensors(value, device) for value in payload]
    if isinstance(payload, tuple):
        return tuple(_move_tensors(value, device) for value in payload)
    return payload


def _concatenate_inputs(
    chosen_inputs: dict[str, torch.Tensor], rejected_inputs: dict[str, torch.Tensor]
) -> dict[str, torch.Tensor]:
    if chosen_inputs.keys() != rejected_inputs.keys():
        raise ValueError("chosen and rejected model inputs must have identical keys")
    return {
        key: torch.cat((chosen_inputs[key], rejected_inputs[key]), dim=0)
        for key in chosen_inputs
    }


def _completion_lengths(labels: torch.Tensor) -> torch.Tensor:
    return labels.ne(-100).sum(dim=-1).clamp_min(1).to(torch.float32)


class LuminaDPOTrainer:
    def __init__(
        self,
        *,
        model,
        ref_model,
        args,
        train_dataset,
        eval_dataset,
        data_collator,
        beta: float,
        reference_free: bool,
        length_normalize: bool,
    ) -> None:
        from transformers import Trainer

        class _Trainer(Trainer):
            def compute_loss(inner_self, model, inputs, return_outputs=False, num_items_in_batch=None):
                chosen_inputs = _prefixed(inputs, "chosen_")
                rejected_inputs = _prefixed(inputs, "rejected_")
                chosen_labels = chosen_inputs.pop("labels")
                rejected_labels = rejected_inputs.pop("labels")
                input_device = _input_device(model)
                chosen_inputs = _move_tensors(chosen_inputs, input_device)
                rejected_inputs = _move_tensors(rejected_inputs, input_device)
                combined_inputs = _concatenate_inputs(chosen_inputs, rejected_inputs)
                combined_labels = torch.cat((chosen_labels, rejected_labels), dim=0)
                chosen_batch_size = chosen_labels.shape[0]

                policy_logps = completion_sequence_logps(model, combined_inputs, combined_labels)
                policy_chosen = policy_logps[:chosen_batch_size]
                policy_rejected = policy_logps[chosen_batch_size:]
                chosen_lengths = _completion_lengths(chosen_labels)
                rejected_lengths = _completion_lengths(rejected_labels)
                if length_normalize:
                    policy_chosen = policy_chosen / chosen_lengths.to(policy_chosen.device)
                    policy_rejected = policy_rejected / rejected_lengths.to(policy_rejected.device)

                if reference_free:
                    logits = beta * (policy_chosen - policy_rejected)
                else:
                    if ref_model is None:
                        raise RuntimeError("standard DPO requires a frozen reference model")
                    with torch.no_grad():
                        ref_logps = completion_sequence_logps(ref_model, combined_inputs, combined_labels)
                        ref_chosen = ref_logps[:chosen_batch_size]
                        ref_rejected = ref_logps[chosen_batch_size:]
                        if length_normalize:
                            ref_chosen = ref_chosen / chosen_lengths.to(ref_chosen.device)
                            ref_rejected = ref_rejected / rejected_lengths.to(ref_rejected.device)
                    logits = beta * ((policy_chosen - policy_rejected) - (ref_chosen - ref_rejected))
                loss = -F.logsigmoid(logits).mean()
                with torch.no_grad():
                    inner_self.log({
                        "dpo/policy_chosen_logp": policy_chosen.detach().mean().item(),
                        "dpo/policy_rejected_logp": policy_rejected.detach().mean().item(),
                        "dpo/policy_margin": (policy_chosen - policy_rejected).detach().mean().item(),
                        "dpo/preference_logit": logits.detach().mean().item(),
                        "dpo/chosen_completion_tokens": chosen_lengths.detach().mean().item(),
                        "dpo/rejected_completion_tokens": rejected_lengths.detach().mean().item(),
                    })
                if return_outputs:
                    return loss, {"preference_logits": logits.detach()}
                return loss

            def prediction_step(inner_self, model, inputs, prediction_loss_only, ignore_keys=None):
                # DPO batches contain chosen/rejected-prefixed fields, so the base Trainer
                # prediction path cannot call model(**inputs) directly during evaluation.
                with torch.no_grad():
                    loss = inner_self.compute_loss(model, inputs, return_outputs=False)
                return loss.detach(), None, None

        self.trainer = _Trainer(
            model=model,
            args=args,
            train_dataset=train_dataset,
            eval_dataset=eval_dataset,
            data_collator=data_collator,
        )

    def train(self) -> Any:
        return self.trainer.train()

    def save_model(self, output_dir: str) -> None:
        self.trainer.save_model(output_dir)


def main() -> None:
    from transformers import TrainingArguments

    args = parse_args()
    cfg = load_config(args.config)
    training_cfg = cfg.get("training", {})
    reference_free = bool(training_cfg.get("reference_free", False))
    if reference_free:
        raise ValueError("formal DPO requires reference_free: false")

    train_file = resolve_data_path(cfg["data"]["train_file"], config_path=args.config)
    dataset = DPODataset(train_file)
    if len(dataset) == 0:
        raise SystemExit(f"DPO dataset is empty: {train_file}")
    eval_dataset = None
    if cfg.get("data", {}).get("eval_file"):
        eval_file = resolve_data_path(cfg["data"]["eval_file"], config_path=args.config)
        eval_dataset = DPODataset(eval_file)

    model_cfg = cfg.get("model", {})
    init_swanlab("lumina-agentic-dpo", training_cfg.get("run_name"), cfg, required=True)
    model = load_q_lora_model(model_cfg, cfg.get("lora", {}), train=True)
    ref_model = None
    if not reference_free:
        ref_model = load_q_lora_model(model_cfg, None, train=False)
        ref_model.eval()
        for parameter in ref_model.parameters():
            parameter.requires_grad = False

    processor = load_processor(model_cfg["name_or_path"])
    training_args = TrainingArguments(**supported_dataclass_kwargs(TrainingArguments, training_cfg))
    template_collator = ChatTemplateCollator(
        processor,
        max_length=int(cfg.get("training", {}).get("max_length", 4096)),
        downsample_mode=cfg.get("data", {}).get("downsample_mode", "16x"),
        max_slice_nums=int(cfg.get("data", {}).get("max_slice_nums", 9)),
    )
    trainer = LuminaDPOTrainer(
        model=model,
        ref_model=ref_model,
        args=training_args,
        train_dataset=dataset,
        eval_dataset=eval_dataset,
        data_collator=DPOCollator(template_collator),
        beta=float(cfg.get("training", {}).get("beta", 0.1)),
        reference_free=reference_free,
        length_normalize=bool(cfg.get("training", {}).get("length_normalize", False)),
    )
    trainer.train()
    output_dir = Path(cfg["training"]["output_dir"])
    trainer.save_model(str(output_dir))
    processor.save_pretrained(output_dir)
    best_checkpoint = trainer.trainer.state.best_model_checkpoint
    (output_dir / "best_checkpoint.json").write_text(
        json.dumps(
            {
                "loadedAtEnd": bool(training_args.load_best_model_at_end),
                "sourceCheckpoint": Path(best_checkpoint).name if best_checkpoint else None,
                "bestMetric": trainer.trainer.state.best_metric,
                "globalStep": trainer.trainer.state.global_step,
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
