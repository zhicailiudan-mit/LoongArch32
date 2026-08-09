`timescale 1ns / 1ps

`include "defines.vh"

import cpu_types_pkg::*;

// Frontend ownership boundary.  BPU, IF_stage (including PC/IBUF), and IF_ID
// remain unchanged leaf modules; this wrapper only carries their existing
// connections and packetizes the IF_ID output as fetch_uop_t.
module Frontend (
    input  logic                    clk,
    input  logic                    rstn,
    input  logic                    flush,
    input  logic                    redirect_valid,
    input  logic [31:0]             redirect_target,
    input  logic                    ex_stall,

    input  issue_uop_t              issue_uop,
    input  logic                    issue_valid,
    input  logic                    issue_fire,
    input  logic                    ex_valid,
    input  logic                    ex_is_br_jmp,
    input  logic                    ex_is_call,
    input  logic                    ex_is_ret,
    input  logic                    ex_is_conditional,
    input  logic                    ex_offset_negative,
    input  logic [31:0]             ex_pc,
    input  logic                    ex_real_taken,
    input  logic [31:0]             ex_real_target,
    input  logic [2:0]              ex_ras_ptr,
    input  prediction_meta_t        ex_pred,
    output logic                    branch_mispredict,

    output logic [1:0]              fetch_valid,
    input  logic                    fetch_ready,
    output fetch_uop_t              fetch_uop0,
    output fetch_uop_t              fetch_uop1,

    output logic                    ifetch_rreq,
    input  logic                    ifetch_ready,
    output logic [31:0]             ifetch_addr,
    output logic                    ifetch_dual,
    input  logic                    ifetch_valid,
    input  logic [31:0]             ifetch_inst,
    input  logic                    ifetch1_valid,
    input  logic [31:0]             ifetch1_inst,
    output logic                    perf_bpu_wait,
    output logic                    perf_icache_wait,
    output logic                    perf_fetch_fire0,
    output logic                    perf_fetch_fire1,
    output logic                    perf_branch_fire,
    output logic                    perf_branch_predicted_taken,
    output logic                    perf_branch_actual_taken,
    output logic                    perf_branch_mispredict,
    output logic                    perf_branch_btb_hit,
    output logic [31:0]             perf_branch_pc,
    output logic                    perf_branch_conditional,
    output logic                    perf_branch_backward,
    output logic                    perf_branch_jirl,
    output logic                    perf_direction_mispredict,
    output logic                    perf_target_mispredict,
    output logic                    perf_btb_update,
    output logic                    perf_btb_update_conditional,
    output logic                    perf_btb_update_backward
);

    wire [31:0] pred_target;
    wire        bpu_valid;
    wire [31:0] bpu_pc;
    wire        bpu_redirect_valid;
    wire [31:0] bpu_redirect_pc;
    wire        bpu_pred_taken;
    wire [ 9:0] bpu_pred_index;
    wire [31:0] bpu_pred1_target;
    wire        bpu_pred1_taken;
    wire [ 9:0] bpu_pred1_index;
    wire        bpu_pred1_btb_hit;
    wire [ 2:0] bpu_pred_ras_sp_before;
    wire [ 3:0] bpu_pred_ras_count_before;
    wire        bpu_pred_btb_hit;
    wire [ 2:0] bpu_if_ras_ptr_unused;
    wire        bpu_pred_error;

    wire        if_valid;
    wire [31:0] if_pc;
    wire [31:0] if_inst;
    wire [ 2:0] if_ras_ptr;
    wire        if_pred_valid;
    wire        if_pred_taken;
    wire [31:0] if_pred_target;
    wire [ 9:0] if_pred_index;
    wire [ 2:0] if_ras_sp_before;
    wire [ 3:0] if_ras_count_before;
    wire        if_perf_btb_hit;
    wire        if1_valid;
    wire [31:0] if1_pc;
    wire [31:0] if1_inst;
    wire [ 2:0] if1_ras_ptr;
    wire        if1_pred_valid;
    wire        if1_pred_taken;
    wire [31:0] if1_pred_target;
    wire [ 9:0] if1_pred_index;
    wire [ 2:0] if1_ras_sp_before;
    wire [ 3:0] if1_ras_count_before;
    wire        if1_perf_btb_hit;
    wire        if_packet_ready;
    wire        if_packet_fire;
    wire [ 1:0] if_packet_pop_count;

    wire        id_packet_valid;
    wire [31:0] id_packet_pc;
    wire [31:0] id_packet_inst;
    wire [ 2:0] id_packet_ras_ptr;
    wire        id_packet_pred_valid;
    wire        id_packet_pred_taken;
    wire [31:0] id_packet_pred_target;
    wire [ 9:0] id_packet_pred_index;
    wire [ 2:0] id_packet_ras_sp_before;
    wire [ 3:0] id_packet_ras_count_before;
    wire        id_packet_perf_btb_hit;
    wire        id1_packet_valid;
    wire [31:0] id1_packet_pc;
    wire [31:0] id1_packet_inst;
    wire [ 2:0] id1_packet_ras_ptr;
    wire        id1_packet_pred_valid;
    wire        id1_packet_pred_taken;
    wire [31:0] id1_packet_pred_target;
    wire [ 9:0] id1_packet_pred_index;
    wire [ 2:0] id1_packet_ras_sp_before;
    wire [ 3:0] id1_packet_ras_count_before;
    wire        id1_packet_perf_btb_hit;

    assign branch_mispredict = bpu_pred_error;
    assign if_packet_fire = if_valid & if_packet_ready & !flush;
    assign if_packet_pop_count = if_packet_fire ?
                                 (if1_valid ? 2'd2 : 2'd1) : 2'd0;
    assign fetch_valid = {id1_packet_valid, id_packet_valid};
    // BPU itself is combinational and has no ready signal.  The observable
    // predictor/front-end wait is a valid predicted fetch packet held because
    // the IF/ID boundary cannot accept it.
    assign perf_bpu_wait = bpu_valid && !if_packet_ready;
    assign perf_icache_wait = 1'b0;
    assign perf_fetch_fire0 = 1'b0;
    assign perf_fetch_fire1 = 1'b0;

    BranchPredUnit u_bpu (
        .cpu_clk        (clk),
        .cpu_rstn       (rstn),
        .if_pc          (bpu_pc),
        .id_pc          (issue_uop.pc),
        .if_valid       (bpu_valid),
        .redirect_valid (bpu_redirect_valid),
        .redirect_pc    (bpu_redirect_pc),
        .ifetch_valid   (ifetch_valid),
        .ifetch_inst    (ifetch_inst),
        .id_valid       (1'b0),
        .id_fire        (1'b0),
        .id_pred_valid_in(1'b0),
        .id_pred_taken_in(1'b0),
        .id_pred_target_in(32'h0),
        .id_pred_index_in(10'h0),
        .id_ras_sp_before_in(3'h0),
        .id_ras_count_before_in(4'h0),
        .id_perf_btb_hit_in(1'b0),
        .ex_pred_valid_in(ex_pred.valid),
        .ex_pred_taken_in(ex_pred.taken),
        .ex_pred_target_in(ex_pred.target),
        .ex_pred_index_in(ex_pred.index),
        .ex_ras_sp_before_in(ex_pred.ras_sp_before),
        .ex_ras_count_before_in(ex_pred.ras_count_before),
        .ex_perf_btb_hit_in(ex_pred.perf_btb_hit),
        .pl_suspend     (ex_stall),
        .pred_target    (pred_target),
        .pred_taken_out (bpu_pred_taken),
        .pred_index_out (bpu_pred_index),
        .pred1_target    (bpu_pred1_target),
        .pred1_taken_out (bpu_pred1_taken),
        .pred1_index_out (bpu_pred1_index),
        .pred1_btb_hit_out(bpu_pred1_btb_hit),
        .pred_ras_sp_before(bpu_pred_ras_sp_before),
        .pred_ras_count_before(bpu_pred_ras_count_before),
        .pred_error     (bpu_pred_error),
        .perf_branch_fire(perf_branch_fire),
        .perf_predicted_taken(perf_branch_predicted_taken),
        .perf_actual_taken(perf_branch_actual_taken),
        .perf_mispredict(perf_branch_mispredict),
        .perf_pred_btb_hit_out(bpu_pred_btb_hit),
        .perf_resolved_btb_hit(perf_branch_btb_hit),
        .perf_resolved_pc(perf_branch_pc),
        .perf_resolved_conditional(perf_branch_conditional),
        .perf_resolved_backward(perf_branch_backward),
        .perf_resolved_jirl(perf_branch_jirl),
        .perf_direction_mispredict(perf_direction_mispredict),
        .perf_target_mispredict(perf_target_mispredict),
        .perf_btb_update(perf_btb_update),
        .perf_btb_update_conditional(perf_btb_update_conditional),
        .perf_btb_update_backward(perf_btb_update_backward),
        .ex_valid       (ex_valid),
        .ex_is_bj       (ex_is_br_jmp),
        .ex_is_call     (ex_is_call),
        .ex_is_ret      (ex_is_ret),
        .ex_is_conditional(ex_is_conditional),
        .ex_offset_negative(ex_offset_negative),
        .ex_pc          (ex_pc),
        .real_taken     (ex_real_taken),
        .real_target    (ex_real_target),
        .if_ras_ptr     (bpu_if_ras_ptr_unused),
        .ex_ras_ptr     (ex_ras_ptr)
    );

    FetchUnit u_fetch_unit (
        .cpu_rstn       (rstn),
        .cpu_clk        (clk),
        .ibuf_pop_count (if_packet_pop_count),
        .pred_error     (redirect_valid),
        .redirect_target(redirect_target),
        .pred_target    (pred_target),
        .pred_taken     (bpu_pred_taken),
        .pred_index     (bpu_pred_index),
        .pred1_target   (bpu_pred1_target),
        .pred1_taken    (bpu_pred1_taken),
        .pred1_index    (bpu_pred1_index),
        .pred1_btb_hit  (bpu_pred1_btb_hit),
        .pred_ras_sp_before(bpu_pred_ras_sp_before),
        .pred_ras_count_before(bpu_pred_ras_count_before),
        .perf_pred_btb_hit(bpu_pred_btb_hit),
        .if_valid       (if_valid),
        .if_pc          (if_pc),
        .if_inst        (if_inst),
        .if_ras_ptr     (if_ras_ptr),
        .if_pred_valid  (if_pred_valid),
        .if_pred_taken  (if_pred_taken),
        .if_pred_target (if_pred_target),
        .if_pred_index  (if_pred_index),
        .if_ras_sp_before(if_ras_sp_before),
        .if_ras_count_before(if_ras_count_before),
        .if_perf_btb_hit(if_perf_btb_hit),
        .if1_valid      (if1_valid),
        .if1_pc         (if1_pc),
        .if1_inst       (if1_inst),
        .if1_ras_ptr    (if1_ras_ptr),
        .if1_pred_valid (if1_pred_valid),
        .if1_pred_taken (if1_pred_taken),
        .if1_pred_target(if1_pred_target),
        .if1_pred_index (if1_pred_index),
        .if1_ras_sp_before(if1_ras_sp_before),
        .if1_ras_count_before(if1_ras_count_before),
        .if1_perf_btb_hit(if1_perf_btb_hit),
        .bpu_valid      (bpu_valid),
        .bpu_pc         (bpu_pc),
        .bpu_redirect_valid(bpu_redirect_valid),
        .bpu_redirect_pc(bpu_redirect_pc),
        .ifetch_rreq    (ifetch_rreq),
        .ifetch_ready   (ifetch_ready),
        .ifetch_addr    (ifetch_addr),
        .ifetch_dual    (ifetch_dual),
        .ifetch_valid   (ifetch_valid),
        .ifetch_inst    (ifetch_inst),
        .ifetch1_valid  (ifetch1_valid),
        .ifetch1_inst   (ifetch1_inst)
    );

    FetchDecodeBuffer u_fetch_decode_buf (
        .cpu_clk            (clk),
        .cpu_rstn           (rstn),
        .flush              (flush),
        .in_valid           (if_valid & !flush),
        .in_ready           (if_packet_ready),
        .in_pc              (if_pc),
        .in_inst            (if_inst),
        .in_ras_ptr         (if_ras_ptr),
        .in_pred_valid      (if_pred_valid),
        .in_pred_taken      (if_pred_taken),
        .in_pred_target     (if_pred_target),
        .in_pred_index      (if_pred_index),
        .in_ras_sp_before   (if_ras_sp_before),
        .in_ras_count_before(if_ras_count_before),
        .in_perf_btb_hit     (if_perf_btb_hit),
        .in1_valid          (if1_valid),
        .in1_pc             (if1_pc),
        .in1_inst           (if1_inst),
        .in1_ras_ptr        (if1_ras_ptr),
        .in1_pred_valid     (if1_pred_valid),
        .in1_pred_taken     (if1_pred_taken),
        .in1_pred_target    (if1_pred_target),
        .in1_pred_index     (if1_pred_index),
        .in1_ras_sp_before  (if1_ras_sp_before),
        .in1_ras_count_before(if1_ras_count_before),
        .in1_perf_btb_hit     (if1_perf_btb_hit),
        .out_valid          (id_packet_valid),
        .out_ready          (fetch_ready),
        .out_pc             (id_packet_pc),
        .out_inst           (id_packet_inst),
        .out_ras_ptr        (id_packet_ras_ptr),
        .out_pred_valid     (id_packet_pred_valid),
        .out_pred_taken     (id_packet_pred_taken),
        .out_pred_target    (id_packet_pred_target),
        .out_pred_index     (id_packet_pred_index),
        .out_ras_sp_before  (id_packet_ras_sp_before),
        .out_ras_count_before(id_packet_ras_count_before),
        .out_perf_btb_hit     (id_packet_perf_btb_hit),
        .out1_valid         (id1_packet_valid),
        .out1_pc            (id1_packet_pc),
        .out1_inst          (id1_packet_inst),
        .out1_ras_ptr       (id1_packet_ras_ptr),
        .out1_pred_valid    (id1_packet_pred_valid),
        .out1_pred_taken    (id1_packet_pred_taken),
        .out1_pred_target   (id1_packet_pred_target),
        .out1_pred_index    (id1_packet_pred_index),
        .out1_ras_sp_before (id1_packet_ras_sp_before),
        .out1_ras_count_before(id1_packet_ras_count_before),
        .out1_perf_btb_hit     (id1_packet_perf_btb_hit)
    );

    always_comb begin
        fetch_uop0 = '0;
        fetch_uop0.pc = id_packet_pc;
        fetch_uop0.instruction = id_packet_inst;
        fetch_uop0.pred.ras_ptr = id_packet_ras_ptr;
        fetch_uop0.pred.valid = id_packet_pred_valid;
        fetch_uop0.pred.taken = id_packet_pred_taken;
        fetch_uop0.pred.target = id_packet_pred_target;
        fetch_uop0.pred.index = id_packet_pred_index;
        fetch_uop0.pred.ras_sp_before = id_packet_ras_sp_before;
        fetch_uop0.pred.ras_count_before = id_packet_ras_count_before;
        fetch_uop0.pred.perf_btb_hit = id_packet_perf_btb_hit;

        fetch_uop1 = '0;
        fetch_uop1.pc = id1_packet_pc;
        fetch_uop1.instruction = id1_packet_inst;
        fetch_uop1.pred.ras_ptr = id1_packet_ras_ptr;
        fetch_uop1.pred.valid = id1_packet_pred_valid;
        fetch_uop1.pred.taken = id1_packet_pred_taken;
        fetch_uop1.pred.target = id1_packet_pred_target;
        fetch_uop1.pred.index = id1_packet_pred_index;
        fetch_uop1.pred.ras_sp_before = id1_packet_ras_sp_before;
        fetch_uop1.pred.ras_count_before = id1_packet_ras_count_before;
        fetch_uop1.pred.perf_btb_hit = id1_packet_perf_btb_hit;
    end

endmodule
