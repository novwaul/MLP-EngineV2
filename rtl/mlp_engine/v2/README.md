# mlp_engine/v2

<p align="center"><img src="../../../docs/arch/v2.svg" alt="mlp_engine/v2 architecture" width="900"></p>

## How it computes

Four images are processed at a time. Array row *r* is image *r*, and array
column *c* is output neuron *c* (`program/test_code/src/mlp_engine/v2/mlp.c`).

1. **Setup:** the core packs the model once and each 4-image batch into bytes
   in RAM (`pack()`, low 8 bits of each 32-bit value).
2. **Per 4-output block of a layer:**
   - `CFG` sets the A/W/BIAS/OUT addresses, strides, and shape (m images ×
     n outputs × K elements).
   - `LOAD` makes the DMA fetch a 16-element K tile of activations, weights,
     and biases into one buffer bank.
   - `RUN` streams the tile through the 4×4 output-stationary array.
     Activations enter from the left and move right, weights enter from the
     top and move down, and each PE accumulates its own 20-bit sum (starting
     from the bias). Meanwhile the next `LOAD` fills the other bank.
   - After the last K tile, the sums go through ReLU, `(sum + 128) >>> 8`, and
     saturation to uint8 (`result_buf`), and `STORE` writes them to the
     scratchpad.
3. Each layer's output in the scratchpad (0x4000 / 0x4400 / 0x4600) is the
   next layer's input. The core reads the final 10 outputs per image from the
   scratchpad and takes the argmax.
