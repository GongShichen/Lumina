#!/usr/bin/env python3
"""Build a Lumina-ready MiniMind-o Core ML bundle.

This converter targets the text Thinker path of `jingyaogong/minimind-3o`
for ReAct planning. It intentionally does not export the Talker/Mimi audio
decoder because Lumina's task execution path needs structured text tool calls.

Output layout:

    Resources/Models/MiniMindOReActModel/
      ├── model.mlmodelc or model.mlpackage
      ├── model_config.json
      └── hf_model/
          ├── tokenizer.json
          ├── tokenizer_config.json
          └── ...

The exported graph uses:
- Core ML MLState `kv_cache_0` for K/V cache residency.
- Conv2d-backed linear projections for ANE-friendly matmul lowering.
- RMSNorm via the LayerNorm([x, -x]) trick.
- Decomposed fp16 softmax (`ane_softmax`) unless USE_NATIVE_SOFTMAX=1.
- In-graph argmax output named `token_id`, matching Lumina's lightweight
  stateful Core ML runner.
"""

from __future__ import annotations

import argparse
import json
import math
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F


THIS_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(THIS_DIR))
from ane_ops import (  # noqa: E402
    MODEL_DTYPE,
    ane_norm_from_hf,
    ane_softmax,
    conv_from_linear,
    repeat_kv_ane,
)


DEFAULT_REPO = "jingyaogong/minimind-3o"


def snapshot(repo_id: str, output_root: Path) -> Path:
    from huggingface_hub import snapshot_download

    hf_dir = output_root / "hf_model"
    print(f"[MiniMind-o] downloading {repo_id} -> {hf_dir}")
    snapshot_download(
        repo_id,
        local_dir=str(hf_dir),
        allow_patterns=[
            "*.json",
            "*.jinja",
            "*.py",
            "*.bin",
            "tokenizer*",
            "special_tokens_map.json",
        ],
    )
    return hf_dir


def rotate_half(x: torch.Tensor) -> torch.Tensor:
    x1, x2 = torch.chunk(x, 2, dim=-1)
    return torch.cat((-x2, x1), dim=-1)


def precompute_rope(head_dim: int, context: int, theta: float) -> tuple[torch.Tensor, torch.Tensor]:
    freqs = 1.0 / (theta ** (torch.arange(0, head_dim, 2).float() / head_dim))
    t = torch.arange(context, dtype=torch.float32)
    values = torch.outer(t, freqs)
    cos = torch.cat([torch.cos(values), torch.cos(values)], dim=-1)
    sin = torch.cat([torch.sin(values), torch.sin(values)], dim=-1)
    return cos.to(MODEL_DTYPE), sin.to(MODEL_DTYPE)


