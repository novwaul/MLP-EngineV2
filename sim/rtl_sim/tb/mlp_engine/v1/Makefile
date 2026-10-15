HERE     := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
ROOT     := $(abspath $(HERE)/../../../../..)
RTL_DIR  := $(ROOT)/rtl
PROGRAM  := $(ROOT)/program/test_code/src/mlp_engine/v1

# Local sky130 SRAM macro models. Identical to the OpenRAM-generated
# upstream from the ciel PDK, except `parameter VERBOSE` is defaulted to 0
# instead of 1 so the gate-level netlist (which can't carry per-instance
# parameter overrides through synthesis) doesn't spam $display on every
# access. The RTL flow uses the same models.

SRAM_MACRO_DIR := $(RTL_DIR)/macros/sky130_sram_macros
SRAM_MACRO_SOURCES := \
    $(SRAM_MACRO_DIR)/sky130_sram_1kbyte_1rw1r_8x1024_8.v \
    $(SRAM_MACRO_DIR)/sky130_sram_1kbyte_1rw1r_32x256_8.v

TB_NUM   ?= 10
TOP      := CORE_TB
# Each invocation lands under a fresh build/sim_<N>_<date>_<time>/ dir so
# previous runs accumulate side-by-side. The same tag is forwarded to the
# program build so this run simulates exactly the hex it just compiled.
ifndef RUN_TAG
RUN_TAG  := $(shell date +%Y-%m-%d_%H-%M-%S)
endif
OUT_DIR  := $(HERE)/build/sim_$(TB_NUM)_$(RUN_TAG)
OBJ_DIR  := $(OUT_DIR)/obj
EXE      := $(OBJ_DIR)/V$(TOP)
HEX      := $(PROGRAM)/build/image_$(TB_NUM)_$(RUN_TAG)/mlp_riscv.hex

VERILOG_SOURCES := \
    $(RTL_DIR)/common/core_package.sv \
    $(RTL_DIR)/common/d_flip_flop.sv \
    $(RTL_DIR)/common/mux2to1.sv \
    $(RTL_DIR)/common/mux3to1.sv \
    $(RTL_DIR)/common/mux4to1.sv \
    $(RTL_DIR)/common/mux5to1.sv \
    $(RTL_DIR)/common/counter.sv \
    $(RTL_DIR)/memory/memory_top.sv \
    $(RTL_DIR)/cache/submodule/cache_sram.sv \
    $(RTL_DIR)/cache/instr_cache.sv \
    $(RTL_DIR)/mlp_engine/v1/core/alu.sv \
    $(RTL_DIR)/mlp_engine/v1/core/csr.sv \
    $(RTL_DIR)/mlp_engine/v1/core/decoder.sv \
    $(RTL_DIR)/mlp_engine/v1/core/regfile.sv \
    $(RTL_DIR)/mlp_engine/v1/core/scalar_core.sv \
    $(RTL_DIR)/mlp_engine/v1/cpu_top.sv \
    $(SRAM_MACRO_SOURCES) \
    $(HERE)/core_tb.sv \
    $(HERE)/gpr_public.vlt \
    $(RTL_DIR)/mlp_engine/v1/scratch_pad/submodule/scratch_pad_sram.sv \
    $(RTL_DIR)/mlp_engine/v1/scratch_pad/scratch_pad.sv \
    $(RTL_DIR)/mlp_engine/v1/core/systolic_array.sv

SIM_MAIN := $(HERE)/sim_main.cpp

NPROC := $(shell nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)

# RTL warning suppressions plus standalone-only flags.
VFLAGS := \
    --cc --exe --build \
    --top-module $(TOP) \
    --Mdir $(OBJ_DIR) \
    -O3 \
    --x-assign 0 --x-initial 0 \
    --threads 1 \
    --build-jobs $(NPROC) \
    --timescale-override 1ns/1ps \
    --no-timing \
    +define+SIM \
    -CFLAGS "-O3 -fstrict-aliasing -DSIM_NUM_OF_TEST=$(TB_NUM)" \
    -Wno-WIDTH -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC \
    -Wno-CASEINCOMPLETE -Wno-UNOPTFLAT \
    -Wno-LATCH -Wno-INITIALDLY -Wno-MULTIDRIVEN -Wno-STMTDLY \
    -Wno-BLKANDNBLK \
    -GInitFile='"$(HEX)"' \
    -GImageInitFile='"$(ROOT)/program/test_code/image/image_$(TB_NUM).txt"' \
    -GNumOfTest=$(TB_NUM)

SHELL := /bin/bash

.PHONY: all program build run clean

all: run

# Rebuild the RISC-V program so the simulation always runs against fresh hex/bin artifacts
program:
	$(MAKE) -C $(PROGRAM) all TB_NUM=$(TB_NUM) RUN_TAG=$(RUN_TAG)

build: $(EXE)

$(EXE): $(VERILOG_SOURCES) $(SIM_MAIN)
	mkdir -p $(OUT_DIR)
	verilator $(VFLAGS) $(VERILOG_SOURCES) $(SIM_MAIN)

run: program build
	set -o pipefail; cd $(OUT_DIR) && ./obj/V$(TOP) 2>&1 | tee run.log

# Wipes all accumulated runs. Remove a single run manually with rm -rf.
clean:
	rm -rf $(HERE)/build
