# mlp_engine/v2

The baseline core, extended with an instruction register and a command
interface, plus an independent accelerator, a 4 KB scratchpad, and a
registered data-bus arbiter. The accelerator is driven by custom-0
instructions.

<p align="center"><img src="../../../docs/arch/v2.svg" alt="mlp_engine/v2 architecture" width="900"></p>

## Blocks

| Block | Description |
|---|---|
| `MLP_V2_TOP` (`cpu_top.sv`) | Instruction cache, core, accelerator, data-bus arbiter, and scratchpad. An `imem_response` register holds refill data for the cache. |
| `INSTR_CACHE` | Same as `scalar_core`. |
| `SCALAR_CORE` (`core/scalar_core.sv`) | Baseline core plus extensions: instruction register, byte strobes, and misaligned-access / bus-error faults. `REGFILE`/`ALU`/`CSR` are reused from `rtl/scalar_core/core/`. |
| `DECODER` (`core/decoder.sv`) | Same FSM as `scalar_core` (Fetch → Execute → Dmem \| Jump), plus StCustom (accelerator command handshake) and StStop (EBREAK or unsupported instruction). |
| `MLP_V2_ACCELERATOR` (`core/accelerator.sv`) | Config registers (A/W/BIAS/OUT address, strides, shape), byte-granular DMA, double buffers, `result_buf`, and status (busy, error code, overflow). |
| `MLP_V2_ARRAY` (`core/systolic_array.sv`) | 4×4 output-stationary systolic array. Activations move right and weights move down, one PE per cycle, through nearest-neighbour registers only. |
| Data bus arbiter (in `cpu_top.sv`) | Round-robin between the core and the accelerator, one transaction at a time: IDLE → SPAD \| EXTERNAL → RESPONSE → GAP. The dmem port is driven by `addr_q`/`data_q`/`strb_q`/`write_q`. |
| `MLP_V2_SCRATCH_PAD` (`scratch_pad/scratch_pad.sv`) | 0x4000–0x4FFF, 4 KB, built from 4 × `sky130_sram_1kbyte_1rw1r_32x256_8` banks. |

## Accelerator commands

custom-0 opcode (`0x0B`), `funct3`: `CFG` (0), `LOAD` (1), `RUN` (2),
`STORE` (3), `WAIT` (4), `STATUS` (5). C wrappers are in
`program/test_code/src/mlp_engine/v2/accel.h`.

The program processes each layer four output columns at a time:
`CFG` → `LOAD` → (`RUN` while the next `LOAD` fills the other bank) → `STORE`.
Layer outputs go to the scratchpad (0x4000 / 0x4400 / 0x4600), and the next
layer reads its input from there.

## Double buffering

The operand buffers have two banks (`abuf[2][4][16]`, `wbuf[2][4][16]`,
`bbuf[2][4]`). While the array computes a 16-element K tile from one bank, the
DMA loads the next tile into the other bank. The two banks swap roles every
tile, so data transfer overlaps with computation.

```
bank 0:  LOAD tile0 | RUN tile0  | LOAD tile2 | RUN tile2  | ...
bank 1:             | LOAD tile1 | RUN tile1  | LOAD tile3 | ...
```

## `pack()`

- **Why:** the testbench preloads every value (image pixel, weight, bias) as
  one 32-bit word.
- **What:** `pack()` (`mlp.c`) runs on the scalar core. It takes the low
  8 bits of four consecutive words and stores them as the four bytes of one
  word in RAM.
- **When:** the model is packed once at start-up, and the input images once
  per 4-image batch.
- The DMA reads these packed bytes. Packing time is included in mcycle.

## Data widths in the accelerator

| Item | Width | Notes |
|---|---|---|
| Activation | 8-bit unsigned | Low 8 bits of each 32-bit value, packed 4 per word by `pack()` |
| Weight | 8-bit signed | Same packing |
| Bias | 8-bit signed | Sign-extended to 20 bits and loaded as the initial sum |
| Product | 17-bit signed | `{1'b0, a} × w` (the activation is zero-extended so values ≥ 128 stay positive) |
| Accumulator | 20-bit signed | Computed in 21 bits; a sign mismatch sets the overflow flag and reports `ERR_OVERFLOW` |
| Output | 8-bit unsigned | ReLU, then round `(sum + 128) >>> 8` and saturate to 255 (≤ 0 → 0, ≥ 65408 → 255) |

Each layer's 8-bit output is written to the scratchpad and used directly as
the next layer's activation.