class MiniMindAttentionANE(nn.Module):
    def __init__(self, hf_attn: nn.Module, cfg, layer_index: int, context: int):
        super().__init__()
        self.layer_index = layer_index
        self.context = context
        self.num_heads = int(cfg.num_attention_heads)
        self.num_kv_heads = int(cfg.num_key_value_heads or cfg.num_attention_heads)
        self.head_dim = int(cfg.head_dim)
        self.n_rep = self.num_heads // self.num_kv_heads
        self.scale = 1.0 / math.sqrt(self.head_dim)

        self.q_proj = conv_from_linear(hf_attn.q_proj, dtype=MODEL_DTYPE)
        self.k_proj = conv_from_linear(hf_attn.k_proj, dtype=MODEL_DTYPE)
        self.v_proj = conv_from_linear(hf_attn.v_proj, dtype=MODEL_DTYPE)
        self.o_proj = conv_from_linear(hf_attn.o_proj, dtype=MODEL_DTYPE)
        self.q_norm = ane_norm_from_hf(hf_attn.q_norm.weight, cfg.rms_norm_eps, self.head_dim)
        self.k_norm = ane_norm_from_hf(hf_attn.k_norm.weight, cfg.rms_norm_eps, self.head_dim)
        cos, sin = precompute_rope(self.head_dim, context, float(cfg.rope_theta))
        self.register_buffer("cos_cached", cos, persistent=False)
        self.register_buffer("sin_cached", sin, persistent=False)

    def forward(
        self,
        hidden_states: torch.Tensor,
        kv_cache: torch.Tensor,
        position_ids: torch.Tensor,
        causal_mask: torch.Tensor,
    ) -> torch.Tensor:
        batch, seq_len, _ = hidden_states.shape
        x = hidden_states.permute(0, 2, 1).unsqueeze(2).to(MODEL_DTYPE)
        q = self.q_proj.forward_conv(x).view(batch, self.num_heads, self.head_dim, seq_len).permute(0, 1, 3, 2)
        k = self.k_proj.forward_conv(x).view(batch, self.num_kv_heads, self.head_dim, seq_len).permute(0, 1, 3, 2)
        v = self.v_proj.forward_conv(x).view(batch, self.num_kv_heads, self.head_dim, seq_len).permute(0, 1, 3, 2)
        q = self.q_norm(q)
        k = self.k_norm(k)

        pos = position_ids.to(torch.long)
        cos = self.cos_cached.index_select(0, pos).view(1, 1, seq_len, self.head_dim)
        sin = self.sin_cached.index_select(0, pos).view(1, 1, seq_len, self.head_dim)
        q = (q * cos) + (rotate_half(q) * sin)
        k = (k * cos) + (rotate_half(k) * sin)

        k_idx = self.layer_index
        v_idx = self.layer_index + kv_cache.shape[0] // 2
        current_pos = position_ids[0]
        kv_cache[k_idx:k_idx + 1, :, current_pos:current_pos + seq_len, :] = k.squeeze(0).to(MODEL_DTYPE)
        kv_cache[v_idx:v_idx + 1, :, current_pos:current_pos + seq_len, :] = v.squeeze(0).to(MODEL_DTYPE)

        k_full = kv_cache[k_idx:k_idx + 1, :, :, :]
        v_full = kv_cache[v_idx:v_idx + 1, :, :, :]
        k_full = repeat_kv_ane(k_full, self.n_rep, self.num_kv_heads, self.context, self.head_dim)
        v_full = repeat_kv_ane(v_full, self.n_rep, self.num_kv_heads, self.context, self.head_dim)

        scores = torch.matmul(q.to(MODEL_DTYPE), k_full.transpose(-1, -2).to(MODEL_DTYPE)) * self.scale
        scores = scores + causal_mask.to(MODEL_DTYPE)
        attn = ane_softmax(scores, dim=-1)
        out = torch.matmul(attn.to(MODEL_DTYPE), v_full.to(MODEL_DTYPE))
        out = out.permute(0, 2, 1, 3).contiguous().view(batch, seq_len, self.num_heads * self.head_dim)
        return self.o_proj(out)


class MiniMindMLPANE(nn.Module):
    def __init__(self, hf_mlp: nn.Module):
        super().__init__()
        self.gate_proj = conv_from_linear(hf_mlp.gate_proj, dtype=MODEL_DTYPE)
        self.up_proj = conv_from_linear(hf_mlp.up_proj, dtype=MODEL_DTYPE)
        self.down_proj = conv_from_linear(hf_mlp.down_proj, dtype=MODEL_DTYPE)

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        x = x.permute(0, 2, 1).unsqueeze(2).to(MODEL_DTYPE)
        gate = F.silu(self.gate_proj.forward_conv(x).to(MODEL_DTYPE))
        up = self.up_proj.forward_conv(x).to(MODEL_DTYPE)
        out = self.down_proj.forward_conv((gate * up).to(MODEL_DTYPE))
        return out.squeeze(2).permute(0, 2, 1)


