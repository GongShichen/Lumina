from __future__ import annotations

import json
import os
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable

import torch
import torch.nn.functional as F
from torch.utils.checkpoint import checkpoint


DEFAULT_MODEL_ID = "openbmb/MiniCPM-V-4.6"


def resolve_data_path(path: str | Path, *, config_path: str | Path | None = None) -> Path:
    candidate = Path(path).expanduser()
    if candidate.is_absolute() and candidate.exists():
        return candidate

    bases: list[Path] = []
    if config_path is not None:
        bases.append(Path(config_path).expanduser().resolve().parent)
    bases.append(Path.cwd())

    env_root = os.environ.get("LUMINA_TRAINING_DATA_ROOT")
    if env_root:
        bases.insert(0, Path(env_root).expanduser())

    for base in bases:
        resolved = (base / candidate).resolve()
        if resolved.exists():
            return resolved

    parts = candidate.parts
    if "TrainingData" in parts:
        suffix = Path(*parts[parts.index("TrainingData") :])
        for base in bases:
            direct = (base / suffix).resolve()
            if direct.exists():
                return direct
            nested = (base / suffix.relative_to("TrainingData")).resolve()
            if nested.exists():
                return nested

    return candidate.resolve()


def read_jsonl(path: str | Path) -> list[dict[str, Any]]:
    records: list[dict[str, Any]] = []
    with Path(path).open("r", encoding="utf-8") as handle:
        for line_no, line in enumerate(handle, start=1):
            line = line.strip()
            if not line:
                continue
            try:
                payload = json.loads(line)
            except json.JSONDecodeError as exc:
                raise ValueError(f"{path}:{line_no}: invalid JSON") from exc
            if not isinstance(payload, dict):
                raise ValueError(f"{path}:{line_no}: expected JSON object")
            records.append(payload)
    return records


def maybe_with_image(messages: list[dict[str, Any]], record: dict[str, Any], data_file: Path) -> list[dict[str, Any]]:
    metadata = record.get("metadata") if isinstance(record.get("metadata"), dict) else {}
    image_path = metadata.get("localImagePath")
    if not image_path:
        return messages

    resolved = resolve_data_path(image_path, config_path=data_file)
    if not resolved.exists():
        return messages

    patched: list[dict[str, Any]] = []
    injected = False
    for message in messages:
        item = dict(message)
        if not injected and item.get("role") == "user":
            content = item.get("content", "")
            if isinstance(content, str):
                item["content"] = [
                    {"type": "image", "url": str(resolved)},
                    {"type": "text", "text": content},
                ]
                injected = True
        patched.append(item)
    return patched


@dataclass
class SFTRecord:
    id: str
    messages: list[dict[str, Any]]


@dataclass
class DPORecord:
    id: str
    prompt: list[dict[str, Any]]
    chosen: list[dict[str, Any]]
    rejected: list[dict[str, Any]]


class SFTDataset(torch.utils.data.Dataset[SFTRecord]):
    def __init__(self, path: str | Path) -> None:
        self.path = Path(path)
        self.records: list[SFTRecord] = []
        for raw in read_jsonl(self.path):
            messages = raw.get("messages")
            if not isinstance(messages, list) or len(messages) < 2:
                continue
            self.records.append(
                SFTRecord(
                    id=str(raw.get("id", len(self.records))),
                    messages=maybe_with_image(messages, raw, self.path),
                )
            )

    def __len__(self) -> int:
        return len(self.records)

    def __getitem__(self, index: int) -> SFTRecord:
        return self.records[index]


