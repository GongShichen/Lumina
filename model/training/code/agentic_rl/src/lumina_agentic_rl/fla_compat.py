from __future__ import annotations

import importlib.machinery
import sys
import types
from typing import Any


def install_fla_causal_conv_compat() -> None:
    """Expose FLA's Triton causal-conv kernels through the API Transformers expects."""
    from transformers.utils.import_utils import is_causal_conv1d_available

    if is_causal_conv1d_available():
        return

    from fla.modules.convolution import causal_conv1d, causal_conv1d_update as fla_causal_conv1d_update

    def causal_conv1d_fn(
        x,
        weight,
        bias=None,
        seq_idx=None,
        initial_states=None,
        return_final_states=False,
        final_states_out=None,
        activation=None,
        **_: Any,
    ):
        if seq_idx is not None:
            raise ValueError("packed seq_idx is not supported by the FLA compatibility path")
        output, final_state = causal_conv1d(
            x.transpose(1, 2),
            weight=weight,
            bias=bias,
            initial_state=initial_states,
            output_final_state=return_final_states,
            activation=activation,
            backend="triton",
        )
        output = output.transpose(1, 2)
        if final_states_out is not None and final_state is not None:
            final_states_out.copy_(final_state)
        return (output, final_state) if return_final_states else output

    def causal_conv1d_update(x, conv_state, weight, bias=None, activation=None, **_: Any):
        output = fla_causal_conv1d_update(
            x.transpose(1, 2),
            conv_state,
            weight=weight,
            bias=bias,
            activation=activation,
        )
        return output.transpose(1, 2)

    module = types.ModuleType("causal_conv1d")
    module.__spec__ = importlib.machinery.ModuleSpec("causal_conv1d", loader=None)
    module.__version__ = "fla-compat-0.5.1"
    module.causal_conv1d_fn = causal_conv1d_fn
    module.causal_conv1d_update = causal_conv1d_update
    sys.modules["causal_conv1d"] = module
    is_causal_conv1d_available.cache_clear()

    loaded = sys.modules.get("transformers.models.qwen3_5.modeling_qwen3_5")
    if loaded is not None:
        loaded.causal_conv1d_fn = causal_conv1d_fn
        loaded.causal_conv1d_update = causal_conv1d_update
        loaded.is_fast_path_available = all(
            (
                causal_conv1d_fn,
                causal_conv1d_update,
                loaded.chunk_gated_delta_rule,
                loaded.fused_recurrent_gated_delta_rule,
            )
        )
