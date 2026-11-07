"""Zero-dependency ONNX Protobuf wire-format reader and writer (integer tensors).

Supports standard ONNX ModelProto / GraphProto / NodeProto / TensorProto
binaries without requiring external protobuf or onnx Python packages.
"""

from __future__ import annotations

import struct
from dataclasses import dataclass, field
from typing import Dict, List, Optional, Tuple

# ONNX TensorProto.DataType constants (from onnx.proto)
ONNX_UINT8 = 2
ONNX_INT8 = 3
ONNX_INT16 = 5
ONNX_INT32 = 6
ONNX_INT64 = 7


@dataclass
class OnnxTensor:
    name: str
    dims: List[int]
    data_type: int
    values: List[int]


@dataclass
class OnnxNode:
    name: str
    op_type: str
    inputs: List[str]
    outputs: List[str]
    attributes: Dict[str, object] = field(default_factory=dict)


@dataclass
class OnnxModel:
    name: str
    nodes: List[OnnxNode]
    initializers: Dict[str, OnnxTensor]
    input_shapes: Dict[str, List[int]]
    output_shapes: Dict[str, List[int]]


# -----------------------------------------------------------------------------
# Low-level Protobuf Wire Format Decoder
# -----------------------------------------------------------------------------

def _read_varint(buf: bytes, pos: int) -> Tuple[int, int]:
    result = 0
    shift = 0
    while True:
        if pos >= len(buf):
            raise ValueError("Unexpected EOF while reading protobuf varint")
        b = buf[pos]
        pos += 1
        result |= (b & 0x7F) << shift
        if not (b & 0x80):
            break
        shift += 7
    return result, pos


def _to_signed64(val: int) -> int:
    return val - (1 << 64) if val >= (1 << 63) else val


def _to_signed32(val: int) -> int:
    val &= 0xFFFFFFFF
    return val - (1 << 32) if val >= (1 << 31) else val


def _iter_fields(buf: bytes) -> List[Tuple[int, int, object]]:
    pos = 0
    end = len(buf)
    fields: List[Tuple[int, int, object]] = []
    while pos < end:
        tag, pos = _read_varint(buf, pos)
        field_num = tag >> 3
        wire_type = tag & 0x07
        if wire_type == 0:
            val, pos = _read_varint(buf, pos)
            fields.append((field_num, wire_type, val))
        elif wire_type == 1:
            fields.append((field_num, wire_type, buf[pos : pos + 8]))
            pos += 8
        elif wire_type == 2:
            length, pos = _read_varint(buf, pos)
            fields.append((field_num, wire_type, buf[pos : pos + length]))
            pos += length
        elif wire_type == 5:
            fields.append((field_num, wire_type, buf[pos : pos + 4]))
            pos += 4
        else:
            raise ValueError(f"Unsupported protobuf wire type: {wire_type}")
    return fields


def _parse_attribute(buf: bytes) -> Tuple[str, object]:
    name = ""
    i_val: Optional[int] = None
    s_val: Optional[bytes] = None
    for fnum, wtype, val in _iter_fields(buf):
        if fnum == 1 and wtype == 2:
            name = bytes(val).decode("utf-8", errors="replace")
        elif fnum == 3 and wtype == 0:
            i_val = _to_signed64(int(val))
        elif fnum == 4 and wtype == 2:
            s_val = bytes(val)
    if i_val is not None:
        return name, i_val
    if s_val is not None:
        return name, s_val
    return name, None


def _parse_node(buf: bytes) -> OnnxNode:
    inputs: List[str] = []
    outputs: List[str] = []
    name = ""
    op_type = ""
    attrs: Dict[str, object] = {}
    for fnum, wtype, val in _iter_fields(buf):
        if fnum == 1 and wtype == 2:
            inputs.append(bytes(val).decode("utf-8"))
        elif fnum == 2 and wtype == 2:
            outputs.append(bytes(val).decode("utf-8"))
        elif fnum == 3 and wtype == 2:
            name = bytes(val).decode("utf-8")
        elif fnum == 4 and wtype == 2:
            op_type = bytes(val).decode("utf-8")
        elif fnum == 5 and wtype == 2:
            k, v = _parse_attribute(bytes(val))
            if k:
                attrs[k] = v
    return OnnxNode(name=name, op_type=op_type, inputs=inputs, outputs=outputs, attributes=attrs)


