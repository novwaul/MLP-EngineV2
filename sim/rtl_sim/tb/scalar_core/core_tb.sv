////////////////////////////////////////////////////////////////////////////////
// AS501
// Final Project
// Scalar Core Testbench (C++ top wrapper, NumOfTest = 10)
////////////////////////////////////////////////////////////////////////////////
// Copyright (c) 2024 by Smart Energy-Efficient Design Lab. (SEED), KAIST
// All rights reserved.
////////////////////////////////////////////////////////////////////////////////
// The Verilator C++ testbench (sim_main.cpp) drives clk_i, mclk_i, rst_ni;
// this is a structural wrapper around CPU_TOP + MEMORY_TOP. Memory is
// preloaded via $readmemh inside MEMORY_TOP under `ifdef SIM`.
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

    localparam InputAddr     = DMemStart;
    localparam Fc1WAddr      = (InputAddr   + InputSize   * NumOfTest   * 4);
    localparam Fc1BAddr      = (Fc1WAddr    + InputSize   * Hidden1Size * 4);
    localparam Fc1OAddr      = (Fc1BAddr    + Hidden1Size * 4);
    localparam Fc2WAddr      = (Fc1OAddr    + Hidden1Size * 4);
    localparam Fc2BAddr      = (Fc2WAddr    + Hidden1Size * Hidden2Size * 4);
    localparam Fc2OAddr      = (Fc2BAddr    + Hidden2Size * 4);
    localparam Fc3WAddr      = (Fc2OAddr    + Hidden2Size * 4);
    localparam Fc3BAddr      = (Fc3WAddr    + Hidden2Size * OutputSize * 4);
    localparam OutputAddr    = (Fc3BAddr    + OutputSize  * 4);
    localparam LabelAddr     = (OutputAddr  + OutputSize  * 4);

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

    CPU_TOP #(.DWidth(DWidth)) DUT(
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

endmodule
