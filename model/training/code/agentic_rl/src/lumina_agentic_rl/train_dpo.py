from __future__ import annotations

import argparse
from pathlib import Path
from typing import Any

import torch
import torch.nn.functional as F

from .config import load_config, supported_dataclass_kwargs
from .train_common import (
    ChatTemplateCollator,
    DPODataset,
    collate_encoded,
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
        chosen_batch = collate_encoded(chosen, self.pad_token_id)
        rejected_batch = collate_encoded(rejected, self.pad_token_id)
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


def _sequence_logps(logits: torch.Tensor, labels: torch.Tensor) -> torch.Tensor:
    labels = labels.to(logits.device)
    shifted_logits = logits[:, :-1, :]
    shifted_labels = labels[:, 1:]
    mask = shifted_labels.ne(-100)
    safe_labels = shifted_labels.masked_fill(~mask, 0)
    target_logits = torch.gather(shifted_logits, dim=-1, index=safe_labels.unsqueeze(-1)).squeeze(-1)
    token_logps = target_logits - torch.logsumexp(shifted_logits, dim=-1)
    return (token_logps * mask).sum(dim=-1)


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

                chosen_outputs = model(**chosen_inputs)
                rejected_outputs = model(**rejected_inputs)
                policy_chosen = _sequence_logps(chosen_outputs.logits, chosen_labels)
                policy_rejected = _sequence_logps(rejected_outputs.logits, rejected_labels)
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
                        ref_chosen_outputs = ref_model(**chosen_inputs)
                        ref_rejected_outputs = ref_model(**rejected_inputs)
                        ref_chosen = _sequence_logps(ref_chosen_outputs.logits, chosen_labels)
                        ref_rejected = _sequence_logps(ref_rejected_outputs.logits, rejected_labels)
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
    train_file = resolve_data_path(cfg["data"]["train_file"], config_path=args.config)
    dataset = DPODataset(train_file)
    if len(dataset) == 0:
        raise SystemExit(f"DPO dataset is empty: {train_file}")
    eval_dataset = None
    if cfg.get("data", {}).get("eval_file"):
        eval_file = resolve_data_path(cfg["data"]["eval_file"], config_path=args.config)
        eval_dataset = DPODataset(eval_file)

    model_cfg = cfg.get("model", {})
    model = load_q_lora_model(model_cfg, cfg.get("lora", {}), train=True)
    reference_free = bool(cfg.get("training", {}).get("reference_free", False))
    ref_model = None
    if not reference_free:
        ref_model = load_q_lora_model(model_cfg, None, train=False)
        ref_model.eval()
        for parameter in ref_model.parameters():
            parameter.requires_grad = False

    processor = load_processor(model_cfg["name_or_path"])
    init_swanlab("lumina-agentic-dpo", cfg.get("training", {}).get("run_name"), cfg)

    training_args = TrainingArguments(**supported_dataclass_kwargs(TrainingArguments, cfg.get("training", {})))
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
    trainer.save_model(cfg["training"]["output_dir"])
    processor.save_pretrained(cfg["training"]["output_dir"])


if __name__ == "__main__":
    main()
