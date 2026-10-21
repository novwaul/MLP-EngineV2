////////////////////////////////////////////////////////////////////////////////
// AS501
// Final Project
// RISC-V Startup Assembly Code (MLP Engine v2)
////////////////////////////////////////////////////////////////////////////////
// start.S goes through the C preprocessor, so comments use // and /* */.

.section .text.start
.globl _start
_start:
    // Initialize stack pointer and global pointer
    la sp, _stack_top
    .option push
    .option norelax
    la gp, __global_pointer$
    .option pop

    // Clear .bss
    la t0, _bss_start
    la t1, _bss_end
1:  bgeu t0, t1, 2f
    sw zero, 0(t0)
    addi t0, t0, 4
    j 1b

    // Run main, then stop the core
2:  call main
    ebreak
3:  j 3b
