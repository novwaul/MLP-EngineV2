// Behavioral SV replacements for the sky130_fd_sc_hd primitives.v UDPs,
// usable with Verilator (which doesn't support Verilog 1995 `table`
// syntax). With +define+NO_PRIMITIVES the UDP definitions in primitives.v
// are gated out and these modules fill in.
//
// Edge / polarity / mux-select encodings here mirror the truth tables in
// the upstream primitives.v (DFF $NSR has SET dominant over RESET, $P /
// $PR / $PS rising-edge, dlatches transparent when GATE high, mux_4to2
// selects via {S1,S0}). _pp$PG$N variants delegate to the non-_pp form
// since power-good / NOTIFIER inputs are no-ops in functional sim.

`default_nettype none
`celldefine

// ---------------------------------------------------------------------------
// DFFs
// ---------------------------------------------------------------------------

// Rising-edge CLK_N, async SET (dominates) and async RESET, both active high.
module sky130_fd_sc_hd__udp_dff$NSR #(parameter DELAY = 0) (
    output reg Q,
    input      SET,
    input      RESET,
    input      CLK_N,
    input      D
);
    always @(posedge CLK_N or posedge SET or posedge RESET) begin
        if (SET)        Q <= 1'b1;
        else if (RESET) Q <= 1'b0;
        else            Q <= D;
    end
endmodule

module sky130_fd_sc_hd__udp_dff$NSR_pp$PG$N #(parameter DELAY = 0) (
    output Q,
    input  SET,
    input  RESET,
    input  CLK_N,
    input  D,
    input  NOTIFIER,
    input  VPWR,
    input  VGND
);
    sky130_fd_sc_hd__udp_dff$NSR i (.Q(Q), .SET(SET), .RESET(RESET), .CLK_N(CLK_N), .D(D));
endmodule

// Rising-edge CLK, no async controls.
module sky130_fd_sc_hd__udp_dff$P #(parameter DELAY = 0) (
    output reg Q,
    input      D,
    input      CLK
);
    always @(posedge CLK) Q <= D;
endmodule

module sky130_fd_sc_hd__udp_dff$P_pp$PG$N #(parameter DELAY = 0) (
    output Q,
    input  D,
    input  CLK,
    input  NOTIFIER,
    input  VPWR,
    input  VGND
);
    sky130_fd_sc_hd__udp_dff$P i (.Q(Q), .D(D), .CLK(CLK));
endmodule

// Rising-edge CLK with async RESET (active high).
module sky130_fd_sc_hd__udp_dff$PR #(parameter DELAY = 0) (
    output reg Q,
    input      D,
    input      CLK,
    input      RESET
);
    always @(posedge CLK or posedge RESET) begin
        if (RESET) Q <= 1'b0;
        else       Q <= D;
    end
endmodule

module sky130_fd_sc_hd__udp_dff$PR_pp$PG$N #(parameter DELAY = 0) (
    output Q,
    input  D,
    input  CLK,
    input  RESET,
    input  NOTIFIER,
    input  VPWR,
    input  VGND
);
    sky130_fd_sc_hd__udp_dff$PR i (.Q(Q), .D(D), .CLK(CLK), .RESET(RESET));
endmodule

// Rising-edge CLK with async SET (active high).
module sky130_fd_sc_hd__udp_dff$PS #(parameter DELAY = 0) (
    output reg Q,
    input      D,
    input      CLK,
    input      SET
);
    always @(posedge CLK or posedge SET) begin
        if (SET) Q <= 1'b1;
        else     Q <= D;
    end
endmodule

module sky130_fd_sc_hd__udp_dff$PS_pp$PG$N #(parameter DELAY = 0) (
    output Q,
    input  D,
    input  CLK,
    input  SET,
    input  NOTIFIER,
    input  VPWR,
    input  VGND
);
    sky130_fd_sc_hd__udp_dff$PS i (.Q(Q), .D(D), .CLK(CLK), .SET(SET));
endmodule

// ---------------------------------------------------------------------------
// D-latches: transparent when GATE=1, hold when GATE=0. Upstream tables
// for dlatch$P and dlatch$lP are identical; the variants differ only in
// drive strength which functional sim ignores.
// ---------------------------------------------------------------------------
module sky130_fd_sc_hd__udp_dlatch$P #(parameter DELAY = 0) (
    output reg Q,
    input      D,
    input      GATE
);
    always @* if (GATE) Q = D;
endmodule

