#!/usr/bin/env python3
"""mlpv2c: PyTorch-to-ONNX-to-C Neural Network Compiler for MLP-EngineV2 (MLP_V2_TOP).

Usage:
  # 1. Compile a PyTorch model file (.py -> .onnx -> LIR AST -> mlp.h / mlp.c)
  python3 compiler/mlpv2c.py compiler/model.py -o compiler/build

  # 2. Or compile an existing ONNX file directly (.onnx -> LIR AST -> mlp.h / mlp.c)
  python3 compiler/mlpv2c.py compiler/build/mnist_mlp.onnx -o compiler/build
"""

from __future__ import annotations

import argparse
import importlib.util
import inspect
import sys
from pathlib import Path

if __package__ is None or __package__ == "":
    sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from compiler.codegen import generate_all, write_generated_files
from compiler.frontend import convert_pytorch_to_onnx, load_onnx
from compiler.memory_planner import plan_memory
from compiler.scheduler import ProgramSchedule, schedule_program


def load_pytorch_model_from_py(py_path: Path) -> object:
    """Import a Python file (`model.py`) and return its instantiated PyTorch `nn.Module`."""
    spec = importlib.util.spec_from_file_location(py_path.stem, py_path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Failed to load Python module from {py_path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)

    if hasattr(module, "build_model") and callable(module.build_model):
        return module.build_model()

    # Fallback: find the first class with `named_modules` and `forward`
    for _name, obj in inspect.getmembers(module, inspect.isclass):
        if obj.__module__ == module.__name__ and hasattr(obj, "forward"):
            instance = obj()
            if hasattr(module, "load_pretrained_parameters") and callable(
                module.load_pretrained_parameters
            ):
                module.load_pretrained_parameters(instance)
            return instance

    raise ValueError(
        f"No `build_model()` function or `nn.Module` subclass found in {py_path}"
    )


def print_compilation_summary(schedule: ProgramSchedule) -> None:
    graph = schedule.graph
    mplan = schedule.memory_plan

    print("=" * 76)
    print(f" MLP-EngineV2 Compiler (mlpv2c) — Model: {graph.name}")
    print("=" * 76)
    print(f" Batch Size (M)       : {graph.batch_size}")
    print(f" Input Features       : {graph.input_size}")
    print(f" Scratchpad Strategy  : {mplan.allocation_mode} (peak {mplan.peak_spad_bytes} / 4096 B)")
    print(f" Packed .noinit RAM   : {mplan.total_noinit_bytes:,} B")
    print("-" * 76)
    print(
        f" {'Layer':<8} {'Shape':<14} {'SPAD Out':<12} {'Bank':<6} "
        f"{'Base CFG':>10} {'Opt CFG':>10} {'Saved':>9}"
    )
    print("-" * 76)
    for lsched in schedule.layer_schedules:
        layer = lsched.layer
        mem = lsched.mem
        shape_str = f"{layer.in_features} -> {layer.out_features}"
        spad_str = f"0x{mem.output_spad_addr:04x}"
        print(
            f" {layer.name:<8} {shape_str:<14} {spad_str:<12} {mem.output_spad_bank:<6} "
            f"{lsched.baseline_cfg_count:>10,} {lsched.optimized_cfg_count:>10,} "
            f"{lsched.cfg_reduction_pct:>8.1f}%"
        )
    print("-" * 76)
    print(
        f" {'TOTAL':<8} {'':<14} {'':<12} {'':<6} "
        f"{schedule.total_baseline_cfgs:>10,} {schedule.total_optimized_cfgs:>10,} "
        f"{schedule.total_cfg_reduction_pct:>8.1f}%"
    )
    print("=" * 76)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="mlpv2c",
        description="PyTorch / ONNX to MLP_V2_TOP Compiler (PyTorch -> ONNX -> Schedule -> LIR AST -> C)",
    )
    parser.add_argument(
        "model_input",
        help="Input PyTorch model script (e.g. compiler/model.py) or .onnx file",
    )
    parser.add_argument("-o", "--output", required=True, help="Output directory for .onnx, mlp.h, and mlp.c")
    parser.add_argument("--batch-size", type=int, default=4, help="Batch size M (1..4)")
    parser.add_argument("--num-test", type=int, default=10, help="Default NUM_OF_TEST macro")
    parser.add_argument("--ping-pong", action="store_true", help="Force scratchpad ping-pong mode")
    args = parser.parse_args(argv)

    input_path = Path(args.model_input)
    out_dir = Path(args.output)
    out_dir.mkdir(parents=True, exist_ok=True)

    if input_path.suffix == ".py":
        model = load_pytorch_model_from_py(input_path)
        onnx_path = out_dir / "mnist_mlp.onnx"
        onnx_bytes = convert_pytorch_to_onnx(
            model,
            output_onnx_path=onnx_path,
            batch_size=args.batch_size,
        )
        print(
            f"[mlpv2c] Extracted ONNX from PyTorch '{model.__class__.__name__}' "
            f"({input_path}) -> {onnx_path} ({len(onnx_bytes):,} B)"
        )
    else:
        onnx_path = input_path

    graph = load_onnx(onnx_path, batch_size=args.batch_size)
    for w in graph.validate():
        print(f"[mlpv2c][WARN] {w}")

    mplan = plan_memory(graph, force_ping_pong=args.ping_pong)
    schedule = schedule_program(graph, mplan, optimize_cfg=True)
    print_compilation_summary(schedule)

    artifacts = generate_all(schedule, num_of_test=args.num_test)
    written = write_generated_files(artifacts, out_dir=out_dir)
    for name, path in written.items():
        print(f"[mlpv2c] Generated {name:<10} -> {path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
