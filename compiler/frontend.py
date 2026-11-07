"""ONNX Frontend and PyTorch Symbolic Tracer for MLP-EngineV2 Compiler.

Architecture:
  1. `convert_pytorch_to_onnx(model)`: Symbolically traces `model.forward(x)` on a
     PyTorch `nn.Module` to extract the ONNX computation graph (`Gemm`, `Relu`, and
     integer initializers) into standard `.onnx` protobuf bytes.
  2. `load_onnx(path_or_bytes)`: Parses `.onnx` graphs (`ModelProto` / `GraphProto`),
     fuses `Gemm` (or `MatMul + Add`) with `Relu`, transposes weights when `transB=0`,
     validates `int8` hardware bounds, and returns `ModelGraph`.
"""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Dict, List, Optional, Sequence, Tuple, Union

from .ir import HW_ARRAY_ROWS, LinearLayer, ModelGraph
from .onnx_proto import OnnxModel, parse_onnx_bytes, serialize_model_to_onnx_bytes


def _cast_int8(values: Sequence[Union[int, float]]) -> List[int]:
    """Validate and cast integer tensor elements to signed int8 [-128, 127]."""
    out: List[int] = []
    for v in values:
        iv = int(round(v))
        if not (-128 <= iv <= 127):
            raise ValueError(f"Parameter value {iv} is out of int8 hardware range [-128, 127].")
        out.append(iv)
    return out


def _transpose_2d(flat: List[int], rows: int, cols: int) -> List[int]:
    """Transpose a flat [rows, cols] matrix into [cols, rows]."""
    out = [0] * (rows * cols)
    for r in range(rows):
        row_off = r * cols
        for c in range(cols):
            out[c * rows + r] = flat[row_off + c]
    return out


# =============================================================================
# 1. Canonical ONNX Frontend (`load_onnx`)
# =============================================================================

def load_onnx(
    path_or_bytes: Union[str, Path, bytes],
    batch_size: int = HW_ARRAY_ROWS,
) -> ModelGraph:
    """Parse an ONNX model (.onnx file or ONNX protobuf bytes) into `ModelGraph`."""
    if isinstance(path_or_bytes, (str, Path)):
        raw_bytes = Path(path_or_bytes).read_bytes()
        default_name = Path(path_or_bytes).stem
    elif isinstance(path_or_bytes, (bytes, bytearray)):
        raw_bytes = bytes(path_or_bytes)
        default_name = "onnx_model"
    else:
        raise TypeError(
            f"load_onnx expects a .onnx file path or ONNX bytes, got {type(path_or_bytes)}"
        )

    onnx_model: OnnxModel = parse_onnx_bytes(raw_bytes)
    model_name = onnx_model.name or default_name
    inits = onnx_model.initializers
    nodes = onnx_model.nodes

    # Map consumer nodes by their input tensor name to fuse Add / Relu
    consumers_by_input: Dict[str, List[int]] = {}
    for idx, node in enumerate(nodes):
        for inp in node.inputs:
            consumers_by_input.setdefault(inp, []).append(idx)

    layers: List[LinearLayer] = []
    visited: set[int] = set()
    layer_idx = 1

    for idx, node in enumerate(nodes):
        if idx in visited:
            continue

        if node.op_type == "Gemm":
            visited.add(idx)
            if len(node.inputs) < 2:
                raise ValueError(f"ONNX Gemm node '{node.name}' has fewer than 2 inputs.")
            w_name = node.inputs[1]
            b_name = node.inputs[2] if len(node.inputs) >= 3 else None
            if w_name not in inits:
                raise ValueError(f"ONNX Gemm weight '{w_name}' not found in initializers.")

            w_tensor = inits[w_name]
            if len(w_tensor.dims) != 2:
                raise ValueError(f"ONNX Gemm weight '{w_name}' must be 2D, got {w_tensor.dims}")

            trans_b = int(node.attributes.get("transB", 0))
            w_vals = _cast_int8(w_tensor.values)
            if trans_b == 1:
                out_features, in_features = w_tensor.dims[0], w_tensor.dims[1]
            else:
                in_features, out_features = w_tensor.dims[0], w_tensor.dims[1]
                w_vals = _transpose_2d(w_vals, in_features, out_features)

            if b_name and b_name in inits:
                b_vals = _cast_int8(inits[b_name].values)
            else:
                b_vals = [0] * out_features

            out_edge = node.outputs[0]
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
            w_name = node.inputs[1] if node.inputs[1] in inits else node.inputs[0]
            if w_name not in inits:
                raise ValueError(f"ONNX MatMul weight '{w_name}' not found in initializers.")
            w_tensor = inits[w_name]
            if len(w_tensor.dims) != 2:
                raise ValueError(f"ONNX MatMul weight '{w_name}' must be 2D, got {w_tensor.dims}")

            in_features, out_features = w_tensor.dims[0], w_tensor.dims[1]
            w_vals = _transpose_2d(_cast_int8(w_tensor.values), in_features, out_features)
            b_vals = [0] * out_features
            cur_out = node.outputs[0]

            for next_idx in consumers_by_input.get(cur_out, []):
                cand = nodes[next_idx]
                if cand.op_type == "Add":
                    for add_in in cand.inputs:
                        if add_in in inits:
                            b_vals = _cast_int8(inits[add_in].values)
                            visited.add(next_idx)
                            cur_out = cand.outputs[0]
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


# =============================================================================
# 2. PyTorch `nn.Module` Symbolic Forward Tracer -> ONNX Extractor
# =============================================================================

