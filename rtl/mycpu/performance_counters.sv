`timescale 1ns / 1ps
`include "defines.vh"

// Observation-only performance accounting.  All state and all plusarg/print
// logic are simulation-only; no counter feeds a functional control signal.
module PerformanceCounters #(
    parameter integer ROB_DEPTH_P = `ROB_DEPTH,
    parameter integer IQ_DEPTH_P  = 8,
    parameter integer LQ_DEPTH_P  = 8,
    parameter integer SQ_DEPTH_P  = 4,
    parameter integer SB_DEPTH_P  = 4
) (
    input logic                    clk,
    input logic                    rstn,
    input logic [1:0]              decode_valid,
    input logic                    decode_ready,
    input logic                    issue0_valid,
    input logic                    issue0_ready,
    input logic                    issue0_fire,
    input logic                    issue1_valid,
    input logic                    issue1_ready,
    input logic                    issue1_fire,
    input logic                    system_issue_valid,
    input logic                    system_issue_ready,
    input logic                    system_issue_fire,
    input logic                    commit0_valid,
    input logic [31:0]             commit0_pc,
    input logic                    commit1_valid,
    input logic [31:0]             commit1_pc,
    input logic [`ROB_TAG_W:0]     rob_occupancy,
    input logic [3:0]              issue_occupancy,
    input logic [3:0]              lq_occupancy,
    input logic [2:0]              sq_occupancy,
    input logic [2:0]              sb_occupancy,
    input logic                    rob_block,
    input logic                    issue_queue_block,
    input logic                    source_wait,
    input logic                    source_wait_dep_load,
    input logic                    source_wait_dep_muldiv,
    input logic                    source_wait_dep_alu,
    input logic                    source_wait_dep_branch,
    input logic                    source_wait_store_addr,
    input logic                    source_wait_store_data,
    input logic                    iq_no_ready,
    input logic                    serializing_block,
    input logic                    lsu_order_block,
    input logic                    lsu_queue_block,
    input logic                    muldiv_block,
    input logic                    privilege_block,
    input logic                    bpu_wait,
    input logic                    icache_wait,
    input logic                    dcache_wait,
    input logic                    dcache_backpressure,
    input logic                    load_issue,
    input logic                    load_forward,
    input logic                    load_response,
    input logic                    store_issue,
    input logic                    store_release,
    input logic                    store_drain,
    input logic                    recovery,
    input logic                    fetch_fire0,
    input logic                    fetch_fire1,
    input logic                    dispatch_fire0,
    input logic                    dispatch_fire1,
    input logic                    branch_fire,
    input logic                    branch_predicted_taken,
    input logic                    branch_actual_taken,
    input logic                    branch_mispredict
);
`ifndef SYNTHESIS
    localparam integer PRIMARY_REASON_COUNT = 12;

    typedef enum logic [3:0] {
        PRIMARY_RECOVERY = 4'd0,
        PRIMARY_SERIAL   = 4'd1,
        PRIMARY_ICACHE   = 4'd2,
        PRIMARY_FRONTEND = 4'd3,
        PRIMARY_DECODE   = 4'd4,
        PRIMARY_IQ_EMPTY = 4'd5,
        PRIMARY_SOURCE   = 4'd6,
        PRIMARY_LSU_ORDER= 4'd7,
        PRIMARY_QUEUE    = 4'd8,
        PRIMARY_DC_WAIT  = 4'd9,
        PRIMARY_DC_BACK  = 4'd10,
        PRIMARY_OTHER    = 4'd11
    } primary_reason_t;

    logic [31:0] perf_start_pc_cfg;
    logic [31:0] perf_end_pc_cfg;
    integer perf_start_count_cfg;
    integer perf_log_interval_cfg;
    integer perf_summary_interval_cfg;
    logic perf_start_arg;
    logic perf_end_arg;
    logic perf_count_arg;
    logic perf_log_arg;
    logic perf_summary_arg;
    logic perf_summary_interval_arg;
    logic perf_window_started;
    logic perf_window_done;
    logic perf_summary_printed;
    logic recovery_penalty_active;

    // Base cycle counter
    logic [63:0] perf_cycles_global;

    wire [1:0] issue_width = {1'b0, issue0_fire} +
                             {1'b0, issue1_fire} +
                             {1'b0, system_issue_fire};
    wire [1:0] retire_width = {1'b0, commit0_valid} +
                              {1'b0, commit1_valid};
    wire [1:0] decode_accept_width = decode_ready ?
                                     ({1'b0, decode_valid[0]} +
                                      {1'b0, decode_valid[1]}) : 2'd0;
    wire [1:0] dispatch_width = {1'b0, dispatch_fire0} +
                                {1'b0, dispatch_fire1};
    wire [1:0] fetch_width = {1'b0, fetch_fire0} +
                             {1'b0, fetch_fire1};

    wire start_pc_hit = (commit0_valid && (commit0_pc == perf_start_pc_cfg)) ||
                        (commit1_valid && (commit1_pc == perf_start_pc_cfg));
    wire end_pc_hit = (commit0_valid && (commit0_pc == perf_end_pc_cfg)) ||
                      (commit1_valid && (commit1_pc == perf_end_pc_cfg));
    
    wire window_start_event = (!perf_window_started && !perf_window_done) &&
                              ((perf_start_arg && start_pc_hit) ||
                               (perf_count_arg && perf_cycles_global == perf_start_count_cfg));

    wire window_measure = !perf_window_done &&
                          (!perf_start_arg && !perf_count_arg || perf_window_started ||
                           start_pc_hit || (perf_count_arg && perf_cycles_global == perf_start_count_cfg));
                           
    wire window_end_event = window_measure && perf_end_arg && end_pc_hit;

    wire window_open_pulse = window_start_event;

    // Mutually Exclusive Zero-Issue Categories
    primary_reason_t primary_reason;
    always_comb begin
        primary_reason = PRIMARY_OTHER;
        if (issue_width == 0) begin
            if (recovery_penalty_active)
                primary_reason = PRIMARY_RECOVERY;
            else if (privilege_block || serializing_block)
                primary_reason = PRIMARY_SERIAL;
            else if (icache_wait)
                primary_reason = PRIMARY_ICACHE;
            else if (decode_valid == 0)
                primary_reason = PRIMARY_FRONTEND;
            else if (issue_occupancy == 0)
                primary_reason = PRIMARY_DECODE;
            else if (source_wait)
                primary_reason = PRIMARY_SOURCE;
            else if (lsu_order_block)
                primary_reason = PRIMARY_LSU_ORDER;
            else if (lsu_queue_block || rob_block || issue_queue_block)
                primary_reason = PRIMARY_QUEUE;
            else if (dcache_wait)
                primary_reason = PRIMARY_DC_WAIT;
            else if (dcache_backpressure)
                primary_reason = PRIMARY_DC_BACK;
        end
    end

    // Storage for all counters
    logic [63:0] perf_cycles;
    logic [63:0] perf_fetch_uops;
    logic [63:0] perf_decode_uops;
    logic [63:0] perf_dispatch_uops;
    logic [63:0] perf_issued_uops;
    logic [63:0] perf_retired_uops;
    
    logic [63:0] perf_issue_width0_cycles;
    logic [63:0] perf_issue_width1_cycles;
    logic [63:0] perf_issue_width2_cycles;
    
    logic [63:0] perf_retire_width0_cycles;
    logic [63:0] perf_retire_width1_cycles;
    logic [63:0] perf_retire_width2_cycles;
    
    logic [63:0] perf_rob_occupancy_sum;
    logic [63:0] perf_issue_occupancy_sum;
    logic [63:0] perf_lq_occupancy_sum;
    logic [63:0] perf_sq_occupancy_sum;
    logic [63:0] perf_sb_occupancy_sum;
    
    logic [`ROB_TAG_W:0] perf_rob_occupancy_max;
    logic [3:0] perf_issue_occupancy_max;
    logic [3:0] perf_lq_occupancy_max;
    logic [2:0] perf_sq_occupancy_max;
    logic [2:0] perf_sb_occupancy_max;

    // Raw overlapping stall counters
    logic [63:0] raw_source_wait_cycles;
    logic [63:0] raw_source_wait_dep_load_cycles;
    logic [63:0] raw_source_wait_dep_muldiv_cycles;
    logic [63:0] raw_source_wait_dep_alu_cycles;
    logic [63:0] raw_source_wait_dep_branch_cycles;
    logic [63:0] raw_source_wait_store_addr_cycles;
    logic [63:0] raw_source_wait_store_data_cycles;
    logic [63:0] raw_iq_no_ready_cycles;
    logic [63:0] raw_source_wait_stalled_cycles;
    logic [63:0] raw_lsu_order_block_cycles;
    logic [63:0] raw_lsu_queue_block_cycles;
    logic [63:0] raw_dcache_wait_cycles;
    logic [63:0] raw_dcache_backpressure_cycles;
    logic [63:0] raw_iq_full_cycles;
    logic [63:0] raw_lq_full_cycles;
    logic [63:0] raw_rob_full_cycles;
    logic [63:0] raw_muldiv_block_cycles;

    // Memory event counters
    logic [63:0] perf_load_issue_count;
    logic [63:0] perf_load_forward_count;
    logic [63:0] perf_load_response_count;
    logic [63:0] perf_store_issue_count;
    logic [63:0] perf_store_release_count;
    logic [63:0] perf_store_drain_count;
    
    logic [63:0] perf_branch_count;
    logic [63:0] perf_branch_taken_count;
    logic [63:0] perf_branch_predicted_taken_count;
    logic [63:0] perf_branch_mispredict_count;
    logic [63:0] perf_pred_nt_actual_nt;
    logic [63:0] perf_pred_nt_actual_t;
    logic [63:0] perf_pred_t_actual_nt;
    logic [63:0] perf_pred_t_actual_t;
    logic [63:0] perf_recovery_count;

    wire [63:0] branch_count_next = perf_branch_count + branch_fire;
    wire [63:0] branch_taken_count_next = perf_branch_taken_count +
                                                   (branch_fire && branch_actual_taken);
    wire [63:0] branch_predicted_taken_count_next =
        perf_branch_predicted_taken_count +
        (branch_fire && branch_predicted_taken);
    wire [63:0] branch_mispredict_count_next =
        perf_branch_mispredict_count +
        (branch_fire && branch_mispredict);
    wire [63:0] pred_nt_actual_nt_next = perf_pred_nt_actual_nt +
        (branch_fire && !branch_predicted_taken && !branch_actual_taken);
    wire [63:0] pred_nt_actual_t_next = perf_pred_nt_actual_t +
        (branch_fire && !branch_predicted_taken && branch_actual_taken);
    wire [63:0] pred_t_actual_nt_next = perf_pred_t_actual_nt +
        (branch_fire && branch_predicted_taken && !branch_actual_taken);
    wire [63:0] pred_t_actual_t_next = perf_pred_t_actual_t +
        (branch_fire && branch_predicted_taken && branch_actual_taken);
    
    logic [63:0] perf_primary [0:PRIMARY_REASON_COUNT-1];
    
    logic [63:0] interval_cycles;
    logic [63:0] interval_decode_uops;
    logic [63:0] interval_issued_uops;
    logic [63:0] interval_retired_uops;
    logic [63:0] interval_rob_occ_sum;
    logic [63:0] interval_iq_occ_sum;
    
    logic [63:0] interval_snapshot_cycles;
    logic [63:0] interval_snapshot_decode_uops;
    logic [63:0] interval_snapshot_issued_uops;
    logic [63:0] interval_snapshot_retired_uops;
    logic [63:0] interval_snapshot_rob_occ_sum;
    logic [63:0] interval_snapshot_iq_occ_sum;
    
    // Arrays for histograms
    logic [63:0] rob_hist [0:ROB_DEPTH_P];
    logic [63:0] iq_hist [0:IQ_DEPTH_P];
    logic [63:0] lq_hist [0:LQ_DEPTH_P];
    logic [63:0] sq_hist [0:SQ_DEPTH_P];
    logic [63:0] sb_hist [0:SB_DEPTH_P];

    initial begin
        perf_start_pc_cfg = 32'h0;
        perf_end_pc_cfg = 32'h0;
        perf_log_interval_cfg = 10000;
        perf_start_count_cfg = 0;
        perf_summary_interval_cfg = 100000;
        perf_summary_interval_arg = 1;
        perf_summary_arg = 1;
        perf_start_arg = $value$plusargs("perf_start_pc=%h", perf_start_pc_cfg);
        perf_end_arg = $value$plusargs("perf_end_pc=%h", perf_end_pc_cfg);
        perf_count_arg = $value$plusargs("perf_start_count=%d", perf_start_count_cfg);
        perf_log_arg = $test$plusargs("perf_log");
        if ($test$plusargs("perf_summary")) perf_summary_arg = 1;
        if ($value$plusargs("perf_summary_interval=%d", perf_summary_interval_cfg))
            perf_summary_interval_arg = 1;
        if (!$value$plusargs("perf_log_interval=%d", perf_log_interval_cfg) ||
            (perf_log_interval_cfg < 1))
            perf_log_interval_cfg = 10000;
    end

    function automatic real ratio_pct(input logic [63:0] numerator, input logic [63:0] denominator);
        real nreal;
        real dreal;
        begin
            nreal = numerator;
            dreal = denominator;
            if (denominator == 0) ratio_pct = 0.0;
            else ratio_pct = 100.0 * nreal / dreal;
        end
    endfunction
    
    function automatic string primary_name(input integer reason);
        begin
            case (reason)
                PRIMARY_RECOVERY: primary_name = "recovery_penalty";
                PRIMARY_SERIAL: primary_name = "privilege_serial";
                PRIMARY_ICACHE: primary_name = "icache_wait";
                PRIMARY_FRONTEND: primary_name = "frontend_empty";
                PRIMARY_DECODE: primary_name = "decode_empty";
                PRIMARY_IQ_EMPTY: primary_name = "iq_empty";
                PRIMARY_SOURCE: primary_name = "source_wait";
                PRIMARY_LSU_ORDER: primary_name = "lsu_order";
                PRIMARY_QUEUE: primary_name = "queue_block";
                PRIMARY_DC_WAIT: primary_name = "dcache_wait";
                PRIMARY_DC_BACK: primary_name = "dcache_backpressure";
                PRIMARY_OTHER: primary_name = "other";
                default: primary_name = "unknown";
            endcase
        end
    endfunction

    always_ff @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            perf_cycles_global <= 0;
            perf_window_started <= 1'b0;
            perf_window_done <= 1'b0;
            perf_summary_printed <= 1'b0;
            recovery_penalty_active <= 1'b0;
            perf_cycles <= 0;
            perf_fetch_uops <= 0;
            perf_decode_uops <= 0;
            perf_dispatch_uops <= 0;
            perf_issued_uops <= 0;
            perf_retired_uops <= 0;
            perf_issue_width0_cycles <= 0;
            perf_issue_width1_cycles <= 0;
            perf_issue_width2_cycles <= 0;
            perf_retire_width0_cycles <= 0;
            perf_retire_width1_cycles <= 0;
            perf_retire_width2_cycles <= 0;
            perf_rob_occupancy_sum <= 0;
            perf_issue_occupancy_sum <= 0;
            perf_lq_occupancy_sum <= 0;
            perf_sq_occupancy_sum <= 0;
            perf_sb_occupancy_sum <= 0;
            perf_rob_occupancy_max <= 0;
            perf_issue_occupancy_max <= 0;
            perf_lq_occupancy_max <= 0;
            perf_sq_occupancy_max <= 0;
            perf_sb_occupancy_max <= 0;
            perf_branch_count <= 0;
            perf_branch_taken_count <= 0;
            perf_branch_predicted_taken_count <= 0;
            perf_branch_mispredict_count <= 0;
            perf_pred_nt_actual_nt <= 0;
            perf_pred_nt_actual_t <= 0;
            perf_pred_t_actual_nt <= 0;
            perf_pred_t_actual_t <= 0;
            perf_recovery_count <= 0;
            interval_cycles <= 0;
            interval_decode_uops <= 0;
            interval_issued_uops <= 0;
            interval_retired_uops <= 0;
            interval_rob_occ_sum <= 0;
            interval_iq_occ_sum <= 0;
            interval_snapshot_cycles <= 0;
            interval_snapshot_decode_uops <= 0;
            interval_snapshot_issued_uops <= 0;
            interval_snapshot_retired_uops <= 0;
            interval_snapshot_rob_occ_sum <= 0;
            interval_snapshot_iq_occ_sum <= 0;
            raw_source_wait_cycles <= 0;
            raw_source_wait_dep_load_cycles <= 0;
            raw_source_wait_dep_muldiv_cycles <= 0;
            raw_source_wait_dep_alu_cycles <= 0;
            raw_source_wait_dep_branch_cycles <= 0;
            raw_source_wait_store_addr_cycles <= 0;
            raw_source_wait_store_data_cycles <= 0;
            raw_iq_no_ready_cycles <= 0;
            raw_source_wait_stalled_cycles <= 0;
            raw_lsu_order_block_cycles <= 0;
            raw_lsu_queue_block_cycles <= 0;
            raw_dcache_wait_cycles <= 0;
            raw_dcache_backpressure_cycles <= 0;
            raw_iq_full_cycles <= 0;
            raw_lq_full_cycles <= 0;
            raw_rob_full_cycles <= 0;
            raw_muldiv_block_cycles <= 0;
            perf_load_issue_count <= 0;
            perf_load_forward_count <= 0;
            perf_load_response_count <= 0;
            perf_store_issue_count <= 0;
            perf_store_release_count <= 0;
            perf_store_drain_count <= 0;
            for (integer i=0; i<PRIMARY_REASON_COUNT; i++) perf_primary[i] <= 0;
            for (integer i=0; i<=ROB_DEPTH_P; i++) rob_hist[i] <= 0;
            for (integer i=0; i<=IQ_DEPTH_P; i++) iq_hist[i] <= 0;
            for (integer i=0; i<=LQ_DEPTH_P; i++) lq_hist[i] <= 0;
            for (integer i=0; i<=SQ_DEPTH_P; i++) sq_hist[i] <= 0;
            for (integer i=0; i<=SB_DEPTH_P; i++) sb_hist[i] <= 0;
        end else begin
            perf_cycles_global <= perf_cycles_global + 1;
            
            if (window_open_pulse) begin
                perf_window_started <= 1'b1;
                perf_cycles <= 0;
                perf_fetch_uops <= 0;
                perf_decode_uops <= 0;
                perf_dispatch_uops <= 0;
                perf_issued_uops <= 0;
                perf_retired_uops <= 0;
                perf_issue_width0_cycles <= 0;
                perf_issue_width1_cycles <= 0;
                perf_issue_width2_cycles <= 0;
                perf_retire_width0_cycles <= 0;
                perf_retire_width1_cycles <= 0;
                perf_retire_width2_cycles <= 0;
                perf_rob_occupancy_sum <= 0;
                perf_issue_occupancy_sum <= 0;
                perf_lq_occupancy_sum <= 0;
                perf_sq_occupancy_sum <= 0;
                perf_sb_occupancy_sum <= 0;
                perf_rob_occupancy_max <= 0;
                perf_issue_occupancy_max <= 0;
                perf_lq_occupancy_max <= 0;
                perf_sq_occupancy_max <= 0;
                perf_sb_occupancy_max <= 0;
                perf_branch_count <= 0;
                perf_branch_taken_count <= 0;
                perf_branch_predicted_taken_count <= 0;
                perf_branch_mispredict_count <= 0;
                perf_pred_nt_actual_nt <= 0;
                perf_pred_nt_actual_t <= 0;
                perf_pred_t_actual_nt <= 0;
                perf_pred_t_actual_t <= 0;
                perf_recovery_count <= 0;
                interval_cycles <= 0;
                interval_decode_uops <= 0;
                interval_issued_uops <= 0;
                interval_retired_uops <= 0;
                interval_rob_occ_sum <= 0;
                interval_iq_occ_sum <= 0;
                interval_snapshot_cycles <= 0;
                interval_snapshot_decode_uops <= 0;
                interval_snapshot_issued_uops <= 0;
                interval_snapshot_retired_uops <= 0;
                interval_snapshot_rob_occ_sum <= 0;
                interval_snapshot_iq_occ_sum <= 0;
                raw_source_wait_cycles <= 0;
                raw_source_wait_dep_load_cycles <= 0;
                raw_source_wait_dep_muldiv_cycles <= 0;
                raw_source_wait_dep_alu_cycles <= 0;
                raw_source_wait_dep_branch_cycles <= 0;
                raw_source_wait_store_addr_cycles <= 0;
                raw_source_wait_store_data_cycles <= 0;
                raw_iq_no_ready_cycles <= 0;
                raw_source_wait_stalled_cycles <= 0;
                raw_lsu_order_block_cycles <= 0;
                raw_lsu_queue_block_cycles <= 0;
                raw_dcache_wait_cycles <= 0;
                raw_dcache_backpressure_cycles <= 0;
                raw_iq_full_cycles <= 0;
                raw_lq_full_cycles <= 0;
                raw_rob_full_cycles <= 0;
                raw_muldiv_block_cycles <= 0;
                perf_load_issue_count <= 0;
                perf_load_forward_count <= 0;
                perf_load_response_count <= 0;
                perf_store_issue_count <= 0;
                perf_store_release_count <= 0;
                perf_store_drain_count <= 0;
                for (integer i=0; i<PRIMARY_REASON_COUNT; i++) perf_primary[i] <= 0;
                for (integer i=0; i<=ROB_DEPTH_P; i++) rob_hist[i] <= 0;
                for (integer i=0; i<=IQ_DEPTH_P; i++) iq_hist[i] <= 0;
                for (integer i=0; i<=LQ_DEPTH_P; i++) lq_hist[i] <= 0;
                for (integer i=0; i<=SQ_DEPTH_P; i++) sq_hist[i] <= 0;
                for (integer i=0; i<=SB_DEPTH_P; i++) sb_hist[i] <= 0;
            end
            
            if (window_end_event) begin
                perf_window_done <= 1'b1;
            end
            
            if (recovery) begin
                recovery_penalty_active <= 1'b1;
            end else if (issue_width > 0) begin
                recovery_penalty_active <= 1'b0;
            end
            
            if (window_measure) begin
                perf_cycles <= perf_cycles + 1;
                perf_fetch_uops <= perf_fetch_uops + fetch_width;
                perf_decode_uops <= perf_decode_uops + decode_accept_width;
                perf_dispatch_uops <= perf_dispatch_uops + dispatch_width;
                perf_issued_uops <= perf_issued_uops + issue_width;
                perf_retired_uops <= perf_retired_uops + retire_width;
                
                if (issue_width == 0) perf_issue_width0_cycles <= perf_issue_width0_cycles + 1;
                else if (issue_width == 1) perf_issue_width1_cycles <= perf_issue_width1_cycles + 1;
                else if (issue_width == 2) perf_issue_width2_cycles <= perf_issue_width2_cycles + 1;
                
                if (retire_width == 0) perf_retire_width0_cycles <= perf_retire_width0_cycles + 1;
                else if (retire_width == 1) perf_retire_width1_cycles <= perf_retire_width1_cycles + 1;
                else if (retire_width == 2) perf_retire_width2_cycles <= perf_retire_width2_cycles + 1;
                
                perf_rob_occupancy_sum <= perf_rob_occupancy_sum + rob_occupancy;
                perf_issue_occupancy_sum <= perf_issue_occupancy_sum + issue_occupancy;
                perf_lq_occupancy_sum <= perf_lq_occupancy_sum + lq_occupancy;
                perf_sq_occupancy_sum <= perf_sq_occupancy_sum + sq_occupancy;
                perf_sb_occupancy_sum <= perf_sb_occupancy_sum + sb_occupancy;
                
                if (rob_occupancy > perf_rob_occupancy_max) perf_rob_occupancy_max <= rob_occupancy;
                if (issue_occupancy > perf_issue_occupancy_max) perf_issue_occupancy_max <= issue_occupancy;
                if (lq_occupancy > perf_lq_occupancy_max) perf_lq_occupancy_max <= lq_occupancy;
                if (sq_occupancy > perf_sq_occupancy_max) perf_sq_occupancy_max <= sq_occupancy;
                if (sb_occupancy > perf_sb_occupancy_max) perf_sb_occupancy_max <= sb_occupancy;

                if (source_wait)            raw_source_wait_cycles <= raw_source_wait_cycles + 1;
                if (source_wait_dep_load)   raw_source_wait_dep_load_cycles <= raw_source_wait_dep_load_cycles + 1;
                if (source_wait_dep_muldiv) raw_source_wait_dep_muldiv_cycles <= raw_source_wait_dep_muldiv_cycles + 1;
                if (source_wait_dep_alu)    raw_source_wait_dep_alu_cycles <= raw_source_wait_dep_alu_cycles + 1;
                if (source_wait_dep_branch) raw_source_wait_dep_branch_cycles <= raw_source_wait_dep_branch_cycles + 1;
                if (source_wait_store_addr) raw_source_wait_store_addr_cycles <= raw_source_wait_store_addr_cycles + 1;
                if (source_wait_store_data) raw_source_wait_store_data_cycles <= raw_source_wait_store_data_cycles + 1;
                if (iq_no_ready)            raw_iq_no_ready_cycles <= raw_iq_no_ready_cycles + 1;
                if (source_wait && iq_no_ready) raw_source_wait_stalled_cycles <= raw_source_wait_stalled_cycles + 1;
                if (lsu_order_block)      raw_lsu_order_block_cycles <= raw_lsu_order_block_cycles + 1;
                if (lsu_queue_block)      raw_lsu_queue_block_cycles <= raw_lsu_queue_block_cycles + 1;
                if (dcache_wait)         raw_dcache_wait_cycles <= raw_dcache_wait_cycles + 1;
                if (dcache_backpressure) raw_dcache_backpressure_cycles <= raw_dcache_backpressure_cycles + 1;
                if (issue_occupancy == IQ_DEPTH_P) raw_iq_full_cycles <= raw_iq_full_cycles + 1;
                if (lq_occupancy == LQ_DEPTH_P)   raw_lq_full_cycles <= raw_lq_full_cycles + 1;
                if (rob_occupancy == ROB_DEPTH_P)  raw_rob_full_cycles <= raw_rob_full_cycles + 1;
                if (muldiv_block)        raw_muldiv_block_cycles <= raw_muldiv_block_cycles + 1;

                perf_load_issue_count    <= perf_load_issue_count + load_issue;
                perf_load_forward_count  <= perf_load_forward_count + load_forward;
                perf_load_response_count <= perf_load_response_count + load_response;
                perf_store_issue_count   <= perf_store_issue_count + store_issue;
                perf_store_release_count <= perf_store_release_count + store_release;
                perf_store_drain_count   <= perf_store_drain_count + store_drain;
                
                rob_hist[rob_occupancy] <= rob_hist[rob_occupancy] + 1;
                iq_hist[issue_occupancy] <= iq_hist[issue_occupancy] + 1;
                lq_hist[lq_occupancy] <= lq_hist[lq_occupancy] + 1;
                sq_hist[sq_occupancy] <= sq_hist[sq_occupancy] + 1;
                sb_hist[sb_occupancy] <= sb_hist[sb_occupancy] + 1;
                
                if (issue_width == 0) begin
                    perf_primary[primary_reason] <= perf_primary[primary_reason] + 1;
                end
                
                if (branch_fire) begin
                    perf_branch_count <= branch_count_next;
                    perf_branch_taken_count <= branch_taken_count_next;
                    perf_branch_predicted_taken_count <=
                        branch_predicted_taken_count_next;
                    perf_branch_mispredict_count <= branch_mispredict_count_next;
                    perf_pred_nt_actual_nt <= pred_nt_actual_nt_next;
                    perf_pred_nt_actual_t <= pred_nt_actual_t_next;
                    perf_pred_t_actual_nt <= pred_t_actual_nt_next;
                    perf_pred_t_actual_t <= pred_t_actual_t_next;

                    // Check the next values so the resolving branch on this
                    // clock edge is included despite nonblocking assignments.
                    if (branch_count_next !=
                        pred_nt_actual_nt_next + pred_nt_actual_t_next +
                        pred_t_actual_nt_next + pred_t_actual_t_next)
                        $fatal(1, "branch quadrant total mismatch");
                    if (branch_taken_count_next !=
                        pred_nt_actual_t_next + pred_t_actual_t_next)
                        $fatal(1, "branch taken quadrant mismatch");
                    if (branch_predicted_taken_count_next !=
                        pred_t_actual_nt_next + pred_t_actual_t_next)
                        $fatal(1, "branch predicted-taken quadrant mismatch");
                    if (branch_mispredict_count_next !=
                        pred_nt_actual_t_next + pred_t_actual_nt_next)
                        $fatal(1, "branch mispredict quadrant mismatch");
                end else if (branch_mispredict) begin
                    $fatal(1, "branch_mispredict asserted without branch_fire");
                end
                if (recovery)
                    perf_recovery_count <= perf_recovery_count + 1;
                
                interval_cycles <= interval_cycles + 1;
                interval_decode_uops <= interval_decode_uops + decode_accept_width;
                interval_issued_uops <= interval_issued_uops + issue_width;
                interval_retired_uops <= interval_retired_uops + retire_width;
                interval_rob_occ_sum <= interval_rob_occ_sum + rob_occupancy;
                interval_iq_occ_sum <= interval_iq_occ_sum + issue_occupancy;
                
                if (perf_log_arg && (interval_cycles == perf_log_interval_cfg - 1)) begin
                    interval_snapshot_cycles <= interval_cycles + 1;
                    interval_snapshot_decode_uops <= interval_decode_uops + decode_accept_width;
                    interval_snapshot_issued_uops <= interval_issued_uops + issue_width;
                    interval_snapshot_retired_uops <= interval_retired_uops + retire_width;
                    interval_snapshot_rob_occ_sum <= interval_rob_occ_sum + rob_occupancy;
                    interval_snapshot_iq_occ_sum <= interval_iq_occ_sum + issue_occupancy;
                    
                    interval_cycles <= 0;
                    interval_decode_uops <= 0;
                    interval_issued_uops <= 0;
                    interval_retired_uops <= 0;
                    interval_rob_occ_sum <= 0;
                    interval_iq_occ_sum <= 0;
                    
                    $display("[PERF-INTERVAL] cycles=%0d decode_ipc=%.4f issue_ipc=%.4f retire_ipc=%.4f rob_avg=%.4f iq_avg=%.4f",
                             perf_cycles + 1,
                             real'(interval_decode_uops + decode_accept_width) / (interval_cycles + 1),
                             real'(interval_issued_uops + issue_width) / (interval_cycles + 1),
                             real'(interval_retired_uops + retire_width) / (interval_cycles + 1),
                             real'(interval_rob_occ_sum + rob_occupancy) / (interval_cycles + 1),
                             real'(interval_iq_occ_sum + issue_occupancy) / (interval_cycles + 1));
                end
                
                if (perf_summary_interval_arg && (perf_cycles % perf_summary_interval_cfg == perf_summary_interval_cfg - 1)) begin
                    print_summary();
                end
            end
        end
    end

    task automatic print_summary;
        begin
            perf_summary_printed = 1'b1;
            if (perf_cycles == 0) begin
                $display("[PERF-SUMMARY] Error: No cycles measured.");
                return;
            end
            $display("==========================================================");
            $display("[PERF-SUMMARY-BEGIN]");
            $display("CYCLES=%0d", perf_cycles);
            $display("FETCHED_UOPS=%0d IPC=%.4f", perf_fetch_uops, real'(perf_fetch_uops) / perf_cycles);
            $display("DECODED_UOPS=%0d IPC=%.4f", perf_decode_uops, real'(perf_decode_uops) / perf_cycles);
            $display("DISPATCHED_UOPS=%0d IPC=%.4f", perf_dispatch_uops, real'(perf_dispatch_uops) / perf_cycles);
            $display("ISSUED_UOPS=%0d IPC=%.4f", perf_issued_uops, real'(perf_issued_uops) / perf_cycles);
            $display("RETIRED_UOPS=%0d IPC=%.4f", perf_retired_uops, real'(perf_retired_uops) / perf_cycles);
            $display("----------------------------------------------------------");
            $display("ISSUE_WIDTH_0_CYCLES=%0d PCT=%.2f%%", perf_issue_width0_cycles, ratio_pct(perf_issue_width0_cycles, perf_cycles));
            $display("ISSUE_WIDTH_1_CYCLES=%0d PCT=%.2f%%", perf_issue_width1_cycles, ratio_pct(perf_issue_width1_cycles, perf_cycles));
            $display("ISSUE_WIDTH_2_CYCLES=%0d PCT=%.2f%%", perf_issue_width2_cycles, ratio_pct(perf_issue_width2_cycles, perf_cycles));
            $display("----------------------------------------------------------");
            $display("RETIRE_WIDTH_0_CYCLES=%0d PCT=%.2f%%", perf_retire_width0_cycles, ratio_pct(perf_retire_width0_cycles, perf_cycles));
            $display("RETIRE_WIDTH_1_CYCLES=%0d PCT=%.2f%%", perf_retire_width1_cycles, ratio_pct(perf_retire_width1_cycles, perf_cycles));
            $display("RETIRE_WIDTH_2_CYCLES=%0d PCT=%.2f%%", perf_retire_width2_cycles, ratio_pct(perf_retire_width2_cycles, perf_cycles));
            $display("----------------------------------------------------------");
            $display("ZERO_ISSUE_REASONS (Total=%0d):", perf_issue_width0_cycles);
            for (integer i = 0; i < PRIMARY_REASON_COUNT; i++) begin
                if (perf_primary[i] > 0)
                    $display("  %s: %0d (%.2f%%)", primary_name(i), perf_primary[i], ratio_pct(perf_primary[i], perf_issue_width0_cycles));
            end
            $display("----------------------------------------------------------");
            $display("RAW_STALL_SIGNALS:");
            $display("  source_wait=%0d (%.2f%%)", raw_source_wait_cycles, ratio_pct(raw_source_wait_cycles, perf_cycles));
            $display("  lsu_order=%0d (%.2f%%)", raw_lsu_order_block_cycles, ratio_pct(raw_lsu_order_block_cycles, perf_cycles));
            $display("  lsu_queue=%0d (%.2f%%)", raw_lsu_queue_block_cycles, ratio_pct(raw_lsu_queue_block_cycles, perf_cycles));
            $display("  dcache_wait=%0d (%.2f%%)", raw_dcache_wait_cycles, ratio_pct(raw_dcache_wait_cycles, perf_cycles));
            $display("  dcache_backpressure=%0d (%.2f%%)", raw_dcache_backpressure_cycles, ratio_pct(raw_dcache_backpressure_cycles, perf_cycles));
            $display("  iq_full=%0d (%.2f%%)", raw_iq_full_cycles, ratio_pct(raw_iq_full_cycles, perf_cycles));
            $display("  lq_full=%0d (%.2f%%)", raw_lq_full_cycles, ratio_pct(raw_lq_full_cycles, perf_cycles));
            $display("  rob_full=%0d (%.2f%%)", raw_rob_full_cycles, ratio_pct(raw_rob_full_cycles, perf_cycles));
            $display("  muldiv=%0d (%.2f%%)", raw_muldiv_block_cycles, ratio_pct(raw_muldiv_block_cycles, perf_cycles));
            $display("----------------------------------------------------------");
            $display("SOURCE_WAIT_ATTRIBUTION:");
            $display("  oldest_source_wait  = %0d (%.2f%%)", raw_source_wait_cycles, ratio_pct(raw_source_wait_cycles, perf_cycles));
            $display("    dep_load          = %0d (%.2f%%)", raw_source_wait_dep_load_cycles, ratio_pct(raw_source_wait_dep_load_cycles, perf_cycles));
            $display("    dep_muldiv        = %0d (%.2f%%)", raw_source_wait_dep_muldiv_cycles, ratio_pct(raw_source_wait_dep_muldiv_cycles, perf_cycles));
            $display("    dep_alu           = %0d (%.2f%%)", raw_source_wait_dep_alu_cycles, ratio_pct(raw_source_wait_dep_alu_cycles, perf_cycles));
            $display("    dep_branch        = %0d (%.2f%%)", raw_source_wait_dep_branch_cycles, ratio_pct(raw_source_wait_dep_branch_cycles, perf_cycles));
            $display("    store_addr        = %0d (%.2f%%)", raw_source_wait_store_addr_cycles, ratio_pct(raw_source_wait_store_addr_cycles, perf_cycles));
            $display("    store_data        = %0d (%.2f%%)", raw_source_wait_store_data_cycles, ratio_pct(raw_source_wait_store_data_cycles, perf_cycles));
            $display("  iq_no_ready         = %0d (%.2f%%)", raw_iq_no_ready_cycles, ratio_pct(raw_iq_no_ready_cycles, perf_cycles));
            $display("  source_wait_stalled = %0d (%.2f%%)", raw_source_wait_stalled_cycles, ratio_pct(raw_source_wait_stalled_cycles, perf_cycles));
            $display("----------------------------------------------------------");
            $display("MEMORY_EVENTS:");
            $display("  load_issue=%0d", perf_load_issue_count);
            $display("  load_forward=%0d", perf_load_forward_count);
            $display("  load_response=%0d", perf_load_response_count);
            $display("  store_issue=%0d", perf_store_issue_count);
            $display("  store_release=%0d", perf_store_release_count);
            $display("  store_drain=%0d", perf_store_drain_count);
            $display("----------------------------------------------------------");
            $display("BRANCH_STATS:");
            $display("  branch_count=%0d", perf_branch_count);
            $display("  taken_count=%0d", perf_branch_taken_count);
            $display("  predicted_taken_count=%0d", perf_branch_predicted_taken_count);
            $display("  mispredict_count=%0d", perf_branch_mispredict_count);
            $display("  pred_nt_actual_nt=%0d", perf_pred_nt_actual_nt);
            $display("  pred_nt_actual_t=%0d", perf_pred_nt_actual_t);
            $display("  pred_t_actual_nt=%0d", perf_pred_t_actual_nt);
            $display("  pred_t_actual_t=%0d", perf_pred_t_actual_t);
            $display("  mispredict_rate=%.2f%%", ratio_pct(perf_branch_mispredict_count, perf_branch_count));
            $display("  recovery_count=%0d", perf_recovery_count);
            $display("  recovery_loss_cycles=%0d", perf_primary[PRIMARY_RECOVERY]);
            $display("----------------------------------------------------------");
            $display("QUEUE_OCCUPANCY:");
            $display("  ROB: avg=%.2f max=%0d", real'(perf_rob_occupancy_sum) / perf_cycles, perf_rob_occupancy_max);
            $display("  IQ : avg=%.2f max=%0d", real'(perf_issue_occupancy_sum) / perf_cycles, perf_issue_occupancy_max);
            $display("  LQ : avg=%.2f max=%0d", real'(perf_lq_occupancy_sum) / perf_cycles, perf_lq_occupancy_max);
            $display("  SQ : avg=%.2f max=%0d", real'(perf_sq_occupancy_sum) / perf_cycles, perf_sq_occupancy_max);
            $display("  SB : avg=%.2f max=%0d", real'(perf_sb_occupancy_sum) / perf_cycles, perf_sb_occupancy_max);
            $display("[PERF-SUMMARY-END]");
            $display("==========================================================");
        end
    endtask

    final begin
        if (perf_summary_arg && !perf_summary_printed) begin
            print_summary();
        end
    end
`endif
endmodule
