"""Tiling, Double-Buffering Scheduler, and Redundant-CFG Optimizer for MLP-EngineV2."""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import List, Optional, Tuple

from .ir import HW_ARRAY_COLS, HW_K_TILE, LinearLayer, ModelGraph
from .memory_planner import LayerMemoryBinding, MemoryPlan

# Hardware CFG register indices (from rtl/mlp_engine/v2/core/accelerator.sv)
CFG_A = 0
CFG_W = 1
CFG_BIAS = 2
CFG_OUT = 3
CFG_A_STRIDE = 4
CFG_W_STRIDE = 5
CFG_OUT_STRIDE = 6
CFG_SHAPE = 7

# Hardware RUN flags
ACC_FIRST = 1
ACC_LAST = 2

# Hardware WAIT masks
ACC_WAIT_TRANSFER = 1
ACC_WAIT_COMPUTE = 2
ACC_WAIT_ALL = 3


@dataclass
class KTileSpec:
    """One K-dimension tile [k_offset, k_offset + k_len) within a 4-column block."""

    k_offset: int
    k_len: int
    bank: int
    run_flags: int
    next_k_offset: Optional[int] = None
    next_k_len: Optional[int] = None
    next_shape_changes: bool = False


@dataclass
class ColBlockSchedule:
    """Schedule for one output column block [col_offset, col_offset + n_cols)."""

    col_offset: int
    n_cols: int
    k_tiles: List[KTileSpec] = field(default_factory=list)


@dataclass
class LayerSchedule:
    """Complete tiled & double-buffered schedule for one LinearLayer."""

    layer: LinearLayer
    mem: LayerMemoryBinding
    full_col_blocks: int
    tail_cols: int
    full_k_tiles: int
    tail_k: int
    shape_hoisted_to_layer: bool = False
    col_blocks: List[ColBlockSchedule] = field(default_factory=list)
    baseline_cfg_count: int = 0
    optimized_cfg_count: int = 0

    @property
    def cfg_reduction_pct(self) -> float:
        if self.baseline_cfg_count == 0:
            return 0.0
        saved = self.baseline_cfg_count - self.optimized_cfg_count
        return 100.0 * saved / self.baseline_cfg_count


@dataclass
class ProgramSchedule:
    """Full-model schedule across all layers."""

    graph: ModelGraph
    memory_plan: MemoryPlan
    layer_schedules: List[LayerSchedule] = field(default_factory=list)

    @property
    def total_baseline_cfgs(self) -> int:
        return sum(s.baseline_cfg_count for s in self.layer_schedules)

    @property
    def total_optimized_cfgs(self) -> int:
        return sum(s.optimized_cfg_count for s in self.layer_schedules)

    @property
    def total_cfg_reduction_pct(self) -> float:
        base = self.total_baseline_cfgs
        if base == 0:
            return 0.0
        return 100.0 * (base - self.total_optimized_cfgs) / base


def schedule_layer(
    layer: LinearLayer,
    mem: LayerMemoryBinding,
    optimize_cfg: bool = True,
) -> LayerSchedule:
    """Tile a LinearLayer into (col_block <= 4, k_tile <= 16) with bank 0/1 double-buffering."""
    in_f = layer.in_features
    out_f = layer.out_features

    full_col_blocks = out_f // HW_ARRAY_COLS
    tail_cols = out_f % HW_ARRAY_COLS
    full_k_tiles = in_f // HW_K_TILE
    tail_k = in_f % HW_K_TILE
    shape_hoisted_to_layer = optimize_cfg and (tail_cols == 0) and (tail_k == 0)

    col_blocks: List[ColBlockSchedule] = []
    baseline_cfgs = 0
    optimized_cfgs = 0

    # Layer-level invariant CFG registers:
    # Always hoist ACC_A_STRIDE, ACC_W_STRIDE, ACC_OUT_STRIDE (3 regs).
    # When both out_features % 4 == 0 and in_features % 16 == 0, ACC_SHAPE is also
    # invariant across the entire layer and hoisted to the layer prologue (+1 reg).
    if optimize_cfg:
        optimized_cfgs += 4 if shape_hoisted_to_layer else 3

    for col in range(0, out_f, HW_ARRAY_COLS):
        n = min(HW_ARRAY_COLS, out_f - col)
        k_specs: List[KTileSpec] = []
        bank = 0

        # Column-block initial setup:
        # Baseline writes all 8 CFG registers before initial LOAD(0).
        baseline_cfgs += 8
        if optimize_cfg:
            # 4 regs (ACC_BIAS, ACC_OUT, ACC_A, ACC_W) if ACC_SHAPE was hoisted to layer,
            # otherwise 5 regs (+ ACC_SHAPE).
            optimized_cfgs += 4 if shape_hoisted_to_layer else 5
        else:
            optimized_cfgs += 8

        k_offsets = list(range(0, in_f, HW_K_TILE))
        for idx, k in enumerate(k_offsets):
            k_len = min(HW_K_TILE, in_f - k)
            is_first = idx == 0
            is_last = idx == len(k_offsets) - 1
            flags = (ACC_FIRST if is_first else 0) | (ACC_LAST if is_last else 0)

            if not is_last:
                next_k = k_offsets[idx + 1]
                next_len = min(HW_K_TILE, in_f - next_k)
                shape_changes = next_len != k_len
                baseline_cfgs += 8
                if optimize_cfg:
                    # Inside K-loop, only ACC_A and ACC_W change (plus ACC_SHAPE on tail tile)
                    optimized_cfgs += 3 if shape_changes else 2
                else:
                    optimized_cfgs += 8
            else:
                next_k = None
                next_len = None
                shape_changes = False

            k_specs.append(
                KTileSpec(
                    k_offset=k,
                    k_len=k_len,
                    bank=bank,
                    run_flags=flags,
                    next_k_offset=next_k,
                    next_k_len=next_len,
                    next_shape_changes=shape_changes,
                )
            )
            bank ^= 1

        col_blocks.append(ColBlockSchedule(col_offset=col, n_cols=n, k_tiles=k_specs))

    return LayerSchedule(
        layer=layer,
        mem=mem,
        full_col_blocks=full_col_blocks,
        tail_cols=tail_cols,
        full_k_tiles=full_k_tiles,
        tail_k=tail_k,
        shape_hoisted_to_layer=shape_hoisted_to_layer,
        col_blocks=col_blocks,
        baseline_cfg_count=baseline_cfgs,
        optimized_cfg_count=optimized_cfgs,
    )


def schedule_program(
    graph: ModelGraph,
    memory_plan: MemoryPlan,
    optimize_cfg: bool = True,
) -> ProgramSchedule:
    """Create the complete tiled and double-buffered schedule for `graph`."""
    layer_scheds: List[LayerSchedule] = []
    for layer, mem in zip(graph.layers, memory_plan.layers):
        layer_scheds.append(schedule_layer(layer, mem, optimize_cfg=optimize_cfg))
    return ProgramSchedule(
        graph=graph,
        memory_plan=memory_plan,
        layer_schedules=layer_scheds,
    )
