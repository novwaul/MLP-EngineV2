////////////////////////////////////////////////////////////////////////////////
// AS501
// Final Project
// MLP Engine v2 accelerator command intrinsics
////////////////////////////////////////////////////////////////////////////////
// custom-0, funct7=0, funct3=0..5. rs1/rs2 are values, not register numbers.
// memory clobbers order compiler accesses; ACC.WAIT orders accelerator completion.
////////////////////////////////////////////////////////////////////////////////

#ifndef MLP_V2_ACCEL_H
#define MLP_V2_ACCEL_H
#include <stdint.h>

// ACC.CFG field index
enum {
    ACC_A,
    ACC_W,
    ACC_BIAS,
    ACC_OUT,
    ACC_A_STRIDE,
    ACC_W_STRIDE,
    ACC_OUT_STRIDE,
    ACC_SHAPE
};

// ACC.WAIT mask
enum { ACC_WAIT_TRANSFER = 1, ACC_WAIT_COMPUTE = 2, ACC_WAIT_ALL = 3 };

// ACC.RUN flags and K tile size
enum { ACC_FIRST = 1, ACC_LAST = 2, ACC_K_TILE = 16 };

#define ACC_INLINE static inline __attribute__((always_inline))

// ACC.CFG: cfg[field] = value
ACC_INLINE void acc_config(unsigned field, uint32_t value) {
    __asm__ volatile(".insn r 0x0b, 0, 0, x0, %0, %1"
                     :: "r"(field), "r"(value) : "memory");
}

// ACC.LOAD: fill an operand bank
ACC_INLINE void acc_load(unsigned bank) {
    __asm__ volatile(".insn r 0x0b, 1, 0, x0, %0, x0" :: "r"(bank) : "memory");
}

// ACC.RUN: compute one K block from a bank
ACC_INLINE void acc_run(unsigned bank, unsigned flags) {
    __asm__ volatile(".insn r 0x0b, 2, 0, x0, %0, %1"
                     :: "r"(bank), "r"(flags) : "memory");
}

// ACC.STORE: write the output tile
ACC_INLINE void acc_store(void) {
    __asm__ volatile(".insn r 0x0b, 3, 0, x0, x0, x0" ::: "memory");
}

// ACC.WAIT: wait until the selected engines are idle
ACC_INLINE void acc_wait(unsigned mask) {
    __asm__ volatile(".insn r 0x0b, 4, 0, x0, %0, x0" :: "r"(mask) : "memory");
}

// ACC.STATUS: error code in [31:16], state flags in [5:0]
ACC_INLINE uint32_t acc_status(void) {
    uint32_t value;
    __asm__ volatile(".insn r 0x0b, 5, 0, %0, x0, x0" : "=r"(value) :: "memory");
    return value;
}

#endif
