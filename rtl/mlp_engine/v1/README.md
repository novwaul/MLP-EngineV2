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
   - `LBU` × 16 moves the compressed outputs to the scratchpad (layers 1 and
     2), or `SB` × 16 writes them to external memory (layer 3).
3. Layer 1's output stays in the scratchpad, and layer 2's output overwrites
   the input area. The core takes the argmax of the four results in external
   memory.

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
