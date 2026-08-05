`timescale 1ns / 1ps

`include "defines.vh"

import cpu_types_pkg::*;

// Dual-issue execution ownership boundary.
//
// Lane 0 is the ordered-facing execution result used by the existing LSU and
// branch recovery links. Lane 1 is an independent integer/MDU result lane
// selected by Scheduler for side-effect-free register-producing operations.
// The former issue/EX staging is represented by the two lane-local state
// machines here; no legacy pipeline module remains in the active path.
module ExecutionCluster (
    input  logic                  cpu_rstn,
    input  logic                  cpu_clk,
    input  logic                  lane0_result_stall,
    input  logic                  lane1_result_stall,
    input  logic                  pred_error,
    input  logic                  recover_valid,
    input  logic                  system_flush,
    input  uop_id_t               recover_id,

    input  completion_t           store_data_complete0,
    input  completion_t           store_data_complete1,
    input  commit_t               store_data_commit0,
    input  commit_t               store_data_commit1,

    input  logic                  issue0_valid,
    input  logic                  issue0_fire,
    input  issue_uop_t            issue0,
    output logic                  issue0_ready,

    input  logic                  issue1_valid,
    input  logic                  issue1_fire,
    input  issue_uop_t            issue1,
    output logic                  issue1_ready,

    output execute_result_t       execute_result,
    output execute_result_t       execute_result1,
    output completion_t           issue1_complete,
    output logic                  alu_done,
    output logic                  muldiv_busy,
    output logic                  branch_mispredict,
    output logic                  redirect_valid,
    output logic [31:0]           redirect_target,
    output uop_id_t               branch_recover_id,
    output logic                  pipeline_flush
);
    wire lane1_ready;
    assign issue1_ready = lane1_ready && !pipeline_flush;
    
    wire lane0_muldiv_busy;
    assign muldiv_busy = lane0_muldiv_busy || !lane1_ready;
    
    // Lane 0 execution path
    ExecutionLane0 u_execution_lane0 (
        .cpu_rstn           (cpu_rstn),
        .cpu_clk            (cpu_clk),
        .lane0_result_stall (lane0_result_stall),
        .pred_error         (pred_error),
        .recover_valid      (recover_valid),
        .system_flush       (system_flush),
        .recover_id         (recover_id),
        .store_data_complete0(store_data_complete0),
        .store_data_complete1(store_data_complete1),
        .store_data_commit0  (store_data_commit0),
        .store_data_commit1  (store_data_commit1),
        
        .issue0_valid   (issue0_valid),
        .issue0_fire    (issue0_fire),
        .issue0         (issue0),
        .issue0_ready   (issue0_ready),
        
        .execute_result     (execute_result),
        .alu_done           (alu_done),
        .muldiv_busy        (lane0_muldiv_busy),
        .branch_mispredict  (branch_mispredict),
        .redirect_valid     (redirect_valid),
        .redirect_target    (redirect_target),
        .branch_recover_id  (branch_recover_id),
        .pipeline_flush     (pipeline_flush)
    );

    // Lane 1 retains the old one-cycle completion timing, but is now an
    // ordinary execution lane owned by this cluster rather than a private
    // backend execution path.
    wire unused_issue0_valid = issue0_valid;
    wire unused_issue1_valid = issue1_valid;
    ExecutionLane1 u_execution_lane1 (
        .clk                (cpu_clk),
        .rstn               (cpu_rstn),
        .flush              (pipeline_flush),
        .recover_valid      (recover_valid),
        .system_flush       (system_flush),
        .recover_id         (recover_id),
        .store_data_complete0(store_data_complete0),
        .store_data_complete1(store_data_complete1),
        .store_data_commit0  (store_data_commit0),
        .store_data_commit1  (store_data_commit1),
        .result_stall       (lane1_result_stall),
        .issue_ready        (lane1_ready),
        .issue_valid        (issue1_fire),
        .issue_uop_id       (issue1.uop_id),
        .issue_pc           (issue1.pc),
        .issue_src0         (issue1.src0_value),
        .issue_src1         (issue1.src1_value),
        .issue_src1_ready   (issue1.src1_ready),
        .issue_src1_id      (issue1.src1_id),
        .issue_imm          (issue1.imm),
        .issue_reg_write    (issue1.reg_write),
        .issue_arch_rd      (issue1.arch_rd),
        .issue_result_sel   (issue1.result_sel),
        .issue_alu_op       (issue1.alu_op),
        .issue_src_a_sel    (issue1.src_a_sel),
        .issue_src_b_sel    (issue1.src_b_sel),
        .issue_store_mask   (issue1.store_mask),
        .issue_load_ext_op  (issue1.load_ext_op),
        .issue_is_ld_st     (issue1.is_ld_st),
        .execute_result     (execute_result1),
        .complete_valid     (issue1_complete.valid),
        .complete_uop_id    (issue1_complete.uop_id),
        .complete_value     (issue1_complete.value),
        .complete_reg_write (issue1_complete.reg_write)
    );

`ifndef SYNTHESIS
    assert property (@(posedge cpu_clk) disable iff (!cpu_rstn || system_flush || (recover_valid && uop_is_younger(execute_result.uop_id, recover_id)))
        lane0_result_stall && execute_result.valid
        |=> execute_result.valid &&
            $stable(execute_result.uop_id) &&
            $stable(execute_result.pc) &&
            $stable(execute_result.alu_result) &&
            (($stable(execute_result.src1_value) &&
              $stable(execute_result.store_data_ready)) ||
             (!$past(execute_result.store_data_ready) &&
              execute_result.store_data_ready)) &&
            $stable(execute_result.store_mask)) else $fatal(1, "Lane 0 execute_result hold violation");

    assert property (@(posedge cpu_clk) disable iff (!cpu_rstn || system_flush || (recover_valid && uop_is_younger(execute_result1.uop_id, recover_id)))
        lane1_result_stall && execute_result1.valid
        |=> execute_result1.valid &&
            $stable(execute_result1.uop_id) &&
            $stable(execute_result1.pc) &&
            $stable(execute_result1.alu_result) &&
            (($stable(execute_result1.src1_value) &&
              $stable(execute_result1.store_data_ready)) ||
             (!$past(execute_result1.store_data_ready) &&
              execute_result1.store_data_ready)) &&
            $stable(execute_result1.store_mask)) else $fatal(1, "Lane 1 execute_result hold violation");
`endif

endmodule
