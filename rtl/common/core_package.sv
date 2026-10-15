////////////////////////////////////////////////////////////////////////////////
// AS501
// Final Project
// Core constants
////////////////////////////////////////////////////////////////////////////////
// Copyright (c) 2024 by Smart Energy-Efficient Design Lab. (SEED), KAIST
// All rights reserved.
//
//                            Written by Hyungjoon Bae (jo_on@kaist.ac.kr)
//                            Supervised by Wanyeong Jung (wanyeong@kaist.ac.kr)
////////////////////////////////////////////////////////////////////////////////
//
// Originally these constants lived in `package pkg_bool / pkg_rw / pkg_opfunct3`
// and were brought into each module with `import pkg_*::*;`. Yosys's stock
// `read_verilog -sv` parser rejects `import` outside of certain narrow
// positions, so the equivalents are defined here as `define macros — which
// every Verilog/SV-aware tool (Yosys, DC, VCS, Verilator) accepts identically.

`ifndef CORE_PACKAGE_SV
`define CORE_PACKAGE_SV

// Boolean (was: package pkg_bool)
`define TRUE   1'b1
`define FALSE  1'b0

// Read/Write select (was: package pkg_rw)
`define READ   1'b0
`define WRITE  1'b1

// ALU funct3 opcodes — {instr[30], instr[25], instr[14:12]}  (was: package pkg_opfunct3)
`define ADD    5'b0_0000
`define SUB    5'b1_0000
`define SLL    5'b0_0001
`define SLT    5'b0_0010
`define SLTU   5'b0_0011
`define XOR    5'b0_0100
`define SRL    5'b0_0101
`define SRA    5'b1_0101
`define OR     5'b0_0110
`define AND    5'b0_0111
`define MUL    5'b0_1000
`define MULH   5'b0_1001
`define MULHU  5'b0_1011
`define MULHSU 5'b0_1010

`endif
