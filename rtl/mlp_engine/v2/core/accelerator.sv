////////////////////////////////////////////////////////////////////////////////
// AS501
// Final Project
// MLP Engine v2 Accelerator
////////////////////////////////////////////////////////////////////////////////
// custom-0: funct3=CFG,LOAD,RUN,STORE,WAIT,STATUS (0..5); funct7=0.
// Command handshake retires once. One transfer and one computation may overlap.
////////////////////////////////////////////////////////////////////////////////

module MLP_V2_ACCELERATOR #(
    parameter K_TILE                = 16
)(
    // Basic signals
    input   logic                   clk,
    input   logic                   rstn,
    // Command interface
    input   logic                   cmd_valid,
    input   logic   [2:0]           cmd_op,
    input   logic   [31:0]          cmd_rs1,
    input   logic   [31:0]          cmd_rs2,
    output  logic                   cmd_ready,
    output  logic   [31:0]          cmd_result,
    // Memory interface
    output  logic                   mem_valid,
    output  logic                   mem_write,
    output  logic   [31:0]          mem_addr,
    output  logic   [31:0]          mem_wdata,
    output  logic   [3:0]           mem_wstrb,
    input   logic                   mem_ready,
    input   logic                   mem_error,
    input   logic   [31:0]          mem_rdata,
    // Status
    output  logic                   compute_busy,
    output  logic                   transfer_busy,
    output  logic   [31:0]          error_code
);

    // Commands (funct3)
    localparam      CMD_CFG         = 0;
    localparam      CMD_LOAD        = 1;
    localparam      CMD_RUN         = 2;
    localparam      CMD_STORE       = 3;
    localparam      CMD_WAIT        = 4;
    localparam      CMD_STATUS      = 5;

    // Error codes (sticky)
    localparam      ERR_COMMAND     = 1;
    localparam      ERR_LOAD        = 2;
    localparam      ERR_RUN         = 3;
    localparam      ERR_STORE       = 4;
    localparam      ERR_ARGUMENT    = 5;
    localparam      ERR_BUS         = 6;
    localparam      ERR_OVERFLOW    = 7;

    // Configuration registers (cfg index)
    localparam      CFG_A           = 0;
    localparam      CFG_W           = 1;
    localparam      CFG_BIAS        = 2;
    localparam      CFG_OUT         = 3;
    localparam      CFG_A_STRIDE    = 4;
    localparam      CFG_W_STRIDE    = 5;
    localparam      CFG_OUT_STRIDE  = 6;
    localparam      CFG_SHAPE       = 7;

////////////////////////////////////////////////////////////////////////////////
// Configuration & Operand Banks
    // Configuration: A,W,bias,out bases; A,W,out byte strides; shape.
    // Activations, weights, bias and outputs are all one byte per element.
    logic   [31:0]                  cfg             [8];

    typedef enum logic [1:0] {
        FREE, FILLING, READY, CONSUMING
    } bank_state_t;

    bank_state_t                    bank_state      [2];
    logic          [7:0]            abuf            [2][4][K_TILE];
    logic signed   [7:0]            wbuf            [2][4][K_TILE];
    logic signed   [7:0]            bbuf            [2][4];
    logic   [2:0]                   bank_m          [2];
    logic   [2:0]                   bank_n          [2];
    logic   [7:0]                   bank_k          [2];
    logic   [31:0]                  bank_out        [2];
    logic   [31:0]                  bank_out_stride [2];

    // Output tile
    logic   [7:0]                   result_buf      [4][4];
    logic                           result_valid;
    logic                           tile_open;
    logic   [2:0]                   tile_m;
    logic   [2:0]                   tile_n;
    logic   [31:0]                  tile_out;
    logic   [31:0]                  tile_stride;