@dataclass
class _SymbolicTensor:
    """Symbolic tensor passed through `model.forward(x)` during PyTorch-to-ONNX tracing."""

    name: str
    shape: Tuple[int, int]


def _extract_module_param_list(raw_param: object, expected_len: int) -> List[int]:
    if hasattr(raw_param, "detach"):
        vals = raw_param.detach().cpu().reshape(-1).tolist()  # type: ignore
    elif isinstance(raw_param, list):
        vals = raw_param
    else:
        vals = [0] * expected_len
    return _cast_int8(vals)


def convert_pytorch_to_onnx(
    model: object,
    output_onnx_path: Optional[Union[str, Path]] = None,
    batch_size: int = HW_ARRAY_ROWS,
) -> bytes:
    """Symbolically trace `model.forward(x)` on a PyTorch `nn.Module` and export to ONNX."""
    if not hasattr(model, "named_modules"):
        raise TypeError(f"Expected a PyTorch nn.Module instance, got {type(model)}")

    mods = list(model.named_modules())  # type: ignore
    linear_mods = [
        (mname, mod)
        for mname, mod in mods
        if mod.__class__.__name__ == "Linear"
        and hasattr(mod, "in_features")
        and hasattr(mod, "out_features")
    ]
    if not linear_mods:
        raise ValueError("No Linear layers found in PyTorch nn.Module.")

    first_in_features = int(linear_mods[0][1].in_features)
    traced_ops: List[Tuple[str, object, _SymbolicTensor, _SymbolicTensor]] = []
    saved_forwards: List[Tuple[object, object]] = []

    for mname, mod in mods:
        if mod is model:
            continue
        cls_name = mod.__class__.__name__
        orig_fwd = getattr(mod, "forward", None)
        if cls_name == "Linear":
            def _make_linear_proxy(sub_name: str, sub_mod: object):
                def _proxy(sym_x: _SymbolicTensor) -> _SymbolicTensor:
                    in_f = int(getattr(sub_mod, "in_features"))
                    out_f = int(getattr(sub_mod, "out_features"))
                    if sym_x.shape[1] != in_f:
                        raise ValueError(
                            f"Shape mismatch in '{sub_name}': expected (*, {in_f}), got {sym_x.shape}"
                        )
                    out_sym = _SymbolicTensor(
                        name=f"{sub_name}_gemm_out",
                        shape=(sym_x.shape[0], out_f),
                    )
                    traced_ops.append(("Linear", (sub_name, sub_mod), sym_x, out_sym))
                    return out_sym
                return _proxy

            saved_forwards.append((mod, orig_fwd))
            setattr(mod, "forward", _make_linear_proxy(mname, mod))
        elif cls_name == "ReLU":
            def _make_relu_proxy(sub_name: str, sub_mod: object):
                def _proxy(sym_x: _SymbolicTensor) -> _SymbolicTensor:
                    out_sym = _SymbolicTensor(
                        name=f"{sub_name}_relu_out",
                        shape=sym_x.shape,
                    )
                    traced_ops.append(("ReLU", (sub_name, sub_mod), sym_x, out_sym))
                    return out_sym
                return _proxy

            saved_forwards.append((mod, orig_fwd))
            setattr(mod, "forward", _make_relu_proxy(mname, mod))

    try:
        if hasattr(model, "forward"):
            sym_in = _SymbolicTensor(name="input", shape=(batch_size, first_in_features))
            model.forward(sym_in)  # type: ignore
    finally:
        for mod, orig_fwd in saved_forwards:
            if orig_fwd is not None:
                setattr(mod, "forward", orig_fwd)

    layer_tuples: List[Tuple[str, int, int, bool, List[int], List[int]]] = []
    if traced_ops:
        i = 0
        while i < len(traced_ops):
            op_kind, info, _in_sym, out_sym = traced_ops[i]
            if op_kind == "Linear":
                sub_name, sub_mod = info  # type: ignore
                in_f = int(getattr(sub_mod, "in_features"))
                out_f = int(getattr(sub_mod, "out_features"))
                w_vals = _extract_module_param_list(getattr(sub_mod, "weight", None), in_f * out_f)
                b_vals = _extract_module_param_list(getattr(sub_mod, "bias", None), out_f)
                has_relu = (
                    i + 1 < len(traced_ops)
                    and traced_ops[i + 1][0] == "ReLU"
                    and traced_ops[i + 1][2].name == out_sym.name
                )
                layer_name = sub_name if sub_name else f"fc{len(layer_tuples) + 1}"
                layer_tuples.append((layer_name, in_f, out_f, has_relu, w_vals, b_vals))
                i += 2 if has_relu else 1
            else:
                i += 1
    else:
        for idx, (mname, mod) in enumerate(linear_mods, start=1):
            in_f = int(mod.in_features)
            out_f = int(mod.out_features)
            w_vals = _extract_module_param_list(getattr(mod, "weight", None), in_f * out_f)
            b_vals = _extract_module_param_list(getattr(mod, "bias", None), out_f)
            layer_tuples.append((mname or f"fc{idx}", in_f, out_f, True, w_vals, b_vals))

    onnx_bytes = serialize_model_to_onnx_bytes(
        name=model.__class__.__name__,
        batch_size=batch_size,
        input_size=layer_tuples[0][1],
        layers=layer_tuples,
    )

    if output_onnx_path is not None:
        out_p = Path(output_onnx_path)
        out_p.parent.mkdir(parents=True, exist_ok=True)
        out_p.write_bytes(onnx_bytes)

    return onnx_bytes
