"""ONNX Frontend and PyTorch ONNX Exporter for MLP-EngineV2 Compiler.

Architecture:
  1. `convert_pytorch_to_onnx(model)`: Uses PyTorch's built-in `torch.onnx.export()`
     to export a `torch.nn.Module` into standard `.onnx` protobuf bytes.
  2. `load_onnx(path_or_bytes)`: Uses `onnx` (`onnx.load` / `onnx.numpy_helper`)
     to parse `.onnx` graphs, fuse `Gemm` (or `MatMul + Add`) with `Relu`,
     transpose weights when `transB=0`, validate `int8` hardware bounds, and
     return `ModelGraph`.
"""

from __future__ import annotations

import io
from pathlib import Path
from typing import Dict, List, Optional, Sequence, Union

import onnx
from onnx import numpy_helper
import torch
import torch.nn as nn

from .ir import HW_ARRAY_ROWS, LinearLayer, ModelGraph


def _cast_int8(values: Sequence[Union[int, float]]) -> List[int]:
    """Validate and cast tensor elements to signed int8 [-128, 127]."""
    out: List[int] = []
    for v in values:
        iv = int(round(float(v)))
        if not (-128 <= iv <= 127):
            raise ValueError(f"Parameter value {iv} is out of int8 hardware range [-128, 127].")
        out.append(iv)
    return out


def convert_pytorch_to_onnx(
    model: nn.Module,
    output_onnx_path: Optional[Union[str, Path]] = None,
    batch_size: int = HW_ARRAY_ROWS,
) -> bytes:
    """Export a PyTorch `nn.Module` to ONNX bytes via `torch.onnx.export()`."""
    if not isinstance(model, nn.Module):
        raise TypeError(f"Expected a torch.nn.Module instance, got {type(model)}")

    linear_mods = [m for m in model.modules() if isinstance(m, nn.Linear)]
    if not linear_mods:
        raise ValueError("No torch.nn.Linear layers found in PyTorch nn.Module.")

    first_in_features = int(linear_mods[0].in_features)
    model.eval()
    dummy_input = torch.zeros((batch_size, first_in_features), dtype=torch.float32)

    buf = io.BytesIO()
    try:
        torch.onnx.export(
            model,
            dummy_input,
            buf,
            input_names=["input"],
            output_names=["output"],
            opset_version=13,
            do_constant_folding=True,
            dynamo=False,
        )
    except TypeError:
        buf = io.BytesIO()
        torch.onnx.export(
            model,
            dummy_input,
            buf,
            input_names=["input"],
            output_names=["output"],
            opset_version=13,
            do_constant_folding=True,
        )

    onnx_bytes = buf.getvalue()
    if output_onnx_path is not None:
        out_p = Path(output_onnx_path)
        out_p.parent.mkdir(parents=True, exist_ok=True)
        out_p.write_bytes(onnx_bytes)

    return onnx_bytes


