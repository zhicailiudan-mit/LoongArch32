`timescale 1ns / 1ps

`include "defines.vh"

import cpu_types_pkg::*;

// DispatchQueue ownership boundary. The queue consumes typed lane packets;
// this wrapper only applies execution-unit policy and routes the selected
// packets to main/system/fast issue consumers.
module Scheduler (
    input  logic                    clk,
    input  logic                    rstn,
    input  logic                    flush,
    input  logic                    recover_valid,
    input  logic                    system_flush,
    input  uop_id_t                 recover_id,
    input  logic                    barrier_release,

    input  logic                    dispatch0_valid,
    output logic                    dispatch0_ready,
    input  issue_uop_t              dispatch0_uop,
    input  logic                    dispatch0_src0_ready,
    input  uop_id_t                 dispatch0_src0_id,
    input  logic                    dispatch0_src1_ready,
    input  uop_id_t                 dispatch0_src1_id,
    input  logic                    dispatch1_valid,
    output logic                    dispatch1_ready,
    input  issue_uop_t              dispatch1_uop,
    input  logic                    dispatch1_src0_ready,
    input  uop_id_t                 dispatch1_src0_id,
    input  logic                    dispatch1_src1_ready,
    input  uop_id_t                 dispatch1_src1_id,

    input  completion_t              complete0,
    input  completion_t              complete1,
    input  commit_t                  commit0,
    input  commit_t                  commit1,

    input  logic                     rob_head_valid,
    input  logic [`ROB_TAG_W-1:0]    rob_head_tag,
    input  uop_id_t                  rob_head_id,
    input  logic                     system_inflight,

    output logic                     issue0_valid,
    input  logic                     issue0_ready,
    output logic                     issue0_fire,
    output issue_uop_t               issue0,

    output logic                     system_issue_valid,
    input  logic                     system_issue_ready,
    output logic                     system_issue_fire,
    output issue_uop_t               system_issue,

    output logic                     issue1_valid,
    input  logic                     issue1_ready,
    output logic                     issue1_fire,
    output issue_uop_t               issue1,
    output logic [2:0]               occupancy
);

    dispatch_uop_t dq_enq [0:1];
    wire dq_enq_ready [0:1];
    wire dq_issue_valid [0:1];
    wire dq_issue_ready [0:1];
    wire issue_uop_t dq_issue [0:1];
    wire [2:0] dq_occupancy;
    wire completion_t dq_complete [0:1];
    wire commit_t dq_commit [0:1];

    assign dq_complete[0] = complete0;
    assign dq_complete[1] = complete1;
    assign dq_commit[0] = commit0;
    assign dq_commit[1] = commit1;

    always_comb begin
        dq_enq[0] = '0;
        dq_enq[0].valid = dispatch0_valid;
        dq_enq[0].src0_ready = dispatch0_src0_ready;
        dq_enq[0].src0_id = dispatch0_src0_id;
        dq_enq[0].src1_ready = dispatch0_src1_ready;
        dq_enq[0].src1_id = dispatch0_src1_id;
        dq_enq[0].uop = dispatch0_uop;

        dq_enq[1] = '0;
        dq_enq[1].valid = dispatch1_valid;
        dq_enq[1].src0_ready = dispatch1_src0_ready;
        dq_enq[1].src0_id = dispatch1_src0_id;
        dq_enq[1].src1_ready = dispatch1_src1_ready;
        dq_enq[1].src1_id = dispatch1_src1_id;
        dq_enq[1].uop = dispatch1_uop;
    end

    wire dq_is_system = (dq_issue[0].system_op != SYS_NONE);
    wire system_at_head = rob_head_valid &&
                          uop_id_equal(dq_issue[0].uop_id, rob_head_id);

    // A lane0-selected ALU/MDU/LSU uop may execute on lane1 when lane0 is
    // occupied. Branch and system operations retain their ordered lane0 path.
    wire dq0_fast_eligible = !dq_issue[0].is_br_jmp &&
                             !dq_issue[0].is_call &&
                             !dq_issue[0].is_ret &&
                             !dq_issue[0].pred.taken &&
                             (dq_issue[0].system_op == SYS_NONE) &&
                             (dq_issue[0].is_ld_st ||
                              (dq_issue[0].result_sel == `WD_ALU));
    wire steal_main_to_lane1 = dq_issue_valid[0] && !dq_is_system &&
                               !issue0_ready && issue1_ready &&
                               dq0_fast_eligible && !dq_issue_valid[1] &&
                               !system_inflight &&
                               !flush;

    assign dq_issue_ready[0] = dq_is_system ?
                                (system_issue_ready && system_at_head &&
                                 !system_inflight) :
                                ((steal_main_to_lane1 || issue0_ready) &&
                                 !system_inflight);
    assign dq_issue_ready[1] = issue1_ready && !flush &&
                                !system_inflight && !dq_is_system &&
                                !steal_main_to_lane1;

    assign dispatch0_ready = dq_enq_ready[0];
    assign dispatch1_ready = dq_enq_ready[1];
    assign issue0_valid = dq_issue_valid[0] && !dq_is_system &&
                               !system_inflight && !steal_main_to_lane1;
    assign issue0_fire = issue0_valid && issue0_ready;
    assign system_issue_valid = dq_issue_valid[0] && dq_is_system &&
                                system_at_head && !system_inflight;
    assign system_issue_fire = system_issue_valid && system_issue_ready;
    assign issue1_valid = !system_inflight && !dq_is_system &&
                          (steal_main_to_lane1 ? dq_issue_valid[0] :
                                                dq_issue_valid[1]);
    assign issue1_fire = issue1_valid && issue1_ready;
    assign occupancy = dq_occupancy;

    DispatchQueue #(
        .RESOURCE_AWARE_PAIRING(1'b1),
        .BRANCH_AT_ROB_HEAD    (1'b0)
    ) u_dispatch_queue (
        .clk            (clk),
        .rstn           (rstn),
        .flush          (flush),
        .recover_valid  (recover_valid),
        .system_flush   (system_flush),
        .recover_id     (recover_id),
        .barrier_release(barrier_release),
        .enq            (dq_enq),
        .enq_ready      (dq_enq_ready),
        .complete       (dq_complete),
        .commit         (dq_commit),
        .rob_head_valid (rob_head_valid),
        .rob_head_tag   (rob_head_tag),
        .rob_head_id    (rob_head_id),
        .issue_valid    (dq_issue_valid),
        .issue_ready    (dq_issue_ready),
        .issue           (dq_issue),
        .occupancy      (dq_occupancy)
    );

    assign issue0 = dq_issue[0];
    assign system_issue = dq_issue[0];
    assign issue1 = steal_main_to_lane1 ? dq_issue[0] : dq_issue[1];

endmodule