////////////////////////////////////////////////////////////////////////////////
// Transfer (DMA) State
    // Transfer descriptor is copied on acceptance; later CFG cannot mutate it.
    typedef enum logic [2:0] {
        D_IDLE, D_BIAS, D_A, D_W, D_STORE
    } dma_state_t;

    dma_state_t                     dma_state;
    logic                           dma_bank;
    logic   [31:0]                  dma_a_addr;
    logic   [31:0]                  dma_w_addr;
    logic   [31:0]                  dma_bias_addr;
    logic   [31:0]                  dma_out_addr;
    logic   [31:0]                  dma_a_stride;
    logic   [31:0]                  dma_w_stride;
    logic   [31:0]                  dma_out_stride;
    logic   [2:0]                   dma_m;
    logic   [2:0]                   dma_n;
    logic   [7:0]                   dma_k;
    integer                         dma_row;
    integer                         dma_col;
    integer                         dma_idx;

    // One-word read cache: consecutive bytes of a word need one bus access.
    logic                           cache_valid;
    logic   [31:0]                  cache_addr;
    logic   [31:0]                  cache_data;

    logic   [31:0]                  elem_addr;
    logic   [31:0]                  read_word;
    logic   [31:0]                  shifted;
    logic                           read_hit;
    logic                           dma_fire;

////////////////////////////////////////////////////////////////////////////////
// Compute State
    typedef enum logic [1:0] {
        C_IDLE, C_FEED, C_FINISH
    } compute_state_t;

    compute_state_t                 compute_state;
    logic                           compute_bank;
    logic                           last_block;
    integer                         step;

    logic          [7:0]            a_edge          [4];
    logic signed   [7:0]            w_edge          [4];
    logic signed   [7:0]            bias_edge       [4];
    logic   [3:0]                   a_edge_valid;
    logic   [3:0]                   w_edge_valid;
    logic signed   [19:0]           sums            [4][4];
    logic                           array_overflow;
    logic                           array_init;
    logic                           run_accept;

    wire                            bank_sel = cmd_rs1[0];