class MiniMindBlockANE(nn.Module):
    def __init__(self, hf_block: nn.Module, cfg, layer_index: int, context: int):
        super().__init__()
        self.input_layernorm = ane_norm_from_hf(hf_block.input_layernorm.weight, cfg.rms_norm_eps, cfg.hidden_size)
        self.post_attention_layernorm = ane_norm_from_hf(hf_block.post_attention_layernorm.weight, cfg.rms_norm_eps, cfg.hidden_size)
        self.self_attn = MiniMindAttentionANE(hf_block.self_attn, cfg, layer_index, context)
        self.mlp = MiniMindMLPANE(hf_block.mlp)

    def forward(
        self,
        hidden_states: torch.Tensor,
        kv_cache: torch.Tensor,
        position_ids: torch.Tensor,
        causal_mask: torch.Tensor,
    ) -> torch.Tensor:
        residual = hidden_states
        hidden_states = self.self_attn(
            self.input_layernorm(hidden_states),
            kv_cache,
            position_ids,
            causal_mask,
        )
        hidden_states = residual + hidden_states
        residual = hidden_states
        hidden_states = self.mlp(self.post_attention_layernorm(hidden_states))
        return residual + hidden_states


class MiniMindStatefulANE(nn.Module):
    def __init__(self, hf_model: nn.Module, context: int):
        super().__init__()
        self.cfg = hf_model.config
        self.context = context
        self.embed_tokens = hf_model.model.embed_tokens
        self.layers = nn.ModuleList([
            MiniMindBlockANE(block, self.cfg, i, context)
            for i, block in enumerate(hf_model.model.layers)
        ])
        self.norm = ane_norm_from_hf(hf_model.model.norm.weight, self.cfg.rms_norm_eps, self.cfg.hidden_size)
        lm_head = hf_model.lm_head
        if getattr(self.cfg, "tie_word_embeddings", True):
            tied = nn.Linear(self.cfg.hidden_size, self.cfg.vocab_size, bias=False)
            tied.weight.data = hf_model.model.embed_tokens.weight.detach().clone()
            lm_head = tied
        self.lm_head = conv_from_linear(lm_head, dtype=MODEL_DTYPE)
        cache_shape = (
            2 * int(self.cfg.num_hidden_layers),
            int(self.cfg.num_key_value_heads),
            context,
            int(self.cfg.head_dim),
        )
        self.register_buffer("kv_cache_0", torch.zeros(cache_shape, dtype=MODEL_DTYPE))

    def forward(
        self,
        input_ids: torch.Tensor,
        position_ids: torch.Tensor,
        causal_mask: torch.Tensor,
        update_mask: torch.Tensor,
    ) -> torch.Tensor:
        hidden_states = self.embed_tokens(input_ids.to(torch.long)).to(MODEL_DTYPE)
        hidden_states = hidden_states + update_mask.sum().to(MODEL_DTYPE) * 0
        for layer in self.layers:
            hidden_states = layer(hidden_states, self.kv_cache_0, position_ids, causal_mask)
        hidden_states = self.norm(hidden_states)
        x = hidden_states[:, -1:, :].permute(0, 2, 1).unsqueeze(2).to(MODEL_DTYPE)
        logits = self.lm_head.forward_conv(x).squeeze(2).permute(0, 2, 1).float()
        return torch.argmax(logits.squeeze(0), dim=-1).to(torch.int32)


