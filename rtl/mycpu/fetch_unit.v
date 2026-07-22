`timescale 1ns / 1ps

`include "defines.vh"

module FetchUnit (
    input  wire         cpu_rstn     ,
    input  wire         cpu_clk      ,
    // backend consumer
    input  wire [ 1:0]  ibuf_pop_count,
    // From BPU
    input  wire         pred_error   ,
    input  wire [31:0]  redirect_target,
    input  wire [31:0]  pred_target  ,
    input  wire         pred_taken   ,
    input  wire [ 9:0]  pred_index   ,
    input  wire [31:0]  pred1_target,
    input  wire         pred1_taken,
    input  wire [ 9:0]  pred1_index,
    input  wire         pred1_btb_hit,
    input  wire [ 2:0]  pred_ras_sp_before,
    input  wire [ 3:0]  pred_ras_count_before,
    input  wire         perf_pred_btb_hit,
    // To ID
    output wire         if_valid     ,
    output wire [31:0]  if_pc        ,
    output wire [31:0]  if_inst      ,
    output wire [ 2:0]  if_ras_ptr   ,
    output wire         if_pred_valid,
    output wire         if_pred_taken,
    output wire [31:0]  if_pred_target,
    output wire [ 9:0]  if_pred_index,
    output wire [ 2:0]  if_ras_sp_before,
    output wire [ 3:0]  if_ras_count_before,
    output wire         if_perf_btb_hit,
    output wire         if1_valid,
    output wire [31:0]  if1_pc,
    output wire [31:0]  if1_inst,
    output wire [ 2:0]  if1_ras_ptr,
    output wire         if1_pred_valid,
    output wire         if1_pred_taken,
    output wire [31:0]  if1_pred_target,
    output wire [ 9:0]  if1_pred_index,
    output wire [ 2:0]  if1_ras_sp_before,
    output wire [ 3:0]  if1_ras_count_before,
    output wire         if1_perf_btb_hit,
    // To BPU
    output wire         bpu_valid    ,
    output wire [31:0]  bpu_pc       ,
    output wire         bpu_redirect_valid,
    output wire [31:0]  bpu_redirect_pc,
    // Instruction Fetch Interface
    output wire         ifetch_rreq  ,
    input  wire         ifetch_ready ,
    output wire [31:0]  ifetch_addr  ,
    output wire         ifetch_dual  ,
    input  wire         ifetch_valid ,
    input  wire [31:0]  ifetch_inst,
    input  wire         ifetch1_valid,
    input  wire [31:0]  ifetch1_inst
);

    localparam IBUF_DEPTH = 16;
    localparam IBUF_PTR_W = 4;

    wire [31:0] pc_reg;
    reg         redirect_pending;
    reg  [31:0] redirect_pc;

    wire [31:0] fetch_pc = redirect_pending ? redirect_pc : pc_reg;

    // ------------------------------------------------------------
    // IBUF: instruction + PC + prediction packet.
    // ------------------------------------------------------------
    reg [31:0] ibuf_pc      [IBUF_DEPTH-1:0];
    reg [31:0] ibuf_inst    [IBUF_DEPTH-1:0];
    reg [ 2:0] ibuf_ras_ptr [IBUF_DEPTH-1:0];
    reg        ibuf_pred_valid [IBUF_DEPTH-1:0];
    reg        ibuf_pred_taken [IBUF_DEPTH-1:0];
    reg [31:0] ibuf_pred_target[IBUF_DEPTH-1:0];
    reg [ 9:0] ibuf_pred_index [IBUF_DEPTH-1:0];
    reg [ 2:0] ibuf_ras_sp_before   [IBUF_DEPTH-1:0];
    reg [ 3:0] ibuf_ras_count_before[IBUF_DEPTH-1:0];
    reg        ibuf_perf_btb_hit[IBUF_DEPTH-1:0];

    reg [IBUF_PTR_W-1:0] ibuf_rptr;
    reg [IBUF_PTR_W-1:0] ibuf_wptr;
    reg [IBUF_PTR_W:0]   ibuf_count;
    // Metadata FIFO mirrors the in-order ICache request queue.  Four packets
    // can be in flight; each packet reserves one or two IBUF entries.
    localparam META_DEPTH = 4;
    localparam META_PTR_W = 2;
    reg [31:0] meta_pc [META_DEPTH-1:0];
    reg [ 2:0] meta_ras_ptr [META_DEPTH-1:0];
    reg        meta_pred_valid [META_DEPTH-1:0];
    reg        meta_pred_taken [META_DEPTH-1:0];
    reg [31:0] meta_pred_target [META_DEPTH-1:0];
    reg [ 9:0] meta_pred_index [META_DEPTH-1:0];
    reg [ 2:0] meta_ras_sp_before [META_DEPTH-1:0];
    reg [ 3:0] meta_ras_count_before [META_DEPTH-1:0];
    reg        meta_perf_btb_hit [META_DEPTH-1:0];
    reg        meta_pred1_taken [META_DEPTH-1:0];
    reg [31:0] meta_pred1_target [META_DEPTH-1:0];
    reg [ 9:0] meta_pred1_index [META_DEPTH-1:0];
    reg        meta_pred1_btb_hit [META_DEPTH-1:0];
    reg        meta_dual [META_DEPTH-1:0];
    reg [META_PTR_W-1:0] meta_rptr;
    reg [META_PTR_W-1:0] meta_wptr;
    reg [META_PTR_W:0] meta_count;
    reg [3:0] pending_slots;

    wire pending_valid = (meta_count != 0);
    wire [31:0] pending_pc = meta_pc[meta_rptr];
    wire [2:0] pending_ras_ptr = meta_ras_ptr[meta_rptr];
    wire pending_pred_valid = meta_pred_valid[meta_rptr];
    wire pending_pred_taken = meta_pred_taken[meta_rptr];
    wire [31:0] pending_pred_target = meta_pred_target[meta_rptr];
    wire [9:0] pending_pred_index = meta_pred_index[meta_rptr];
    wire [2:0] pending_ras_sp_before = meta_ras_sp_before[meta_rptr];
    wire [3:0] pending_ras_count_before = meta_ras_count_before[meta_rptr];
    wire pending_perf_btb_hit = meta_perf_btb_hit[meta_rptr];
    wire pending_pred1_taken = meta_pred1_taken[meta_rptr];
    wire [31:0] pending_pred1_target = meta_pred1_target[meta_rptr];
    wire [9:0] pending_pred1_index = meta_pred1_index[meta_rptr];
    wire pending_pred1_btb_hit = meta_pred1_btb_hit[meta_rptr];
    wire pending_dual = meta_dual[meta_rptr];
    wire [IBUF_PTR_W-1:0] ibuf_rptr1 = ibuf_rptr + 1'b1;

    assign if_valid            = (ibuf_count != 0);
    assign if_pc               = ibuf_pc[ibuf_rptr];
    assign if_inst             = ibuf_inst[ibuf_rptr];
    assign if_ras_ptr          = ibuf_ras_ptr[ibuf_rptr];
    assign if_pred_valid       = ibuf_pred_valid[ibuf_rptr];
    assign if_pred_taken       = ibuf_pred_taken[ibuf_rptr];
    assign if_pred_target      = ibuf_pred_target[ibuf_rptr];
    assign if_pred_index       = ibuf_pred_index[ibuf_rptr];
    assign if_ras_sp_before    = ibuf_ras_sp_before[ibuf_rptr];
    assign if_ras_count_before = ibuf_ras_count_before[ibuf_rptr];
    assign if_perf_btb_hit      = ibuf_perf_btb_hit[ibuf_rptr];

    assign if1_valid            = (ibuf_count >= 2);
    assign if1_pc               = ibuf_pc[ibuf_rptr1];
    assign if1_inst             = ibuf_inst[ibuf_rptr1];
    assign if1_ras_ptr          = ibuf_ras_ptr[ibuf_rptr1];
    assign if1_pred_valid       = ibuf_pred_valid[ibuf_rptr1];
    assign if1_pred_taken       = ibuf_pred_taken[ibuf_rptr1];
    assign if1_pred_target      = ibuf_pred_target[ibuf_rptr1];
    assign if1_pred_index       = ibuf_pred_index[ibuf_rptr1];
    assign if1_ras_sp_before    = ibuf_ras_sp_before[ibuf_rptr1];
    assign if1_ras_count_before = ibuf_ras_count_before[ibuf_rptr1];
    assign if1_perf_btb_hit      = ibuf_perf_btb_hit[ibuf_rptr1];

    wire [1:0] ibuf_pop_actual =
        ((ibuf_pop_count == 2) && (ibuf_count >= 2)) ? 2'd2 :
        ((ibuf_pop_count != 0) && (ibuf_count != 0)) ? 2'd1 : 2'd0;

    wire ibuf_room_for_return = pending_dual ?
                                (ibuf_count <= IBUF_DEPTH - 2) :
                                (ibuf_count < IBUF_DEPTH);

    // ------------------------------------------------------------
    // F1 fetch packet. F0 performs PC selection and prediction, then
    // registers the complete packet here before it reaches ICache.
    // ------------------------------------------------------------
    reg        f1_valid;
    reg [31:0] f1_pc;
    reg [ 2:0] f1_ras_ptr;
    reg        f1_pred_valid;
    reg        f1_pred_taken;
    reg [31:0] f1_pred_target;
    reg [ 9:0] f1_pred_index;
    reg [ 2:0] f1_ras_sp_before;
    reg [ 3:0] f1_ras_count_before;
    reg        f1_perf_btb_hit;
    reg        f1_pred1_taken;
    reg [31:0] f1_pred1_target;
    reg [ 9:0] f1_pred1_index;
    reg        f1_pred1_btb_hit;
    reg        f1_dual;

    // ------------------------------------------------------------
    // Ordered response consumes the metadata at the FIFO head.
    // ------------------------------------------------------------
    wire consume_resp = ifetch_valid & (!pending_dual || ifetch1_valid) &
                        pending_valid & !pred_error;
    // IBUF count plus F1 and every accepted outstanding packet
    // are all reserved entries. This prevents a returned instruction from
    // overflowing IBUF while the backend is stalled.
    wire fetch_dual_candidate = !pred_taken && (fetch_pc[4:2] != 3'd7);
    wire [IBUF_PTR_W+1:0] ibuf_reserved =
        {1'b0, ibuf_count} +
        pending_slots +
        (f1_valid ? (f1_dual ? 2 : 1) : 0);
    wire [IBUF_PTR_W+1:0] prepare_slots = fetch_dual_candidate ? 2 : 1;
    wire ibuf_room_for_prepare =
        (ibuf_reserved + prepare_slots <= IBUF_DEPTH);

    wire f1_fire =
        f1_valid &&
        !pred_error &&
        ifetch_ready &&
        ((meta_count < META_DEPTH) || consume_resp);
    wire meta_push = f1_fire;
    wire meta_pop = consume_resp;

    wire can_prepare =
        cpu_rstn &&
        !pred_error &&
        ibuf_room_for_prepare &&
        (!f1_valid || f1_fire);

    wire fetch_prepare = can_prepare;

    assign ifetch_rreq = f1_fire;
    assign ifetch_addr = f1_pc;
    assign ifetch_dual = f1_dual;

    assign bpu_valid = fetch_prepare;
    assign bpu_pc    = fetch_pc;
    wire [31:0] fetch_advance_target = pred_taken ? pred_target :
        (fetch_dual_candidate ?
            (pred1_taken ? pred1_target : fetch_pc + 32'd8) :
            fetch_pc + 32'd4);

    // Redirects are held for one cycle, then fetched as a normal BPU
    // request. This removes the EX->ICache address path.
    assign bpu_redirect_valid = 1'b0;
    assign bpu_redirect_pc    = 32'h0;

    always @(posedge cpu_clk or negedge cpu_rstn) begin
        if (!cpu_rstn) begin
            redirect_pending <= 1'b0;
            redirect_pc      <= `PC_INIT_VAL;
        end
        else if (pred_error) begin
            redirect_pending <= 1'b1;
            redirect_pc      <= redirect_target;
        end
        else if (fetch_prepare && redirect_pending) begin
            redirect_pending <= 1'b0;
        end
    end

    PcReg u_pc_reg (
        .cpu_clk    (cpu_clk   ),
        .cpu_rstn   (cpu_rstn  ),
        .suspend    (1'b0      ),
        .if_valid   (fetch_prepare),
        .din        (fetch_advance_target),
        .pc         (pc_reg    )
    );

    always @(posedge cpu_clk or negedge cpu_rstn) begin
        if (!cpu_rstn) begin
            f1_valid            <= 1'b0;
            f1_pc               <= `PC_INIT_VAL;
            f1_ras_ptr          <= 3'h0;
            f1_pred_valid       <= 1'b0;
            f1_pred_taken       <= 1'b0;
            f1_pred_target      <= `PC_INIT_VAL;
            f1_pred_index       <= 10'h0;
            f1_ras_sp_before    <= 3'h0;
            f1_ras_count_before <= 4'h0;
            f1_perf_btb_hit     <= 1'b0;
            f1_pred1_taken      <= 1'b0;
            f1_pred1_target     <= `PC_INIT_VAL + 32'd8;
            f1_pred1_index      <= 10'h0;
            f1_pred1_btb_hit    <= 1'b0;
            f1_dual             <= 1'b0;
        end
        else if (pred_error) begin
            f1_valid <= 1'b0;
        end
        else if (fetch_prepare) begin
            f1_valid            <= 1'b1;
            f1_pc               <= fetch_pc;
            f1_ras_ptr          <= pred_ras_sp_before;
            f1_pred_valid       <= 1'b1;
            f1_pred_taken       <= pred_taken;
            f1_pred_target      <= pred_target;
            f1_pred_index       <= pred_index;
            f1_ras_sp_before    <= pred_ras_sp_before;
            f1_ras_count_before <= pred_ras_count_before;
            f1_perf_btb_hit     <= perf_pred_btb_hit;
            f1_pred1_taken      <= pred1_taken;
            f1_pred1_target     <= pred1_target;
            f1_pred1_index      <= pred1_index;
            f1_pred1_btb_hit    <= pred1_btb_hit;
            f1_dual             <= fetch_dual_candidate;
        end
        else if (f1_fire) begin
            f1_valid <= 1'b0;
        end
    end

    always @(posedge cpu_clk or negedge cpu_rstn) begin
        if (!cpu_rstn) begin
            ibuf_rptr <= {IBUF_PTR_W{1'b0}};
            ibuf_wptr <= {IBUF_PTR_W{1'b0}};
            ibuf_count <= {(IBUF_PTR_W+1){1'b0}};

            meta_rptr <= {META_PTR_W{1'b0}};
            meta_wptr <= {META_PTR_W{1'b0}};
            meta_count <= {(META_PTR_W+1){1'b0}};
            pending_slots <= 4'd0;
        end
        else if (pred_error) begin
            ibuf_rptr <= {IBUF_PTR_W{1'b0}};
            ibuf_wptr <= {IBUF_PTR_W{1'b0}};
            ibuf_count <= {(IBUF_PTR_W+1){1'b0}};

            meta_rptr <= {META_PTR_W{1'b0}};
            meta_wptr <= {META_PTR_W{1'b0}};
            meta_count <= {(META_PTR_W+1){1'b0}};
            pending_slots <= 4'd0;
        end
        else begin
            if (consume_resp && ibuf_room_for_return) begin
                ibuf_pc[ibuf_wptr] <= pending_pc;
                ibuf_inst[ibuf_wptr] <= ifetch_inst;
                ibuf_ras_ptr[ibuf_wptr] <= pending_ras_ptr;
                ibuf_pred_valid[ibuf_wptr] <= pending_pred_valid;
                ibuf_pred_taken[ibuf_wptr] <= pending_pred_taken;
                ibuf_pred_target[ibuf_wptr] <= pending_pred_target;
                ibuf_pred_index[ibuf_wptr] <= pending_pred_index;
                ibuf_ras_sp_before[ibuf_wptr] <= pending_ras_sp_before;
                ibuf_ras_count_before[ibuf_wptr] <= pending_ras_count_before;
                ibuf_perf_btb_hit[ibuf_wptr] <= pending_perf_btb_hit;
                if (pending_dual) begin
                    ibuf_pc[ibuf_wptr + 1'b1] <= pending_pc + 32'd4;
                    ibuf_inst[ibuf_wptr + 1'b1] <= ifetch1_inst;
                    ibuf_ras_ptr[ibuf_wptr + 1'b1] <= pending_ras_ptr;
                    ibuf_pred_valid[ibuf_wptr + 1'b1] <= 1'b1;
                    ibuf_pred_taken[ibuf_wptr + 1'b1] <= pending_pred1_taken;
                    ibuf_pred_target[ibuf_wptr + 1'b1] <= pending_pred1_target;
                    ibuf_pred_index[ibuf_wptr + 1'b1] <= pending_pred1_index;
                    ibuf_ras_sp_before[ibuf_wptr + 1'b1] <= pending_ras_sp_before;
                    ibuf_ras_count_before[ibuf_wptr + 1'b1] <= pending_ras_count_before;
                    ibuf_perf_btb_hit[ibuf_wptr + 1'b1] <= pending_pred1_btb_hit;
                end
                ibuf_wptr <= ibuf_wptr + (pending_dual ? 2 : 1);
            end

            if (ibuf_pop_actual != 0) begin
                ibuf_rptr <= ibuf_rptr + ibuf_pop_actual;
            end

            ibuf_count <= ibuf_count +
                          ((consume_resp && ibuf_room_for_return) ?
                           (pending_dual ? 2 : 1) : 0) -
                          ibuf_pop_actual;

            if (meta_pop)
                meta_rptr <= meta_rptr + 1'b1;

            if (meta_push) begin
                meta_pc[meta_wptr] <= f1_pc;
                meta_ras_ptr[meta_wptr] <= f1_ras_ptr;
                meta_pred_valid[meta_wptr] <= f1_pred_valid;
                meta_pred_taken[meta_wptr] <= f1_pred_taken;
                meta_pred_target[meta_wptr] <= f1_pred_target;
                meta_pred_index[meta_wptr] <= f1_pred_index;
                meta_ras_sp_before[meta_wptr] <= f1_ras_sp_before;
                meta_ras_count_before[meta_wptr] <= f1_ras_count_before;
                meta_perf_btb_hit[meta_wptr] <= f1_perf_btb_hit;
                meta_pred1_taken[meta_wptr] <= f1_pred1_taken;
                meta_pred1_target[meta_wptr] <= f1_pred1_target;
                meta_pred1_index[meta_wptr] <= f1_pred1_index;
                meta_pred1_btb_hit[meta_wptr] <= f1_pred1_btb_hit;
                meta_dual[meta_wptr] <= f1_dual;
                meta_wptr <= meta_wptr + 1'b1;
            end

            case ({meta_push, meta_pop})
                2'b10: meta_count <= meta_count + 1'b1;
                2'b01: meta_count <= meta_count - 1'b1;
                default: meta_count <= meta_count;
            endcase
            pending_slots <= pending_slots +
                             (meta_push ? (f1_dual ? 2 : 1) : 0) -
                             (meta_pop ? (pending_dual ? 2 : 1) : 0);
        end
    end

endmodule