def load_onnx(
    path_or_bytes: Union[str, Path, bytes],
    batch_size: int = HW_ARRAY_ROWS,
) -> ModelGraph:
    """Parse an ONNX model (.onnx file or ONNX protobuf bytes) into `ModelGraph`."""
    if isinstance(path_or_bytes, (str, Path)):
        model_proto = onnx.load(str(path_or_bytes))
        default_name = Path(path_or_bytes).stem
    elif isinstance(path_or_bytes, (bytes, bytearray)):
        model_proto = onnx.load_from_string(bytes(path_or_bytes))
        default_name = "onnx_model"
    else:
        raise TypeError(
            f"load_onnx expects a .onnx file path or ONNX bytes, got {type(path_or_bytes)}"
        )

    graph_proto = model_proto.graph
    model_name = (
        default_name
        if graph_proto.name in ("", "onnx_graph", "main_graph", "torch_jit")
        else graph_proto.name
    )

    inits = {init.name: numpy_helper.to_array(init) for init in graph_proto.initializer}
    nodes = list(graph_proto.node)

    consumers_by_input: Dict[str, List[int]] = {}
    for idx, node in enumerate(nodes):
        for inp in node.input:
            consumers_by_input.setdefault(inp, []).append(idx)

    layers: List[LinearLayer] = []
    visited: set[int] = set()
    layer_idx = 1

    for idx, node in enumerate(nodes):
        if idx in visited:
            continue

        if node.op_type == "Gemm":
            visited.add(idx)
            if len(node.input) < 2:
                raise ValueError(f"ONNX Gemm node '{node.name}' has fewer than 2 inputs.")
            w_name = node.input[1]
            b_name = node.input[2] if len(node.input) >= 3 else None
            if w_name not in inits:
                raise ValueError(f"ONNX Gemm weight '{w_name}' not found in initializers.")

            w_arr = inits[w_name]
            if w_arr.ndim != 2:
                raise ValueError(f"ONNX Gemm weight '{w_name}' must be 2D, got {w_arr.shape}")

            attrs = {a.name: onnx.helper.get_attribute_value(a) for a in node.attribute}
            trans_b = int(attrs.get("transB", 0))
            if trans_b == 0:
                w_arr = w_arr.T
            out_features, in_features = int(w_arr.shape[0]), int(w_arr.shape[1])
            w_vals = _cast_int8(w_arr.reshape(-1).tolist())

            if b_name and b_name in inits:
                b_vals = _cast_int8(inits[b_name].reshape(-1).tolist())
            else:
                b_vals = [0] * out_features

            out_edge = node.output[0]
            has_relu = False
            for next_idx in consumers_by_input.get(out_edge, []):
                if nodes[next_idx].op_type == "Relu":
                    has_relu = True
                    visited.add(next_idx)
                    break

            lname = f"fc{layer_idx}"
            layer_idx += 1
            layers.append(
                LinearLayer(
                    name=lname,
                    in_features=in_features,
                    out_features=out_features,
                    has_relu=has_relu,
                    weights=w_vals,
                    bias=b_vals,
                )
            )

        elif node.op_type == "MatMul":
            visited.add(idx)
            w_name = node.input[1] if node.input[1] in inits else node.input[0]
            if w_name not in inits:
                raise ValueError(f"ONNX MatMul weight '{w_name}' not found in initializers.")
            w_arr = inits[w_name]
            if w_arr.ndim != 2:
                raise ValueError(f"ONNX MatMul weight '{w_name}' must be 2D, got {w_arr.shape}")

            w_arr = w_arr.T
            out_features, in_features = int(w_arr.shape[0]), int(w_arr.shape[1])
            w_vals = _cast_int8(w_arr.reshape(-1).tolist())
            b_vals = [0] * out_features
            cur_out = node.output[0]

            for next_idx in consumers_by_input.get(cur_out, []):
                cand = nodes[next_idx]
                if cand.op_type == "Add":
                    for add_in in cand.input:
                        if add_in in inits:
                            b_vals = _cast_int8(inits[add_in].reshape(-1).tolist())
                            visited.add(next_idx)
                            cur_out = cand.output[0]
                            break

            has_relu = False
            for next_idx in consumers_by_input.get(cur_out, []):
                if nodes[next_idx].op_type == "Relu":
                    has_relu = True
                    visited.add(next_idx)
                    break

            lname = f"fc{layer_idx}"
            layer_idx += 1
            layers.append(
                LinearLayer(
                    name=lname,
                    in_features=in_features,
                    out_features=out_features,
                    has_relu=has_relu,
                    weights=w_vals,
                    bias=b_vals,
                )
            )

    if not layers:
        raise ValueError("No Gemm or MatMul layers found in ONNX graph.")

    graph = ModelGraph(
        name=model_name,
        input_size=layers[0].in_features,
        batch_size=batch_size,
        layers=layers,
    )
    graph.validate()
    return graph
