`timescale 1ns / 1ps

`include "defines.vh"

// Simulation-only performance counters.  They are deliberately excluded from
// synthesis so observation logic cannot become a high-fanout timing endpoint
// or obscure the real CPU critical path in Vivado reports.
module PerformanceCounters (
    input  logic                    clk,
    input  logic                    rstn,
    input  logic [1:0]              decode_valid,
    input  logic                    decode_ready,
    input  logic                    issue0_valid,
    input  logic                    issue0_ready,
    input  logic                    issue0_fire,
    input  logic                    issue1_valid,
    input  logic                    issue1_ready,
    input  logic                    issue1_fire,
    input  logic                    system_issue_valid,
    input  logic                    system_issue_ready,
    input  logic                    system_issue_fire,
    input  logic                    commit0_valid,
    input  logic                    commit1_valid,
    input  logic [`ROB_TAG_W:0]     rob_occupancy,
    input  logic [2:0]              issue_occupancy,
    input  logic [2:0]              lq_occupancy,
    input  logic [2:0]              sq_occupancy,
    input  logic [2:0]              sb_occupancy,
    input  logic                    rob_block,
    input  logic                    issue_queue_block,
    input  logic                    source_wait,
    input  logic                    serializing_block,
    input  logic                    lsu_order_block,
    input  logic                    lsu_queue_block,
    input  logic                    muldiv_block,
    input  logic                    privilege_block,
    input  logic                    bpu_wait,
    input  logic                    icache_wait,
    input  logic                    dcache_wait,
    input  logic                    dcache_backpressure,
    input  logic                    load_issue,
    input  logic                    load_forward,
    input  logic                    load_response,
    input  logic                    store_issue,
    input  logic                    store_release,
    input  logic                    store_drain,
    input  logic                    recovery
);
`ifndef SYNTHESIS
    wire [1:0] issue_width = {1'b0, issue0_fire} +
                             {1'b0, issue1_fire} +
                             {1'b0, system_issue_fire};
    wire [1:0] retire_width = {1'b0, commit0_valid} +
                              {1'b0, commit1_valid};
    wire any_issue = |issue_width;

    (* keep = "true", mark_debug = "true" *) logic [63:0] perf_cycles;
    (* keep = "true", mark_debug = "true" *) logic [63:0] perf_issued_uops;
    (* keep = "true", mark_debug = "true" *) logic [63:0] perf_retired_uops;
    (* keep = "true", mark_debug = "true" *) logic [63:0] perf_issue_width0_cycles;
    (* keep = "true", mark_debug = "true" *) logic [63:0] perf_issue_width1_cycles;
    (* keep = "true", mark_debug = "true" *) logic [63:0] perf_issue_width2_cycles;
    (* keep = "true", mark_debug = "true" *) logic [63:0] perf_issue_width3_cycles;
    (* keep = "true", mark_debug = "true" *) logic [63:0] perf_retire_width0_cycles;
    (* keep = "true", mark_debug = "true" *) logic [63:0] perf_retire_width1_cycles;
    (* keep = "true", mark_debug = "true" *) logic [63:0] perf_retire_width2_cycles;

    (* keep = "true", mark_debug = "true" *) logic [63:0] perf_rob_occupancy_sum;
    (* keep = "true", mark_debug = "true" *) logic [63:0] perf_issue_occupancy_sum;
    (* keep = "true", mark_debug = "true" *) logic [`ROB_TAG_W:0] perf_rob_occupancy_max;
    (* keep = "true", mark_debug = "true" *) logic [2:0] perf_issue_occupancy_max;
    (* keep = "true", mark_debug = "true" *) logic [63:0] perf_rob_full_cycles;
    (* keep = "true", mark_debug = "true" *) logic [63:0] perf_issue_queue_full_cycles;
    (* keep = "true", mark_debug = "true" *) logic [63:0] perf_lq_full_cycles;
    (* keep = "true", mark_debug = "true" *) logic [63:0] perf_sq_full_cycles;
    (* keep = "true", mark_debug = "true" *) logic [63:0] perf_sb_full_cycles;

    (* keep = "true", mark_debug = "true" *) logic [63:0] perf_decode_backpressure_cycles;
    (* keep = "true", mark_debug = "true" *) logic [63:0] perf_rob_block_cycles;
    (* keep = "true", mark_debug = "true" *) logic [63:0] perf_issue_queue_block_cycles;
    (* keep = "true", mark_debug = "true" *) logic [63:0] perf_source_wait_cycles;
    (* keep = "true", mark_debug = "true" *) logic [63:0] perf_issue0_block_cycles;
    (* keep = "true", mark_debug = "true" *) logic [63:0] perf_issue1_block_cycles;
    (* keep = "true", mark_debug = "true" *) logic [63:0] perf_system_issue_block_cycles;
    (* keep = "true", mark_debug = "true" *) logic [63:0] perf_serializing_block_cycles;
    (* keep = "true", mark_debug = "true" *) logic [63:0] perf_lsu_order_block_cycles;
    (* keep = "true", mark_debug = "true" *) logic [63:0] perf_lsu_queue_block_cycles;
    (* keep = "true", mark_debug = "true" *) logic [63:0] perf_muldiv_block_cycles;
    (* keep = "true", mark_debug = "true" *) logic [63:0] perf_privilege_block_cycles;
    (* keep = "true", mark_debug = "true" *) logic [63:0] perf_bpu_wait_cycles;
    (* keep = "true", mark_debug = "true" *) logic [63:0] perf_icache_wait_cycles;
    (* keep = "true", mark_debug = "true" *) logic [63:0] perf_dcache_wait_cycles;
    (* keep = "true", mark_debug = "true" *) logic [63:0] perf_dcache_backpressure_cycles;
    (* keep = "true", mark_debug = "true" *) logic [63:0] perf_load_issue_count;
    (* keep = "true", mark_debug = "true" *) logic [63:0] perf_load_forward_count;
    (* keep = "true", mark_debug = "true" *) logic [63:0] perf_load_response_count;
    (* keep = "true", mark_debug = "true" *) logic [63:0] perf_store_issue_count;
    (* keep = "true", mark_debug = "true" *) logic [63:0] perf_store_release_count;
    (* keep = "true", mark_debug = "true" *) logic [63:0] perf_store_drain_count;
    (* keep = "true", mark_debug = "true" *) logic [63:0] perf_recovery_count;
    (* keep = "true", mark_debug = "true" *) logic [63:0] perf_recovery_loss_cycles;
    (* keep = "true", mark_debug = "true" *) logic recovery_penalty_active;

    always_ff @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            perf_cycles <= 0;
            perf_issued_uops <= 0;
            perf_retired_uops <= 0;
            perf_issue_width0_cycles <= 0;
            perf_issue_width1_cycles <= 0;
            perf_issue_width2_cycles <= 0;
            perf_issue_width3_cycles <= 0;
            perf_retire_width0_cycles <= 0;
            perf_retire_width1_cycles <= 0;
            perf_retire_width2_cycles <= 0;
            perf_rob_occupancy_sum <= 0;
            perf_issue_occupancy_sum <= 0;
            perf_rob_occupancy_max <= 0;
            perf_issue_occupancy_max <= 0;
            perf_rob_full_cycles <= 0;
            perf_issue_queue_full_cycles <= 0;
            perf_lq_full_cycles <= 0;
            perf_sq_full_cycles <= 0;
            perf_sb_full_cycles <= 0;
            perf_decode_backpressure_cycles <= 0;
            perf_rob_block_cycles <= 0;
            perf_issue_queue_block_cycles <= 0;
            perf_source_wait_cycles <= 0;
            perf_issue0_block_cycles <= 0;
            perf_issue1_block_cycles <= 0;
            perf_system_issue_block_cycles <= 0;
            perf_serializing_block_cycles <= 0;
            perf_lsu_order_block_cycles <= 0;
            perf_lsu_queue_block_cycles <= 0;
            perf_muldiv_block_cycles <= 0;
            perf_privilege_block_cycles <= 0;
            perf_bpu_wait_cycles <= 0;
            perf_icache_wait_cycles <= 0;
            perf_dcache_wait_cycles <= 0;
            perf_dcache_backpressure_cycles <= 0;
            perf_load_issue_count <= 0;
            perf_load_forward_count <= 0;
            perf_load_response_count <= 0;
            perf_store_issue_count <= 0;
            perf_store_release_count <= 0;
            perf_store_drain_count <= 0;
            perf_recovery_count <= 0;
            perf_recovery_loss_cycles <= 0;
            recovery_penalty_active <= 1'b0;
        end else begin
            perf_cycles <= perf_cycles + 1;
            perf_issued_uops <= perf_issued_uops + issue_width;
            perf_retired_uops <= perf_retired_uops + retire_width;
            case (issue_width)
                0: perf_issue_width0_cycles <= perf_issue_width0_cycles + 1;
                1: perf_issue_width1_cycles <= perf_issue_width1_cycles + 1;
                2: perf_issue_width2_cycles <= perf_issue_width2_cycles + 1;
                default: perf_issue_width3_cycles <= perf_issue_width3_cycles + 1;
            endcase
            case (retire_width)
                0: perf_retire_width0_cycles <= perf_retire_width0_cycles + 1;
                1: perf_retire_width1_cycles <= perf_retire_width1_cycles + 1;
                default: perf_retire_width2_cycles <= perf_retire_width2_cycles + 1;
            endcase

            perf_rob_occupancy_sum <= perf_rob_occupancy_sum + rob_occupancy;
            perf_issue_occupancy_sum <= perf_issue_occupancy_sum + issue_occupancy;
            if (rob_occupancy > perf_rob_occupancy_max)
                perf_rob_occupancy_max <= rob_occupancy;
            if (issue_occupancy > perf_issue_occupancy_max)
                perf_issue_occupancy_max <= issue_occupancy;
            if (rob_occupancy == `ROB_DEPTH) perf_rob_full_cycles <= perf_rob_full_cycles + 1;
            if (issue_occupancy == 4) perf_issue_queue_full_cycles <= perf_issue_queue_full_cycles + 1;
            if (lq_occupancy == 4) perf_lq_full_cycles <= perf_lq_full_cycles + 1;
            if (sq_occupancy == 4) perf_sq_full_cycles <= perf_sq_full_cycles + 1;
            if (sb_occupancy == 4) perf_sb_full_cycles <= perf_sb_full_cycles + 1;

            if ((|decode_valid) && !decode_ready) perf_decode_backpressure_cycles <= perf_decode_backpressure_cycles + 1;
            if (rob_block) perf_rob_block_cycles <= perf_rob_block_cycles + 1;
            if (issue_queue_block) perf_issue_queue_block_cycles <= perf_issue_queue_block_cycles + 1;
            if (source_wait) perf_source_wait_cycles <= perf_source_wait_cycles + 1;
            if (issue0_valid && !issue0_ready) perf_issue0_block_cycles <= perf_issue0_block_cycles + 1;
            if (issue1_valid && !issue1_ready) perf_issue1_block_cycles <= perf_issue1_block_cycles + 1;
            if (system_issue_valid && !system_issue_ready) perf_system_issue_block_cycles <= perf_system_issue_block_cycles + 1;
            if (serializing_block) perf_serializing_block_cycles <= perf_serializing_block_cycles + 1;
            if (lsu_order_block) perf_lsu_order_block_cycles <= perf_lsu_order_block_cycles + 1;
            if (lsu_queue_block) perf_lsu_queue_block_cycles <= perf_lsu_queue_block_cycles + 1;
            if (muldiv_block) perf_muldiv_block_cycles <= perf_muldiv_block_cycles + 1;
            if (privilege_block) perf_privilege_block_cycles <= perf_privilege_block_cycles + 1;
            if (bpu_wait) perf_bpu_wait_cycles <= perf_bpu_wait_cycles + 1;
            if (icache_wait) perf_icache_wait_cycles <= perf_icache_wait_cycles + 1;
            if (dcache_wait) perf_dcache_wait_cycles <= perf_dcache_wait_cycles + 1;
            if (dcache_backpressure) perf_dcache_backpressure_cycles <= perf_dcache_backpressure_cycles + 1;
            if (load_issue) perf_load_issue_count <= perf_load_issue_count + 1;
            if (load_forward) perf_load_forward_count <= perf_load_forward_count + 1;
            if (load_response) perf_load_response_count <= perf_load_response_count + 1;
            if (store_issue) perf_store_issue_count <= perf_store_issue_count + 1;
            if (store_release) perf_store_release_count <= perf_store_release_count + 1;
            if (store_drain) perf_store_drain_count <= perf_store_drain_count + 1;

            if (recovery) begin
                perf_recovery_count <= perf_recovery_count + 1;
                recovery_penalty_active <= 1'b1;
            end else if (recovery_penalty_active && any_issue) begin
                recovery_penalty_active <= 1'b0;
            end else if (recovery_penalty_active) begin
                perf_recovery_loss_cycles <= perf_recovery_loss_cycles + 1;
            end

`ifndef SYNTHESIS
            if ($test$plusargs("perf_log") &&
                (((perf_cycles + 1) % 10000) == 0))
                $display("[PERF] cyc=%0d issue=%0d retire=%0d rob_occ_sum=%0d iq_occ_sum=%0d rob_full=%0d iq_full=%0d lq/sq/sb_full=%0d/%0d/%0d block rob/iq/src/lsuord/lsuq=%0d/%0d/%0d/%0d/%0d wait bpu/ic/dc=%0d/%0d/%0d mem ld/ldf/ldr/st/rel/drain=%0d/%0d/%0d/%0d/%0d/%0d recovery=%0d loss=%0d",
                    perf_cycles + 1, perf_issued_uops + issue_width,
                    perf_retired_uops + retire_width, perf_rob_occupancy_sum,
                    perf_issue_occupancy_sum, perf_rob_full_cycles,
                    perf_issue_queue_full_cycles, perf_lq_full_cycles,
                    perf_sq_full_cycles, perf_sb_full_cycles,
                    perf_rob_block_cycles, perf_issue_queue_block_cycles,
                    perf_source_wait_cycles, perf_lsu_order_block_cycles,
                    perf_lsu_queue_block_cycles, perf_bpu_wait_cycles,
                    perf_icache_wait_cycles, perf_dcache_wait_cycles,
                    perf_load_issue_count, perf_load_forward_count,
                    perf_load_response_count, perf_store_issue_count,
                    perf_store_release_count, perf_store_drain_count,
                    perf_recovery_count, perf_recovery_loss_cycles);
`endif
        end
    end
`endif
endmodule
