`timescale 1ns / 1ps

`include "defines.vh"

module ICache (
    input  wire         cpu_rstn,       // low active
    input  wire         cpu_clk,

    // Interface to CPU
    input  wire         inst_rreq,
    output wire         inst_ready,
    input  wire [31:0]  inst_addr,
    input  wire         inst_cacheable,
    input  wire         inst_dual,
    output reg          inst_valid,
    output reg  [31:0]  inst_out,
    output reg          inst1_valid,
    output reg  [31:0]  inst1_out,
    input  wire         pred_error,

    // Interface to Read Bus
    input  wire         dev_rrdy,
    output reg  [ 3:0]  cpu_ren,
    output reg  [31:0]  cpu_raddr,
    input  wire         dev_rvalid,
    input  wire [31:0]  dev_rdata,

    input  wire         maint_valid,
    output wire         maint_ready,
    output reg          maint_done,
    input  wire         maint_all,
    input  wire [1:0]   maint_mode,
    input  wire [31:0]  maint_addr,
    input  wire [31:0]  maint_ctag
);

`ifdef ENABLE_ICACHE

    localparam INDEX_WID  = $clog2(`CACHE_BLK_NUM);
    localparam OFFSET_WID = $clog2(`CACHE_BLK_LEN) + 2;
    localparam TAG_WID    = 32 - INDEX_WID - OFFSET_WID;
    localparam BLK_WID    = `CACHE_BLK_SIZE + TAG_WID + 1;

    localparam IDLE    = 4'b0001;
    localparam TAG_CHK = 4'b0010;
    localparam RD_MEM  = 4'b0100;
    localparam REFILL  = 4'b1000;

    reg [3:0] current_state;
    reg [3:0] next_state;

    // Four-entry decoupling queue.  It lets the frontend continue producing
    // predicted fetch packets while a cache miss is being refilled.  The
    // cache core consumes requests strictly in order, so response metadata can
    // be tracked by an equally ordered FIFO in IF_stage without transaction IDs.
    localparam REQ_DEPTH = 4;
    localparam REQ_PTR_W = 2;
    reg [31:0] req_addr_q      [REQ_DEPTH-1:0];
    reg        req_cacheable_q [REQ_DEPTH-1:0];
    reg        req_dual_q      [REQ_DEPTH-1:0];
    reg [REQ_PTR_W-1:0] req_rptr;
    reg [REQ_PTR_W-1:0] req_wptr;
    reg [REQ_PTR_W:0]   req_count;
    wire        core_req_ready;
    wire        req_pop             = core_req_ready && (req_count != 0) && !pred_error;
    wire        req_push            = inst_rreq && inst_ready;
    wire        core_inst_rreq      = req_pop;
    wire [31:0] core_inst_addr      = req_addr_q[req_rptr];
    wire        core_inst_cacheable = req_cacheable_q[req_rptr];
    wire        core_inst_dual      = req_dual_q[req_rptr];

    assign inst_ready = cpu_rstn && !pred_error &&
                        ((req_count < REQ_DEPTH) || req_pop);

    always @(posedge cpu_clk or negedge cpu_rstn) begin
        if (!cpu_rstn) begin
            req_rptr  <= {REQ_PTR_W{1'b0}};
            req_wptr  <= {REQ_PTR_W{1'b0}};
            req_count <= {(REQ_PTR_W+1){1'b0}};
        end else if (pred_error) begin
            req_rptr  <= {REQ_PTR_W{1'b0}};
            req_wptr  <= {REQ_PTR_W{1'b0}};
            req_count <= {(REQ_PTR_W+1){1'b0}};
        end else begin
            if (req_push) begin
                req_addr_q[req_wptr]      <= inst_addr;
                req_cacheable_q[req_wptr] <= inst_cacheable;
                req_dual_q[req_wptr]      <= inst_dual;
                req_wptr                  <= req_wptr + 1'b1;
            end
            if (req_pop)
                req_rptr <= req_rptr + 1'b1;
            case ({req_push, req_pop})
                2'b10: req_count <= req_count + 1'b1;
                2'b01: req_count <= req_count - 1'b1;
                default: req_count <= req_count;
            endcase
        end
    end

    reg [31:0] inst_addr_r;
    reg        inst_dual_r;
    reg        inst_cacheable_r;

    always @(posedge cpu_clk or negedge cpu_rstn) begin
        if (!cpu_rstn) begin
            inst_addr_r <= `PC_INIT_VAL;
            inst_dual_r <= 1'b0;
            inst_cacheable_r <= 1'b0;
        end else if (core_inst_rreq) begin
            inst_addr_r <= core_inst_addr;
            inst_dual_r <= core_inst_dual;
            inst_cacheable_r <= core_inst_cacheable;
        end
    end

    wire [TAG_WID-1:0] tag_from_cpu =
        inst_addr_r[31 : INDEX_WID + OFFSET_WID];

    wire [INDEX_WID-1:0] index_from_cpu =
        inst_addr_r[INDEX_WID + OFFSET_WID - 1 : OFFSET_WID];

    wire [OFFSET_WID-1:0] offset =
        inst_addr_r[OFFSET_WID - 1 : 0];

    wire [2:0] word_offset =
        offset[4:2];

    // IF_stage presents a registered F1 address, but F1 may already hold
    // the next packet while ICache is still completing inst_addr_r. Only
    // an accepted request transfers ownership of the BRAM lookup address.
    wire [INDEX_WID-1:0] cache_index =
        core_inst_rreq ? core_inst_addr[INDEX_WID + OFFSET_WID - 1 : OFFSET_WID]
                  : inst_addr_r[INDEX_WID + OFFSET_WID - 1 : OFFSET_WID];

    reg [31:0]          miss_addr_wr;
    reg [TAG_WID-1:0]   tag_from_cpu_wr;
    reg [INDEX_WID-1:0] cache_idx_wr;
    reg [2:0]           miss_word_offset_wr;
    reg                 miss_cacheable_wr;

    wire cache_we;
    wire [INDEX_WID-1:0] bram_index;
    reg [`CACHE_BLK_NUM-1:0] line_enabled;

    reg [INDEX_WID-1:0] bram_index_r;

    always @(posedge cpu_clk or negedge cpu_rstn) begin
        if (!cpu_rstn)
            bram_index_r <= {INDEX_WID{1'b0}};
        else
            bram_index_r <= bram_index;
    end

    wire bram_line_ready =
        (bram_index_r == index_from_cpu);

    function [31:0] get_word_from_line;
        input [`CACHE_BLK_SIZE-1:0] line;
        input [2:0]                 idx;
        begin
            case (idx)
                3'd0: get_word_from_line = line[ 31:  0];
                3'd1: get_word_from_line = line[ 63: 32];
                3'd2: get_word_from_line = line[ 95: 64];
                3'd3: get_word_from_line = line[127: 96];
                3'd4: get_word_from_line = line[159:128];
                3'd5: get_word_from_line = line[191:160];
                3'd6: get_word_from_line = line[223:192];
                3'd7: get_word_from_line = line[255:224];
                default: get_word_from_line = 32'h0;
            endcase
        end
    endfunction

    function [`CACHE_BLK_SIZE-1:0] set_word_to_line;
        input [`CACHE_BLK_SIZE-1:0] line;
        input [2:0]                 idx;
        input [31:0]                word_data;

        reg [`CACHE_BLK_SIZE-1:0] tmp;
        begin
            tmp = line;

            case (idx)
                3'd0: tmp[ 31:  0] = word_data;
                3'd1: tmp[ 63: 32] = word_data;
                3'd2: tmp[ 95: 64] = word_data;
                3'd3: tmp[127: 96] = word_data;
                3'd4: tmp[159:128] = word_data;
                3'd5: tmp[191:160] = word_data;
                3'd6: tmp[223:192] = word_data;
                3'd7: tmp[255:224] = word_data;
                default: tmp = line;
            endcase

            set_word_to_line = tmp;
        end
    endfunction

    wire [BLK_WID-1:0] cache_line_r;

    wire               valid_bit      = cache_line_r[BLK_WID-1];
    wire [TAG_WID-1:0] tag_from_cache = cache_line_r[BLK_WID-2 : `CACHE_BLK_SIZE];

    wire hit =
        (current_state == TAG_CHK) &&
        bram_line_ready &&
        valid_bit &&
        line_enabled[index_from_cpu] &&
        inst_cacheable_r &&
        (tag_from_cpu == tag_from_cache) &&
        !pred_error;

    wire [31:0] hit_inst =
        get_word_from_line(cache_line_r[`CACHE_BLK_SIZE-1:0], word_offset);
    wire [31:0] hit_inst1 =
        get_word_from_line(cache_line_r[`CACHE_BLK_SIZE-1:0],
                           word_offset + 3'd1);

    always @(posedge cpu_clk or negedge cpu_rstn) begin
        if (!cpu_rstn) begin
            miss_addr_wr         <= `PC_INIT_VAL;
            tag_from_cpu_wr      <= {TAG_WID{1'b0}};
            cache_idx_wr         <= {INDEX_WID{1'b0}};
            miss_word_offset_wr  <= 3'b000;
            miss_cacheable_wr    <= 1'b0;
        end else if ((current_state == TAG_CHK) &&
                     bram_line_ready &&
                     !hit &&
                     !pred_error) begin
            miss_addr_wr         <= inst_addr_r;
            tag_from_cpu_wr      <= tag_from_cpu;
            cache_idx_wr         <= index_from_cpu;
            miss_word_offset_wr  <= word_offset;
            miss_cacheable_wr    <= inst_cacheable_r;
        end
    end

    reg [OFFSET_WID:0]        recv_cnt;
    reg [`CACHE_BLK_SIZE-1:0] cache_line_data;
    reg [`CACHE_BLK_LEN-1:0]  refill_word_valid;

    wire [2:0] refill_word_offset =
        miss_word_offset_wr + recv_cnt[2:0];

    wire [`CACHE_BLK_SIZE-1:0] cache_line_data_next =
        set_word_to_line(cache_line_data, refill_word_offset, dev_rdata);

    always @(posedge cpu_clk or negedge cpu_rstn) begin
        if (!cpu_rstn) begin
            recv_cnt          <= 0;
            cache_line_data   <= {`CACHE_BLK_SIZE{1'b0}};
            refill_word_valid <= {`CACHE_BLK_LEN{1'b0}};
        end else if (current_state == RD_MEM && dev_rrdy) begin
            recv_cnt          <= 0;
            cache_line_data   <= {`CACHE_BLK_SIZE{1'b0}};
            refill_word_valid <= {`CACHE_BLK_LEN{1'b0}};
        end else if (current_state == REFILL && dev_rvalid) begin
            cache_line_data <= cache_line_data_next;
            refill_word_valid[refill_word_offset] <= 1'b1;

            if (recv_cnt == `CACHE_BLK_LEN - 1)
                recv_cnt <= 0;
            else
                recv_cnt <= recv_cnt + 1'b1;
        end
    end

    reg cwf_new_req;
    reg discard_active;

    // A redirected miss may still return bus beats.  Drain those beats for
    // cache refill purposes, but never expose them as instruction responses
    // and do not start a corrected-path request in the old refill context.
    always @(posedge cpu_clk or negedge cpu_rstn) begin
        if (!cpu_rstn)
            discard_active <= 1'b0;
        else if (pred_error) begin
            if ((current_state == REFILL) && dev_rvalid &&
                (recv_cnt == `CACHE_BLK_LEN - 1))
                discard_active <= 1'b0;
            else
                discard_active <= (current_state == RD_MEM) ||
                                  (current_state == REFILL);
        end else if ((current_state == REFILL) && dev_rvalid &&
                     (recv_cnt == `CACHE_BLK_LEN - 1)) begin
            discard_active <= 1'b0;
        end
    end

    wire recv_cur_word =
        (current_state == REFILL) &&
        dev_rvalid &&
        (refill_word_offset == word_offset);

    wire cwf_word_ready =
        refill_word_valid[word_offset] |
        recv_cur_word;
    wire [2:0] word1_offset = word_offset + 3'd1;
    wire recv_next_word =
        (current_state == REFILL) && dev_rvalid &&
        (refill_word_offset == word1_offset);
    wire cwf_word1_ready = refill_word_valid[word1_offset] |
                           recv_next_word;

    wire cwf_tag_match =
        (tag_from_cpu == tag_from_cpu_wr);

    wire cwf_idx_match =
        (index_from_cpu == cache_idx_wr);

    wire cwf_blk_hit =
        (current_state == REFILL) &&
        cwf_tag_match &&
        cwf_idx_match;

    wire cwf_hit =
        cwf_new_req &&
        cwf_blk_hit &&
        cwf_word_ready &&
        (!inst_dual_r || cwf_word1_ready) &&
        !pred_error && !discard_active;

    wire [31:0] cwf_inst =
        recv_cur_word ?
        dev_rdata :
        get_word_from_line(cache_line_data, word_offset);
    wire [31:0] cwf_inst1 =
        recv_next_word ? dev_rdata :
        get_word_from_line(cache_line_data, word1_offset);

    always @(posedge cpu_clk or negedge cpu_rstn) begin
        if (!cpu_rstn) begin
            cwf_new_req <= 1'b0;
        end else if (pred_error) begin
            // The frontend drops all metadata on a redirect.  Cancel the
            // matching critical-word-first response as well; the outstanding
            // refill may still finish and populate the cache, but it must not
            // be presented as the response for a corrected-path request.
            cwf_new_req <= 1'b0;
        end else begin
            if (current_state == RD_MEM && dev_rrdy) begin
                cwf_new_req <= 1'b1;
            end

            else if (current_state == REFILL && core_inst_rreq) begin
                cwf_new_req <= 1'b1;
            end

            else if (current_state == REFILL && cwf_hit) begin
                cwf_new_req <= 1'b0;
            end

            else if (current_state != REFILL) begin
                cwf_new_req <= 1'b0;
            end
        end
    end

    wire cwf_req_left =
        (current_state == REFILL) &&
        (
            (cwf_new_req && !cwf_hit) ||
            core_inst_rreq
        );

    always @(*) begin
        inst_valid = hit | cwf_hit;
        inst1_valid = (hit | cwf_hit) & inst_dual_r;

        if (hit) begin
            inst_out = hit_inst;
            inst1_out = hit_inst1;
        end else if (cwf_hit) begin
            inst_out = cwf_inst;
            inst1_out = cwf_inst1;
        end else begin
            inst_out = 32'h0;
            inst1_out = 32'h0;
        end
    end

    assign cache_we =
        (current_state == REFILL) &&
        dev_rvalid &&
        (recv_cnt == `CACHE_BLK_LEN - 1) &&
        miss_cacheable_wr;

    wire [BLK_WID-1:0] cache_line_w = {
        1'b1,
        tag_from_cpu_wr,
        cache_line_data_next
    };

    wire [INDEX_WID-1:0] normal_bram_index =
        cache_we ? cache_idx_wr : cache_index;

    // CACOP invalidation uses a small shadow-valid array.  StoreTag is rare
    // and writes the selected BRAM row after a registered lookup, keeping
    // the wide write mux out of the normal hit path.
    localparam M_IDLE   = 3'd0;
    localparam M_LOOKUP = 3'd1;
    localparam M_APPLY  = 3'd2;
    localparam M_ALL    = 3'd3;
    localparam M_DONE   = 3'd4;
    reg [2:0]           maint_state;
    reg [INDEX_WID-1:0] maint_index_r;
    reg [INDEX_WID-1:0] maint_count;
    reg [TAG_WID-1:0]   maint_tag_r;
    reg [1:0]           maint_mode_r;
    reg [31:0]          maint_ctag_r;

    wire maint_active = (maint_state != M_IDLE);
    assign core_req_ready = (maint_state == M_IDLE) &&
                            !discard_active &&
                            ((current_state == IDLE) ||
                             ((current_state == TAG_CHK) && hit) ||
                             ((current_state == REFILL) &&
                              (!cwf_new_req || cwf_hit)));
    // Supervisor-required CACOP 0x00 is index invalidate.  Cache data/tag RAM
    // must not be rewritten; invalidation is represented by line_enabled.
    wire maint_store_we = 1'b0;
    wire bram_we = cache_we | maint_store_we;
    wire [BLK_WID-1:0] maint_line_w = {
        maint_ctag_r[0],
        maint_ctag_r[TAG_WID:1],
        cache_line_r[`CACHE_BLK_SIZE-1:0]
    };
    wire [BLK_WID-1:0] bram_line_w = maint_store_we ?
                                       maint_line_w : cache_line_w;
    assign maint_ready = (maint_state == M_IDLE) &&
                         (current_state == IDLE) && (req_count == 0) &&
                         !core_inst_rreq;
    assign bram_index = maint_active ? maint_index_r : normal_bram_index;

    always @(posedge cpu_clk or negedge cpu_rstn) begin
        if (!cpu_rstn) begin
            maint_state   <= M_IDLE;
            maint_index_r <= {INDEX_WID{1'b0}};
            maint_count   <= {INDEX_WID{1'b0}};
            maint_tag_r   <= {TAG_WID{1'b0}};
            maint_mode_r  <= 2'b00;
            maint_ctag_r  <= 32'h0;
            line_enabled  <= {`CACHE_BLK_NUM{1'b0}};
            maint_done    <= 1'b0;
        end else begin
            maint_done    <= 1'b0;
            if (cache_we)
                line_enabled[cache_idx_wr] <= 1'b1;

            case (maint_state)
                M_IDLE: begin
                    if (maint_valid && maint_ready) begin
                        maint_index_r <= maint_addr[INDEX_WID+OFFSET_WID-1:OFFSET_WID];
                        maint_tag_r   <= maint_addr[31:INDEX_WID+OFFSET_WID];
                        maint_mode_r  <= maint_mode;
                        maint_ctag_r  <= maint_ctag;
                        maint_count   <= {INDEX_WID{1'b0}};
                        if (maint_all)
                            maint_state <= M_ALL;
                        else if ((maint_mode == 2'b10) || (maint_mode == 2'b00))
                            maint_state <= M_LOOKUP;
                        else
                            maint_state <= M_APPLY;
                    end
                end
                M_LOOKUP: maint_state <= M_APPLY;
                M_APPLY: begin
                    case (maint_mode_r)
                        2'b00: line_enabled[maint_index_r] <= 1'b0;
                        2'b01: line_enabled[maint_index_r] <= 1'b0;
                        2'b10: begin
                            if (valid_bit && (tag_from_cache == maint_tag_r))
                                line_enabled[maint_index_r] <= 1'b0;
                        end
                        default: begin end
                    endcase
                    maint_state <= M_DONE;
                end
                M_ALL: begin
                    line_enabled[maint_count] <= 1'b0;
                    if (maint_count == `CACHE_BLK_NUM-1)
                        maint_state <= M_DONE;
                    else
                        maint_count <= maint_count + 1'b1;
                end
                M_DONE: begin
                    maint_done    <= 1'b1;
                    maint_state <= M_IDLE;
                end
                default: maint_state <= M_IDLE;
            endcase
        end
    end

    always @(posedge cpu_clk or negedge cpu_rstn) begin
        if (!cpu_rstn)
            current_state <= IDLE;
        else
            current_state <= next_state;
    end

    always @(*) begin
        case (current_state)
            IDLE: begin
                if (core_inst_rreq)
                    next_state = TAG_CHK;
                else
                    next_state = IDLE;
            end

            TAG_CHK: begin
                // A redirect invalidates inst_addr_r even when the synchronous
                // tag/data RAM has not returned yet.  Check it before
                // bram_line_ready so the old lookup cannot become a miss on
                // the following cycle and get paired with new-path metadata.
                if (pred_error) begin
                    next_state = IDLE;
                end else if (!bram_line_ready) begin
                    next_state = TAG_CHK;
                end else if (hit) begin
                    if (core_inst_rreq)
                        next_state = TAG_CHK;
                    else
                        next_state = IDLE;
                end else begin
                    next_state = RD_MEM;
                end
            end

            RD_MEM: begin
                if (dev_rrdy)
                    next_state = REFILL;
                else
                    next_state = RD_MEM;
            end

            REFILL: begin
                if (dev_rvalid && (recv_cnt == `CACHE_BLK_LEN - 1)) begin
                    if (discard_active || pred_error)
                        next_state = IDLE;
                    else if (cwf_req_left)
                        next_state = TAG_CHK;
                    else
                        next_state = IDLE;
                end else begin
                    next_state = REFILL;
                end
            end

            default: begin
                next_state = IDLE;
            end
        endcase
    end

    always @(*) begin
        if (current_state == RD_MEM && dev_rrdy)
            cpu_ren = 4'b1111;
        else
            cpu_ren = 4'b0000;

        cpu_raddr = miss_addr_wr;
    end

    blk_mem_gen_0 U_isram (
        .clka   (cpu_clk),
        .wea    (bram_we),
        .addra  (bram_index),
        .dina   (bram_line_w),
        .douta  (cache_line_r)
    );

`else

    assign maint_ready = 1'b1;
    always @(*) maint_done = maint_valid;

    localparam IDLE  = 2'b00;
    localparam STAT0 = 2'b01;
    localparam STAT1 = 2'b11;

    reg [1:0] state, nstat;
    reg       dev_rvalid_r;
    wire      dev_rvalid_pos = !dev_rvalid_r & dev_rvalid;
    assign inst_ready = (state == IDLE) ||
                        ((state == STAT1) && dev_rvalid_pos);

    always @(posedge cpu_clk or negedge cpu_rstn) begin
        state        <= !cpu_rstn ? IDLE : nstat;
        dev_rvalid_r <= !cpu_rstn ? 1'b0 : dev_rvalid;
    end

    always @(*) begin
        case (state)
            IDLE   : nstat = inst_rreq ? (dev_rrdy ? STAT1 : STAT0) : IDLE;
            STAT0  : nstat = dev_rrdy ? STAT1 : STAT0;
            STAT1  : nstat = inst_rreq ? (dev_rrdy ? STAT1 : STAT0) : (dev_rvalid_pos ? IDLE : STAT1);
            default: nstat = IDLE;
        endcase
    end

    reg cpu_ren0;

    always @(posedge cpu_clk or negedge cpu_rstn) begin
        if (!cpu_rstn) begin
            inst_valid <= 1'b0;
            inst1_valid <= 1'b0;
            inst1_out <= 32'h0;
            cpu_ren0   <= 1'b0;
        end else begin
            inst1_valid <= 1'b0;
            inst1_out <= 32'h0;
            case (state)
                IDLE: begin
                    inst_valid <= 1'b0;
                    cpu_ren0   <= (inst_rreq & dev_rrdy) ? 1'b1 : 1'b0;
                    cpu_raddr  <= inst_rreq ? inst_addr : 32'h0;
                end

                STAT0: begin
                    cpu_ren0   <= dev_rrdy ? 1'b1 : 1'b0;
                end

                STAT1: begin
                    cpu_ren0   <= (inst_rreq & dev_rrdy) ? 1'b1 : 1'b0;
                    cpu_raddr  <= inst_rreq ? inst_addr : 32'h0;
                    inst_valid <= dev_rvalid_pos ? 1'b1 : 1'b0;
                    inst_out   <= dev_rvalid_pos ? dev_rdata[31:0] : 32'h0;
                end

                default: begin
                    inst_valid <= 1'b0;
                    cpu_ren0   <= 1'b0;
                end
            endcase
        end
    end

    always @(*) begin
        cpu_ren = {4{cpu_ren0 & !inst_rreq}};
    end

`endif

endmodule
