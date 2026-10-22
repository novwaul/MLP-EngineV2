# mlp_engine/v2

<p align="center"><img src="../../../docs/arch/v2.svg" alt="mlp_engine/v2 architecture" width="900"></p>

## How it computes

Four images are processed at a time. Array row *r* is image *r*, and array
column *c* is output neuron *c* (`program/test_code/src/mlp_engine/v2/mlp.c`).

1. **Setup:** the core packs the model once and each 4-image batch into bytes
   in RAM (`pack()`: the low 8 bits of four consecutive 32-bit words become
   one word).
2. **Per 4-output block of a layer:**
   - `CFG` sets the A/W/BIAS/OUT addresses, strides, and shape (m images ×
     n outputs × K elements per tile).
   - `LOAD` makes the DMA fetch a K tile (≤ 16 elements) of activations,
     weights, and biases into one buffer bank.
   - `RUN` streams the tile through the 4×4 output-stationary array while the
     next `LOAD` fills the other bank.
   - After the last tile, the sums are requantized into `result_buf`, and
     `STORE` writes them to the scratchpad.
3. Each layer's output in the scratchpad is the next layer's input. The core
   reads the final 10 outputs per image from the scratchpad and takes the
   argmax.

### Scratchpad storage

- **Size:** 4 × `sky130_sram_1kbyte_1rw1r_32x256_8` banks = 4 KB.
- **Addressing:** byte addresses 0x4000–0x4FFF. Address bits [11:10] select
  the bank, so each bank covers 1 KB:

  | Bank | 0 | 1 | 2 | 3 |
  |---|---|---|---|---|
  | Range | 0x4000–0x43FF | 0x4400–0x47FF | 0x4800–0x4BFF | 0x4C00–0x4FFF |

  Bits [9:2] select the 32-bit row.
- **Byte writes:** each byte is written separately with the byte strobes
  (`wstrb`). `STORE` writes one uint8 per access.
- **Selection:** the data-bus arbiter sends any address in 0x4000–0x4FFF to the
  scratchpad, whether it comes from the core or from the DMA. A scratchpad
  access takes IDLE → SPAD → GAP → RESPONSE.

Only layer outputs (uint8) are kept in the scratchpad. The packed model and
inputs stay in external RAM.

| Data | Size | Address | Bank | Layout |
|---|---:|---|---|---|
| FC1 output | 4 × 128 B | 0x4000–0x41FF | 0 | `[image][neuron]`, stride 128 |
| FC2 output | 4 × 64 B | 0x4400–0x44FF | 1 | stride 64 |
| FC3 output | 4 × 10 B | 0x4600–0x4627 | 1 | stride 10 |

### Arithmetic and bit widths

| Step | Operation | Width |
|---|---|---|
| `LOAD` activation | byte at `A + row·A_STRIDE + k` | 8-bit unsigned |
| `LOAD` weight | byte at `W + col·W_STRIDE + k` | 8-bit signed |
| `LOAD` bias | byte at `BIAS + col` | 8-bit signed |
| DMA reads | a one-word read cache serves the other bytes of the same word | 1 bus read per 4 sequential bytes |
| Operand skew | row/column *i* starts *i* cycles late; a `RUN` takes K + 6 cycles | — |
| First tile (`ACC_FIRST`) | each PE's sum starts at the sign-extended bias | 20-bit signed |
| MAC (every valid step) | `product = {1'b0, a} × w`, `sum += product` (computed in 21 bits) | 17-bit product, 20-bit sum |
| Overflow | bit 20 ≠ bit 19 sets the overflow flag → `ERR_OVERFLOW` | — |
| Last tile (`ACC_LAST`) | `sum ≤ 0 → 0`, `sum ≥ 65408 → 255`, else `(sum + 128) >>> 8` | 8-bit unsigned in `result_buf` |
| `STORE` | byte to `OUT + row·OUT_STRIDE + col` | 8-bit |
