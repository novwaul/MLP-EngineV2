////////////////////////////////////////////////////////////////////////////////
// AS501
// Final Project
// MLP Engine v2 Testbench (C++ top wrapper, NumOfTest = 10)
////////////////////////////////////////////////////////////////////////////////
// Copyright (c) 2024 by Smart Energy-Efficient Design Lab. (SEED), KAIST
// All rights reserved.
////////////////////////////////////////////////////////////////////////////////
// The Verilator C++ testbench (sim_main.cpp) drives clk_i, mclk_i, rst_ni;
// this is a structural wrapper around MLP_V2_TOP + MEMORY_TOP. Memory is
// preloaded via $readmemh inside MEMORY_TOP under `ifdef SIM`. MEMORY_TOP
// writes whole words (no byte strobes), so the program only issues word
// stores to external memory.
////////////////////////////////////////////////////////////////////////////////

module CORE_TB #(
    parameter InitFile      = "",
    parameter ImageInitFile = "",
    parameter NumOfTest     = 10
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

    localparam Fc1WInitFile  = "/workspace/program/test_code/parameter/fc1_weight.txt";
    localparam Fc1BInitFile  = "/workspace/program/test_code/parameter/fc1_bias.txt";
    localparam Fc2WInitFile  = "/workspace/program/test_code/parameter/fc2_weight.txt";
    localparam Fc2BInitFile  = "/workspace/program/test_code/parameter/fc2_bias.txt";
    localparam Fc3WInitFile  = "/workspace/program/test_code/parameter/fc3_weight.txt";
    localparam Fc3BInitFile  = "/workspace/program/test_code/parameter/fc3_bias.txt";
    localparam LabelInitFile = "/workspace/program/test_code/label/label.txt";

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

endmodule
