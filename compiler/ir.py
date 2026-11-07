"""Intermediate Representation (IR) and Hardware Validation for MLP-EngineV2."""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import List, Optional, Tuple

# Hardware constants from rtl/mlp_engine/v2/core/accelerator.sv & systolic_array.sv
HW_ARRAY_ROWS = 4          # M tile max
HW_ARRAY_COLS = 4          # N tile max
HW_K_TILE = 16             # K tile max
HW_NUM_BANKS = 2           # Double-buffered operand banks (bank 0, bank 1)
HW_SPAD_BASE = 0x00004000  # Scratchpad start address
HW_SPAD_SIZE = 0x00001000  # 4 KB total (4 x 1 KB SRAM banks)
HW_SPAD_BANK_SIZE = 0x400  # 1 KB per bank
HW_ACCUM_MIN = -(1 << 19)  # -524,288 (20-bit signed minimum)
HW_ACCUM_MAX = (1 << 19) - 1  # +524,287 (20-bit signed maximum)


@dataclass
class LinearLayer:
    """Represents a fused Fully-Connected (+ Bias + ReLU + Requant) layer."""

    name: str
    in_features: int
    out_features: int
    has_relu: bool = True
    # Stored in row-major [out_features][in_features] order matching V2 DMA layout
    weights: Optional[List[int]] = None
    bias: Optional[List[int]] = None

    def validate(self) -> List[str]:
        """Validate layer dimensions, int8 operand bounds, and 20-bit overflow."""
        warnings: List[str] = []
        if self.in_features <= 0 or self.out_features <= 0:
            raise ValueError(
                f"Layer '{self.name}': invalid shape ({self.in_features} -> {self.out_features})"
            )

        if not self.has_relu:
            warnings.append(
                f"Layer '{self.name}': hardware ACC_LAST always applies ReLU + uint8 "
                "requantization ((sum + 128) >>> 8). Non-ReLU output will still be clamped to [0, 255]."
            )

        if self.weights is not None:
            expected_w = self.out_features * self.in_features
            if len(self.weights) != expected_w:
                raise ValueError(
                    f"Layer '{self.name}': weight count {len(self.weights)} != "
                    f"out_features * in_features ({expected_w})"
                )
            for idx, val in enumerate(self.weights):
                if not (-128 <= val <= 127):
                    raise ValueError(
                        f"Layer '{self.name}': weight[{idx}] = {val} out of int8 range [-128, 127]"
                    )

        if self.bias is not None:
            if len(self.bias) != self.out_features:
                raise ValueError(
                    f"Layer '{self.name}': bias count {len(self.bias)} != "
                    f"out_features ({self.out_features})"
                )
            for idx, val in enumerate(self.bias):
                if not (-128 <= val <= 127):
                    raise ValueError(
                        f"Layer '{self.name}': bias[{idx}] = {val} out of int8 range [-128, 127]"
                    )

        # Static 20-bit accumulator overflow analysis
        if self.weights is not None:
            max_pos_sum = 0
            min_neg_sum = 0
            for c in range(self.out_features):
                row = self.weights[c * self.in_features : (c + 1) * self.in_features]
                b = self.bias[c] if self.bias is not None else 0
                pos_sum = b + sum(255 * w for w in row if w > 0)
                neg_sum = b + sum(255 * w for w in row if w < 0)
                max_pos_sum = max(max_pos_sum, pos_sum)
                min_neg_sum = min(min_neg_sum, neg_sum)

            if max_pos_sum > HW_ACCUM_MAX or min_neg_sum < HW_ACCUM_MIN:
                warnings.append(
                    f"Layer '{self.name}': worst-case accumulator range [{min_neg_sum}, {max_pos_sum}] "
                    f"exceeds 20-bit signed bounds [{HW_ACCUM_MIN}, {HW_ACCUM_MAX}] "
                    "(may trigger ERR_OVERFLOW on extreme all-255 inputs)."
                )
        return warnings


@dataclass
class ModelGraph:
    """Top-level neural network graph IR for MLP-EngineV2."""

    name: str
    input_size: int
    batch_size: int = HW_ARRAY_ROWS
    layers: List[LinearLayer] = field(default_factory=list)

    @property
    def output_size(self) -> int:
        return self.layers[-1].out_features if self.layers else 0

    def validate(self) -> List[str]:
        """Validate end-to-end graph connectivity and hardware constraints."""
        if not self.layers:
            raise ValueError("ModelGraph contains no linear layers.")
        if not (1 <= self.batch_size <= HW_ARRAY_ROWS):
            raise ValueError(
                f"batch_size={self.batch_size} must be in [1, {HW_ARRAY_ROWS}]"
            )

        warnings: List[str] = []
        expected_in = self.input_size
        for idx, layer in enumerate(self.layers):
            if layer.in_features != expected_in:
                raise ValueError(
                    f"Layer {idx} ('{layer.name}') in_features={layer.in_features} "
                    f"does not match previous dimension {expected_in}"
                )
            warnings.extend(layer.validate())
            expected_in = layer.out_features
        return warnings

    def summary_rows(self) -> List[Tuple[str, int, int, int, int]]:
        """Return (name, in_features, out_features, num_weights, num_macs_per_batch)."""
        rows = []
        for layer in self.layers:
            w_cnt = layer.in_features * layer.out_features
            macs = self.batch_size * w_cnt
            rows.append((layer.name, layer.in_features, layer.out_features, w_cnt, macs))
        return rows
