`timescale 1ns / 1ps

`include "defines.vh"

import cpu_types_pkg::*;

// ROB ownership boundary. Retirement remains ordered: commit[0] is older
// than commit[1], while all lane/query traffic uses arrays.
module CommitRecovery (
    input  logic                    clk,
    input  logic                    rstn,
    input  logic                    recover_valid,
    input  uop_id_t                 recover_id,

    input  logic [1:0]              alloc_valid,
    output logic [1:0]              alloc_ready,
    output uop_id_t                 alloc_id [0:1],
    input  issue_uop_t              alloc_uop [0:1],

    input  completion_t              complete [0:1],

    input  uop_id_t                 query_id [0:3],
    output logic                    query_done [0:3],
    output logic [31:0]             query_value [0:3],

    output logic [`ROB_DEPTH-1:0]   rob_live_mask,
    output logic [`ROB_TAG_W:0]     rob_occupancy,
    output logic                    rob_head_valid,
    output logic [`ROB_TAG_W-1:0]   rob_head_tag,
    output uop_id_t                 rob_head_id,
    output commit_t                 commit [0:1]
);

    ReorderBuffer u_reorder_buffer (
        .clk         (clk),
        .rstn        (rstn),
        .alloc_valid (alloc_valid),
        .alloc_ready (alloc_ready),
        .alloc_id    (alloc_id),
        .alloc_uop   (alloc_uop),
        .complete    (complete),
        .recover_valid(recover_valid),
        .recover_id  (recover_id),
        .commit      (commit),
        .query_id    (query_id),
        .query_done  (query_done),
        .query_value (query_value),
        .live_mask   (rob_live_mask),
        .head_id     (rob_head_id),
        .occupancy   (rob_occupancy)
    );

    assign rob_head_tag = rob_head_id.rob_tag;
    assign rob_head_valid = rob_live_mask[rob_head_tag];

endmodule
