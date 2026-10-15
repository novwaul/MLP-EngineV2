
module SCRATCH_PAD_SRAM #(
    parameter DWidth = 8,
    parameter Depth  = 1024,
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

    // sky130_sram_1kbyte_1rw1r_8x1024_8 maps 1024 x 8 exactly (100% utilization).
    // Port 1 (read-only) is tied off; only the 1RW port is used (standard
    // pattern when using efabless' precompiled sky130 OpenRAM macros).
    initial begin
        if (DWidth != 8 || Depth != 1024) begin
            $fatal(1, "SCRATCH_PAD_SRAM: only DWidth=8, Depth=1024 is supported (sky130_sram_1kbyte_1rw1r_8x1024_8).");
        end
    end

    logic   [7:0]    sram_dout;

    sky130_sram_1kbyte_1rw1r_8x1024_8 u_sram (
`ifdef USE_POWER_PINS
        .vccd1  (vccd1),
        .vssd1  (vssd1),
`endif
        // 1RW port: 8-bit data is one byte, so wmask is 1 bit; tie high to
        // write the entire word when web0=0.
        .clk0   (clk_i),
        .csb0   (csb_i),
        .web0   (web_i),
        .wmask0 (1'b1),
        .addr0  (addr_i),
        .din0   (data_i),
        .dout0  (sram_dout),
        // 1R port (unused).
        .clk1   (clk_i),
        .csb1   (1'b1),
        .addr1  (10'b0),
        .dout1  ()
    );

    assign data_o = (!oeb_i) ? sram_dout : '0;

endmodule
