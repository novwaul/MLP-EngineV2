# mlp_engine/v1

<p align="center"><img src="../../../docs/arch/v1.svg" alt="mlp_engine/v1 architecture" width="900"></p>

## How it computes

Four images are processed at a time. Array row *i* is image *i*, and array
column *j* is output neuron *j* (`program/test_code/src/mlp_engine/v1/mlp.c`).

1. **Setup:** the core copies all biases (once) and the current batch of four
   input images into the scratchpad with `SH`.
2. **Per 4-output block of a layer:**
   - `LB` × 4 loads the four biases from the scratchpad into the partial sums.
   - For each input element *k*: `LHU` × 4 loads four weights from external
     memory, `LH` × 4 loads four inputs from the scratchpad, and `MULH` makes
     all 16 PEs do `psum += input × weight` in one cycle. That is nine
     instructions per 16 MACs.
   - `MULHU` applies ReLU to all partial sums.
   - `LBU` × 16 moves the outputs to the scratchpad (layers 1 and 2), or
     `SB` × 16 writes them to external memory (layer 3).
3. The core reads the 10 layer-3 outputs of each image from external memory
   and takes the argmax.

### Scratchpad storage

- **Size:** 4 × `sky130_sram_1kbyte_1rw1r_8x1024_8` = 4096 entries of 8 bits.
- **Addressing:** one entry per 32-bit word address. Address bits [13:12]
  select the SRAM and bits [11:2] select the row, so the scratchpad spans
  0x4000–0x7FFC with a 4-byte stride.
- **Selection:** the scratchpad is chosen by instruction type
  (`SH`/`LBU`/`LB`/`LH`), not by address. Its addresses overlap the weights in
  external memory (from 0x5000), which are read with `LHU`.
- **Write:** an entry stores bits [8:1] of the written value
  (`write_data_i[8:1]`).
- **Read:** an entry is returned as `{entry, 0}`, so the core sees
  `entry << 1`.

Layout used by the program (`SCRATCH_ADDR = 0x4000`):

| Data | Entries | Address range | Notes |
|---|---:|---|---|
| FC1 bias | 128 | 0x4000–0x41FC | Written once with `SH` |
| FC2 bias | 64 | 0x4200–0x42FC | Written once with `SH` |
| FC3 bias | 10 | 0x4300–0x4324 | Written once with `SH` |
| Input, 4 images × 784 | 3136 | 0x4328–0x7424 | Written per batch with `SH`, `[image][pixel]` |
| FC1 output, 4 × 128 | 512 | 0x7428–0x7C24 | Written with `LBU`, `[image][neuron]` |
| FC2 output, 4 × 64 | 256 | 0x4328–0x4724 | Overwrites the start of the input area |

FC3 outputs go to external memory (`OUTPUT_ADDR`) with `SB`, as 4 × 12 words
(10 used).

### Arithmetic and bit widths

| Step | Operation | Width |
|---|---|---|
| Weight load (`LHU`, external) | `data_i = {value[8:1], 1}` | 9-bit signed |
| Input load (`LH`, scratchpad) | read `{entry, 0}` → `data_i = {entry, 1}` | 9-bit unsigned |
| Bias load (`LB`, scratchpad) | `{entry, 1}`, zero-extended into the partial sum | 9-bit → 18-bit |
| MAC (`MULH`, all 16 PEs) | `psum += (sext10(w) × zext10(a))[17:0]` | 18-bit partial sum, wraps on overflow (no detection) |
| ReLU (`MULHU`) | `psum = psum > 0 ? psum : 0` | 18-bit |
| Readout (`LBU`/`SB`) | `data_o = psum[17] ? 0x1FF : psum[16:8] + psum[7]` | 9-bit (saturate or round) |
| Output to scratchpad (`LBU`) | stores `data_o[8:1]` | 8-bit entry |
| Output to external memory (`SB`) | stores `data_o` zero-extended in a 32-bit word | 9-bit value |

## RTL fix for PnR

`core/systolic_array.sv` had three index counters clocked by the falling edge
of data signals instead of `clk`. They now run on `clk` with enables.

```systemverilog
// before
always_ff @(negedge bias_ready_i or negedge rstn)   // pidx: psum write index
always_ff @(negedge data_ready_i or negedge rstn)   // sidx: input/weight write index
always_ff @(negedge data_req     or negedge rstn)   // ridx: psum read index

// after
always_ff @(posedge clk or negedge rstn) ... else if (bias_ready_i) pidx <= pidx + 1;
always_ff @(posedge clk or negedge rstn) ... else if (data_ready_i) sidx <= sidx + 1;
always_ff @(posedge clk or negedge rstn) ... data_req_q <= data_req;
                                             if (data_req_q & ~data_req) ridx <= ridx + 1;
```

The three signals are combinational data signals generated in the core:

```systemverilog
// core/scalar_core.sv:250-252
assign systolic_bias_write_en = dec_write_en & lb;            // → bias_ready_i
assign systolic_data_write_en = dec_write_en & (lh | lhu);    // → data_ready_i
assign systolic_read_en       = dmem_write_o & (sb | lbu);    // → data_req
```

Using them as flip-flop clocks causes three problems:

1. **STA cannot check those flip-flops.** The only clock in the SDC is `clk_i`,
   so these flip-flops become unclocked registers, and their paths are left
   out of setup/hold analysis. Re-synthesizing the pre-fix RTL with the same
   config and running pre-PnR `check_setup` confirms this:

   | RTL | Unclocked register pins | Unconstrained endpoints |
   |---|---:|---:|
   | Before | **23** (`SCORE.ACCELERATOR.*/CLK`) | 25 (their D pins + `vccd1`, `vssd1`) |
   | After | **0** | 2 (`vccd1`, `vssd1`) |

   23 is exactly the counter width: `pidx` 4 bits × 4 rows + `sidx` 3 bits +
   `ridx` 4 bits.
2. **CTS does not treat them as clocks.** They are not buffered or balanced as
   clock nets. Their timing relative to each other and to the `clk` domain is
   not guaranteed.
3. **They react to glitches.** A glitch on a combinational output that looks
   like a falling edge advances a counter, which misaligns the write/read
   index. Zero-delay gate-level simulation cannot catch this.

After the fix, accuracy and `minstret` match the pre-fix RTL. Mcycle is 51.4%
of the pre-fix value and close to the original SAED32 results.
