////////////////////////////////////////////////////////////////////////////////
// AS501
// Final Project
// Scalar Core
////////////////////////////////////////////////////////////////////////////////
// Copyright (c) 2024 by Smart Energy-Efficient Design Lab. (SEED), KAIST
// All rights reserved.
//
//                            Written by Hyungjoon Bae (jo_on@kaist.ac.kr)
//                            Supervised by Wanyeong Jung (wanyeong@kaist.ac.kr)
////////////////////////////////////////////////////////////////////////////////

module SCALAR_CORE #(
    parameter DWidth             = 32,
    localparam NumofReg          = 32,
    localparam AWidth            = $clog2(NumofReg),
    localparam CWidth            = 12,
    localparam OpWidth           = 5
)(
    // Basic signals
    input   logic                   clk,
    input   logic                   rstn,
    // Instruction interface
    input   logic                   imem_ready,
    input   logic   [DWidth-1:0]    imem_rdata,
    output  logic   [DWidth-1:0]    imem_addr,
    output  logic                   imem_valid,
    // Data interface
    input   logic                   mem_ready,
    input   logic   [DWidth-1:0]    mem_rdata,
    output  logic   [DWidth-1:0]    mem_wdata,
    output  logic   [DWidth-1:0]    mem_addr,
    output  logic                   mem_valid,
    output  logic                   mem_write,
    output  logic   [3:0]           mem_wstrb,
    input   logic                   mem_error,
    // Accelerator command interface
    output  logic                   cmd_valid,
    output  logic   [2:0]           cmd_op,
    output  logic   [31:0]          cmd_rs1,
    output  logic   [31:0]          cmd_rs2,
    input   logic                   cmd_ready,
    input   logic   [31:0]          cmd_result,
    // Status
    output  logic                   halted,
    output  logic                   fault
);

////////////////////////////////////////////////////////////////////////////////
// Cycle Counter
    logic   [DWidth*2-1:0]          cycle;

    COUNTER #(.DWidth(DWidth*2), .RValue('0)) COUNTER_CYCLE(
        .clk_i                      (clk),
        .rst_ni                     (rstn),
        .cnt_en_i                   (1'b1),
        .cnt_done_o                 (),
        .cnt_data_o                 (cycle)
    );

////////////////////////////////////////////////////////////////////////////////
// This core is designed in a non-pipelined manner
////////////////////////////////////////////////////////////////////////////////

