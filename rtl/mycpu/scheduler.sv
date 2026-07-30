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
    input  completion_t              system_complete,
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
    output logic [3:0]               occupancy,

    // Store Reservation Interface (to LoadStoreUnit / StoreQueue)
    output logic                     reserve0_valid,
    input  logic                     reserve0_ready,
    output uop_id_t                  reserve0_uop_id,
    output logic [31:0]              reserve0_pc,
    output logic [3:0]               reserve0_store_mask,
    output logic                     reserve0_src1_ready,
    output logic [31:0]              reserve0_src1_value,
    output uop_id_t                  reserve0_src1_id,

    output logic                     reserve1_valid,
    input  logic                     reserve1_ready,
    output uop_id_t                  reserve1_uop_id,
    output logic [31:0]              reserve1_pc,
    output logic [3:0]               reserve1_store_mask,
    output logic                     reserve1_src1_ready,
    output logic [31:0]              reserve1_src1_value,
    output uop_id_t                  reserve1_src1_id,

    output logic                     perf_true_source_wait,
    output logic                     perf_source_wait_dep_load,
    output logic                     perf_source_wait_dep_muldiv,
    output logic                     perf_source_wait_dep_alu,
    output logic                     perf_source_wait_dep_branch,
    output logic                     perf_source_wait_store_addr,
    output logic                     perf_source_wait_store_data,
    output logic                     perf_iq_no_ready,
    output logic                     perf_lsu_order,
    output logic                     perf_serializing
);

    dispatch_uop_t dq_enq [0:1];
    wire dq_enq_ready [0:1];
    wire dq_issue_valid [0:1];
    wire dq_issue_ready [0:1];
    wire issue_uop_t dq_issue [0:1];
    wire [3:0] dq_occupancy;
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
    wire no_sys_active = !system_inflight && !dq_is_system;
    wire system_at_head = rob_head_valid &&
                          uop_id_equal(dq_issue[0].uop_id, rob_head_id);

    // A lane0-selected ALU/MDU operation may execute on lane1 when lane0 is
    // occupied. Memory, Branch and system operations retain their ordered lane0 path.
    wire dq0_fast_eligible = !dq_issue[0].is_br_jmp &&
                             !dq_issue[0].is_call &&
                             !dq_issue[0].is_ret &&
                             !dq_issue[0].pred.taken &&
                             (dq_issue[0].system_op == SYS_NONE) &&
                             !dq_issue[0].is_ld_st &&
                             (dq_issue[0].result_sel == `WD_ALU);
    wire steal_main_to_lane1 = dq_issue_valid[0] && no_sys_active &&
                               !issue0_ready && issue1_ready &&
                               dq0_fast_eligible && !dq_issue_valid[1] &&
                               !flush;

    wire dq0_is_store = dq_issue_valid[0] && no_sys_active &&
                        dq_issue[0].is_ld_st && (dq_issue[0].store_mask != `RAM_WE_N);
    wire dq1_is_store = dq_issue_valid[1] && no_sys_active &&
                        dq_issue[1].is_ld_st && (dq_issue[1].store_mask != `RAM_WE_N);

    wire issue0_base_valid = dq_issue_valid[0] && no_sys_active &&
                             !steal_main_to_lane1;
    wire issue1_base_valid = no_sys_active &&
                             (steal_main_to_lane1 ? dq_issue_valid[0] :
                                                   dq_issue_valid[1]);

    // A reservation request is presented once the execution lane can accept
    // the selected Store.  It intentionally does not depend on reserve*_ready:
    // reserve_valid -> reserve_ready -> issue_fire is therefore acyclic, and
    // a queue with exactly one free entry can still grant one of two Stores.
    assign reserve0_valid = issue0_base_valid && issue0_ready && dq0_is_store;
    assign reserve1_valid = issue1_base_valid && issue1_ready && dq1_is_store;

    wire dq0_lsu_ready = issue0_ready && (!dq0_is_store || reserve0_ready);
    wire dq1_lsu_ready = issue1_ready && (!dq1_is_store || reserve1_ready);

    assign dq_issue_ready[0] = dq_is_system ?
                                (system_issue_ready && system_at_head &&
                                 !system_inflight) :
                                ((steal_main_to_lane1 || dq0_lsu_ready) &&
                                 !system_inflight);
    assign dq_issue_ready[1] = dq1_lsu_ready && !flush &&
                                !system_inflight && !dq_is_system &&
                                !steal_main_to_lane1;

    assign dispatch0_ready = dq_enq_ready[0];
    assign dispatch1_ready = dq_enq_ready[1];
    assign issue0_valid = issue0_base_valid &&
                          (!dq0_is_store || reserve0_ready);
    assign issue0_fire = issue0_valid && issue0_ready;
    assign system_issue_valid = dq_issue_valid[0] && dq_is_system &&
                                system_at_head && !system_inflight;
    assign system_issue_fire = system_issue_valid && system_issue_ready;
    assign issue1_valid = issue1_base_valid &&
                          (!dq1_is_store || reserve1_ready);
    assign issue1_fire = issue1_valid && issue1_ready;
    assign occupancy = dq_occupancy;

    assign reserve0_uop_id = issue0.uop_id;
    assign reserve0_pc = issue0.pc;
    assign reserve0_store_mask = issue0.store_mask;
    assign reserve0_src1_ready = issue0.src1_ready;
    // Decouple store reservation src1_value from long same-cycle bypass chain;
    // StoreQueue snoops completion/commit directly via its own input ports.
    assign reserve0_src1_value = issue0.src1_ready ? issue0.src1_value : 32'h0;
    assign reserve0_src1_id = issue0.src1_id;

    assign reserve1_uop_id = issue1.uop_id;
    assign reserve1_pc = issue1.pc;
    assign reserve1_store_mask = issue1.store_mask;
    assign reserve1_src1_ready = issue1.src1_ready;
    assign reserve1_src1_value = issue1.src1_ready ? issue1.src1_value : 32'h0;
    assign reserve1_src1_id = issue1.src1_id;
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
        .perf_true_source_wait(perf_true_source_wait),
        .perf_source_wait_dep_load(perf_source_wait_dep_load),
        .perf_source_wait_dep_muldiv(perf_source_wait_dep_muldiv),
        .perf_source_wait_dep_alu(perf_source_wait_dep_alu),
        .perf_source_wait_dep_branch(perf_source_wait_dep_branch),
        .perf_source_wait_store_addr(perf_source_wait_store_addr),
        .perf_source_wait_store_data(perf_source_wait_store_data),
        .perf_iq_no_ready(perf_iq_no_ready),
        .perf_lsu_order (perf_lsu_order),
        .perf_serializing(perf_serializing),
        .enq            (dq_enq),
        .enq_ready      (dq_enq_ready),
        .complete       (dq_complete),
        .system_complete(system_complete),
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

`ifndef SYNTHESIS
    always @(posedge clk) begin
        if (rstn && !flush) begin
            if (issue0_fire && dq0_is_store &&
                !(reserve0_valid && reserve0_ready))
                $fatal(1, "[SCHED-ASSERT] lane0 Store issued without SQ reservation");
            if (issue1_fire && dq1_is_store &&
                !(reserve1_valid && reserve1_ready))
                $fatal(1, "[SCHED-ASSERT] lane1 Store issued without SQ reservation");
            if ((reserve0_valid && reserve0_ready) !=
                (issue0_fire && dq0_is_store))
                $fatal(1, "[SCHED-ASSERT] lane0 Store issue/reservation lost atomicity");
            if ((reserve1_valid && reserve1_ready) !=
                (issue1_fire && dq1_is_store))
                $fatal(1, "[SCHED-ASSERT] lane1 Store issue/reservation lost atomicity");
        end
    end
`endif

endmodule
