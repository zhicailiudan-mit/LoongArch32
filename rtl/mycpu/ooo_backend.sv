`timescale 1ns / 1ps

`include "defines.vh"

import cpu_types_pkg::*;

module OooBackend (
    input  logic                         clk,
    input  logic                         rstn,
    input  logic                         flush,
    input  logic                         system_flush,
    input  logic                         redirect_valid,

    input  logic [1:0]                   decode_valid,
    output logic                         decode_ready,
    input  decoded_uop_t                 decode_uop0,
    input  decoded_uop_t                 decode_uop1,

    input  logic                         recover_valid,
    input  uop_id_t                       recover_id,

    input  completion_t                   main_complete,
    input  completion_t                   issue1_complete,
    input  completion_t                   system_complete,

    output logic                         issue0_valid,
    input  logic                         issue0_ready,
    output logic                         issue0_fire,
    output issue_uop_t                   issue0,

    output logic                         issue1_valid,
    input  logic                         issue1_ready,
    output logic                         issue1_fire,
    output issue_uop_t                   issue1,

    output logic                         system_issue_valid,
    input  logic                         system_issue_ready,
    output logic                         system_issue_fire,
    output issue_uop_t                   system_issue,

    output commit_t                      commit0,
    output commit_t                      commit1,

    output logic [`ROB_TAG_W:0]          perf_rob_occupancy,
    output logic [3:0]                   perf_issue_occupancy,
    output logic                         perf_rob_block,
    output logic                         perf_issue_queue_block,
    output logic                         perf_true_source_wait,
    output logic                         perf_lsu_order,
    output logic                         perf_serializing,
    output logic                         perf_dispatch_fire0,
    output logic                         perf_dispatch_fire1,
    output logic                         perf_serializing_block,

    output logic                         rob_head_valid,
    output uop_id_t                      rob_head_id
);

    wire decoded_uop_t decode_uop [0:1];
    wire dispatch_uop_t dispatch [0:1];
    wire [1:0] dispatch_valid;
    wire [1:0] scheduler_dispatch_ready;
    wire [1:0] rob_alloc_ready;
    wire uop_id_t rob_alloc_id [0:1];
    wire [`ROB_DEPTH-1:0] rob_live_mask;
    wire [`ROB_TAG_W:0] rob_occupancy;
    wire [3:0] scheduler_occupancy;
    wire [`ROB_TAG_W-1:0] rob_head_tag;
    wire uop_id_t rob_query_id [0:3];
    wire rob_query_done [0:3];
    wire [31:0] rob_query_value [0:3];
    wire completion_t complete [0:1];
    wire issue_uop_t alloc_uop [0:1];
    wire commit_t commit_internal [0:1];
    reg system_inflight;

    assign decode_uop[0] = decode_uop0;
    assign decode_uop[1] = decode_uop1;
    assign alloc_uop[0] = dispatch[0].uop;
    assign alloc_uop[1] = dispatch[1].uop;

    always @(posedge clk or negedge rstn) begin
        if (!rstn)
            system_inflight <= 1'b0;
        else if (flush || system_complete.valid)
            system_inflight <= 1'b0;
        else if (system_issue_fire)
            system_inflight <= 1'b1;
    end

    RenameDispatch u_rename_dispatch (
        .clk                      (clk),
        .rstn                     (rstn),
        .flush                    (flush),
        .system_flush             (system_flush),
        .redirect_valid           (redirect_valid),
        .decode_valid             (decode_valid),
        .decode_ready             (decode_ready),
        .decode_uop               (decode_uop),
        .commit                    (commit_internal),
        .recover_valid            (recover_valid),
        .recover_id               (recover_id),
        .rob_live_mask            (rob_live_mask),
        .rob_alloc_ready          (rob_alloc_ready),
        .rob_alloc_id             (rob_alloc_id),
        .scheduler_dispatch_ready(scheduler_dispatch_ready),
        .rob_query_done           (rob_query_done),
        .rob_query_value          (rob_query_value),
        .rob_query_id             (rob_query_id),
        .complete                 (complete),
        .dispatch                 (dispatch)
    );

    assign dispatch_valid[0] = dispatch[0].valid;
    assign dispatch_valid[1] = dispatch[1].valid;
    assign perf_dispatch_fire0 = dispatch_valid[0] && scheduler_dispatch_ready[0];
    assign perf_dispatch_fire1 = dispatch_valid[1] && scheduler_dispatch_ready[1];

    Scheduler u_scheduler (
        .clk                  (clk),
        .rstn                 (rstn),
        .flush                (flush),
        .recover_valid        (recover_valid),
        .system_flush         (system_flush),
        .recover_id           (recover_id),
        .barrier_release      (system_complete.valid),
        .dispatch0_valid      (dispatch[0].valid),
        .dispatch0_ready      (scheduler_dispatch_ready[0]),
        .dispatch0_uop        (dispatch[0].uop),
        .dispatch0_src0_ready (dispatch[0].src0_ready),
        .dispatch0_src0_id    (dispatch[0].src0_id),
        .dispatch0_src1_ready (dispatch[0].src1_ready),
        .dispatch0_src1_id    (dispatch[0].src1_id),
        .dispatch1_valid      (dispatch[1].valid),
        .dispatch1_ready      (scheduler_dispatch_ready[1]),
        .dispatch1_uop        (dispatch[1].uop),
        .dispatch1_src0_ready (dispatch[1].src0_ready),
        .dispatch1_src0_id    (dispatch[1].src0_id),
        .dispatch1_src1_ready (dispatch[1].src1_ready),
        .dispatch1_src1_id    (dispatch[1].src1_id),
        .complete0            (complete[0]),
        .complete1            (complete[1]),
        .commit0              (commit_internal[0]),
        .commit1              (commit_internal[1]),
        .rob_head_valid       (rob_head_valid),
        .rob_head_tag         (rob_head_tag),
        .rob_head_id          (rob_head_id),
        .system_inflight      (system_inflight),
        .issue0_valid     (issue0_valid),
        .issue0_ready     (issue0_ready),
        .issue0_fire      (issue0_fire),
        .issue0           (issue0),
        .system_issue_valid   (system_issue_valid),
        .system_issue_ready   (system_issue_ready),
        .system_issue_fire    (system_issue_fire),
        .system_issue         (system_issue),
        .issue1_valid         (issue1_valid),
        .issue1_ready         (issue1_ready),
        .issue1_fire          (issue1_fire),
        .issue1               (issue1),
        .occupancy            (scheduler_occupancy),
        .perf_true_source_wait(perf_true_source_wait),
        .perf_lsu_order       (perf_lsu_order),
        .perf_serializing     (perf_serializing)
    );

    CompletionRouter u_completion_router (
        .main_complete_in   (main_complete),
        .system_complete_in (system_complete),
        .issue1_complete_in (issue1_complete),
        .rob_live_mask      (rob_live_mask),
        .complete0          (complete[0]),
        .complete1          (complete[1])
    );

    CommitRecovery u_commit_recovery (
        .clk          (clk),
        .rstn         (rstn),
        .recover_valid(recover_valid),
        .recover_id   (recover_id),
        .alloc_valid  (dispatch_valid),
        .alloc_ready  (rob_alloc_ready),
        .alloc_id     (rob_alloc_id),
        .alloc_uop    (alloc_uop),
        .complete     (complete),
        .query_id     (rob_query_id),
        .query_done   (rob_query_done),
        .query_value  (rob_query_value),
        .rob_live_mask(rob_live_mask),
        .rob_occupancy(rob_occupancy),
        .rob_head_valid(rob_head_valid),
        .rob_head_tag (rob_head_tag),
        .rob_head_id  (rob_head_id),
        .commit       (commit_internal)
    );

    assign commit0 = commit_internal[0];
    assign commit1 = commit_internal[1];
    assign perf_rob_occupancy = rob_occupancy;
    assign perf_issue_occupancy = scheduler_occupancy;
    assign perf_rob_block = (decode_valid[0] && !rob_alloc_ready[0]) ||
                            (decode_valid[1] && !rob_alloc_ready[1]);
    assign perf_issue_queue_block =
                            (dispatch[0].valid && !scheduler_dispatch_ready[0]) ||
                            (dispatch[1].valid && !scheduler_dispatch_ready[1]);
    assign perf_serializing_block = system_inflight;

endmodule