////////////////////////////////////////////////////////////////////////////////
// Instruction Fetch
    logic   [DWidth-3:0]            inc_iaddr;

    assign inc_iaddr = imem_addr[DWidth-1:2] + {{(DWidth-3){1'b0}}, 1'b1};

    logic   [DWidth-1:0]            branch_addr;
    logic                           dec_br_en;
    logic   [DWidth-1:0]            pc_iaddr_d;

    MUX2TO1 #(.DWidth(DWidth)) MUX_PC(
        .data0_i                    ({inc_iaddr, 2'b0}),
        .data1_i                    (branch_addr),
        .select_i                   (dec_br_en),
        .data_o                     (pc_iaddr_d)
    );

    logic                           dec_pc_en;
    logic   [DWidth-1:0]            pc_iaddr_q;

    D_FF #(.DWidth(DWidth), .RValue('0)) FF_PC (
        .clk_i                      (clk),
        .rst_ni                     (rstn),
        .write_en_i                 (dec_pc_en),
        .write_data_i               (pc_iaddr_d),
        .read_data_o                (pc_iaddr_q)
    );

    logic                           dec_iaddr_en;
    logic   [DWidth-1:0]            ir_addr_q;

    D_FF #(.DWidth(DWidth), .RValue('0)) FF_IADDR(
        .clk_i                      (clk),
        .rst_ni                     (rstn),
        .write_en_i                 (dec_iaddr_en),
        .write_data_i               (pc_iaddr_q),
        .read_data_o                (ir_addr_q)
    );

    assign  imem_addr = pc_iaddr_q;

////////////////////////////////////////////////////////////////////////////////
// Instruction Decode & Register File read & CSR read
    logic   [1:0]                   dec_a_sel;
    logic   [DWidth-1:0]            dec_b_imm;
    logic   [1:0]                   dec_b_sel;
    logic   [OpWidth-1:0]           dec_alu_op_sel;
    logic                           alu_zero;
    logic   [2:0]                   dec_ls_ext_sel;
    logic   [1:0]                   dec_rf_write_sel;
    logic                           dec_br_sel;

    logic   [AWidth-1:0]            dec_read1_addr;
    logic   [AWidth-1:0]            dec_read2_addr;
    logic   [AWidth-1:0]            dec_write_addr;
    logic                           dec_write_en;

    logic                           dec_cwrite_sel;
    logic   [CWidth-1:0]            dec_cread_addr;
    logic   [CWidth-1:0]            dec_cwrite_addr;
    logic                           dec_cwrite_en;

    logic   [DWidth*2-1:0]          dec_instret;

    // Instruction register: the decoder works on the latched instruction
    logic   [31:0]                  instruction;
    logic   [31:0]                  decode_instruction;

    always_ff @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            instruction <= 0;
        end else if (dec_iaddr_en) begin
            instruction <= imem_rdata;
        end
    end

    assign decode_instruction = instruction;

    // Data access fault: misaligned LOAD/STORE or bus error
    logic   [DWidth-1:0]            alu_res;
    logic   [31:0]                  access_addr;
    logic                           access_misaligned;
    logic                           access_fault;

    assign access_addr       = alu_res;
    assign access_misaligned = (instruction[14:12] == 1 || instruction[14:12] == 5) ? access_addr[0] :   // LH/LHU/SH
                               instruction[14:12] == 2 ? |access_addr[1:0] : 1'b0;                       // LW/SW
    assign access_fault      = ((instruction[6:0] == 7'h03 || instruction[6:0] == 7'h23) && access_misaligned) ||
                               (mem_ready && mem_error);

    DECODER #(.DWidth(DWidth), .OpWidth(OpWidth), .NumofReg(NumofReg), .CWidth(CWidth)) DECODER(
        .clk_i                      (clk),
        .rst_ni                     (rstn),
        .pc_en_o                    (dec_pc_en),
        .iaddr_en_o                 (dec_iaddr_en),
        .imem_ready_i               (imem_ready),
        .imem_rdata_i               (decode_instruction),
        .imem_read_o                (imem_valid),
        .br_sel_o                   (dec_br_sel),
        .pc_br_en_o                 (dec_br_en),
        .alu_b_imm_o                (dec_b_imm),
        .alu_a_sel_o                (dec_a_sel),
        .alu_b_sel_o                (dec_b_sel),
        .alu_op_sel_o               (dec_alu_op_sel),
        .flag_zero_i                (alu_zero),
        .ls_ext_sel_o               (dec_ls_ext_sel),
        .rf_write_sel_o             (dec_rf_write_sel),
        .rf_write_addr_o            (dec_write_addr),
        .rf_write_en_o              (dec_write_en),
        .rf_read1_addr_o            (dec_read1_addr),
        .rf_read2_addr_o            (dec_read2_addr),
        .csr_write_sel_o            (dec_cwrite_sel),
        .csr_write_en_o             (dec_cwrite_en),
        .csr_read_addr_o            (dec_cread_addr),
        .csr_write_addr_o           (dec_cwrite_addr),
        .csr_instret_o              (dec_instret),
        .dmem_ready_i               (mem_ready),
        .dmem_req_o                 (mem_valid),
        .dmem_write_o               (mem_write),
        .mem_fault_i                (access_fault),
        .cmd_ready_i                (cmd_ready),
        .cmd_valid_o                (cmd_valid),
        .halted_o                   (halted),
        .fault_o                    (fault)
    );

    logic   [DWidth-1:0]            rf_write_data;
    logic   [DWidth-1:0]            rf_read1_data;
    logic   [DWidth-1:0]            rf_read2_data;

    REGFILE #(.DWidth(DWidth), .NumofReg(NumofReg)) SRF(
        .clk_i                      (clk),
        .rst_ni                     (rstn),
        .read1_addr_i               (dec_read1_addr),
        .read2_addr_i               (dec_read2_addr),
        .write_addr_i               (dec_write_addr),
        .write_data_i               (rf_write_data),
        .write_en_i                 (dec_write_en),
        .read1_data_o               (rf_read1_data),
        .read2_data_o               (rf_read2_data)
    );

    logic   [DWidth-1:0]            csr_write_data;
    logic   [DWidth-1:0]            csr_read_data;

    CSR #(.DWidth(DWidth), .AWidth(CWidth)) CSR(
        .clk_i                      (clk),
        .rst_ni                     (rstn),
        .cycle_i                    (cycle),
        .instret_i                  (dec_instret),
        .read_addr_i                (dec_cread_addr),
        .write_addr_i               (dec_cwrite_addr),
        .write_data_i               (csr_write_data),
        .write_en_i                 (dec_cwrite_en),
        .read_data_o                (csr_read_data)
    );

