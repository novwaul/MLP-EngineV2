// 4 KiB scratchpad: four 256x32 SRAM macros, four byte write enables.
// Inputs and read-bank selection are sampled on the rising edge. The macro
// returns read data after the falling edge; the top's existing GAP cycle
// captures it on the next rising edge. rdata is meaningful for reads only.
module MLP_V2_SCRATCH_PAD (
`ifdef USE_POWER_PINS
    inout vccd1,vssd1,
`endif
    input logic clk,en,write_en,
    input logic [9:0] word_addr,
    input logic [31:0] wdata,
    input logic [3:0] wstrb,
    output logic [31:0] rdata
);
    logic [1:0] read_bank;
    wire [31:0] bank_rdata [4];
    always_ff @(posedge clk) if(en && !write_en)
        read_bank<=word_addr[9:8];

    for(genvar bank=0;bank<4;bank++) begin : banks
        sky130_sram_1kbyte_1rw1r_32x256_8 u_sram (
`ifdef USE_POWER_PINS
            .vccd1(vccd1),.vssd1(vssd1),
`endif
            .clk0(clk),
            .csb0(!(en && word_addr[9:8]==2'(bank))),
            .web0(!write_en),
            .wmask0(wstrb),
            .addr0(word_addr[7:0]),
            .din0(wdata),
            .dout0(bank_rdata[bank]),
            // The independent read-only port is unused.
            .clk1(clk),.csb1(1'b1),.addr1(8'b0),.dout1()
        );
    end
    assign rdata=bank_rdata[read_bank];
endmodule