module sky130_fd_sc_hd__udp_dlatch$P_pp$PG$N #(parameter DELAY = 0) (
    output Q,
    input  D,
    input  GATE,
    input  NOTIFIER,
    input  VPWR,
    input  VGND
);
    sky130_fd_sc_hd__udp_dlatch$P i (.Q(Q), .D(D), .GATE(GATE));
endmodule

module sky130_fd_sc_hd__udp_dlatch$lP #(parameter DELAY = 0) (
    output reg Q,
    input      D,
    input      GATE
);
    always @* if (GATE) Q = D;
endmodule

module sky130_fd_sc_hd__udp_dlatch$lP_pp$PG$N #(parameter DELAY = 0) (
    output Q,
    input  D,
    input  GATE,
    input  NOTIFIER,
    input  VPWR,
    input  VGND
);
    sky130_fd_sc_hd__udp_dlatch$lP i (.Q(Q), .D(D), .GATE(GATE));
endmodule

// Latch with async RESET (active high).
module sky130_fd_sc_hd__udp_dlatch$PR #(parameter DELAY = 0) (
    output reg Q,
    input      D,
    input      GATE,
    input      RESET
);
    always @* begin
        if (RESET)     Q = 1'b0;
        else if (GATE) Q = D;
    end
endmodule

module sky130_fd_sc_hd__udp_dlatch$PR_pp$PG$N #(parameter DELAY = 0) (
    output Q,
    input  D,
    input  GATE,
    input  RESET,
    input  NOTIFIER,
    input  VPWR,
    input  VGND
);
    sky130_fd_sc_hd__udp_dlatch$PR i (.Q(Q), .D(D), .GATE(GATE), .RESET(RESET));
endmodule

// ---------------------------------------------------------------------------
// MUXes
// ---------------------------------------------------------------------------
module sky130_fd_sc_hd__udp_mux_2to1 #(parameter DELAY = 0) (
    output X,
    input  A0,
    input  A1,
    input  S
);
    assign X = S ? A1 : A0;
endmodule

module sky130_fd_sc_hd__udp_mux_2to1_N #(parameter DELAY = 0) (
    output Y,
    input  A0,
    input  A1,
    input  S
);
    assign Y = ~(S ? A1 : A0);
endmodule

// 4:1 mux selected by {S1, S0}: 00->A0, 01->A1, 10->A2, 11->A3.
module sky130_fd_sc_hd__udp_mux_4to2 #(parameter DELAY = 0) (
    output reg X,
    input      A0,
    input      A1,
    input      A2,
    input      A3,
    input      S0,
    input      S1
);
    always @* begin
        case ({S1, S0})
            2'b00:   X = A0;
            2'b01:   X = A1;
            2'b10:   X = A2;
            default: X = A3;
        endcase
    end
endmodule

// ---------------------------------------------------------------------------
// Power-good cells: pass UDP_IN through (always good in functional sim).
// ---------------------------------------------------------------------------
module sky130_fd_sc_hd__udp_pwrgood$l_pp$G #(parameter DELAY = 0) (
    output UDP_OUT,
    input  UDP_IN,
    input  VGND
);
    assign UDP_OUT = UDP_IN;
endmodule

module sky130_fd_sc_hd__udp_pwrgood$l_pp$PG #(parameter DELAY = 0) (
    output UDP_OUT,
    input  UDP_IN,
    input  VPWR,
    input  VGND
);
    assign UDP_OUT = UDP_IN;
endmodule

module sky130_fd_sc_hd__udp_pwrgood$l_pp$PG$S #(parameter DELAY = 0) (
    output UDP_OUT,
    input  UDP_IN,
    input  VPWR,
    input  VGND,
    input  SLEEP
);
    assign UDP_OUT = UDP_IN;
endmodule

module sky130_fd_sc_hd__udp_pwrgood_pp$G #(parameter DELAY = 0) (
    output UDP_OUT,
    input  UDP_IN,
    input  VGND
);
    assign UDP_OUT = UDP_IN;
endmodule

module sky130_fd_sc_hd__udp_pwrgood_pp$P #(parameter DELAY = 0) (
    output UDP_OUT,
    input  UDP_IN,
    input  VPWR
);
    assign UDP_OUT = UDP_IN;
endmodule

module sky130_fd_sc_hd__udp_pwrgood_pp$PG #(parameter DELAY = 0) (
    output UDP_OUT,
    input  UDP_IN,
    input  VPWR,
    input  VGND
);
    assign UDP_OUT = UDP_IN;
endmodule

`endcelldefine
`default_nettype wire
