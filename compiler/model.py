"""PyTorch MLP Model Definition (`MnistMLP`) for MLP-EngineV2 Compiler (`mlpv2c`).

This file defines the 3-layer MNIST MLP (`784 -> 128 -> 64 -> 10`) as a PyTorch
`nn.Module` and loads the integer weights/biases from `program/test_code/parameter/`.

Compile directly with `mlpv2c`:
    python3 compiler/mlpv2c.py compiler/model.py -o compiler/build
"""

from __future__ import annotations

from pathlib import Path
from typing import List

import torch
import torch.nn as nn

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_PARAM_DIR = ROOT / "program" / "test_code" / "parameter"


class MnistMLP(nn.Module):
    """3-Layer MNIST MLP (784 -> 128 -> 64 -> 10) with ReLU activations."""

    def __init__(self) -> None:
        super().__init__()
        self.fc1 = nn.Linear(784, 128)
        self.relu1 = nn.ReLU()
        self.fc2 = nn.Linear(128, 64)
        self.relu2 = nn.ReLU()
        self.fc3 = nn.Linear(64, 10)
        self.relu3 = nn.ReLU()

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        x = self.relu1(self.fc1(x))
        x = self.relu2(self.fc2(x))
        x = self.relu3(self.fc3(x))
        return x


def _parse_hex_lines(text: str) -> List[int]:
    vals: List[int] = []
    for line in text.splitlines():
        s = line.strip()
        if not s:
            continue
        b = int(s, 16) & 0xFF
        vals.append(b - 256 if b >= 128 else b)
    return vals


def load_pretrained_parameters(model: MnistMLP, param_dir: Path = DEFAULT_PARAM_DIR) -> None:
    """Load integer weights and biases from `program/test_code/parameter/` into `MnistMLP`."""
    with torch.no_grad():
        for idx, layer in enumerate((model.fc1, model.fc2, model.fc3), start=1):
            w_vals = _parse_hex_lines((param_dir / f"fc{idx}_weight.txt").read_text(encoding="utf-8"))
            b_vals = _parse_hex_lines((param_dir / f"fc{idx}_bias.txt").read_text(encoding="utf-8"))
            layer.weight.copy_(
                torch.tensor(w_vals, dtype=torch.float32).reshape(layer.out_features, layer.in_features)
            )
            layer.bias.copy_(torch.tensor(b_vals, dtype=torch.float32))


def build_model(param_dir: Path = DEFAULT_PARAM_DIR) -> MnistMLP:
    """Instantiate `MnistMLP` and populate its trained integer weights/biases."""
    model = MnistMLP()
    if param_dir.exists():
        load_pretrained_parameters(model, param_dir)
    return model