class DPODataset(torch.utils.data.Dataset[DPORecord]):
    def __init__(self, path: str | Path) -> None:
        self.path = Path(path)
        self.records: list[DPORecord] = []
        for raw in read_jsonl(self.path):
            prompt = raw.get("prompt")
            chosen = raw.get("chosen")
            rejected = raw.get("rejected")
            if not all(isinstance(x, list) and x for x in (prompt, chosen, rejected)):
                continue
            self.records.append(
                DPORecord(
                    id=str(raw.get("id", len(self.records))),
                    prompt=maybe_with_image(prompt, raw, self.path),
                    chosen=chosen,
                    rejected=rejected,
                )
            )

    def __len__(self) -> int:
        return len(self.records)

    def __getitem__(self, index: int) -> DPORecord:
        return self.records[index]


def local_rank_device_map(requested: str | dict[str, int] | None = None) -> dict[str, int] | str | None:
    if requested == "none":
        return None
    if requested:
        return requested
    if not torch.cuda.is_available():
        return None
    local_rank = int(os.environ.get("LOCAL_RANK", "0"))
    torch.cuda.set_device(local_rank)
    return {"": local_rank}


def _set_full_finetune_trainable(model, freeze_patterns: tuple[str, ...]) -> None:
    trainable = 0
    total = 0
    for name, parameter in model.named_parameters():
        total += parameter.numel()
        frozen = any(pattern in name.lower() for pattern in freeze_patterns)
        parameter.requires_grad = not frozen
        if parameter.requires_grad:
            trainable += parameter.numel()
    if int(os.environ.get("LOCAL_RANK", "0")) == 0:
        pct = 100 * trainable / total if total else 0
        print(f"trainable params: {trainable:,} || all params: {total:,} || trainable%: {pct:.4f}")


def load_processor(model_name_or_path: str):
    from transformers import AutoProcessor

    return AutoProcessor.from_pretrained(model_name_or_path, trust_remote_code=True)


def load_q_lora_model(model_cfg: dict[str, Any], lora_cfg: dict[str, Any] | None, *, train: bool = True):
    from .fla_compat import install_fla_causal_conv_compat

    install_fla_causal_conv_compat()
    from peft import LoraConfig, PeftModel, get_peft_model, prepare_model_for_kbit_training
    from transformers import AutoModelForImageTextToText, BitsAndBytesConfig

    name_or_path = model_cfg.get("name_or_path") or DEFAULT_MODEL_ID
    load_in_8bit = bool(model_cfg.get("load_in_8bit", True))
    quantization_config = BitsAndBytesConfig(load_in_8bit=True) if load_in_8bit else None
    dtype = torch.bfloat16 if model_cfg.get("torch_dtype", "bfloat16") == "bfloat16" else torch.float16

    model_kwargs: dict[str, Any] = {
        "dtype": dtype,
        "quantization_config": quantization_config,
        "device_map": local_rank_device_map(model_cfg.get("device_map")),
        "trust_remote_code": True,
    }
    if model_cfg.get("attn_implementation"):
        model_kwargs["attn_implementation"] = model_cfg["attn_implementation"]
    model = AutoModelForImageTextToText.from_pretrained(name_or_path, **model_kwargs)
    base_device_map = getattr(model, "hf_device_map", None)
    if hasattr(model, "config"):
        model.config.use_cache = False
        if hasattr(model.config, "text_config"):
            model.config.text_config.use_cache = False
    if train and bool(model_cfg.get("gradient_checkpointing", True)) and hasattr(model, "gradient_checkpointing_enable"):
        model.gradient_checkpointing_enable()

    adapter_path = model_cfg.get("adapter_path")
    if train and adapter_path and bool(model_cfg.get("merge_adapter_for_full_finetune", False)):
        model = PeftModel.from_pretrained(model, adapter_path, is_trainable=False)
        model = model.merge_and_unload()
        if hasattr(model, "config"):
            model.config.use_cache = False
        if hasattr(model, "gradient_checkpointing_enable"):
            model.gradient_checkpointing_enable()
        if hasattr(model, "enable_input_require_grads"):
            model.enable_input_require_grads()
        freeze_patterns = tuple(model_cfg.get("freeze_patterns", []))
        _set_full_finetune_trainable(model, freeze_patterns)
        if base_device_map:
            model.hf_device_map = base_device_map
            model.is_parallelizable = True
            model.model_parallel = True
    elif train and adapter_path:
        if load_in_8bit:
            model = prepare_model_for_kbit_training(model, use_gradient_checkpointing=True)
        model = PeftModel.from_pretrained(model, adapter_path, is_trainable=True)
        if bool(model_cfg.get("gradient_checkpointing", True)) and hasattr(model, "enable_input_require_grads"):
            model.enable_input_require_grads()
        if base_device_map:
            model.hf_device_map = base_device_map
            model.is_parallelizable = True
            model.model_parallel = True
        if int(os.environ.get("LOCAL_RANK", "0")) == 0 and hasattr(model, "print_trainable_parameters"):
            model.print_trainable_parameters()
    elif adapter_path:
        model = PeftModel.from_pretrained(model, adapter_path, is_trainable=False)
        if base_device_map:
            model.hf_device_map = base_device_map
            model.is_parallelizable = True
            model.model_parallel = True
    elif train and lora_cfg:
        if load_in_8bit:
            model = prepare_model_for_kbit_training(model, use_gradient_checkpointing=True)
        freeze_patterns = tuple(model_cfg.get("freeze_patterns", []))
        for name, parameter in model.named_parameters():
            if any(pattern in name.lower() for pattern in freeze_patterns):
                parameter.requires_grad = False
        peft_config = LoraConfig(**lora_cfg)
        model = get_peft_model(model, peft_config)
        if bool(model_cfg.get("gradient_checkpointing", True)) and hasattr(model, "enable_input_require_grads"):
            model.enable_input_require_grads()
        if base_device_map:
            model.hf_device_map = base_device_map
            model.is_parallelizable = True
            model.model_parallel = True
        if int(os.environ.get("LOCAL_RANK", "0")) == 0 and hasattr(model, "print_trainable_parameters"):
            model.print_trainable_parameters()
    return model


