HERE     := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
ROOT     := $(abspath $(HERE)/../../../..)
RTL_DIR  := $(ROOT)/rtl
PROGRAM  := $(ROOT)/program/test_code/src/scalar_core

# Local sky130 SRAM macro models. Identical to the OpenRAM-generated
# upstream from the ciel PDK, except `parameter VERBOSE` is defaulted to 0
# instead of 1 so the placed netlist doesn't spam $display on every
# access. The RTL flow uses the same models.
SRAM_MACRO_DIR := $(RTL_DIR)/macros/sky130_sram_macros
SRAM_MACRO_SOURCES := \
    $(SRAM_MACRO_DIR)/sky130_sram_1kbyte_1rw1r_8x1024_8.v \
    $(SRAM_MACRO_DIR)/sky130_sram_1kbyte_1rw1r_32x256_8.v

# core_tb.sv hardcodes NumOfTest = 10
TB_NUM   := 10
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

# Builds a Verilator simulation of the post-PnR CPU_TOP placed netlist
# (sky130 stdcells + SRAM macros) wired to the same RTL MEMORY_TOP and
# the core_tb.sv wrapper. Defaults to the most recent librelane run.
SRAM_MACRO_COMMIT := 8afc8346a57fe1ab7934ba5a6056ea8b43078e71
NETLIST ?= $(shell ls -1d $(ROOT)/librelane/scalar_core/runs/*/final/pnl/CPU_TOP.pnl.v 2>/dev/null | tail -1)
# ciel PDK root; docker-compose mounts ~/.ciel at /pdk and exports PDK_ROOT.
PDK_ROOT ?= /pdk
STDCELL_VERILOG_DIR := $(PDK_ROOT)/ciel/sky130/versions/$(SRAM_MACRO_COMMIT)/sky130A/libs.ref/sky130_fd_sc_hd/verilog

# Verilator can't parse the Verilog 1995 UDP `table` blocks in primitives.v,
# so +define+NO_PRIMITIVES gates them out and our behavioral replacements
# (sky130_fd_sc_hd_udp_models.v) provide the same UDP module names.
STDCELL_SOURCES := \
    $(ROOT)/sim/pnl_sim/tb/sky130_fd_sc_hd_udp_models.v \
    $(STDCELL_VERILOG_DIR)/sky130_fd_sc_hd.v

VERILOG_SOURCES := \
    $(RTL_DIR)/memory/memory_top.sv \
    $(STDCELL_SOURCES) \
    $(SRAM_MACRO_SOURCES) \
    $(NETLIST) \
    $(HERE)/core_tb.sv \
    $(HERE)/gpr_public.vlt

SIM_MAIN := $(HERE)/sim_main.cpp

NPROC := $(shell nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)

# +define+FUNCTIONAL/UNIT_DELAY=#0 selects the behavioral sky130 cell models
# (no UDPs, no specify-block delays) so Verilator can simulate them; the
# extra -Wno flags suppress the noisy stdcell-library warnings on top of the
# RTL-side suppressions.
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
    +define+FUNCTIONAL \
    +define+UNIT_DELAY=\#0 \
    +define+USE_POWER_PINS \
    +define+NO_PRIMITIVES \
    -CFLAGS "-O3 -fstrict-aliasing -DSIM_NUM_OF_TEST=10" \
    -Wno-WIDTH -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC \
    -Wno-CASEINCOMPLETE -Wno-UNOPTFLAT \
    -Wno-LATCH -Wno-INITIALDLY -Wno-MULTIDRIVEN -Wno-STMTDLY \
    -Wno-BLKANDNBLK -Wno-PINMISSING -Wno-ASSIGNDLY \
    -Wno-IMPLICIT -Wno-COMBDLY -Wno-LITENDIAN -Wno-SELRANGE \
    -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM -Wno-TIMESCALEMOD \
    -GInitFile='"$(HEX)"'

SHELL := /bin/bash

.PHONY: all program build run clean

all: run

program:
	$(MAKE) -C $(PROGRAM) all TB_NUM=$(TB_NUM) RUN_TAG=$(RUN_TAG)

build: $(EXE)

# NETLIST may be passed on the command line; otherwise the latest librelane
# run of this design is picked.
$(EXE): $(VERILOG_SOURCES) $(SIM_MAIN)
	test -f "$(NETLIST)"
	mkdir -p $(OUT_DIR)
	verilator $(VFLAGS) $(VERILOG_SOURCES) $(SIM_MAIN)

run: program build
	set -o pipefail; cd $(OUT_DIR) && ./obj/V$(TOP) 2>&1 | tee run.log

# Wipes all accumulated runs. Remove a single run manually with rm -rf.
clean:
	rm -rf $(HERE)/build
