#ifndef MLP_V2_ACCEL_H
#define MLP_V2_ACCEL_H
#include <stdint.h>

// custom-0, funct7=0, funct3=0..5. rs1/rs2 are values, not register numbers.
enum { ACC_A, ACC_W, ACC_BIAS, ACC_OUT, ACC_A_STRIDE, ACC_W_STRIDE,
       ACC_OUT_STRIDE, ACC_SHAPE };
enum { ACC_WAIT_TRANSFER=1, ACC_WAIT_COMPUTE=2, ACC_WAIT_ALL=3 };
enum { ACC_FIRST=1, ACC_LAST=2, ACC_K_TILE=16 };
#define ACC_INLINE static inline __attribute__((always_inline))
ACC_INLINE void acc_config(unsigned field, uint32_t value) {
    __asm__ volatile(".insn r 0x0b, 0, 0, x0, %0, %1"
                     :: "r"(field), "r"(value) : "memory");
}
ACC_INLINE void acc_load(unsigned bank) {
    __asm__ volatile(".insn r 0x0b, 1, 0, x0, %0, x0" :: "r"(bank) : "memory");
}
ACC_INLINE void acc_run(unsigned bank, unsigned flags) {
    __asm__ volatile(".insn r 0x0b, 2, 0, x0, %0, %1"
                     :: "r"(bank), "r"(flags) : "memory");
}
ACC_INLINE void acc_store(void) {
    __asm__ volatile(".insn r 0x0b, 3, 0, x0, x0, x0" ::: "memory");
}
ACC_INLINE void acc_wait(unsigned mask) {
    __asm__ volatile(".insn r 0x0b, 4, 0, x0, %0, x0" :: "r"(mask) : "memory");
}
ACC_INLINE uint32_t acc_status(void) {
    uint32_t value;
    __asm__ volatile(".insn r 0x0b, 5, 0, %0, x0, x0" : "=r"(value) :: "memory");
    return value;
}
// memory clobbers order compiler accesses; ACC.WAIT orders accelerator completion.
#endif
