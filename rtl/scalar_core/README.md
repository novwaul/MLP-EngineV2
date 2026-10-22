# scalar_core

<p align="center"><img src="../../docs/arch/scalar_core.svg" alt="scalar_core architecture" width="900"></p>

## How it computes

Inference runs entirely in software (`program/test_code/src/scalar_core/mlp.c`),
one image at a time.

1. For each output neuron of a layer, the core computes
   `sum = bias + Σ input[j] × weight[j]` with 32-bit integer `MUL`/`ADD`
   instructions.
2. It applies ReLU and rescales: `out = sum > 0 ? (sum + 128) >> 8 : 0`.
3. All operands and layer outputs are read from and written to external
   memory through the `dmem_*` port.
4. After the three layers (784 → 128 → 64 → 10), the core takes the argmax
   and compares it with the label.