def load_hf_model(hf_dir: Path):
    from transformers import AutoModelForCausalLM

    try:
        model = AutoModelForCausalLM.from_pretrained(
            str(hf_dir),
            trust_remote_code=True,
            torch_dtype=torch.float16,
            low_cpu_mem_usage=True,
        )
        return model.eval()
    except ImportError as error:
        print(f"[MiniMind-o] AutoModel import needs Omni audio/vision packages; falling back to text Thinker loader: {error}")

    import importlib.util

    module_path = hf_dir / "model_minimind.py"
    spec = importlib.util.spec_from_file_location("lumina_minimind_model_minimind", module_path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Cannot import MiniMind text model from {module_path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)

    raw_config = json.loads((hf_dir / "config.json").read_text(encoding="utf-8"))
    config = module.MiniMindConfig(
        hidden_size=int(raw_config.get("hidden_size", 768)),
        num_hidden_layers=int(raw_config.get("num_hidden_layers", 8)),
        use_moe=bool(raw_config.get("use_moe", False)),
        vocab_size=int(raw_config.get("vocab_size", 6400)),
        bos_token_id=int(raw_config.get("bos_token_id", 1)),
        eos_token_id=int(raw_config.get("eos_token_id", 2)),
        num_attention_heads=int(raw_config.get("num_attention_heads", 8)),
        num_key_value_heads=int(raw_config.get("num_key_value_heads", 4)),
        head_dim=int(raw_config.get("head_dim", 96)),
        hidden_act=str(raw_config.get("hidden_act", "silu")),
        intermediate_size=int(raw_config.get("intermediate_size", 2432)),
        max_position_embeddings=int(raw_config.get("max_position_embeddings", 32768)),
        rms_norm_eps=float(raw_config.get("rms_norm_eps", 1e-6)),
        rope_theta=float(raw_config.get("rope_theta", 1_000_000.0)),
        tie_word_embeddings=bool(raw_config.get("tie_word_embeddings", True)),
        inference_rope_scaling=bool(raw_config.get("inference_rope_scaling", False)),
    )
    model = module.MiniMindForCausalLM(config)
    state_path = hf_dir / "pytorch_model.bin"
    state = torch.load(state_path, map_location="cpu")
    missing, unexpected = model.load_state_dict(state, strict=False)
    print(f"[MiniMind-o] loaded Thinker weights from {state_path.name}: missing={len(missing)}, ignored={len(unexpected)}")
    return model.half().eval()


def convert_model(hf_dir: Path, output: Path, context: int, minimum_deployment_target) -> None:
    import coremltools as ct

    hf_model = load_hf_model(hf_dir)
    model = MiniMindStatefulANE(hf_model, context).eval()
    example = (
        torch.zeros(1, 1, dtype=torch.int32),
        torch.zeros(1, dtype=torch.int32),
        torch.zeros(1, 1, 1, context, dtype=MODEL_DTYPE),
        torch.zeros(1, 1, context, 1, dtype=MODEL_DTYPE),
    )
    print("[MiniMind-o] tracing stateful decoder")
    t0 = time.time()
    traced = torch.jit.trace(model, example, strict=False)
    print(f"[MiniMind-o] traced in {time.time() - t0:.1f}s")

    print("[MiniMind-o] converting to Core ML with MLState kv_cache_0")
    package = ct.convert(
        traced,
        convert_to="mlprogram",
        minimum_deployment_target=minimum_deployment_target,
        compute_precision=ct.precision.FLOAT16,
        inputs=[
            ct.TensorType(name="input_ids", shape=(1, 1), dtype=np.int32),
            ct.TensorType(name="position_ids", shape=(1,), dtype=np.int32),
            ct.TensorType(name="causal_mask", shape=(1, 1, 1, context), dtype=np.float16),
            ct.TensorType(name="update_mask", shape=(1, 1, context, 1), dtype=np.float16),
        ],
        outputs=[ct.TensorType(name="token_id", dtype=np.int32)],
        states=[
            ct.StateType(
                wrapped_type=ct.TensorType(
                    shape=(
                        2 * int(hf_model.config.num_hidden_layers),
                        int(hf_model.config.num_key_value_heads),
                        context,
                        int(hf_model.config.head_dim),
                    ),
                    dtype=np.float16,
                ),
                name="kv_cache_0",
            )
        ],
    )
    package_path = output / "model.mlpackage"
    if package_path.exists():
        shutil.rmtree(package_path)
    package.save(str(package_path))
    print(f"[MiniMind-o] saved {package_path}")


def compile_model(output: Path) -> None:
    package_path = output / "model.mlpackage"
    compiled_path = output / "model.mlmodelc"
    if compiled_path.exists():
        shutil.rmtree(compiled_path)
    print("[MiniMind-o] compiling mlpackage -> mlmodelc")
    subprocess.run(
        ["xcrun", "coremlcompiler", "compile", str(package_path), str(output)],
        check=True,
    )
    produced = output / "model.mlmodelc"
    if not produced.exists():
        for candidate in output.glob("*.mlmodelc"):
            if candidate.name != "model.mlmodelc":
                shutil.move(str(candidate), str(produced))
                break


def write_model_config(hf_dir: Path, output: Path, context: int, repo_id: str) -> None:
    cfg = json.loads((hf_dir / "config.json").read_text(encoding="utf-8"))
    out = {
        "model_name": "MiniMind-o",
        "architecture": cfg.get("model_type", "minimind-o"),
        "hidden_size": int(cfg.get("hidden_size", 768)),
        "context_length": context,
        "vocab_size": int(cfg.get("vocab_size", 6400)),
        "bos_token_id": int(cfg.get("bos_token_id", 1)),
        "eos_token_id": int(cfg.get("eos_token_id", 2)),
        "num_hidden_layers": int(cfg.get("num_hidden_layers", 8)),
        "num_attention_heads": int(cfg.get("num_attention_heads", 8)),
        "num_key_value_heads": int(cfg.get("num_key_value_heads", 4)),
        "head_dim": int(cfg.get("head_dim", 96)),
        "rope_theta": float(cfg.get("rope_theta", 1_000_000.0)),
        "source_repo": repo_id,
        "coreml_export": {
            "kv_cache": "MLState kv_cache_0",
            "linear": "Conv2d 1x1",
            "rms_norm": "ANE LayerNorm mirror trick",
            "softmax": "decomposed fp16" if os.environ.get("USE_NATIVE_SOFTMAX") != "1" else "native",
            "argmax": "in_graph"
        }
    }
    (output / "model_config.json").write_text(json.dumps(out, ensure_ascii=False, indent=2), encoding="utf-8")


def copy_tokenizer(hf_dir: Path, output: Path) -> None:
    dst = output / "hf_model"
    dst.mkdir(parents=True, exist_ok=True)
    keep = {
        "tokenizer.json",
        "tokenizer_config.json",
        "special_tokens_map.json",
        "generation_config.json",
        "chat_template.jinja",
        "config.json",
        "model_minimind.py",
        "model_omni.py",
    }
    for name in keep:
        src = hf_dir / name
        if src.exists():
            shutil.copy2(src, dst / name)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", default=DEFAULT_REPO)
    parser.add_argument("--hf-dir", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--context-length", type=int, default=12000)
    parser.add_argument("--skip-compile", action="store_true")
    parser.add_argument("--deployment", choices=["ios18", "ios26"], default="ios18")
    args = parser.parse_args()

    args.output.mkdir(parents=True, exist_ok=True)
    if args.hf_dir:
        hf_dir = args.hf_dir
    else:
        hf_dir = snapshot(args.repo, args.output / ".download")

    copy_tokenizer(hf_dir, args.output)
    write_model_config(hf_dir, args.output, args.context_length, args.repo)

    try:
        import coremltools as ct
    except Exception as exc:
        raise SystemExit(
            "coremltools is required for MiniMind-o conversion. "
            "Install it in the conversion environment, e.g. `python3 -m pip install coremltools torch transformers huggingface_hub`."
        ) from exc

    target = ct.target.iOS18 if args.deployment == "ios18" else ct.target.iOS26
    convert_model(hf_dir, args.output, args.context_length, target)
    if not args.skip_compile:
        compile_model(args.output)
    print(f"[MiniMind-o] bundle ready: {args.output}")


if __name__ == "__main__":
    main()
