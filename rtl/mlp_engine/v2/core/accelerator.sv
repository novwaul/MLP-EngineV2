// custom-0: funct3=CFG,LOAD,RUN,STORE,WAIT,STATUS (0..5); funct7=0.
// Command handshake retires once. One transfer and one computation may overlap.
module MLP_V2_ACCELERATOR #(parameter K_TILE=16) (
    input logic clk, rstn,
    input logic cmd_valid,
    input logic [2:0] cmd_op,
    input logic [31:0] cmd_rs1, cmd_rs2,
    output logic cmd_ready,
    output logic [31:0] cmd_result,
    output logic mem_valid, mem_write,
    output logic [31:0] mem_addr, mem_wdata,
    output logic [3:0] mem_wstrb,
    input logic mem_ready, mem_error,
    input logic [31:0] mem_rdata,
    output logic compute_busy, transfer_busy,
    output logic [31:0] error_code
);
    // Configuration: A,W,bias,out bases; A,W,out byte strides; shape.
    // Activations, weights, bias and outputs are all one byte per element.
    logic [31:0] cfg [8];
    typedef enum logic [1:0] {FREE,FILLING,READY,CONSUMING} bank_state_t;
    bank_state_t bank_state [2];
    logic [7:0] abuf [2][4][K_TILE];
    logic signed [7:0] wbuf [2][4][K_TILE];
    logic signed [7:0] bbuf [2][4];
    logic [2:0] bm [2], bn [2];
    logic [7:0] bk [2];
    logic [31:0] bout [2], bostride [2];
    logic [7:0] result_buf [4][4];
    logic result_valid, tile_open;
    logic [2:0] tile_m,tile_n;
    logic [31:0] tile_out,tile_stride;

    // Transfer descriptor is copied on acceptance; later CFG cannot mutate it.
    typedef enum logic [2:0] {D_IDLE,D_BIAS,D_A,D_W,D_STORE} dma_state_t;
    dma_state_t ds;
    logic db;
    logic [31:0] da,dw,dbias,dout,das,dws,dos;
    logic [2:0] dm,dn;
    logic [7:0] dk;
    integer dr,dc,di;
    logic cache_valid;
    logic [31:0] cache_addr,cache_data;
    logic [31:0] elem_addr,read_word,shifted;
    logic read_hit,dma_fire;

    typedef enum logic [1:0] {C_IDLE,C_FEED,C_FINISH} compute_state_t;
    compute_state_t cs;
    logic cb, last_block;
    integer step;
    logic [7:0] ae [4];
    logic signed [7:0] we [4],bias_edge [4];
    logic [3:0] av,wv;
    logic signed [19:0] sums [4][4];
    logic array_overflow,array_init,run_accept;
    wire bank_sel = cmd_rs1[0];
    // Use widened arithmetic to reject wrapping descriptors before any access.
    // The memory map is not checked here: each word is decoded by the bus.
    function automatic logic span_ok(input logic [31:0] base,stride,
                                     input logic [31:0] rows,bytes_per_row);
        logic [63:0] limit;
        limit={32'b0,base}+({32'b0,rows}-1)*{32'b0,stride}+{32'b0,bytes_per_row};
        return rows!=0 && bytes_per_row!=0 && limit<=64'h1_0000_0000;
    endfunction
    wire shape_ok = cfg[7][2:0]>=1 && cfg[7][2:0]<=4 &&
                    cfg[7][6:4]>=1 && cfg[7][6:4]<=4 &&
                    cfg[7][15:8]>=1 && cfg[7][15:8]<=K_TILE &&
                    (cfg[7] & 32'hffff0088)==0;
    wire addresses_ok = span_ok(cfg[0],cfg[4],{29'b0,cfg[7][2:0]},
                                           {24'b0,cfg[7][15:8]}) &&
                        span_ok(cfg[1],cfg[5],{29'b0,cfg[7][6:4]},
                                           {24'b0,cfg[7][15:8]}) &&
                        span_ok(cfg[2],0,1,{29'b0,cfg[7][6:4]}) &&
                        span_ok(cfg[3],cfg[6],{29'b0,cfg[7][2:0]},
                                           {29'b0,cfg[7][6:4]});
    wire continuation_ok = tile_open && bm[bank_sel]==tile_m && bn[bank_sel]==tile_n &&
                           bout[bank_sel]==tile_out && bostride[bank_sel]==tile_stride;
    assign transfer_busy = ds!=D_IDLE;
    assign compute_busy = cs!=C_IDLE;
    always_comb begin
        cmd_ready=1;
        cmd_result={error_code[15:0],10'b0,result_valid,
                    (bank_state[1]==READY),(bank_state[0]==READY),tile_open,
                    compute_busy,transfer_busy};
        case(cmd_op)
            1: cmd_ready=!transfer_busy;
            2: cmd_ready=!compute_busy;
            3: cmd_ready=!transfer_busy && !compute_busy;
            4: cmd_ready=(!(cmd_rs1[0] && transfer_busy) &&
                          !(cmd_rs1[1] && compute_busy));
            default: ;
        endcase
    end
    assign run_accept = cmd_valid && cmd_ready && cmd_op==2 && error_code==0 &&
                        cmd_rs1<2 && (cmd_rs2 & ~32'd3)==0 &&
                        bank_state[bank_sel]==READY && !result_valid &&
                        (cmd_rs2[0] ? !tile_open : continuation_ok);
    assign array_init=run_accept;
    always_comb begin
        av=0; wv=0;
        for(int i=0;i<4;i++) begin
            ae[i]=0; we[i]=0; bias_edge[i]=bbuf[bank_sel][i];
            if(cs==C_FEED && step>=i && step-i<bk[cb]) begin
                if(i<bm[cb]) begin ae[i]=abuf[cb][i][step-i]; av[i]=1; end
                if(i<bn[cb]) begin we[i]=wbuf[cb][i][step-i]; wv[i]=1; end
            end
        end
    end
    MLP_V2_ARRAY array(.clk,.rstn,.init(array_init),.clear_sum(cmd_rs2[0]),
        .advance(cs==C_FEED),.a_edge(ae),.w_edge(we),.a_valid(av),.w_valid(wv),
        .bias(bias_edge),.sums,.overflow(array_overflow));

    always_comb begin
        elem_addr=0;
        case(ds)
            D_BIAS: elem_addr=dbias+dc;
            D_A: elem_addr=da+dr*das+di;
            D_W: elem_addr=dw+dc*dws+di;
            D_STORE: elem_addr=dout+dr*dos+dc;
            default: ;
        endcase
        mem_addr={elem_addr[31:2],2'b0};
        read_hit=cache_valid && cache_addr==mem_addr && ds!=D_STORE;
        mem_valid=transfer_busy && !read_hit;
        mem_write=ds==D_STORE;
        mem_wstrb=mem_write ? (4'b0001 << elem_addr[1:0]) : 4'b0;
        mem_wdata=0;
        if(ds==D_STORE) mem_wdata={24'b0,result_buf[dr][dc]} << (8*elem_addr[1:0]);
        read_word=read_hit ? cache_data : mem_rdata;
        shifted=read_word >> (8*elem_addr[1:0]);
        dma_fire=transfer_busy && (read_hit || mem_ready);
    end

    always_ff @(posedge clk or negedge rstn) begin
        if(!rstn) begin
            ds<=D_IDLE; cs<=C_IDLE; error_code<=0;
            result_valid<=0; tile_open<=0; step<=0;
            db<=0; cb<=0; last_block<=0; cache_valid<=0;
            cache_addr<=0; cache_data<=0;
            da<=0;dw<=0;dbias<=0;dout<=0;das<=0;dws<=0;dos<=0;
            dm<=0;dn<=0;dk<=0;dr<=0;dc<=0;di<=0;
            tile_m<=0;tile_n<=0;tile_out<=0;tile_stride<=0;
            for(int i=0;i<8;i++) cfg[i]<=0;
            for(int b=0;b<2;b++) begin
                bank_state[b]<=FREE;bm[b]<=0;bn[b]<=0;bk[b]<=0;
                bout[b]<=0;bostride[b]<=0;
                for(int c=0;c<4;c++) bbuf[b][c]<=0;
            end
        end else begin
            if(cmd_valid && cmd_ready) begin
                case(cmd_op)
                    0: begin
                        if(cmd_rs1<8) cfg[cmd_rs1]<=cmd_rs2;
                        else error_code<=1;
                    end
                    1: if(error_code==0) begin
                        if(cmd_rs1>=2 || cmd_rs2!=0 || bank_state[bank_sel]!=FREE ||
                           !shape_ok || !addresses_ok) error_code<=2;
                        else begin
                            db<=bank_sel; bank_state[bank_sel]<=FILLING;
                            da<=cfg[0];dw<=cfg[1];dbias<=cfg[2];
                            das<=cfg[4];dws<=cfg[5];
                            dm<=cfg[7][2:0];dn<=cfg[7][6:4];dk<=cfg[7][15:8];
                            bm[bank_sel]<=cfg[7][2:0];bn[bank_sel]<=cfg[7][6:4];
                            bk[bank_sel]<=cfg[7][15:8];
                            bout[bank_sel]<=cfg[3];bostride[bank_sel]<=cfg[6];
                            dc<=0;dr<=0;di<=0;cache_valid<=0;ds<=D_BIAS;
                            for(int c=0;c<4;c++) bbuf[bank_sel][c]<=0;
                        end
                    end
                    2: if(error_code==0) begin
                        if(!run_accept) error_code<=3;
                        else begin
                            cb<=bank_sel;last_block<=cmd_rs2[1];step<=0;cs<=C_FEED;
                            bank_state[bank_sel]<=CONSUMING;
                            if(cmd_rs2[0]) begin
                                tile_open<=1;tile_m<=bm[bank_sel];tile_n<=bn[bank_sel];
                                tile_out<=bout[bank_sel];tile_stride<=bostride[bank_sel];
                            end
                        end
                    end
                    3: if(error_code==0) begin
                        if(!result_valid || cmd_rs1!=0 || cmd_rs2!=0) error_code<=4;
                        else begin
                            ds<=D_STORE;dout<=tile_out;dos<=tile_stride;
                            dm<=tile_m;dn<=tile_n;dr<=0;dc<=0;cache_valid<=0;
                        end
                    end
                    4: if(cmd_rs1>3 || cmd_rs2!=0) error_code<=5;
                    5: if(cmd_rs1!=0 || cmd_rs2!=0) error_code<=5;
                    default: error_code<=1;
                endcase
            end
            if(dma_fire) begin
                if(mem_ready && mem_error && !read_hit) begin
                    error_code<=6;ds<=D_IDLE;
                    if(ds!=D_STORE) bank_state[db]<=FREE;
                end else begin
                    if(!read_hit && ds!=D_STORE) begin
                        cache_valid<=1;cache_addr<=mem_addr;cache_data<=mem_rdata;
                    end
                    case(ds)
                        D_BIAS: begin
                            bbuf[db][dc]<=shifted[7:0];
                            if(dc+1==dn) begin dc<=0;ds<=D_A; end else dc<=dc+1;
                        end
                        D_A: begin
                            abuf[db][dr][di]<=shifted[7:0];
                            if(di+1==dk) begin
                                di<=0;
                                if(dr+1==dm) begin dr<=0;ds<=D_W; end else dr<=dr+1;
                            end else di<=di+1;
                        end
                        D_W: begin
                            wbuf[db][dc][di]<=shifted[7:0];
                            if(di+1==dk) begin
                                di<=0;
                                if(dc+1==dn) begin
                                    dc<=0;ds<=D_IDLE;bank_state[db]<=READY;
                                end else dc<=dc+1;
                            end else di<=di+1;
                        end
                        D_STORE: begin
                            if(dc+1==dn) begin
                                dc<=0;
                                if(dr+1==dm) begin ds<=D_IDLE;result_valid<=0; end
                                else dr<=dr+1;
                            end else dc<=dc+1;
                        end
                        default: ;
                    endcase
                end
            end
            if(cs==C_FEED) begin
                // Last MAC at k-1 + row3 + col3; bubbles mask partial tiles.
                if(step==int'(bk[cb])+5) cs<=C_FINISH;
                else step<=step+1;
            end
            if(cs==C_FINISH) begin
                cs<=C_IDLE;bank_state[cb]<=FREE;
                if(array_overflow) error_code<=7;
                if(last_block) begin
                    tile_open<=0;result_valid<=1;
                    for(int r=0;r<4;r++) for(int c=0;c<4;c++) begin
                        if(r<tile_m && c<tile_n) begin
                            // ReLU, round (sum+128)>>8 and saturate to uint8.
                            result_buf[r][c]<=sums[r][c]<=0 ? 8'd0 :
                                sums[r][c]>=20'sd65408 ? 8'd255 :
                                8'((sums[r][c]+20'sd128)>>>8);
                        end else result_buf[r][c]<=0;
                    end
                end
            end
        end
    end
endmodule
