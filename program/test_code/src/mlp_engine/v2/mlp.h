#ifndef MLP_V2_MLP_H
#define MLP_V2_MLP_H

#define INPUT_SIZE   784
#define HIDDEN1_SIZE 128
#define HIDDEN2_SIZE 64
#define OUTPUT_SIZE  10
#define NUM_OF_TEST  10
#define ARRAY_SIZE   4

#define COL_NUM     ((OUTPUT_SIZE+ARRAY_SIZE-1)/ARRAY_SIZE)

// Memory preloaded by CORE_TB/MEMORY_TOP, one 32-bit word per value. The
// layout is the same as mlp_engine v1 (sim/rtl_sim/tb/mlp_engine/v1/core_tb.sv).
#define SCRATCH_ADDR 0x00004000
#define FC1_W_ADDR   (SCRATCH_ADDR + 0x00001000)
#define FC2_W_ADDR   (FC1_W_ADDR   + INPUT_SIZE   * HIDDEN1_SIZE * 4)
#define FC3_W_ADDR   (FC2_W_ADDR   + HIDDEN1_SIZE * HIDDEN2_SIZE * 4)
#define FC1_B_ADDR   (FC3_W_ADDR   + HIDDEN2_SIZE * OUTPUT_SIZE  * 4)
#define FC2_B_ADDR   (FC1_B_ADDR   + HIDDEN1_SIZE * 4)
#define FC3_B_ADDR   (FC2_B_ADDR   + HIDDEN2_SIZE * 4)
#define OUTPUT_ADDR  (FC3_B_ADDR   + OUTPUT_SIZE  * 4)
#define INPUT_ADDR   (OUTPUT_ADDR  + ARRAY_SIZE   * ARRAY_SIZE   * COL_NUM  * 4)
#define LABEL_ADDR   (INPUT_ADDR   + INPUT_SIZE   * NUM_OF_TEST  * 4)

// Scratchpad (0x4000-0x4fff) buffers for each layer's uint8 outputs.
#define FC1_O_ADDR   0x00004000
#define FC2_O_ADDR   0x00004400
#define FC3_O_ADDR   0x00004600

#endif