////////////////////////////////////////////////////////////////////////////////
// Execute & Address calculation
    // Execute
    logic   [DWidth-1:0]            alu_a;
    logic   [DWidth-1:0]            alu_b;

    MUX4TO1 #(.DWidth(DWidth)) MUX_ALU_A(
        .data0_i                    (rf_read1_data),
        .data1_i                    (ir_addr_q),
        .data2_i                    (csr_read_data),
        .data3_i                    (~rf_read1_data),
        .select_i                   (dec_a_sel),
        .data_o                     (alu_a)
    );

    MUX4TO1 #(.DWidth(DWidth)) MUX_ALU_B(
        .data0_i                    (rf_read2_data),
        .data1_i                    (dec_b_imm),
        .data2_i                    (csr_read_data),
        .data3_i                    (~dec_b_imm),
        .select_i                   (dec_b_sel),
        .data_o                     (alu_b)
    );


    ALU #(.DWidth(DWidth), .OpWidth(OpWidth)) ALU(
        .a_i                        (alu_a),
        .b_i                        (alu_b),
        .op_sel_i                   (dec_alu_op_sel),
        .res_o                      (alu_res),
        .zero_o                     (alu_zero)
    );

    // Address calculation
    logic   [DWidth-1:0]            br_inc_pc;

    assign br_inc_pc = dec_b_imm + ir_addr_q;

    MUX2TO1 #(.DWidth(DWidth)) MUX_BR(
        .data0_i                    (alu_res),
        .data1_i                    (br_inc_pc),
        .select_i                   (dec_br_sel),
        .data_o                     (branch_addr)
    );

////////////////////////////////////////////////////////////////////////////////
// Access data memory
    // Address: word-aligned address, byte lanes selected by alu_res[1:0]
    logic   [31:0]                  lane_rdata;
    logic   [31:0]                  store_unshifted;

    assign mem_addr   = {alu_res[31:2], 2'b0};
    assign mem_wstrb  = instruction[14:12] == 0 ? 4'b0001 << alu_res[1:0] :   // SB
                        instruction[14:12] == 1 ? 4'b0011 << alu_res[1:0] :   // SH
                                                  4'b1111;                    // SW
    assign lane_rdata = mem_rdata >> (8 * alu_res[1:0]);
    assign mem_wdata  = store_unshifted << (8 * alu_res[1:0]);

    logic   [DWidth-1:0]            data_rdata;

    // Data read
    MUX5TO1 #(.DWidth(DWidth)) MUX_LD(
        .data0_i                    ({{24{lane_rdata[7]}}, lane_rdata[7:0]}),                  // Load Byte
        .data1_i                    ({{16{lane_rdata[15]}}, lane_rdata[15:0]}),                // Load Halfword
        .data2_i                    (lane_rdata[31:0]),                                         // Load Word
        .data3_i                    ({{24{1'b0}}, lane_rdata[7:0]}),                            // Load Unsigned Byte
        .data4_i                    ({{16{1'b0}}, lane_rdata[15:0]}),                           // Load Unsigned Halfword
        .select_i                   (dec_ls_ext_sel),
        .data_o                     (data_rdata)
    );

    // Data write
    MUX3TO1 #(.DWidth(DWidth)) MUX_ST(
        .data0_i                    ({{24{1'b0}}, rf_read2_data[7:0]}),                            // Store Byte
        .data1_i                    ({{16{1'b0}}, rf_read2_data[15:0]}),                           // Store Halfword
        .data2_i                    (rf_read2_data[31:0]),                                         // Store Word
        .select_i                   (dec_ls_ext_sel[1:0]),
        .data_o                     (store_unshifted)
    );

////////////////////////////////////////////////////////////////////////////////
// Write back
    logic   [DWidth-1:0]            standard_write_data;

    // An accelerator command writes its result instead
    assign rf_write_data = cmd_valid ? cmd_result : standard_write_data;

    MUX4TO1 #(.DWidth(DWidth)) MUX_WB(
        .data0_i                    (alu_res),
        .data1_i                    (data_rdata),
        .data2_i                    ({imem_addr[DWidth-1:2], 2'b0}),
        .data3_i                    (csr_read_data),
        .select_i                   (dec_rf_write_sel),
        .data_o                     (standard_write_data)
    );

    MUX2TO1 #(.DWidth(DWidth)) MUX_WB_CSR(
        .data0_i                    (alu_res),
        .data1_i                    (dec_b_imm),
        .select_i                   (dec_cwrite_sel),
        .data_o                     (csr_write_data)
    );

////////////////////////////////////////////////////////////////////////////////
// Accelerator command
    assign cmd_op  = instruction[14:12];
    assign cmd_rs1 = rf_read1_data;
    assign cmd_rs2 = rf_read2_data;

endmodule