////////////////////////////////////////////////////////////////////////////////
// Command Checks
    // Use widened arithmetic to reject wrapping descriptors before any access.
    // The memory map is not checked here: each word is decoded by the bus.
    function automatic logic span_ok(input logic [31:0] base, stride,
                                     input logic [31:0] rows, bytes_per_row);
        logic [63:0] limit;
        limit = {32'b0, base} + ({32'b0, rows} - 1) * {32'b0, stride} + {32'b0, bytes_per_row};
        return rows != 0 && bytes_per_row != 0 && limit <= 64'h1_0000_0000;
    endfunction

    // Shape: m = cfg[7][2:0], n = cfg[7][6:4], k = cfg[7][15:8].
    wire                            shape_ok        = cfg[CFG_SHAPE][2:0] >= 1 && cfg[CFG_SHAPE][2:0] <= 4 &&
                                                      cfg[CFG_SHAPE][6:4] >= 1 && cfg[CFG_SHAPE][6:4] <= 4 &&
                                                      cfg[CFG_SHAPE][15:8] >= 1 && cfg[CFG_SHAPE][15:8] <= K_TILE &&
                                                      (cfg[CFG_SHAPE] & 32'hffff0088) == 0;

    wire                            addresses_ok    = span_ok(cfg[CFG_A], cfg[CFG_A_STRIDE],
                                                              {29'b0, cfg[CFG_SHAPE][2:0]}, {24'b0, cfg[CFG_SHAPE][15:8]}) &&
                                                      span_ok(cfg[CFG_W], cfg[CFG_W_STRIDE],
                                                              {29'b0, cfg[CFG_SHAPE][6:4]}, {24'b0, cfg[CFG_SHAPE][15:8]}) &&
                                                      span_ok(cfg[CFG_BIAS], 0, 1, {29'b0, cfg[CFG_SHAPE][6:4]}) &&
                                                      span_ok(cfg[CFG_OUT], cfg[CFG_OUT_STRIDE],
                                                              {29'b0, cfg[CFG_SHAPE][2:0]}, {29'b0, cfg[CFG_SHAPE][6:4]});

    // A non-first RUN must continue the output tile that is already open.
    wire                            continuation_ok = tile_open &&
                                                      bank_m[bank_sel] == tile_m &&
                                                      bank_n[bank_sel] == tile_n &&
                                                      bank_out[bank_sel] == tile_out &&
                                                      bank_out_stride[bank_sel] == tile_stride;

    assign transfer_busy = dma_state != D_IDLE;
    assign compute_busy  = compute_state != C_IDLE;

////////////////////////////////////////////////////////////////////////////////
// Command Handshake & Status
    always_comb begin
        cmd_ready  = 1;
        cmd_result = {error_code[15:0], 10'b0, result_valid,
                      (bank_state[1] == READY), (bank_state[0] == READY), tile_open,
                      compute_busy, transfer_busy};
        case (cmd_op)
            CMD_LOAD:  cmd_ready = !transfer_busy;
            CMD_RUN:   cmd_ready = !compute_busy;
            CMD_STORE: cmd_ready = !transfer_busy && !compute_busy;
            CMD_WAIT:  cmd_ready = (!(cmd_rs1[0] && transfer_busy) &&
                                    !(cmd_rs1[1] && compute_busy));
            default: ;
        endcase
    end

    assign run_accept = cmd_valid && cmd_ready && cmd_op == CMD_RUN && error_code == 0 &&
                        cmd_rs1 < 2 && (cmd_rs2 & ~32'd3) == 0 &&
                        bank_state[bank_sel] == READY && !result_valid &&
                        (cmd_rs2[0] ? !tile_open : continuation_ok);

    assign array_init = run_accept;

////////////////////////////////////////////////////////////////////////////////
// Systolic Array
    // Skew the operands: row/column i starts i steps late; bubbles mask
    // partial tiles.
    always_comb begin
        a_edge_valid = 0;
        w_edge_valid = 0;
        for (int i = 0; i < 4; i++) begin
            a_edge[i]    = 0;
            w_edge[i]    = 0;
            bias_edge[i] = bbuf[bank_sel][i];
            if (compute_state == C_FEED && step >= i && step - i < bank_k[compute_bank]) begin
                if (i < bank_m[compute_bank]) begin
                    a_edge[i]       = abuf[compute_bank][i][step-i];
                    a_edge_valid[i] = 1;
                end
                if (i < bank_n[compute_bank]) begin
                    w_edge[i]       = wbuf[compute_bank][i][step-i];
                    w_edge_valid[i] = 1;
                end
            end
        end
    end

    MLP_V2_ARRAY array (
        .clk                        (clk),
        .rstn                       (rstn),
        .init                       (array_init),
        .clear_sum                  (cmd_rs2[0]),
        .advance                    (compute_state == C_FEED),
        .a_edge                     (a_edge),
        .w_edge                     (w_edge),
        .a_valid                    (a_edge_valid),
        .w_valid                    (w_edge_valid),
        .bias                       (bias_edge),
        .sums                       (sums),
        .overflow                   (array_overflow)
    );

////////////////////////////////////////////////////////////////////////////////
// Memory Access
    always_comb begin
        elem_addr = 0;
        case (dma_state)
            D_BIAS:  elem_addr = dma_bias_addr + dma_col;
            D_A:     elem_addr = dma_a_addr + dma_row * dma_a_stride + dma_idx;
            D_W:     elem_addr = dma_w_addr + dma_col * dma_w_stride + dma_idx;
            D_STORE: elem_addr = dma_out_addr + dma_row * dma_out_stride + dma_col;
            default: ;
        endcase

        mem_addr  = {elem_addr[31:2], 2'b0};
        read_hit  = cache_valid && cache_addr == mem_addr && dma_state != D_STORE;
        mem_valid = transfer_busy && !read_hit;
        mem_write = dma_state == D_STORE;
        mem_wstrb = mem_write ? (4'b0001 << elem_addr[1:0]) : 4'b0;
        mem_wdata = 0;
        if (dma_state == D_STORE) mem_wdata = {24'b0, result_buf[dma_row][dma_col]} << (8 * elem_addr[1:0]);

        read_word = read_hit ? cache_data : mem_rdata;
        shifted   = read_word >> (8 * elem_addr[1:0]);
        dma_fire  = transfer_busy && (read_hit || mem_ready);
    end

////////////////////////////////////////////////////////////////////////////////
// Control
    always_ff @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            dma_state      <= D_IDLE;
            compute_state  <= C_IDLE;
            error_code     <= 0;
            result_valid   <= 0;
            tile_open      <= 0;
            step           <= 0;
            dma_bank       <= 0;
            compute_bank   <= 0;
            last_block     <= 0;
            cache_valid    <= 0;
            cache_addr     <= 0;
            cache_data     <= 0;
            dma_a_addr     <= 0;
            dma_w_addr     <= 0;
            dma_bias_addr  <= 0;
            dma_out_addr   <= 0;
            dma_a_stride   <= 0;
            dma_w_stride   <= 0;
            dma_out_stride <= 0;
            dma_m          <= 0;
            dma_n          <= 0;
            dma_k          <= 0;
            dma_row        <= 0;
            dma_col        <= 0;
            dma_idx        <= 0;
            tile_m         <= 0;
            tile_n         <= 0;
            tile_out       <= 0;
            tile_stride    <= 0;
            for (int i = 0; i < 8; i++) cfg[i] <= 0;
            for (int b = 0; b < 2; b++) begin
                bank_state[b]      <= FREE;
                bank_m[b]          <= 0;
                bank_n[b]          <= 0;
                bank_k[b]          <= 0;
                bank_out[b]        <= 0;
                bank_out_stride[b] <= 0;
                for (int c = 0; c < 4; c++) bbuf[b][c] <= 0;
            end
        end else begin
            ////////////////////////////////////////////////////////////////////
            // Commands
            if (cmd_valid && cmd_ready) begin
                case (cmd_op)
                    CMD_CFG: begin
                        if (cmd_rs1 < 8) cfg[cmd_rs1] <= cmd_rs2;
                        else error_code <= ERR_COMMAND;
                    end
                    CMD_LOAD: begin
                        if (error_code == 0) begin
                            if (cmd_rs1 >= 2 || cmd_rs2 != 0 || bank_state[bank_sel] != FREE ||
                                !shape_ok || !addresses_ok) begin
                                error_code <= ERR_LOAD;
                            end else begin
                                dma_bank                  <= bank_sel;
                                bank_state[bank_sel]      <= FILLING;
                                dma_a_addr                <= cfg[CFG_A];
                                dma_w_addr                <= cfg[CFG_W];
                                dma_bias_addr             <= cfg[CFG_BIAS];
                                dma_a_stride              <= cfg[CFG_A_STRIDE];
                                dma_w_stride              <= cfg[CFG_W_STRIDE];
                                dma_m                     <= cfg[CFG_SHAPE][2:0];
                                dma_n                     <= cfg[CFG_SHAPE][6:4];
                                dma_k                     <= cfg[CFG_SHAPE][15:8];
                                bank_m[bank_sel]          <= cfg[CFG_SHAPE][2:0];
                                bank_n[bank_sel]          <= cfg[CFG_SHAPE][6:4];
                                bank_k[bank_sel]          <= cfg[CFG_SHAPE][15:8];
                                bank_out[bank_sel]        <= cfg[CFG_OUT];
                                bank_out_stride[bank_sel] <= cfg[CFG_OUT_STRIDE];
                                dma_col                   <= 0;
                                dma_row                   <= 0;
                                dma_idx                   <= 0;
                                cache_valid               <= 0;
                                dma_state                 <= D_BIAS;
                                for (int c = 0; c < 4; c++) bbuf[bank_sel][c] <= 0;
                            end
                        end
                    end
                    CMD_RUN: begin
                        if (error_code == 0) begin
                            if (!run_accept) begin
                                error_code <= ERR_RUN;
                            end else begin
                                compute_bank         <= bank_sel;
                                last_block           <= cmd_rs2[1];
                                step                 <= 0;
                                compute_state        <= C_FEED;
                                bank_state[bank_sel] <= CONSUMING;
                                if (cmd_rs2[0]) begin
                                    tile_open   <= 1;
                                    tile_m      <= bank_m[bank_sel];
                                    tile_n      <= bank_n[bank_sel];
                                    tile_out    <= bank_out[bank_sel];
                                    tile_stride <= bank_out_stride[bank_sel];
                                end
                            end
                        end
                    end
                    CMD_STORE: begin
                        if (error_code == 0) begin
                            if (!result_valid || cmd_rs1 != 0 || cmd_rs2 != 0) begin
                                error_code <= ERR_STORE;
                            end else begin
                                dma_state      <= D_STORE;
                                dma_out_addr   <= tile_out;
                                dma_out_stride <= tile_stride;
                                dma_m          <= tile_m;
                                dma_n          <= tile_n;
                                dma_row        <= 0;
                                dma_col        <= 0;
                                cache_valid    <= 0;
                            end
                        end
                    end
                    CMD_WAIT: begin
                        if (cmd_rs1 > 3 || cmd_rs2 != 0) error_code <= ERR_ARGUMENT;
                    end
                    CMD_STATUS: begin
                        if (cmd_rs1 != 0 || cmd_rs2 != 0) error_code <= ERR_ARGUMENT;
                    end
                    default: begin
                        error_code <= ERR_COMMAND;
                    end
                endcase
            end

            ////////////////////////////////////////////////////////////////////
            // Transfer
            if (dma_fire) begin
                if (mem_ready && mem_error && !read_hit) begin
                    error_code <= ERR_BUS;
                    dma_state  <= D_IDLE;
                    if (dma_state != D_STORE) bank_state[dma_bank] <= FREE;
                end else begin
                    if (!read_hit && dma_state != D_STORE) begin
                        cache_valid <= 1;
                        cache_addr  <= mem_addr;
                        cache_data  <= mem_rdata;
                    end
                    case (dma_state)
                        D_BIAS: begin
                            bbuf[dma_bank][dma_col] <= shifted[7:0];
                            if (dma_col + 1 == dma_n) begin
                                dma_col   <= 0;
                                dma_state <= D_A;
                            end else begin
                                dma_col <= dma_col + 1;
                            end
                        end
                        D_A: begin
                            abuf[dma_bank][dma_row][dma_idx] <= shifted[7:0];
                            if (dma_idx + 1 == dma_k) begin
                                dma_idx <= 0;
                                if (dma_row + 1 == dma_m) begin
                                    dma_row   <= 0;
                                    dma_state <= D_W;
                                end else begin
                                    dma_row <= dma_row + 1;
                                end
                            end else begin
                                dma_idx <= dma_idx + 1;
                            end
                        end
                        D_W: begin
                            wbuf[dma_bank][dma_col][dma_idx] <= shifted[7:0];
                            if (dma_idx + 1 == dma_k) begin
                                dma_idx <= 0;
                                if (dma_col + 1 == dma_n) begin
                                    dma_col              <= 0;
                                    dma_state            <= D_IDLE;
                                    bank_state[dma_bank] <= READY;
                                end else begin
                                    dma_col <= dma_col + 1;
                                end
                            end else begin
                                dma_idx <= dma_idx + 1;
                            end
                        end
                        D_STORE: begin
                            if (dma_col + 1 == dma_n) begin
                                dma_col <= 0;
                                if (dma_row + 1 == dma_m) begin
                                    dma_state    <= D_IDLE;
                                    result_valid <= 0;
                                end else begin
                                    dma_row <= dma_row + 1;
                                end
                            end else begin
                                dma_col <= dma_col + 1;
                            end
                        end
                        default: ;
                    endcase
                end
            end

            ////////////////////////////////////////////////////////////////////
            // Compute
            if (compute_state == C_FEED) begin
                // Last MAC at k-1 + row3 + col3; bubbles mask partial tiles.
                if (step == int'(bank_k[compute_bank]) + 5) compute_state <= C_FINISH;
                else step <= step + 1;
            end
            if (compute_state == C_FINISH) begin
                compute_state            <= C_IDLE;
                bank_state[compute_bank] <= FREE;
                if (array_overflow) error_code <= ERR_OVERFLOW;
                if (last_block) begin
                    tile_open    <= 0;
                    result_valid <= 1;
                    for (int r = 0; r < 4; r++) begin
                        for (int c = 0; c < 4; c++) begin
                            if (r < tile_m && c < tile_n) begin
                                // ReLU, round (sum+128)>>8 and saturate to uint8.
                                result_buf[r][c] <= sums[r][c] <= 0 ? 8'd0 :
                                                    sums[r][c] >= 20'sd65408 ? 8'd255 :
                                                    8'((sums[r][c] + 20'sd128) >>> 8);
                            end else begin
                                result_buf[r][c] <= 0;
                            end
                        end
                    end
                end
            end
        end
    end

endmodule
