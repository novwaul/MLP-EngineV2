################################################################################
## AS501
## Final Project
## C to Hex Generator Makefile (MLP Engine v2)
################################################################################

HERE := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
ROOT := $(abspath $(HERE)/../../../../..)

TOOLCHAIN = riscv32-unknown-elf-

CC = $(TOOLCHAIN)gcc
ELF2HEX = $(ROOT)/program/common/b2h_converter
CFLAGS = -march=rv32im_zicsr -mabi=ilp32 -Wl
MEMORY_BYTE_WIDTH = 4
TARGET ?= mlp
TB_NUM ?= 10
# Every invocation builds into a fresh build/image_<N>_<date>_<time>/ dir so
# previous builds accumulate. Callers (the sim Makefiles) pass their own
# RUN_TAG so the program and the simulation of one run share the same tag.
ifndef RUN_TAG
RUN_TAG := $(shell date +%Y-%m-%d_%H-%M-%S)
endif
OUT_DIR = $(HERE)/build/image_$(TB_NUM)_$(RUN_TAG)

.PHONY: all riscv clean

all: riscv

riscv:
	$(shell sed -i.bak -E "s/^[[:space:]]*#define[[:space:]]+NUM_OF_TEST[[:space:]]+[0-9]+/#define NUM_OF_TEST  ${TB_NUM}/" "$(HERE)/mlp.h")
	$(shell rm -f "$(HERE)/mlp.h.bak")
	$(shell mkdir -p $(OUT_DIR))
	$(CC) $(CFLAGS),-Bstatic,-T,$(HERE)/sections.lds,-Map=$(OUT_DIR)/mem.map,--strip-debug -ffreestanding -nostartfiles -o $(OUT_DIR)/$(TARGET)_riscv.elf $(HERE)/start.S $(HERE)/$(TARGET).c -lm -D RISCV
	$(TOOLCHAIN)objdump --disassemble-all -d $(OUT_DIR)/$(TARGET)_riscv.elf > $(OUT_DIR)/$(TARGET)_riscv.dis
	$(TOOLCHAIN)objcopy -O binary $(OUT_DIR)/$(TARGET)_riscv.elf $(OUT_DIR)/$(TARGET)_riscv.bin
	$(ELF2HEX) $(OUT_DIR)/$(TARGET)_riscv.bin $(OUT_DIR)/$(TARGET)_riscv.hex $(MEMORY_BYTE_WIDTH) 32768

# Wipes all accumulated builds. Remove a single build manually with rm -rf.
clean:
	rm -rf $(HERE)/build
