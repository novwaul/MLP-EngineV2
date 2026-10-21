////////////////////////////////////////////////////////////////////////////////
// AS501
// Final Project
// MLP Engine v2 CPU Top Module
////////////////////////////////////////////////////////////////////////////////
// External memory: aligned 32-bit word address/data with byte strobes.
// A request stays stable until ready; completion must not be repeated while
// the old ready remains asserted. Instruction and data channels are separate.
////////////////////////////////////////////////////////////////////////////////

module MLP_V2_TOP (
`ifdef USE_POWER_PINS
    inout                           vccd1,
    inout                           vssd1,
`endif
    // Basic signals
    input   logic                   clk,
    input   logic                   rstn,
    // Instruction interface
    output  logic                   imem_valid,
    output  logic   [31:0]          imem_addr,
    input   logic                   imem_ready,
    input   logic   [31:0]          imem_rdata,
    // Data interface
    output  logic                   dmem_valid,
    output  logic                   dmem_write,
    output  logic   [31:0]          dmem_addr,
    output  logic   [31:0]          dmem_wdata,
    output  logic   [3:0]           dmem_wstrb,
    input   logic                   dmem_ready,
    input   logic                   dmem_error,
    input   logic   [31:0]          dmem_rdata,
    // Status
    output  logic                   halted,
    output  logic                   fault
);

////////////////////////////////////////////////////////////////////////////////
// Instruction Cache
    logic                           core_imem_valid;
    logic                           core_imem_ready;
    logic   [31:0]                  core_imem_addr;
    logic   [31:0]                  core_imem_rdata;
    logic   [31:0]                  imem_response;

    // Preserve the existing cache and its SRAM macros without modifying them.
    // Its StWrite cycle consumes the response after ready, so retain that word
    // even if the external responder changes rdata as soon as ready drops.
    always_ff @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            imem_response <= 0;
        end else if (imem_valid && imem_ready) begin
            imem_response <= imem_rdata;
        end
    end

    INSTR_CACHE #(.DWidth(32)) ICACHE (
`ifdef USE_POWER_PINS
        .vccd1                      (vccd1),
        .vssd1                      (vssd1),
`endif
        .clk_i                      (clk),
        .rst_ni                     (rstn),
        .read_i                     (core_imem_valid),
        .addr_i                     (core_imem_addr),
        .imem_rdata_i               (imem_ready ? imem_rdata : imem_response),
        .imem_ready_i               (imem_ready),
        .imem_addr_o                (imem_addr),
        .imem_req_o                 (imem_valid),
        .instr_o                    (core_imem_rdata),
        .hit_o                      (core_imem_ready)
    );

////////////////////////////////////////////////////////////////////////////////
// Scalar Core
    logic                           core_mem_valid;
    logic                           core_mem_write;
    logic   [31:0]                  core_mem_addr;
    logic   [31:0]                  core_mem_wdata;
    logic   [3:0]                   core_mem_wstrb;
    logic                           core_mem_ready;
    logic                           core_mem_error;
    logic   [31:0]                  core_mem_rdata;

    logic                           cmd_valid;
    logic                           cmd_ready;
    logic   [2:0]                   cmd_op;
    logic   [31:0]                  cmd_rs1;
    logic   [31:0]                  cmd_rs2;
    logic   [31:0]                  cmd_result;

    SCALAR_CORE core (
        .clk                        (clk),
        .rstn                       (rstn),
        .imem_valid                 (core_imem_valid),
        .imem_addr                  (core_imem_addr),
        .imem_ready                 (core_imem_ready),
        .imem_rdata                 (core_imem_rdata),
        .mem_valid                  (core_mem_valid),
        .mem_write                  (core_mem_write),
        .mem_addr                   (core_mem_addr),
        .mem_wdata                  (core_mem_wdata),
        .mem_wstrb                  (core_mem_wstrb),
        .mem_ready                  (core_mem_ready),
        .mem_error                  (core_mem_error),
        .mem_rdata                  (core_mem_rdata),
        .cmd_valid                  (cmd_valid),
        .cmd_ready                  (cmd_ready),
        .cmd_op                     (cmd_op),
        .cmd_rs1                    (cmd_rs1),
        .cmd_rs2                    (cmd_rs2),
        .cmd_result                 (cmd_result),
        .halted                     (halted),
        .fault                      (fault)
    );