def causal_lm_backbone_and_head(model):
    if hasattr(model, "module"):
        model = model.module
    conditional = model.base_model.model if hasattr(model, "base_model") else model
    backbone = getattr(conditional, "model", None)
    lm_head = getattr(conditional, "lm_head", None)
    if backbone is None or lm_head is None:
        raise TypeError(f"unsupported causal LM wrapper: {type(model)!r}")
    return backbone, lm_head


def _token_nll(hidden_states: torch.Tensor, targets: torch.Tensor, lm_head) -> torch.Tensor:
    logits = lm_head(hidden_states).float()
    return F.cross_entropy(logits, targets, reduction="sum")


def _token_logps(hidden_states: torch.Tensor, targets: torch.Tensor, lm_head) -> torch.Tensor:
    logits = lm_head(hidden_states).float()
    target_logits = torch.gather(logits, dim=-1, index=targets.unsqueeze(-1)).squeeze(-1)
    return target_logits - torch.logsumexp(logits, dim=-1)


def _checkpointed(function, hidden_states: torch.Tensor, targets: torch.Tensor) -> torch.Tensor:
    if torch.is_grad_enabled() and hidden_states.requires_grad:
        return checkpoint(function, hidden_states, targets, use_reentrant=False)
    return function(hidden_states, targets)


def completion_only_cross_entropy(
    model,
    inputs: dict[str, torch.Tensor],
    labels: torch.Tensor,
    *,
    chunk_tokens: int = 4096,
) -> torch.Tensor:
    backbone, lm_head = causal_lm_backbone_and_head(model)
    hidden_states = backbone(**inputs)[0][:, :-1, :]
    shifted_labels = labels[:, 1:].to(hidden_states.device)
    mask = shifted_labels.ne(-100)
    selected_hidden = hidden_states[mask]
    selected_targets = shifted_labels[mask]
    if not selected_targets.numel():
        raise ValueError("batch has no assistant completion tokens")
    losses = [
        _checkpointed(
            lambda hidden, targets: _token_nll(hidden, targets, lm_head),
            selected_hidden[start : start + chunk_tokens],
            selected_targets[start : start + chunk_tokens],
        )
        for start in range(0, selected_targets.numel(), chunk_tokens)
    ]
    return torch.stack(losses).sum() / selected_targets.numel()


