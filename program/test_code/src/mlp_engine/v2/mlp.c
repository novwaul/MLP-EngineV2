////////////////////////////////////////////////////////////////////////////////
// AS501
// Final Project
// Code of multilayer perceptron (MLP Engine v2)
////////////////////////////////////////////////////////////////////////////////

#include <stdint.h>
#include "accel.h"
#include "mlp.h"

// The testbench memory holds one 32-bit word per value and only writes whole
// words, while the accelerator streams packed int8/uint8 operands. The model
// and each batch of images are therefore packed here with word stores only.
#define NOINIT __attribute__((section(".noinit"), aligned(4)))
static uint32_t fc1_w[INPUT_SIZE * HIDDEN1_SIZE / 4]   NOINIT;
static uint32_t fc2_w[HIDDEN1_SIZE * HIDDEN2_SIZE / 4] NOINIT;
static uint32_t fc3_w[HIDDEN2_SIZE * OUTPUT_SIZE / 4]  NOINIT;
static uint32_t fc1_b[HIDDEN1_SIZE / 4]                NOINIT;
static uint32_t fc2_b[HIDDEN2_SIZE / 4]                NOINIT;
static uint32_t fc3_b[(OUTPUT_SIZE + 3) / 4]           NOINIT;
static uint32_t input[ARRAY_SIZE * INPUT_SIZE / 4]     NOINIT;

// x25-x31 report to the testbench as in v1 (-O0 never allocates them):
// x26 images done, x27 correct count, x28-x31 cycle/instret, x25 exit.
#define SET_REG(reg, value) __asm__ volatile("mv " reg ", %0" :: "r"(value))
#define EXIT_MAGIC 99999

#define ADDR(p) ((uint32_t)(uintptr_t)(p))

static unsigned min_u(unsigned a, unsigned b) { return a < b ? a : b; }

// Pack count word-per-value bytes at src into dst, four bytes per word.
static void pack(uint32_t *dst, uint32_t src, unsigned count) {
    const uint32_t *s = (const uint32_t *)(uintptr_t)src;
    for (unsigned i = 0; i < count; i += 4) {
        uint32_t word = 0;
        for (unsigned j = 0; j < 4 && i + j < count; j++) word |= (s[i + j] & 255) << (8 * j);
        dst[i / 4] = word;
    }
}

// Configure one transfer: an m x n output block over K elements [k, k+count).
static void config_block(uint32_t a, uint32_t w, uint32_t bias, uint32_t out,
                         unsigned inputs, unsigned outputs, unsigned m, unsigned n,
                         unsigned k, unsigned count) {
    acc_config(ACC_A, a + k);
    acc_config(ACC_W, w + k);
    acc_config(ACC_BIAS, bias);
    acc_config(ACC_OUT, out);
    acc_config(ACC_A_STRIDE, inputs);
    acc_config(ACC_W_STRIDE, inputs);
    acc_config(ACC_OUT_STRIDE, outputs);
    acc_config(ACC_SHAPE, m | (n << 4) | (count << 8));
}

// One fully connected layer for m images, four output columns at a time.
// Returns -1 if the accelerator reports an error.
static int layer(uint32_t a, uint32_t w, uint32_t bias, uint32_t out,
                 unsigned inputs, unsigned outputs, unsigned m) {
    for (unsigned col = 0; col < outputs; col += 4) {
        unsigned n = min_u(4, outputs - col), bank = 0;
        config_block(a, w + col * inputs, bias + col, out + col,
                     inputs, outputs, m, n, 0, min_u(ACC_K_TILE, inputs));
        acc_load(bank);
        acc_wait(ACC_WAIT_TRANSFER);
        for (unsigned k = 0; k < inputs; k += ACC_K_TILE) {
            unsigned next = k + ACC_K_TILE;
            // Configure the NEXT transfer before RUN: issuing LOAD immediately
            // after RUN can overlap even a short K=16 compute window.
            if (next < inputs)
                config_block(a, w + col * inputs, bias + col, out + col,
                             inputs, outputs, m, n, next, min_u(ACC_K_TILE, inputs - next));
            acc_run(bank, (k == 0 ? ACC_FIRST : 0) | (next >= inputs ? ACC_LAST : 0));
            if (next < inputs) acc_load(bank ^ 1);
            acc_wait(ACC_WAIT_ALL);
            if (acc_status() >> 16) return -1;
            bank ^= 1;
        }
        acc_store();
        acc_wait(ACC_WAIT_TRANSFER);
        if (acc_status() >> 16) return -1;
    }
    return 0;
}