////////////////////////////////////////////////////////////////////////////////
// Accelerator
    logic                           accel_mem_valid;
    logic                           accel_mem_write;
    logic   [31:0]                  accel_mem_addr;
    logic   [31:0]                  accel_mem_wdata;
    logic   [3:0]                   accel_mem_wstrb;
    logic                           accel_mem_ready;
    logic                           accel_mem_error;
    logic   [31:0]                  accel_mem_rdata;

    logic                           compute_busy;
    logic                           transfer_busy;

    MLP_V2_ACCELERATOR accel (
        .clk                        (clk),
        .rstn                       (rstn),
        .cmd_valid                  (cmd_valid),
        .cmd_ready                  (cmd_ready),
        .cmd_op                     (cmd_op),
        .cmd_rs1                    (cmd_rs1),
        .cmd_rs2                    (cmd_rs2),
        .cmd_result                 (cmd_result),
        .mem_valid                  (accel_mem_valid),
        .mem_write                  (accel_mem_write),
        .mem_addr                   (accel_mem_addr),
        .mem_wdata                  (accel_mem_wdata),
        .mem_wstrb                  (accel_mem_wstrb),
        .mem_ready                  (accel_mem_ready),
        .mem_error                  (accel_mem_error),
        .mem_rdata                  (accel_mem_rdata),
        .compute_busy               (compute_busy),
        .transfer_busy              (transfer_busy),
        .error_code                 ()
    );

////////////////////////////////////////////////////////////////////////////////
// Data Bus Arbiter
    typedef enum logic [2:0] {
        IDLE, SPAD, EXTERNAL, RESPONSE, GAP
    } bus_state_t;

    bus_state_t                     state;
    logic                           owner;
    logic                           last_owner;
    logic                           sel;
    logic                           write_q;
    logic                           error_q;
    logic   [31:0]                  addr_q;
    logic   [31:0]                  data_q;
    logic   [31:0]                  response_q;
    logic   [31:0]                  spad_data;
    logic   [3:0]                   strb_q;
    logic                           spad_en;
    logic                           was_spad;
    logic   [31:0]                  req_addr;

    // Round-robin at transaction boundaries. Ownership remains latched until
    // the response is delivered, even if the other requester changes state.
    assign sel      = accel_mem_valid && (!core_mem_valid || !last_owner);
    assign req_addr = sel ? accel_mem_addr : core_mem_addr;
    assign spad_en  = state == SPAD;

    MLP_V2_SCRATCH_PAD spad (
`ifdef USE_POWER_PINS
        .vccd1                      (vccd1),
        .vssd1                      (vssd1),
`endif
        .clk                        (clk),
        .en                         (spad_en),
        .write_en                   (write_q),
        .word_addr                  (addr_q[11:2]),
        .wdata                      (data_q),
        .wstrb                      (strb_q),
        .rdata                      (spad_data)
    );

    assign dmem_valid      = state == EXTERNAL;
    assign dmem_addr       = addr_q;
    assign dmem_wdata      = data_q;
    assign dmem_wstrb      = strb_q;
    assign dmem_write      = write_q;

    assign core_mem_ready  = state == RESPONSE && !owner;
    assign accel_mem_ready = state == RESPONSE && owner;
    assign core_mem_rdata  = response_q;
    assign accel_mem_rdata = response_q;
    assign core_mem_error  = error_q;
    assign accel_mem_error = error_q;

    always_ff @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            state      <= IDLE;
            owner      <= 0;
            last_owner <= 1;
            write_q    <= 0;
            error_q    <= 0;
            addr_q     <= 0;
            data_q     <= 0;
            strb_q     <= 0;
            response_q <= 0;
            was_spad   <= 0;
        end else begin
            case (state)
                IDLE: begin
                    if (core_mem_valid || accel_mem_valid) begin
                        owner      <= sel;
                        last_owner <= sel;
                        addr_q     <= req_addr;
                        data_q     <= sel ? accel_mem_wdata : core_mem_wdata;
                        strb_q     <= sel ? accel_mem_wstrb : core_mem_wstrb;
                        write_q    <= sel ? accel_mem_write : core_mem_write;
                        error_q    <= 0;
                        // Only the scratchpad window is decoded here; as in v1, every
                        // other address goes to the data port, which reports errors.
                        if (req_addr >= 32'h4000 && req_addr < 32'h5000) begin
                            state    <= SPAD;
                            was_spad <= 1;
                        end else begin
                            state    <= EXTERNAL;
                            was_spad <= 0;
                        end
                    end
                end
                SPAD: begin
                    state <= GAP;
                end
                EXTERNAL: begin
                    if (dmem_ready) begin
                        response_q <= dmem_rdata;
                        error_q    <= dmem_error;
                        state      <= RESPONSE;
                    end
                end
                RESPONSE: begin
                    state    <= GAP;
                    was_spad <= 0;
                end
                GAP: begin
                    if (was_spad) begin
                        response_q <= spad_data;
                        state      <= RESPONSE;
                    end else if (!dmem_ready) begin
                        state <= IDLE;
                    end
                end
                default: begin
                    state <= IDLE;
                end
            endcase
        end
    end

endmodule