def _parse_tensor(buf: bytes) -> OnnxTensor:
    dims: List[int] = []
    data_type = ONNX_INT8
    name = ""
    int_data: List[int] = []
    raw_data: Optional[bytes] = None

    for fnum, wtype, val in _iter_fields(buf):
        if fnum == 1:
            if wtype == 0:
                dims.append(_to_signed64(int(val)))
            elif wtype == 2:
                b = bytes(val)
                p = 0
                while p < len(b):
                    v, p = _read_varint(b, p)
                    dims.append(_to_signed64(v))
        elif fnum == 2 and wtype == 0:
            data_type = int(val)
        elif fnum in (5, 7):
            if wtype == 0:
                int_data.append(_to_signed64(int(val)) if fnum == 7 else _to_signed32(int(val)))
            elif wtype == 2:
                b = bytes(val)
                p = 0
                while p < len(b):
                    v, p = _read_varint(b, p)
                    int_data.append(_to_signed64(v) if fnum == 7 else _to_signed32(v))
        elif fnum == 8 and wtype == 2:
            name = bytes(val).decode("utf-8")
        elif fnum == 9 and wtype == 2:
            raw_data = bytes(val)

    values: List[int] = []
    if raw_data is not None:
        if data_type == ONNX_INT8:
            values = list(struct.unpack(f"<{len(raw_data)}b", raw_data))
        elif data_type == ONNX_UINT8:
            values = list(struct.unpack(f"<{len(raw_data)}B", raw_data))
        elif data_type == ONNX_INT16:
            values = list(struct.unpack(f"<{len(raw_data) // 2}h", raw_data))
        elif data_type == ONNX_INT32:
            values = list(struct.unpack(f"<{len(raw_data) // 4}i", raw_data))
        elif data_type == ONNX_INT64:
            values = list(struct.unpack(f"<{len(raw_data) // 8}q", raw_data))
    elif int_data:
        values = int_data

    return OnnxTensor(name=name, dims=dims, data_type=data_type, values=values)


def _parse_value_info(buf: bytes) -> Tuple[str, List[int]]:
    name = ""
    dims: List[int] = []
    for fnum, wtype, val in _iter_fields(buf):
        if fnum == 1 and wtype == 2:
            name = bytes(val).decode("utf-8")
        elif fnum == 2 and wtype == 2:
            for tfnum, twtype, tval in _iter_fields(bytes(val)):
                if tfnum == 1 and twtype == 2:
                    for sfnum, swtype, sval in _iter_fields(bytes(tval)):
                        if sfnum == 2 and swtype == 2:
                            for dfnum, dwtype, dval in _iter_fields(bytes(sval)):
                                if dfnum == 1 and dwtype == 2:
                                    dim_v = -1
                                    for vfnum, vwtype, vval in _iter_fields(bytes(dval)):
                                        if vfnum == 1 and vwtype == 0:
                                            dim_v = _to_signed64(int(vval))
                                    dims.append(dim_v)
    return name, dims


def parse_onnx_bytes(data: bytes) -> OnnxModel:
    """Parse a raw .onnx binary into an OnnxModel structure."""
    graph_bytes: Optional[bytes] = None
    for fnum, wtype, val in _iter_fields(data):
        if fnum == 7 and wtype == 2:
            graph_bytes = bytes(val)
    if graph_bytes is None:
        raise ValueError("ONNX file does not contain a GraphProto (field 7).")

    graph_name = "onnx_graph"
    nodes: List[OnnxNode] = []
    initializers: Dict[str, OnnxTensor] = {}
    input_shapes: Dict[str, List[int]] = {}
    output_shapes: Dict[str, List[int]] = {}

    for fnum, wtype, val in _iter_fields(graph_bytes):
        if fnum == 1 and wtype == 2:
            nodes.append(_parse_node(bytes(val)))
        elif fnum == 2 and wtype == 2:
            graph_name = bytes(val).decode("utf-8")
        elif fnum == 5 and wtype == 2:
            tensor = _parse_tensor(bytes(val))
            initializers[tensor.name] = tensor
        elif fnum == 11 and wtype == 2:
            vname, vdims = _parse_value_info(bytes(val))
            if vname:
                input_shapes[vname] = vdims
        elif fnum == 12 and wtype == 2:
            vname, vdims = _parse_value_info(bytes(val))
            if vname:
                output_shapes[vname] = vdims

    return OnnxModel(
        name=graph_name,
        nodes=nodes,
        initializers=initializers,
        input_shapes=input_shapes,
        output_shapes=output_shapes,
    )


# -----------------------------------------------------------------------------
# Low-level Protobuf Wire Format Encoder (for exporting .onnx files)
# -----------------------------------------------------------------------------

def _encode_varint(val: int) -> bytes:
    if val < 0:
        val += 1 << 64
    out = bytearray()
    while True:
        bits = val & 0x7F
        val >>= 7
        if val:
            out.append(bits | 0x80)
        else:
            out.append(bits)
            break
    return bytes(out)