def completion_sequence_logps(
    model,
    inputs: dict[str, torch.Tensor],
    labels: torch.Tensor,
    *,
    chunk_tokens: int = 4096,
) -> torch.Tensor:
    backbone, lm_head = causal_lm_backbone_and_head(model)
    hidden_states = backbone(**inputs)[0][:, :-1, :]
    shifted_labels = labels[:, 1:].to(hidden_states.device)
    mask = shifted_labels.ne(-100)
    batch_ids = torch.arange(labels.shape[0], device=hidden_states.device).unsqueeze(1).expand_as(mask)[mask]
    selected_hidden = hidden_states[mask]
    selected_targets = shifted_labels[mask]
    if not selected_targets.numel():
        raise ValueError("batch has no assistant completion tokens")
    sequence_logps = hidden_states.new_zeros(labels.shape[0], dtype=torch.float32)
    for start in range(0, selected_targets.numel(), chunk_tokens):
        stop = start + chunk_tokens
        token_logps = _checkpointed(
            lambda hidden, targets: _token_logps(hidden, targets, lm_head),
            selected_hidden[start:stop],
            selected_targets[start:stop],
        )
        sequence_logps = sequence_logps.index_add(0, batch_ids[start:stop], token_logps)
    return sequence_logps


def init_swanlab(
    project: str,
    run_name: str | None = None,
    config: dict[str, Any] | None = None,
    *,
    required: bool = False,
) -> None:
    if int(os.environ.get("LOCAL_RANK", "0")) != 0:
        return
    if not os.environ.get("SWANLAB_API_KEY"):
        if required:
            raise RuntimeError("SWANLAB_API_KEY is required for formal training")
        return
    try:
        import swanlab

        swanlab.login(api_key=os.environ["SWANLAB_API_KEY"])
        swanlab.init(project=project, experiment_name=run_name, config=config or {})
    except Exception as exc:  # pragma: no cover - training should continue if tracking is unavailable.
        if required:
            raise RuntimeError("SwanLab initialization failed") from exc
        if int(os.environ.get("LOCAL_RANK", "0")) == 0:
            print(f"[warn] SwanLab init skipped: {exc}")


def _drop_none(payload: dict[str, Any]) -> dict[str, Any]:
    return {key: value for key, value in payload.items() if value is not None}


