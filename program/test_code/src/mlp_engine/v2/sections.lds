/******************************************************************************/
/* AS501                                                                      */
/* Final Project                                                              */
/* RISC-V Linker Script (MLP Engine v2)                                       */
/******************************************************************************/

OUTPUT_ARCH(riscv)
ENTRY(_start)

/* RAM sits above the testbench's preloaded model, images and labels (which
   end at 0x01e61e28 when NUM_OF_TEST=10000) and ends at the memory top. */
MEMORY
{
    TEXT (rx) : ORIGIN = 0, LENGTH = 16K
    RAM (rw)  : ORIGIN = 0x01f04000, LENGTH = 1M
}

_stack_top = ORIGIN(RAM) + LENGTH(RAM);

SECTIONS
{
    /* Read-only data stays in TEXT and is read through the data port, as in v1. */
    .text :
    {
        KEEP(*(.text.start))
        *(.text .text.*)
        *(.rodata .rodata.* .srodata .srodata.*)
    } > TEXT

    /* start.S does not copy .data from the image into RAM. */
    .data :
    {
        . = ALIGN(4);
        __global_pointer$ = . + 0x800;
        *(.data .data.* .sdata .sdata.*)
    } > RAM
    ASSERT(SIZEOF(.data) == 0, "initialized data is not loaded")

    .bss (NOLOAD) :
    {
        . = ALIGN(4);
        _bss_start = .;
        *(.bss .bss.* .sbss .sbss.* COMMON)
        . = ALIGN(4);
        _bss_end = .;
    } > RAM

    .noinit (NOLOAD) :
    {
        . = ALIGN(4);
        *(.noinit .noinit.*)
        . = ALIGN(4);
        _noinit_end = .;
    } > RAM
    ASSERT(_noinit_end < _stack_top - 4096, "RAM overlaps reserved stack")
}