def _encode_tag(field_num: int, wire_type: int) -> bytes:
    return _encode_varint((field_num << 3) | wire_type)


def _encode_bytes_field(field_num: int, payload: bytes) -> bytes:
    return _encode_tag(field_num, 2) + _encode_varint(len(payload)) + payload


def _encode_str_field(field_num: int, text: str) -> bytes:
    return _encode_bytes_field(field_num, text.encode("utf-8"))


def _encode_varint_field(field_num: int, val: int) -> bytes:
    return _encode_tag(field_num, 0) + _encode_varint(val)


def _encode_int_attribute(name: str, val: int) -> bytes:
    msg = bytearray()
    msg += _encode_str_field(1, name)
    msg += _encode_varint_field(3, val)
    msg += _encode_varint_field(20, 2)  # AttributeProto.INT = 2
    return bytes(msg)


def _encode_tensor_int8(name: str, dims: List[int], values: List[int]) -> bytes:
    msg = bytearray()
    for d in dims:
        msg += _encode_varint_field(1, d)
    msg += _encode_varint_field(2, ONNX_INT8)
    msg += _encode_str_field(8, name)
    raw = struct.pack(f"<{len(values)}b", *values)
    msg += _encode_bytes_field(9, raw)
    return bytes(msg)


def _encode_value_info(name: str, dims: List[int], elem_type: int = ONNX_INT8) -> bytes:
    shape_msg = bytearray()
    for d in dims:
        dim_msg = _encode_varint_field(1, d)
        shape_msg += _encode_bytes_field(1, dim_msg)
    tensor_type_msg = _encode_varint_field(1, elem_type) + _encode_bytes_field(2, bytes(shape_msg))
    type_msg = _encode_bytes_field(1, tensor_type_msg)
    return _encode_str_field(1, name) + _encode_bytes_field(2, type_msg)


def serialize_model_to_onnx_bytes(
    name: str,
    batch_size: int,
    input_size: int,
    layers: List[Tuple[str, int, int, bool, List[int], List[int]]],
) -> bytes:
    """Serialize traced (layer_name, in_f, out_f, has_relu, weights, bias) into ONNX bytes."""
    graph_msg = bytearray()
    prev_out = "input"

    init_msgs: List[bytes] = []
    for idx, (lname, in_f, out_f, has_relu, weights, bias) in enumerate(layers):
        w_name = f"{lname}.weight"
        b_name = f"{lname}.bias"
        gemm_out = f"{lname}_gemm_out" if has_relu else (
            "output" if idx == len(layers) - 1 else f"{lname}_out"
        )

        node_msg = bytearray()
        node_msg += _encode_str_field(1, prev_out)
        node_msg += _encode_str_field(1, w_name)
        node_msg += _encode_str_field(1, b_name)
        node_msg += _encode_str_field(2, gemm_out)
        node_msg += _encode_str_field(3, f"{lname}_Gemm")
        node_msg += _encode_str_field(4, "Gemm")
        node_msg += _encode_bytes_field(5, _encode_int_attribute("transB", 1))
        graph_msg += _encode_bytes_field(1, bytes(node_msg))

        init_msgs.append(_encode_tensor_int8(w_name, [out_f, in_f], weights))
        init_msgs.append(_encode_tensor_int8(b_name, [out_f], bias))

        if has_relu:
            relu_out = "output" if idx == len(layers) - 1 else f"{lname}_relu_out"
            relu_msg = bytearray()
            relu_msg += _encode_str_field(1, gemm_out)
            relu_msg += _encode_str_field(2, relu_out)
            relu_msg += _encode_str_field(3, f"{lname}_Relu")
            relu_msg += _encode_str_field(4, "Relu")
            graph_msg += _encode_bytes_field(1, bytes(relu_msg))
            prev_out = relu_out
        else:
            prev_out = gemm_out

    graph_msg += _encode_str_field(2, name)
    for imsg in init_msgs:
        graph_msg += _encode_bytes_field(5, imsg)

    out_features_final = layers[-1][2]
    graph_msg += _encode_bytes_field(11, _encode_value_info("input", [batch_size, input_size]))
    graph_msg += _encode_bytes_field(12, _encode_value_info(prev_out, [batch_size, out_features_final]))

    model_msg = bytearray()
    model_msg += _encode_varint_field(1, 8)
    model_msg += _encode_str_field(2, "mlpv2c")
    model_msg += _encode_str_field(3, "0.1.0")
    model_msg += _encode_bytes_field(7, bytes(graph_msg))
    opset_msg = _encode_str_field(1, "") + _encode_varint_field(2, 17)
    model_msg += _encode_bytes_field(8, opset_msg)
    return bytes(model_msg)
