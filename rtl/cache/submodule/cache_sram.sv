////////////////////////////////////////////////////////////////////////////////
// AS501
// Final Project
// Cache SRAM
////////////////////////////////////////////////////////////////////////////////
// Copyright (c) 2024 by Smart Energy-Efficient Design Lab. (SEED), KAIST
// All rights reserved.
//
//                            Written by Hyungjoon Bae (jo_on@kaist.ac.kr)
//                            Supervised by Wanyeong Jung (wanyeong@kaist.ac.kr)
////////////////////////////////////////////////////////////////////////////////

module CACHE_SRAM #(
    parameter DWidth = 56,
    parameter Depth  = 128,
    localparam Index = $clog2(Depth)
)(
`ifdef USE_POWER_PINS
    inout                           vccd1,
    inout                           vssd1,
`endif
    input   logic                   clk_i,
    input   logic                   csb_i,
    input   logic                   oeb_i,
    input   logic                   web_i,
    input   logic   [Index-1:0]     addr_i,
    input   logic   [DWidth-1:0]    data_i,
    output  logic   [DWidth-1:0]    data_o
);

    // Built from two sky130_sram_1kbyte_1rw1r_32x256_8 (256 deep x 32 wide)
    // macros. Cache only addresses 128 entries, so the 8th (top) macro
    // address bit is tied 0 -- 50% depth utilization on each macro. The
    // 56-bit word is split:
    //   low macro  -> data[31:0]
    //   high macro -> data[55:32] in the low 24 bits of its 32-bit word
    // Port 1 (read-only) is tied off; only the 1RW port is used (standard
    // pattern when using efabless' precompiled sky130 OpenRAM macros).
    initial begin
        if (DWidth != 56 || Depth != 128) begin
            $fatal(1, "CACHE_SRAM: only DWidth=56, Depth=128 is supported (paired sky130_sram_1kbyte_1rw1r_32x256_8).");
        end
    end

    logic   [7:0]    macro_addr;
    logic   [31:0]   din_lo;
    logic   [31:0]   din_hi;
    logic   [31:0]   dout_lo;
    logic   [31:0]   dout_hi;

    assign macro_addr = {1'b0, addr_i};
    assign din_lo     = data_i[31:0];
    assign din_hi     = {8'b0, data_i[55:32]};

    sky130_sram_1kbyte_1rw1r_32x256_8 u_sram_lo (
`ifdef USE_POWER_PINS
        .vccd1  (vccd1),
        .vssd1  (vssd1),
`endif
        // 1RW port: writes all 4 bytes (wmask all ones) when web0=0.
        .clk0   (clk_i),
        .csb0   (csb_i),
        .web0   (web_i),
        .wmask0 (4'b1111),
        .addr0  (macro_addr),
        .din0   (din_lo),
        .dout0  (dout_lo),
        // 1R port (unused).
        .clk1   (clk_i),
        .csb1   (1'b1),
        .addr1  (8'b0),
        .dout1  ()
    );

    sky130_sram_1kbyte_1rw1r_32x256_8 u_sram_hi (
`ifdef USE_POWER_PINS
        .vccd1  (vccd1),
        .vssd1  (vssd1),
`endif
        // Only the low 24 bits hold real data; upper 8 bits also get written
        // (wmask all ones) but are masked out on read.
        .clk0   (clk_i),
        .csb0   (csb_i),
        .web0   (web_i),
        .wmask0 (4'b1111),
        .addr0  (macro_addr),
        .din0   (din_hi),
        .dout0  (dout_hi),
        // 1R port (unused).
        .clk1   (clk_i),
        .csb1   (1'b1),
        .addr1  (8'b0),
        .dout1  ()
    );

    assign data_o = (!oeb_i) ? {dout_hi[23:0], dout_lo} : '0;

endmodule
