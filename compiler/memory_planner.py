"""Scratchpad (0x4000-0x4FFF) and External RAM Memory Planner for MLP-EngineV2."""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Dict, List

from .ir import HW_SPAD_BANK_SIZE, HW_SPAD_BASE, HW_SPAD_SIZE, ModelGraph

RAM_ORIGIN = 0x01F04000
RAM_LENGTH = 1024 * 1024  # 1 MB
STACK_RESERVED = 4096     # 4 KB reserved at top of RAM (per sections.lds)


@dataclass
class LayerMemoryBinding:
    """Resolved memory addresses and buffer sizes for a single layer."""

    layer_name: str
    # Input source: either C expression "ADDR(input)" (layer 0) or hex scratchpad address
    input_addr_expr: str
    input_is_spad: bool
    input_spad_addr: int
    # Output destination in scratchpad (0x4000-0x4FFF)
    output_spad_addr: int
    output_spad_size: int
    output_spad_bank: int
    # Preloaded 32-bit word-per-value external memory addresses
    preload_w_addr: int
    preload_b_addr: int
    # Packed 4-bytes-per-word .noinit RAM buffer sizes (in 32-bit words)
    packed_w_words: int
    packed_b_words: int


@dataclass
class MemoryPlan:
    """Complete memory plan for a compiled ModelGraph."""

    scratch_base: int = HW_SPAD_BASE
    scratch_size: int = HW_SPAD_SIZE
    allocation_mode: str = "bank_separated"
    layers: List[LayerMemoryBinding] = field(default_factory=list)
    preload_output_addr: int = 0
    preload_input_addr: int = 0
    packed_input_words: int = 0
    total_noinit_bytes: int = 0
    peak_spad_bytes: int = 0

    def by_name(self) -> Dict[str, LayerMemoryBinding]:
        return {b.layer_name: b for b in self.layers}


def _align_up(val: int, align: int) -> int:
    return (val + align - 1) & ~(align - 1)


def plan_memory(graph: ModelGraph, force_ping_pong: bool = False) -> MemoryPlan:
    """Compute scratchpad and external RAM layout for `graph`."""
    batch = graph.batch_size
    out_sizes = [batch * layer.out_features for layer in graph.layers]

    # Verify every single layer output fits in the 4 KB scratchpad
    for layer, osize in zip(graph.layers, out_sizes):
        if osize > HW_SPAD_SIZE:
            raise ValueError(
                f"Layer '{layer.name}' output ({batch} x {layer.out_features} = {osize} B) "
                f"exceeds total 4 KB scratchpad ({HW_SPAD_SIZE} B)."
            )

    # Decide scratchpad placement strategy:
    # 1. If 3-layer standard topology or all outputs fit without overlap, place sequentially
    #    on bank/half-bank boundaries (0x4000, 0x4400, 0x4600, ...) so all layer outputs remain
    #    inspectable after inference and match rtl/mlp_engine/v2/README.md.
    # 2. Otherwise (deep MLP or large hidden layers), use 2-slot Liveness Ping-Pong
    #    (Slot A @ 0x4000, Slot B @ 0x4400 or 0x4800) so layer i's input and output never overlap.
    spad_addrs: List[int] = []
    allocation_mode = "bank_separated"

    if not force_ping_pong:
        cur = HW_SPAD_BASE
        fits_all = True
        for idx, osize in enumerate(out_sizes):
            if idx == 0:
                addr = HW_SPAD_BASE
            elif idx == 1 and cur <= HW_SPAD_BASE + HW_SPAD_BANK_SIZE:
                addr = HW_SPAD_BASE + HW_SPAD_BANK_SIZE  # 0x4400 (Bank 1)
            else:
                addr = _align_up(cur, 0x200)
            if addr + osize > HW_SPAD_BASE + HW_SPAD_SIZE:
                fits_all = False
                break
            spad_addrs.append(addr)
            cur = addr + osize
        if not fits_all:
            force_ping_pong = True

    if force_ping_pong:
        allocation_mode = "ping_pong"
        spad_addrs = []
        max_out = max(out_sizes)
        slot_stride = HW_SPAD_BANK_SIZE if max_out <= HW_SPAD_BANK_SIZE else 2 * HW_SPAD_BANK_SIZE
        if slot_stride * 2 > HW_SPAD_SIZE or max_out > slot_stride:
            raise ValueError(
                f"Cannot ping-pong layer outputs of max size {max_out} B inside 4 KB scratchpad."
            )
        slots = [HW_SPAD_BASE, HW_SPAD_BASE + slot_stride]
        for idx in range(len(out_sizes)):
            spad_addrs.append(slots[idx % 2])

    # Preloaded external memory addresses (starts at 0x5000 = SCRATCH_ADDR + 0x1000)
    cur_preload = HW_SPAD_BASE + HW_SPAD_SIZE
    preload_w: List[int] = []
    preload_b: List[int] = []

    for layer in graph.layers:
        preload_w.append(cur_preload)
        cur_preload += layer.in_features * layer.out_features * 4

    for layer in graph.layers:
        preload_b.append(cur_preload)
        cur_preload += layer.out_features * 4

    preload_output_addr = cur_preload
    col_num = (graph.output_size + batch - 1) // batch
    preload_input_addr = preload_output_addr + batch * batch * col_num * 4

    # Packed .noinit RAM buffers (4 bytes per 32-bit word)
    packed_input_words = (batch * graph.input_size + 3) // 4
    total_noinit_words = packed_input_words

    bindings: List[LayerMemoryBinding] = []
    for idx, layer in enumerate(graph.layers):
        osize = out_sizes[idx]
        oaddr = spad_addrs[idx]
        obank = (oaddr - HW_SPAD_BASE) // HW_SPAD_BANK_SIZE

        if idx == 0:
            in_expr = "ADDR(input)"
            in_is_spad = False
            in_spad = 0
        else:
            prev_addr = spad_addrs[idx - 1]
            in_expr = f"{graph.layers[idx - 1].name.upper()}_O_ADDR"
            in_is_spad = True
            in_spad = prev_addr

        w_words = (layer.in_features * layer.out_features + 3) // 4
        b_words = (layer.out_features + 3) // 4
        total_noinit_words += w_words + b_words

        bindings.append(
            LayerMemoryBinding(
                layer_name=layer.name,
                input_addr_expr=in_expr,
                input_is_spad=in_is_spad,
                input_spad_addr=in_spad,
                output_spad_addr=oaddr,
                output_spad_size=osize,
                output_spad_bank=obank,
                preload_w_addr=preload_w[idx],
                preload_b_addr=preload_b[idx],
                packed_w_words=w_words,
                packed_b_words=b_words,
            )
        )

    total_noinit_bytes = total_noinit_words * 4
    if total_noinit_bytes >= RAM_LENGTH - STACK_RESERVED:
        raise ValueError(
            f"Packed .noinit buffers ({total_noinit_bytes} B) exceed RAM capacity "
            f"({RAM_LENGTH - STACK_RESERVED} B)."
        )

    peak_spad = (
        max(a + s - HW_SPAD_BASE for a, s in zip(spad_addrs, out_sizes))
        if spad_addrs
        else 0
    )

    return MemoryPlan(
        scratch_base=HW_SPAD_BASE,
        scratch_size=HW_SPAD_SIZE,
        allocation_mode=allocation_mode,
        layers=bindings,
        preload_output_addr=preload_output_addr,
        preload_input_addr=preload_input_addr,
        packed_input_words=packed_input_words,
        total_noinit_bytes=total_noinit_bytes,
        peak_spad_bytes=peak_spad,
    )
