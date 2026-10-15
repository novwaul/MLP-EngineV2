// 4x4 output-stationary array. Only nearest-neighbour operand connections.
// advance must also freeze the boundary skew scheduler when deasserted.
module MLP_V2_ARRAY (
    input logic clk, rstn, init, clear_sum, advance,
    input logic [7:0] a_edge [4],
    input logic signed [7:0] w_edge [4],
    input logic [3:0] a_valid, w_valid,
    input logic signed [7:0] bias [4],
    output logic signed [19:0] sums [4][4],
    output logic overflow
);
    logic [7:0] a [4][4];
    logic signed [7:0] w [4][4];
    logic av [4][4], wv [4][4];
    logic ov [4][4];
    always_comb begin
        overflow = 0;
        for (int r=0; r<4; r++)
            for (int c=0; c<4; c++) overflow |= ov[r][c];
    end
    for (genvar r=0; r<4; r++) begin: row
        for (genvar c=0; c<4; c++) begin: col
            wire [7:0] ai = c == 0 ? a_edge[r] : a[r][c-1];
            wire signed [7:0] wi = r == 0 ? w_edge[c] : w[r-1][c];
            wire avi = c == 0 ? a_valid[r] : av[r][c-1];
            wire wvi = r == 0 ? w_valid[c] : wv[r-1][c];
            // Explicit unsigned activation extension prevents values >=128
            // from being interpreted as negative. Product fits signed 17 bits.
            wire signed [16:0] product = $signed({1'b0,ai}) * wi;
            wire signed [20:0] total = {sums[r][c][19],sums[r][c]} +
                                      {{4{product[16]}},product};
            always_ff @(posedge clk or negedge rstn) begin
                if (!rstn) begin
                    a[r][c]<=0; w[r][c]<=0; av[r][c]<=0; wv[r][c]<=0;
                    sums[r][c]<=0; ov[r][c]<=0;
                end else if (init) begin
                    av[r][c]<=0; wv[r][c]<=0;
                    if (clear_sum) begin
                        sums[r][c] <= {{12{bias[c][7]}},bias[c]};
                        ov[r][c] <= 0;
                    end
                end else if (advance) begin
                    a[r][c]<=ai; w[r][c]<=wi; av[r][c]<=avi; wv[r][c]<=wvi;
                    if (avi && wvi) begin
                        sums[r][c] <= total[19:0];
                        if (total[20] != total[19]) ov[r][c] <= 1;
                    end
                end
            end
        end
    end
endmodule