int main(void) {
////////////////////////////////////////////////////////////////////////////////
//  Inference
    unsigned image_idx = 0, correct_count = 0;
    SET_REG("x26", image_idx);
    SET_REG("x27", correct_count);

    unsigned start_clow, start_chigh, start_ilow, start_ihigh;
    unsigned end_clow, end_chigh, end_ilow, end_ihigh;
    __asm__ volatile("csrrs %0, mcycle, x0" : "=r"(start_clow));
    __asm__ volatile("csrrs %0, mcycleh, x0" : "=r"(start_chigh));
    __asm__ volatile("csrrs %0, minstret, x0" : "=r"(start_ilow));
    __asm__ volatile("csrrs %0, minstreth, x0" : "=r"(start_ihigh));

    // Pack the model
    pack(fc1_w, FC1_W_ADDR, INPUT_SIZE * HIDDEN1_SIZE);
    pack(fc2_w, FC2_W_ADDR, HIDDEN1_SIZE * HIDDEN2_SIZE);
    pack(fc3_w, FC3_W_ADDR, HIDDEN2_SIZE * OUTPUT_SIZE);
    pack(fc1_b, FC1_B_ADDR, HIDDEN1_SIZE);
    pack(fc2_b, FC2_B_ADDR, HIDDEN2_SIZE);
    pack(fc3_b, FC3_B_ADDR, OUTPUT_SIZE);

    // Execution, ARRAY_SIZE images at a time
    const uint32_t *label = (const uint32_t *)(uintptr_t)LABEL_ADDR;
    for (unsigned image = 0; image < NUM_OF_TEST; image += ARRAY_SIZE) {
        unsigned m = min_u(ARRAY_SIZE, NUM_OF_TEST - image);
        pack(input, INPUT_ADDR + image * INPUT_SIZE * 4, m * INPUT_SIZE);

        // layer 1, 2, 3
        if (layer(ADDR(input), ADDR(fc1_w), ADDR(fc1_b), FC1_O_ADDR, INPUT_SIZE, HIDDEN1_SIZE, m)) break;
        if (layer(FC1_O_ADDR, ADDR(fc2_w), ADDR(fc2_b), FC2_O_ADDR, HIDDEN1_SIZE, HIDDEN2_SIZE, m)) break;
        if (layer(FC2_O_ADDR, ADDR(fc3_w), ADDR(fc3_b), FC3_O_ADDR, HIDDEN2_SIZE, OUTPUT_SIZE, m)) break;

        // argmax and compare with the label
        for (unsigned r = 0; r < m; r++) {
            volatile const uint8_t *o = (volatile const uint8_t *)(uintptr_t)(FC3_O_ADDR + r * OUTPUT_SIZE);
            unsigned best = 0;
            for (unsigned c = 1; c < OUTPUT_SIZE; c++) if (o[c] > o[best]) best = c;
            if (best == label[image + r]) correct_count++;
        }

        // x27 first: the testbench reads it when x26 changes.
        image_idx += ARRAY_SIZE;
        SET_REG("x27", correct_count);
        SET_REG("x26", image_idx);
    }

    __asm__ volatile("csrrs %0, mcycle, x0" : "=r"(end_clow));
    __asm__ volatile("csrrs %0, mcycleh, x0" : "=r"(end_chigh));
    __asm__ volatile("csrrs %0, minstret, x0" : "=r"(end_ilow));
    __asm__ volatile("csrrs %0, minstreth, x0" : "=r"(end_ihigh));
//
////////////////////////////////////////////////////////////////////////////////

    // Total clock and instruction-retired count
    unsigned cycle_low = end_clow - start_clow;
    if (cycle_low > end_clow) --end_chigh;
    unsigned inst_low = end_ilow - start_ilow;
    if (inst_low > end_ilow) --end_ihigh;
    SET_REG("x28", cycle_low);
    SET_REG("x29", end_chigh - start_chigh);
    SET_REG("x30", inst_low);
    SET_REG("x31", end_ihigh - start_ihigh);

    // Testbench uses this register to check the end of the simulation
    SET_REG("x25", EXIT_MAGIC);
    return 0;
}
