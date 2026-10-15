////////////////////////////////////////////////////////////////////////////////
// AS501
// Final Project
// Gate-level (post-PnR) MLP Engine v1 Testbench (NumOfTest = 10)
////////////////////////////////////////////////////////////////////////////////
// Mirrors rtl_sim/tb/mlp_engine/v1/core_tb.sv but instantiates the post-PnR CPU_TOP
// placed netlist (sky130 stdcells + SRAM macros) instead of the RTL CPU_TOP. Two
// placed netlist-specific differences from the RTL TB:
//   1. CPU_TOP has no DWidth parameter (synth bakes it in) and adds vccd1/
//      vssd1 supply ports, so we drop the `#(.DWidth(...))` override and
//      tie the supply pins off here.
//   2. After Librelane, the SCORE.SRF.GPR register array becomes
//      individual escaped-id wires (`\SCORE.SRF.GPR[<n>] `). The gpr25..gpr31
//      wires below stitch each 32-bit register back together so
//      sim_main.cpp can poll them just like the RTL sim_main.cpp polls the
//      register file -- exit-magic / image-index / accuracy logic stays
//      identical to the RTL flow.
////////////////////////////////////////////////////////////////////////////////

module CORE_TB #(
    parameter InitFile       = ""
)(
    input  logic clk_i,
    input  logic mclk_i,
    input  logic rst_ni
);
    localparam DWidth        = 32;
    localparam MemDepth      = 32'h02004000;
    localparam IMemStart     = 32'h00000000;
    localparam DMemStart     = 32'h00004000;

    localparam InputSize     = 'd784;
    localparam Hidden1Size   = 'd128;
    localparam Hidden2Size   = 'd64;
    localparam OutputSize    = 'd10;
    localparam NumOfTest     = 'd10;
    localparam ArraySize     = 'd4;

    localparam Fc1OAddr      = DMemStart;
    localparam Fc2OAddr      = DMemStart;
    localparam Fc1WAddr      = DMemStart   + 32'h00001000;
    localparam Fc2WAddr      = (Fc1WAddr   + InputSize   * Hidden1Size * 4);
    localparam Fc3WAddr      = (Fc2WAddr   + Hidden1Size * Hidden2Size * 4);
    localparam Fc1BAddr      = (Fc3WAddr   + Hidden2Size * OutputSize  * 4);
    localparam Fc2BAddr      = (Fc1BAddr   + Hidden1Size * 4);
    localparam Fc3BAddr      = (Fc2BAddr   + Hidden2Size * 4);
    localparam OutputAddr    = (Fc3BAddr   + OutputSize  * 4);
    localparam InputAddr     = (OutputAddr + ArraySize   * ArraySize   * ((OutputSize+ArraySize-1)/ArraySize) * 4);
    localparam LabelAddr     = (InputAddr  + InputSize   * NumOfTest   * 4);

    localparam ImageInitFile = "/workspace/program/test_code/image/image_10.txt";
    localparam Fc1WInitFile  = "/workspace/program/test_code/parameter/fc1_weight.txt";
    localparam Fc1BInitFile  = "/workspace/program/test_code/parameter/fc1_bias.txt";
    localparam Fc2WInitFile  = "/workspace/program/test_code/parameter/fc2_weight.txt";
    localparam Fc2BInitFile  = "/workspace/program/test_code/parameter/fc2_bias.txt";
    localparam Fc3WInitFile  = "/workspace/program/test_code/parameter/fc3_weight.txt";
    localparam Fc3BInitFile  = "/workspace/program/test_code/parameter/fc3_bias.txt";
    localparam LabelInitFile = "/workspace/program/test_code/label/label.txt";

    // sky130 power rails -- gate-level netlist exposes them as inout ports.
    logic vccd1, vssd1;
    assign vccd1 = 1'b1;
    assign vssd1 = 1'b0;

    logic                           imem_req;
    logic   [DWidth-1:0]            imem_rdata;
    logic                           imem_ready;

    logic                           dmem_req;
    logic   [DWidth-1:0]            dmem_rdata;
    logic   [DWidth-1:0]            dmem_wdata;
    logic   [DWidth-1:0]            dmem_addr;
    logic                           dmem_ready;
    logic                           dmem_write;

    logic   [DWidth-1:0]            imem_addr;

    // Gate-level CPU_TOP: no parameters, adds vccd1/vssd1 supply ports.
    CPU_TOP DUT(
        .vccd1                      (vccd1),
        .vssd1                      (vssd1),
        .clk_i                      (clk_i),
        .rst_ni                     (rst_ni),

        .imem_ready_i               (imem_ready),
        .imem_rdata_i               (imem_rdata),
        .imem_addr_o                (imem_addr),
        .imem_req_o                 (imem_req),

        .dmem_ready_i               (dmem_ready),
        .dmem_rdata_i               (dmem_rdata),
        .dmem_wdata_o               (dmem_wdata),
        .dmem_addr_o                (dmem_addr),
        .dmem_req_o                 (dmem_req),
        .dmem_write_o               (dmem_write)
    );

    MEMORY_TOP #(.DWidth(DWidth), .MemDepth(MemDepth),
                 .InitFile(InitFile), .IMemStart(IMemStart),
                 .DMemStart(DMemStart), .InputAddr(InputAddr),
                 .Fc1WAddr(Fc1WAddr), .Fc1BAddr(Fc1BAddr),
                 .Fc2WAddr(Fc2WAddr), .Fc2BAddr(Fc2BAddr),
                 .Fc3WAddr(Fc3WAddr), .Fc3BAddr(Fc3BAddr),
                 .LabelAddr(LabelAddr), .ImageInitFile(ImageInitFile),
                 .Fc1WInitFile(Fc1WInitFile), .Fc1BInitFile(Fc1BInitFile),
                 .Fc2WInitFile(Fc2WInitFile), .Fc2BInitFile(Fc2BInitFile),
                 .Fc3WInitFile(Fc3WInitFile), .Fc3BInitFile(Fc3BInitFile),
                 .LabelInitFile(LabelInitFile)) MEMORY(
        .clk_i                      (clk_i),
        .mclk_i                     (mclk_i),
        .rst_ni                     (rst_ni),

        .imem_req_i                 (imem_req),
        .imem_write_i               (),
        .imem_addr_i                (imem_addr),
        .imem_wdata_i               (),
        .imem_ready_o               (imem_ready),
        .imem_rdata_o               (imem_rdata),

        .dmem_req_i                 (dmem_req),
        .dmem_write_i               (dmem_write),
        .dmem_addr_i                (dmem_addr),
        .dmem_wdata_i               (dmem_wdata),
        .dmem_ready_o               (dmem_ready),
        .dmem_rdata_o               (dmem_rdata)
    );

    // ------------------------------------------------------------------------
    // GPR re-assembly. Yosys flattens SCORE.SRF.GPR[0:31] into one escaped
    // identifier per bit, \SCORE.SRF.GPR[<n>] with n = (31-reg)*32 + bit (x0 is
    // constant and optimized away). Each 32-bit register is stitched back
    // together here; the trailing whitespace terminates the escaped id.
    // ------------------------------------------------------------------------
    wire [31:0] gpr25 = {DUT.\SCORE.SRF.GPR[223] , DUT.\SCORE.SRF.GPR[222] , DUT.\SCORE.SRF.GPR[221] , DUT.\SCORE.SRF.GPR[220] , DUT.\SCORE.SRF.GPR[219] , DUT.\SCORE.SRF.GPR[218] , DUT.\SCORE.SRF.GPR[217] , DUT.\SCORE.SRF.GPR[216] , DUT.\SCORE.SRF.GPR[215] , DUT.\SCORE.SRF.GPR[214] , DUT.\SCORE.SRF.GPR[213] , DUT.\SCORE.SRF.GPR[212] , DUT.\SCORE.SRF.GPR[211] , DUT.\SCORE.SRF.GPR[210] , DUT.\SCORE.SRF.GPR[209] , DUT.\SCORE.SRF.GPR[208] , DUT.\SCORE.SRF.GPR[207] , DUT.\SCORE.SRF.GPR[206] , DUT.\SCORE.SRF.GPR[205] , DUT.\SCORE.SRF.GPR[204] , DUT.\SCORE.SRF.GPR[203] , DUT.\SCORE.SRF.GPR[202] , DUT.\SCORE.SRF.GPR[201] , DUT.\SCORE.SRF.GPR[200] , DUT.\SCORE.SRF.GPR[199] , DUT.\SCORE.SRF.GPR[198] , DUT.\SCORE.SRF.GPR[197] , DUT.\SCORE.SRF.GPR[196] , DUT.\SCORE.SRF.GPR[195] , DUT.\SCORE.SRF.GPR[194] , DUT.\SCORE.SRF.GPR[193] , DUT.\SCORE.SRF.GPR[192] };
    wire [31:0] gpr26 = {DUT.\SCORE.SRF.GPR[191] , DUT.\SCORE.SRF.GPR[190] , DUT.\SCORE.SRF.GPR[189] , DUT.\SCORE.SRF.GPR[188] , DUT.\SCORE.SRF.GPR[187] , DUT.\SCORE.SRF.GPR[186] , DUT.\SCORE.SRF.GPR[185] , DUT.\SCORE.SRF.GPR[184] , DUT.\SCORE.SRF.GPR[183] , DUT.\SCORE.SRF.GPR[182] , DUT.\SCORE.SRF.GPR[181] , DUT.\SCORE.SRF.GPR[180] , DUT.\SCORE.SRF.GPR[179] , DUT.\SCORE.SRF.GPR[178] , DUT.\SCORE.SRF.GPR[177] , DUT.\SCORE.SRF.GPR[176] , DUT.\SCORE.SRF.GPR[175] , DUT.\SCORE.SRF.GPR[174] , DUT.\SCORE.SRF.GPR[173] , DUT.\SCORE.SRF.GPR[172] , DUT.\SCORE.SRF.GPR[171] , DUT.\SCORE.SRF.GPR[170] , DUT.\SCORE.SRF.GPR[169] , DUT.\SCORE.SRF.GPR[168] , DUT.\SCORE.SRF.GPR[167] , DUT.\SCORE.SRF.GPR[166] , DUT.\SCORE.SRF.GPR[165] , DUT.\SCORE.SRF.GPR[164] , DUT.\SCORE.SRF.GPR[163] , DUT.\SCORE.SRF.GPR[162] , DUT.\SCORE.SRF.GPR[161] , DUT.\SCORE.SRF.GPR[160] };
    wire [31:0] gpr27 = {DUT.\SCORE.SRF.GPR[159] , DUT.\SCORE.SRF.GPR[158] , DUT.\SCORE.SRF.GPR[157] , DUT.\SCORE.SRF.GPR[156] , DUT.\SCORE.SRF.GPR[155] , DUT.\SCORE.SRF.GPR[154] , DUT.\SCORE.SRF.GPR[153] , DUT.\SCORE.SRF.GPR[152] , DUT.\SCORE.SRF.GPR[151] , DUT.\SCORE.SRF.GPR[150] , DUT.\SCORE.SRF.GPR[149] , DUT.\SCORE.SRF.GPR[148] , DUT.\SCORE.SRF.GPR[147] , DUT.\SCORE.SRF.GPR[146] , DUT.\SCORE.SRF.GPR[145] , DUT.\SCORE.SRF.GPR[144] , DUT.\SCORE.SRF.GPR[143] , DUT.\SCORE.SRF.GPR[142] , DUT.\SCORE.SRF.GPR[141] , DUT.\SCORE.SRF.GPR[140] , DUT.\SCORE.SRF.GPR[139] , DUT.\SCORE.SRF.GPR[138] , DUT.\SCORE.SRF.GPR[137] , DUT.\SCORE.SRF.GPR[136] , DUT.\SCORE.SRF.GPR[135] , DUT.\SCORE.SRF.GPR[134] , DUT.\SCORE.SRF.GPR[133] , DUT.\SCORE.SRF.GPR[132] , DUT.\SCORE.SRF.GPR[131] , DUT.\SCORE.SRF.GPR[130] , DUT.\SCORE.SRF.GPR[129] , DUT.\SCORE.SRF.GPR[128] };
    wire [31:0] gpr28 = {DUT.\SCORE.SRF.GPR[127] , DUT.\SCORE.SRF.GPR[126] , DUT.\SCORE.SRF.GPR[125] , DUT.\SCORE.SRF.GPR[124] , DUT.\SCORE.SRF.GPR[123] , DUT.\SCORE.SRF.GPR[122] , DUT.\SCORE.SRF.GPR[121] , DUT.\SCORE.SRF.GPR[120] , DUT.\SCORE.SRF.GPR[119] , DUT.\SCORE.SRF.GPR[118] , DUT.\SCORE.SRF.GPR[117] , DUT.\SCORE.SRF.GPR[116] , DUT.\SCORE.SRF.GPR[115] , DUT.\SCORE.SRF.GPR[114] , DUT.\SCORE.SRF.GPR[113] , DUT.\SCORE.SRF.GPR[112] , DUT.\SCORE.SRF.GPR[111] , DUT.\SCORE.SRF.GPR[110] , DUT.\SCORE.SRF.GPR[109] , DUT.\SCORE.SRF.GPR[108] , DUT.\SCORE.SRF.GPR[107] , DUT.\SCORE.SRF.GPR[106] , DUT.\SCORE.SRF.GPR[105] , DUT.\SCORE.SRF.GPR[104] , DUT.\SCORE.SRF.GPR[103] , DUT.\SCORE.SRF.GPR[102] , DUT.\SCORE.SRF.GPR[101] , DUT.\SCORE.SRF.GPR[100] , DUT.\SCORE.SRF.GPR[99] , DUT.\SCORE.SRF.GPR[98] , DUT.\SCORE.SRF.GPR[97] , DUT.\SCORE.SRF.GPR[96] };
    wire [31:0] gpr29 = {DUT.\SCORE.SRF.GPR[95] , DUT.\SCORE.SRF.GPR[94] , DUT.\SCORE.SRF.GPR[93] , DUT.\SCORE.SRF.GPR[92] , DUT.\SCORE.SRF.GPR[91] , DUT.\SCORE.SRF.GPR[90] , DUT.\SCORE.SRF.GPR[89] , DUT.\SCORE.SRF.GPR[88] , DUT.\SCORE.SRF.GPR[87] , DUT.\SCORE.SRF.GPR[86] , DUT.\SCORE.SRF.GPR[85] , DUT.\SCORE.SRF.GPR[84] , DUT.\SCORE.SRF.GPR[83] , DUT.\SCORE.SRF.GPR[82] , DUT.\SCORE.SRF.GPR[81] , DUT.\SCORE.SRF.GPR[80] , DUT.\SCORE.SRF.GPR[79] , DUT.\SCORE.SRF.GPR[78] , DUT.\SCORE.SRF.GPR[77] , DUT.\SCORE.SRF.GPR[76] , DUT.\SCORE.SRF.GPR[75] , DUT.\SCORE.SRF.GPR[74] , DUT.\SCORE.SRF.GPR[73] , DUT.\SCORE.SRF.GPR[72] , DUT.\SCORE.SRF.GPR[71] , DUT.\SCORE.SRF.GPR[70] , DUT.\SCORE.SRF.GPR[69] , DUT.\SCORE.SRF.GPR[68] , DUT.\SCORE.SRF.GPR[67] , DUT.\SCORE.SRF.GPR[66] , DUT.\SCORE.SRF.GPR[65] , DUT.\SCORE.SRF.GPR[64] };
    wire [31:0] gpr30 = {DUT.\SCORE.SRF.GPR[63] , DUT.\SCORE.SRF.GPR[62] , DUT.\SCORE.SRF.GPR[61] , DUT.\SCORE.SRF.GPR[60] , DUT.\SCORE.SRF.GPR[59] , DUT.\SCORE.SRF.GPR[58] , DUT.\SCORE.SRF.GPR[57] , DUT.\SCORE.SRF.GPR[56] , DUT.\SCORE.SRF.GPR[55] , DUT.\SCORE.SRF.GPR[54] , DUT.\SCORE.SRF.GPR[53] , DUT.\SCORE.SRF.GPR[52] , DUT.\SCORE.SRF.GPR[51] , DUT.\SCORE.SRF.GPR[50] , DUT.\SCORE.SRF.GPR[49] , DUT.\SCORE.SRF.GPR[48] , DUT.\SCORE.SRF.GPR[47] , DUT.\SCORE.SRF.GPR[46] , DUT.\SCORE.SRF.GPR[45] , DUT.\SCORE.SRF.GPR[44] , DUT.\SCORE.SRF.GPR[43] , DUT.\SCORE.SRF.GPR[42] , DUT.\SCORE.SRF.GPR[41] , DUT.\SCORE.SRF.GPR[40] , DUT.\SCORE.SRF.GPR[39] , DUT.\SCORE.SRF.GPR[38] , DUT.\SCORE.SRF.GPR[37] , DUT.\SCORE.SRF.GPR[36] , DUT.\SCORE.SRF.GPR[35] , DUT.\SCORE.SRF.GPR[34] , DUT.\SCORE.SRF.GPR[33] , DUT.\SCORE.SRF.GPR[32] };
    wire [31:0] gpr31 = {DUT.\SCORE.SRF.GPR[31] , DUT.\SCORE.SRF.GPR[30] , DUT.\SCORE.SRF.GPR[29] , DUT.\SCORE.SRF.GPR[28] , DUT.\SCORE.SRF.GPR[27] , DUT.\SCORE.SRF.GPR[26] , DUT.\SCORE.SRF.GPR[25] , DUT.\SCORE.SRF.GPR[24] , DUT.\SCORE.SRF.GPR[23] , DUT.\SCORE.SRF.GPR[22] , DUT.\SCORE.SRF.GPR[21] , DUT.\SCORE.SRF.GPR[20] , DUT.\SCORE.SRF.GPR[19] , DUT.\SCORE.SRF.GPR[18] , DUT.\SCORE.SRF.GPR[17] , DUT.\SCORE.SRF.GPR[16] , DUT.\SCORE.SRF.GPR[15] , DUT.\SCORE.SRF.GPR[14] , DUT.\SCORE.SRF.GPR[13] , DUT.\SCORE.SRF.GPR[12] , DUT.\SCORE.SRF.GPR[11] , DUT.\SCORE.SRF.GPR[10] , DUT.\SCORE.SRF.GPR[9] , DUT.\SCORE.SRF.GPR[8] , DUT.\SCORE.SRF.GPR[7] , DUT.\SCORE.SRF.GPR[6] , DUT.\SCORE.SRF.GPR[5] , DUT.\SCORE.SRF.GPR[4] , DUT.\SCORE.SRF.GPR[3] , DUT.\SCORE.SRF.GPR[2] , DUT.\SCORE.SRF.GPR[1] , DUT.\SCORE.SRF.GPR[0] };

endmodule
