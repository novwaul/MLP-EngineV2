////////////////////////////////////////////////////////////////////////////////
// AS501
// Final Project
// Gate-level (post-PnR) MLP Engine v2 Testbench (NumOfTest = 10)
////////////////////////////////////////////////////////////////////////////////
// Mirrors rtl_sim/tb/mlp_engine/v2/core_tb.sv but instantiates the post-PnR
// MLP_V2_TOP placed netlist (sky130 stdcells + SRAM macros) instead of the RTL
// MLP_V2_TOP. Two placed netlist-specific differences from the RTL TB:
//   1. MLP_V2_TOP adds vccd1/vssd1 supply ports, tied off here.
//   2. After Librelane, the core.SRF.GPR register array becomes
//      individual escaped-id wires (`\core.SRF.GPR[<n>] `). The gpr25..gpr31
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

    MLP_V2_TOP DUT(
        .vccd1                      (vccd1),
        .vssd1                      (vssd1),
        .clk                        (clk_i),
        .rstn                       (rst_ni),

        .imem_valid                 (imem_req),
        .imem_addr                  (imem_addr),
        .imem_ready                 (imem_ready),
        .imem_rdata                 (imem_rdata),

        .dmem_valid                 (dmem_req),
        .dmem_write                 (dmem_write),
        .dmem_addr                  (dmem_addr),
        .dmem_wdata                 (dmem_wdata),
        .dmem_wstrb                 (),
        .dmem_ready                 (dmem_ready),
        .dmem_error                 (1'b0),
        .dmem_rdata                 (dmem_rdata),

        .halted                     (),
        .fault                      ()
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
    // GPR re-assembly. Yosys flattens core.SRF.GPR[0:31] into one escaped
    // identifier per bit, \core.SRF.GPR[<n>] with n = (31-reg)*32 + bit (x0 is
    // constant and optimized away). Each 32-bit register is stitched back
    // together here; the trailing whitespace terminates the escaped id.
    // ------------------------------------------------------------------------
    wire [31:0] gpr25 = {DUT.\core.SRF.GPR[223] , DUT.\core.SRF.GPR[222] , DUT.\core.SRF.GPR[221] , DUT.\core.SRF.GPR[220] , DUT.\core.SRF.GPR[219] , DUT.\core.SRF.GPR[218] , DUT.\core.SRF.GPR[217] , DUT.\core.SRF.GPR[216] , DUT.\core.SRF.GPR[215] , DUT.\core.SRF.GPR[214] , DUT.\core.SRF.GPR[213] , DUT.\core.SRF.GPR[212] , DUT.\core.SRF.GPR[211] , DUT.\core.SRF.GPR[210] , DUT.\core.SRF.GPR[209] , DUT.\core.SRF.GPR[208] , DUT.\core.SRF.GPR[207] , DUT.\core.SRF.GPR[206] , DUT.\core.SRF.GPR[205] , DUT.\core.SRF.GPR[204] , DUT.\core.SRF.GPR[203] , DUT.\core.SRF.GPR[202] , DUT.\core.SRF.GPR[201] , DUT.\core.SRF.GPR[200] , DUT.\core.SRF.GPR[199] , DUT.\core.SRF.GPR[198] , DUT.\core.SRF.GPR[197] , DUT.\core.SRF.GPR[196] , DUT.\core.SRF.GPR[195] , DUT.\core.SRF.GPR[194] , DUT.\core.SRF.GPR[193] , DUT.\core.SRF.GPR[192] };
    wire [31:0] gpr26 = {DUT.\core.SRF.GPR[191] , DUT.\core.SRF.GPR[190] , DUT.\core.SRF.GPR[189] , DUT.\core.SRF.GPR[188] , DUT.\core.SRF.GPR[187] , DUT.\core.SRF.GPR[186] , DUT.\core.SRF.GPR[185] , DUT.\core.SRF.GPR[184] , DUT.\core.SRF.GPR[183] , DUT.\core.SRF.GPR[182] , DUT.\core.SRF.GPR[181] , DUT.\core.SRF.GPR[180] , DUT.\core.SRF.GPR[179] , DUT.\core.SRF.GPR[178] , DUT.\core.SRF.GPR[177] , DUT.\core.SRF.GPR[176] , DUT.\core.SRF.GPR[175] , DUT.\core.SRF.GPR[174] , DUT.\core.SRF.GPR[173] , DUT.\core.SRF.GPR[172] , DUT.\core.SRF.GPR[171] , DUT.\core.SRF.GPR[170] , DUT.\core.SRF.GPR[169] , DUT.\core.SRF.GPR[168] , DUT.\core.SRF.GPR[167] , DUT.\core.SRF.GPR[166] , DUT.\core.SRF.GPR[165] , DUT.\core.SRF.GPR[164] , DUT.\core.SRF.GPR[163] , DUT.\core.SRF.GPR[162] , DUT.\core.SRF.GPR[161] , DUT.\core.SRF.GPR[160] };
    wire [31:0] gpr27 = {DUT.\core.SRF.GPR[159] , DUT.\core.SRF.GPR[158] , DUT.\core.SRF.GPR[157] , DUT.\core.SRF.GPR[156] , DUT.\core.SRF.GPR[155] , DUT.\core.SRF.GPR[154] , DUT.\core.SRF.GPR[153] , DUT.\core.SRF.GPR[152] , DUT.\core.SRF.GPR[151] , DUT.\core.SRF.GPR[150] , DUT.\core.SRF.GPR[149] , DUT.\core.SRF.GPR[148] , DUT.\core.SRF.GPR[147] , DUT.\core.SRF.GPR[146] , DUT.\core.SRF.GPR[145] , DUT.\core.SRF.GPR[144] , DUT.\core.SRF.GPR[143] , DUT.\core.SRF.GPR[142] , DUT.\core.SRF.GPR[141] , DUT.\core.SRF.GPR[140] , DUT.\core.SRF.GPR[139] , DUT.\core.SRF.GPR[138] , DUT.\core.SRF.GPR[137] , DUT.\core.SRF.GPR[136] , DUT.\core.SRF.GPR[135] , DUT.\core.SRF.GPR[134] , DUT.\core.SRF.GPR[133] , DUT.\core.SRF.GPR[132] , DUT.\core.SRF.GPR[131] , DUT.\core.SRF.GPR[130] , DUT.\core.SRF.GPR[129] , DUT.\core.SRF.GPR[128] };
    wire [31:0] gpr28 = {DUT.\core.SRF.GPR[127] , DUT.\core.SRF.GPR[126] , DUT.\core.SRF.GPR[125] , DUT.\core.SRF.GPR[124] , DUT.\core.SRF.GPR[123] , DUT.\core.SRF.GPR[122] , DUT.\core.SRF.GPR[121] , DUT.\core.SRF.GPR[120] , DUT.\core.SRF.GPR[119] , DUT.\core.SRF.GPR[118] , DUT.\core.SRF.GPR[117] , DUT.\core.SRF.GPR[116] , DUT.\core.SRF.GPR[115] , DUT.\core.SRF.GPR[114] , DUT.\core.SRF.GPR[113] , DUT.\core.SRF.GPR[112] , DUT.\core.SRF.GPR[111] , DUT.\core.SRF.GPR[110] , DUT.\core.SRF.GPR[109] , DUT.\core.SRF.GPR[108] , DUT.\core.SRF.GPR[107] , DUT.\core.SRF.GPR[106] , DUT.\core.SRF.GPR[105] , DUT.\core.SRF.GPR[104] , DUT.\core.SRF.GPR[103] , DUT.\core.SRF.GPR[102] , DUT.\core.SRF.GPR[101] , DUT.\core.SRF.GPR[100] , DUT.\core.SRF.GPR[99] , DUT.\core.SRF.GPR[98] , DUT.\core.SRF.GPR[97] , DUT.\core.SRF.GPR[96] };
    wire [31:0] gpr29 = {DUT.\core.SRF.GPR[95] , DUT.\core.SRF.GPR[94] , DUT.\core.SRF.GPR[93] , DUT.\core.SRF.GPR[92] , DUT.\core.SRF.GPR[91] , DUT.\core.SRF.GPR[90] , DUT.\core.SRF.GPR[89] , DUT.\core.SRF.GPR[88] , DUT.\core.SRF.GPR[87] , DUT.\core.SRF.GPR[86] , DUT.\core.SRF.GPR[85] , DUT.\core.SRF.GPR[84] , DUT.\core.SRF.GPR[83] , DUT.\core.SRF.GPR[82] , DUT.\core.SRF.GPR[81] , DUT.\core.SRF.GPR[80] , DUT.\core.SRF.GPR[79] , DUT.\core.SRF.GPR[78] , DUT.\core.SRF.GPR[77] , DUT.\core.SRF.GPR[76] , DUT.\core.SRF.GPR[75] , DUT.\core.SRF.GPR[74] , DUT.\core.SRF.GPR[73] , DUT.\core.SRF.GPR[72] , DUT.\core.SRF.GPR[71] , DUT.\core.SRF.GPR[70] , DUT.\core.SRF.GPR[69] , DUT.\core.SRF.GPR[68] , DUT.\core.SRF.GPR[67] , DUT.\core.SRF.GPR[66] , DUT.\core.SRF.GPR[65] , DUT.\core.SRF.GPR[64] };
    wire [31:0] gpr30 = {DUT.\core.SRF.GPR[63] , DUT.\core.SRF.GPR[62] , DUT.\core.SRF.GPR[61] , DUT.\core.SRF.GPR[60] , DUT.\core.SRF.GPR[59] , DUT.\core.SRF.GPR[58] , DUT.\core.SRF.GPR[57] , DUT.\core.SRF.GPR[56] , DUT.\core.SRF.GPR[55] , DUT.\core.SRF.GPR[54] , DUT.\core.SRF.GPR[53] , DUT.\core.SRF.GPR[52] , DUT.\core.SRF.GPR[51] , DUT.\core.SRF.GPR[50] , DUT.\core.SRF.GPR[49] , DUT.\core.SRF.GPR[48] , DUT.\core.SRF.GPR[47] , DUT.\core.SRF.GPR[46] , DUT.\core.SRF.GPR[45] , DUT.\core.SRF.GPR[44] , DUT.\core.SRF.GPR[43] , DUT.\core.SRF.GPR[42] , DUT.\core.SRF.GPR[41] , DUT.\core.SRF.GPR[40] , DUT.\core.SRF.GPR[39] , DUT.\core.SRF.GPR[38] , DUT.\core.SRF.GPR[37] , DUT.\core.SRF.GPR[36] , DUT.\core.SRF.GPR[35] , DUT.\core.SRF.GPR[34] , DUT.\core.SRF.GPR[33] , DUT.\core.SRF.GPR[32] };
    wire [31:0] gpr31 = {DUT.\core.SRF.GPR[31] , DUT.\core.SRF.GPR[30] , DUT.\core.SRF.GPR[29] , DUT.\core.SRF.GPR[28] , DUT.\core.SRF.GPR[27] , DUT.\core.SRF.GPR[26] , DUT.\core.SRF.GPR[25] , DUT.\core.SRF.GPR[24] , DUT.\core.SRF.GPR[23] , DUT.\core.SRF.GPR[22] , DUT.\core.SRF.GPR[21] , DUT.\core.SRF.GPR[20] , DUT.\core.SRF.GPR[19] , DUT.\core.SRF.GPR[18] , DUT.\core.SRF.GPR[17] , DUT.\core.SRF.GPR[16] , DUT.\core.SRF.GPR[15] , DUT.\core.SRF.GPR[14] , DUT.\core.SRF.GPR[13] , DUT.\core.SRF.GPR[12] , DUT.\core.SRF.GPR[11] , DUT.\core.SRF.GPR[10] , DUT.\core.SRF.GPR[9] , DUT.\core.SRF.GPR[8] , DUT.\core.SRF.GPR[7] , DUT.\core.SRF.GPR[6] , DUT.\core.SRF.GPR[5] , DUT.\core.SRF.GPR[4] , DUT.\core.SRF.GPR[3] , DUT.\core.SRF.GPR[2] , DUT.\core.SRF.GPR[1] , DUT.\core.SRF.GPR[0] };

endmodule
