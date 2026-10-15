// External memory: aligned 32-bit word address/data with byte strobes.
// A request stays stable until ready; completion must not be repeated while
// the old ready remains asserted. Instruction and data channels are separate.
module MLP_V2_TOP (
`ifdef USE_POWER_PINS
    inout vccd1,vssd1,
`endif
    input logic clk,rstn,
    output logic imem_valid,
    output logic [31:0] imem_addr,
    input logic imem_ready,
    input logic [31:0] imem_rdata,
    output logic dmem_valid,dmem_write,
    output logic [31:0] dmem_addr,dmem_wdata,
    output logic [3:0] dmem_wstrb,
    input logic dmem_ready,dmem_error,
    input logic [31:0] dmem_rdata,
    output logic halted,fault
);
    logic cv,cw,cr,ce,av,aw,ar,ae;
    logic [31:0] ca,cd,cdata,aa,ad,adata;
    logic [3:0] cs,as_;
    logic cmd_valid,cmd_ready;
    logic [2:0] cmd_op;
    logic [31:0] cmd_rs1,cmd_rs2,cmd_result;
    logic compute_busy,transfer_busy;
    logic core_imem_valid,core_imem_ready;
    logic [31:0] core_imem_addr,core_imem_rdata,imem_response;
    // Preserve the existing cache and its SRAM macros without modifying them.
    // Its StWrite cycle consumes the response after ready, so retain that word
    // even if the external responder changes rdata as soon as ready drops.
    always_ff @(posedge clk or negedge rstn) begin
        if(!rstn) imem_response<=0;
        else if(imem_valid && imem_ready) imem_response<=imem_rdata;
    end
    INSTR_CACHE #(.DWidth(32)) ICACHE (
`ifdef USE_POWER_PINS
        .vccd1(vccd1),.vssd1(vssd1),
`endif
        .clk_i(clk),.rst_ni(rstn),.read_i(core_imem_valid),.addr_i(core_imem_addr),
        .imem_rdata_i(imem_ready ? imem_rdata : imem_response),.imem_ready_i(imem_ready),
        .imem_addr_o(imem_addr),.imem_req_o(imem_valid),
        .instr_o(core_imem_rdata),.hit_o(core_imem_ready));
    SCALAR_CORE core(.clk,.rstn,.imem_valid(core_imem_valid),.imem_addr(core_imem_addr),
        .imem_ready(core_imem_ready),.imem_rdata(core_imem_rdata),
        .mem_valid(cv),.mem_write(cw),.mem_addr(ca),.mem_wdata(cd),.mem_wstrb(cs),
        .mem_ready(cr),.mem_error(ce),.mem_rdata(cdata),
        .cmd_valid,.cmd_ready,.cmd_op,.cmd_rs1,.cmd_rs2,.cmd_result,
        .halted,.fault);
    MLP_V2_ACCELERATOR accel(.clk,.rstn,.cmd_valid,.cmd_ready,.cmd_op,.cmd_rs1,.cmd_rs2,.cmd_result,
        .mem_valid(av),.mem_write(aw),.mem_addr(aa),.mem_wdata(ad),.mem_wstrb(as_),
        .mem_ready(ar),.mem_error(ae),.mem_rdata(adata),
        .compute_busy,.transfer_busy,.error_code());

    typedef enum logic [2:0] {IDLE,SPAD,EXTERNAL,RESPONSE,GAP} bus_state_t;
    bus_state_t state;
    logic owner,last_owner,sel,write_q,error_q;
    logic [31:0] addr_q,data_q,response_q,spad_data;
    logic [3:0] strb_q;
    logic spad_en;
    // Round-robin at transaction boundaries. Ownership remains latched until
    // the response is delivered, even if the other requester changes state.
    assign sel=av && (!cv || !last_owner);
    assign spad_en=state==SPAD;
    MLP_V2_SCRATCH_PAD spad(
`ifdef USE_POWER_PINS
        .vccd1(vccd1),.vssd1(vssd1),
`endif
        .clk,.en(spad_en),.write_en(write_q),
        .word_addr(addr_q[11:2]),.wdata(data_q),.wstrb(strb_q),.rdata(spad_data));
    assign dmem_valid=state==EXTERNAL;
    assign dmem_addr=addr_q;
    assign dmem_wdata=data_q;
    assign dmem_wstrb=strb_q;
    assign dmem_write=write_q;
    assign cr=state==RESPONSE && !owner;
    assign ar=state==RESPONSE && owner;
    assign cdata=response_q;
    assign adata=response_q;
    assign ce=error_q;
    assign ae=error_q;
    logic was_spad;
    always_ff @(posedge clk or negedge rstn) begin
        if(!rstn) begin
            state<=IDLE;owner<=0;last_owner<=1;write_q<=0;error_q<=0;
            addr_q<=0;data_q<=0;strb_q<=0;response_q<=0;was_spad<=0;
        end else case(state)
            IDLE:if(cv || av) begin
                owner<=sel;last_owner<=sel;addr_q<=sel ? aa : ca;
                data_q<=sel ? ad : cd;strb_q<=sel ? as_ : cs;write_q<=sel ? aw : cw;
                error_q<=0;
                // Only the scratchpad window is decoded here; as in v1, every
                // other address goes to the data port, which reports errors.
                if((sel ? aa : ca)>=32'h4000 && (sel ? aa : ca)<32'h5000) begin
                    state<=SPAD;was_spad<=1;
                end else begin state<=EXTERNAL;was_spad<=0;end
            end
            SPAD:state<=GAP;
            EXTERNAL:if(dmem_ready) begin
                response_q<=dmem_rdata;error_q<=dmem_error;state<=RESPONSE;
            end
            RESPONSE:begin state<=GAP;was_spad<=0;end
            GAP:begin
                if(was_spad) begin response_q<=spad_data;state<=RESPONSE;end
                else if(!dmem_ready) state<=IDLE;
            end
            default:state<=IDLE;
        endcase
    end
endmodule
