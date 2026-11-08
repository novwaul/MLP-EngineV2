# `mlpv2c`: MLP-EngineV2 Neural Network Compiler

`mlpv2c` extracts standard **ONNX (`.onnx`)** computation graphs from **PyTorch (`nn.Module`)** models and compiles them via a Low-Level IR (AST) into C/intrinsic programs targeting [`MLP_V2_TOP`](../rtl/mlp_engine/v2/cpu_top.sv) and [`MLP_V2_ACCELERATOR`](../rtl/mlp_engine/v2/core/accelerator.sv).

---

## Compiler Pipeline

1. **PyTorch ONNX Exporter & ONNX Frontend ([`model.py`](model.py), [`frontend.py`](frontend.py))**
   - **PyTorch Model ([`model.py`](model.py)):** Defines `MnistMLP(nn.Module)` (`784 -> 128 -> 64 -> 10` with `ReLU`) and loads the integer parameters.
   - **PyTorch → ONNX ([`convert_pytorch_to_onnx()`](frontend.py)):** Exports a PyTorch `nn.Module` to `.onnx` using PyTorch's built-in `torch.onnx.export()`.
   - **ONNX Parser ([`load_onnx()`](frontend.py)):** Uses `onnx.load()` and `onnx.numpy_helper.to_array()` to parse `ModelProto` / `GraphProto`, fuse `Gemm` (or `MatMul + Add`) with `Relu`, transpose `(in_features, out_features)` weights when `transB=0`, and validate hardware bounds ([`ir.py`](ir.py)).

2. **Scratchpad & RAM Memory Planner ([`memory_planner.py`](memory_planner.py))**
   - Allocates layer output buffers in the 4 KB Scratchpad (`0x4000–0x4FFF`, 4 × 1 KB SRAM banks) using bank-separated placement or automatic **2-bank Liveness Ping-Pong (`0x4000` ↔ `0x4400`)** for deep MLPs.

3. **Double-Buffered Tiler & Redundant-CFG Optimizer ([`scheduler.py`](scheduler.py))**
   - Tiles layers into $M \le 4$ (batch), $N \le 4$ (output columns), and $K \le 16$ (`K_TILE`) blocks with `bank 0` / `bank 1` software pipelining (`RUN(b)` overlapped with `LOAD(b ^ 1)`).
   - **Hoisted `ACC.CFG` Optimization:** Hoists layer-invariant strides (`ACC_A_STRIDE`, `ACC_W_STRIDE`, `ACC_OUT_STRIDE`), layer-invariant shape (`ACC_SHAPE` when `tail_cols == 0` and `tail_k == 0`), and column-invariant pointers (`ACC_BIAS`, `ACC_OUT`) out of the inner $K$-tile loop, cutting `ACC.CFG` instructions per batch by **74.2%** (`13,664 → 3,532`).

4. **Low-Level IR (AST) Lowering & Visitor Codegen ([`lir.py`](lir.py), [`codegen.py`](codegen.py))**
   - Lowers each scheduled ONNX layer into a specialized LIR AST (`run_fc1`, `run_fc2`, `run_fc3`, eliminating dead tail branches when `in_features % 16 == 0`), then visits the AST via [`CCodeEmitter`](lir.py) to emit `mlp.h` and `mlp.c`.

---

## Quick Start

```bash
# 1. Create and activate the virtual environment
/usr/bin/python3 -m venv .venv
source .venv/bin/activate
pip install --upgrade pip
pip install "numpy<2" torch onnx

# 2. Compile PyTorch model (compiler/model.py -> mnist_mlp.onnx -> mlp.h / mlp.c)
python3 compiler/mlpv2c.py compiler/model.py -o compiler/build
```