class ChatTemplateCollator:
    def __init__(
        self,
        processor: Any,
        *,
        max_length: int,
        downsample_mode: str = "16x",
        max_slice_nums: int = 9,
    ) -> None:
        self.processor = processor
        self.max_length = max_length
        self.downsample_mode = downsample_mode
        self.max_slice_nums = max_slice_nums
        self.pad_token_id = getattr(getattr(processor, "tokenizer", None), "pad_token_id", None)
        if self.pad_token_id is None:
            self.pad_token_id = getattr(getattr(processor, "tokenizer", None), "eos_token_id", 0)

    def _encode(self, messages: list[dict[str, Any]], *, add_generation_prompt: bool) -> dict[str, torch.Tensor]:
        return self.processor.apply_chat_template(
            messages,
            tokenize=True,
            add_generation_prompt=add_generation_prompt,
            return_dict=True,
            return_tensors="pt",
            processor_kwargs={
                "truncation": False,
                "downsample_mode": self.downsample_mode,
                "max_slice_nums": self.max_slice_nums,
            },
        )

    def _pad_1d(self, tensors: Iterable[torch.Tensor], pad_value: int) -> torch.Tensor:
        values = [tensor.squeeze(0) for tensor in tensors]
        return torch.nn.utils.rnn.pad_sequence(values, batch_first=True, padding_value=pad_value)

    def _stack_extra(self, name: str, tensors: list[torch.Tensor]) -> torch.Tensor | None:
        values = [tensor.squeeze(0) if tensor.ndim > 0 and tensor.shape[0] == 1 else tensor for tensor in tensors]
        try:
            return torch.stack(values, dim=0)
        except RuntimeError:
            if name in {"pixel_values", "image_sizes", "tgt_sizes"}:
                return torch.nn.utils.rnn.pad_sequence(values, batch_first=True, padding_value=0)
            return None

    def encode_pair(self, prompt_messages: list[dict[str, Any]], completion_messages: list[dict[str, Any]]) -> dict[str, torch.Tensor]:
        full_messages = prompt_messages + completion_messages
        full = self._encode(full_messages, add_generation_prompt=False)
        prompt = self._encode(prompt_messages, add_generation_prompt=True)
        labels = full["input_ids"].clone()
        prompt_len = min(prompt["input_ids"].shape[-1], labels.shape[-1])
        labels[:, :prompt_len] = -100
        full["labels"] = labels
        return self._enforce_max_length(full)

    def _enforce_max_length(self, encoded: dict[str, torch.Tensor]) -> dict[str, torch.Tensor]:
        seq_len = encoded["input_ids"].shape[-1]
        if seq_len > self.max_length:
            raise ValueError(
                f"encoded sequence has {seq_len} tokens, exceeding max_length={self.max_length}; "
                "drop the complete record during data QA instead of truncating it"
            )
        return encoded

    def __call__(self, records: list[SFTRecord]) -> dict[str, torch.Tensor]:
        encoded = []
        for record in records:
            encoded.append(self.encode_pair(record.messages[:-1], record.messages[-1:]))
        return collate_encoded(encoded, self.pad_token_id, pad_to_length=self.max_length)


def collate_encoded(
    encoded: list[dict[str, torch.Tensor]],
    pad_token_id: int,
    *,
    pad_to_length: int | None = None,
) -> dict[str, torch.Tensor]:
    batch: dict[str, torch.Tensor] = {}
    for key in ("input_ids", "attention_mask", "labels"):
        if key not in encoded[0]:
            continue
        pad = -100 if key == "labels" else (0 if key == "attention_mask" else pad_token_id)
        values = [item[key].squeeze(0) for item in encoded]
        padded = torch.nn.utils.rnn.pad_sequence(values, batch_first=True, padding_value=pad)
        if pad_to_length is not None:
            if padded.shape[1] > pad_to_length:
                raise ValueError(f"batch sequence length {padded.shape[1]} exceeds pad_to_length={pad_to_length}")
            padded = F.pad(padded, (0, pad_to_length - padded.shape[1]), value=pad)
        batch[key] = padded

    for key in encoded[0]:
        if key in batch or key in {"input_ids", "attention_mask", "labels"}:
            continue
        values = [item[key] for item in encoded if key in item and isinstance(item[key], torch.Tensor)]
        if len(values) != len(encoded):
            continue
        stacked = _stack_tensors(key, values)
        if stacked is not None:
            batch[key] = stacked
    return _drop_none(batch)


def _stack_tensors(name: str, tensors: list[torch.Tensor]) -> torch.Tensor | None:
    values = [tensor.squeeze(0) if tensor.ndim > 0 and tensor.shape[0] == 1 else tensor for tensor in tensors]
    if name in {"target_sizes", "tgt_sizes", "image_sizes"} and len(values) == 1:
        return values[0].unsqueeze(0) if values[0].ndim == 1 else values[0]
    try:
        return torch.stack(values, dim=0)
    except RuntimeError:
        if name in {"pixel_values", "image_sizes", "tgt_sizes"}:
            try:
                return torch.nn.utils.rnn.pad_sequence(values, batch_first=True, padding_value=0)
            except RuntimeError:
                return None
        return None
