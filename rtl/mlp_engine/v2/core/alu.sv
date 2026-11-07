////////////////////////////////////////////////////////////////////////////////
// AS501
// Final Project
// Arithmetic Logic Unit (ALU)
////////////////////////////////////////////////////////////////////////////////
// Copyright (c) 2024 by Smart Energy-Efficient Design Lab. (SEED), KAIST
// All rights reserved.
//
//                            Written by Hyungjoon Bae (jo_on@kaist.ac.kr)
//                            Supervised by Wanyeong Jung (wanyeong@kaist.ac.kr)
////////////////////////////////////////////////////////////////////////////////

module ALU #(
    parameter DWidth  = 32,
    parameter OpWidth = 5,
    localparam ShWidth = $clog2(DWidth)
)(
    // ALU inputs
    input   logic   [DWidth-1:0]    a_i,
    input   logic   [DWidth-1:0]    b_i,
    input   logic   [OpWidth-1:0]   op_sel_i,
    // ALU outputs
    output  logic   [DWidth-1:0]    res_o,
    output  logic                   zero_o
);

////////////////////////////////////////////////////////////////////////////////
//  Multiplier (portable replacement for DW_dp_mult_comb)
//  a_tc=1 -> a is signed (sign-extend), a_tc=0 -> a is unsigned (zero-extend).
//  Same for b_tc. The lower DWidth*2 bits of the signed product are returned.
////////////////////////////////////////////////////////////////////////////////
    logic                           a_signed;
    logic                           b_signed;
    logic   signed  [DWidth:0]      a_se;
    logic   signed  [DWidth:0]      b_se;
    logic   signed  [2*DWidth+1:0]  mul_full;
    logic           [DWidth*2-1:0]  mul_result;

    assign  a_signed = !(op_sel_i[1] & op_sel_i[0]); // `MULHU=0, others=1
    assign  b_signed = !op_sel_i[1];                 // `MULHU,`MULHSU=0, `MUL,`MULH=1

    assign  a_se     = {a_signed & a_i[DWidth-1], a_i};
    assign  b_se     = {b_signed & b_i[DWidth-1], b_i};
    assign  mul_full = a_se * b_se;
    assign  mul_result = mul_full[2*DWidth-1:0];

////////////////////////////////////////////////////////////////////////////////

    // ALU & Output mux
    always_comb begin
        unique case(op_sel_i)
            `ADD:     res_o = a_i + b_i;
            `SUB:     res_o = a_i - b_i;
            `SLL:     res_o = a_i << b_i[ShWidth-1:0];
            `SLT:     res_o = $signed(a_i) < $signed(b_i);
            `SLTU:    res_o = a_i < b_i;
            `XOR:     res_o = a_i ^ b_i;
            `SRL:     res_o = a_i >> b_i[ShWidth-1:0];
            `SRA:     res_o = $unsigned($signed(a_i) >>> b_i[ShWidth-1:0]);
            `OR:      res_o = a_i | b_i;
            `AND:     res_o = a_i & b_i;
            `MUL:     res_o = mul_result[DWidth-1:0];
            `MULHSU:  res_o = mul_result[DWidth*2-1:DWidth];
            default: res_o = '0;
        endcase
    end

    // Zero flag
    assign  zero_o  = ~(|res_o);

endmodule