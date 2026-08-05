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
    input  logic [1:0]               store_reserve_credit,

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
    wire dq_store_pending_valid;
    wire dq_store_pending_ready;
    wire issue_uop_t dq_store_pending;
    wire [1:0] dq_store_pending_occupancy;
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

    wire issue0_base_valid = dq_issue_valid[0] && no_sys_active &&
                             !steal_main_to_lane1;
    wire issue1_base_valid = no_sys_active &&
                             (steal_main_to_lane1 ? dq_issue_valid[0] :
                                                   dq_issue_valid[1]);

    typedef struct packed {
        logic        valid;
        uop_id_t     uop_id;
        logic [31:0] pc;
        logic [3:0]  store_mask;
        uop_id_t     store_data_src_id;
    } store_reservation_intent_t;

    // Scheduler-side two-entry FIFO.  DQ owns the issue-time token until it
    // is accepted here; SQ owns it only after this FIFO's reserve handshake.
    store_reservation_intent_t store_intent_fifo_q [0:1];
    logic store_intent_head_q;
    logic store_intent_tail_q;
    logic [1:0] store_intent_count_q;
    logic intent_push;
    logic intent_pop0, intent_pop1;
    logic [1:0] intent_pop_count;
    store_reservation_intent_t intent_push_entry;
    integer intent_recover_i;
    integer intent_recover_count;
    store_reservation_intent_t intent_recover_entry0;
    store_reservation_intent_t intent_recover_entry1;

    assign reserve0_valid      = (store_intent_count_q != 2'd0) && !flush;
    assign reserve0_uop_id     = (store_intent_count_q != 2'd0) ?
                                 store_intent_fifo_q[store_intent_head_q].uop_id : '0;
    assign reserve0_pc         = (store_intent_count_q != 2'd0) ?
                                 store_intent_fifo_q[store_intent_head_q].pc : 32'h0;
    assign reserve0_store_mask = (store_intent_count_q != 2'd0) ?
                                 store_intent_fifo_q[store_intent_head_q].store_mask : 4'h0;
    assign reserve0_src1_id    = (store_intent_count_q != 2'd0) ?
                                 store_intent_fifo_q[store_intent_head_q].store_data_src_id : '0;
    assign reserve0_src1_ready = 1'b0;
    assign reserve0_src1_value = 32'h0;

    assign reserve1_valid      = (store_intent_count_q == 2'd2) && !flush;
    assign reserve1_uop_id     = (store_intent_count_q == 2'd2) ?
                                 store_intent_fifo_q[store_intent_head_q ^ 1'b1].uop_id : '0;
    assign reserve1_pc         = (store_intent_count_q == 2'd2) ?
                                 store_intent_fifo_q[store_intent_head_q ^ 1'b1].pc : 32'h0;
    assign reserve1_store_mask = (store_intent_count_q == 2'd2) ?
                                 store_intent_fifo_q[store_intent_head_q ^ 1'b1].store_mask : 4'h0;
    assign reserve1_src1_id    = (store_intent_count_q == 2'd2) ?
                                 store_intent_fifo_q[store_intent_head_q ^ 1'b1].store_data_src_id : '0;
    assign reserve1_src1_ready = 1'b0;
    assign reserve1_src1_value = 32'h0;

    assign intent_pop0 = reserve0_valid && reserve0_ready;
    // StoreQueue may select the older of the two reservations when only one
    // SQ slot is free.  That older reservation can be reserve1 even though
    // reserve0 is the FIFO head, so consume each accepted lane independently
    // and compact the two-entry ring below.  Losing this pop would duplicate
    // the reserve1 Store on the next cycle.
    assign intent_pop1 = reserve1_valid && reserve1_ready;
    assign intent_pop_count = {1'b0, intent_pop0} + {1'b0, intent_pop1};
    assign dq_store_pending_ready = (store_intent_count_q < 2'd2) ||
                                    (intent_pop_count != 2'd0);
    assign intent_push = dq_store_pending_valid && dq_store_pending_ready;
    assign intent_push_entry.valid = 1'b1;
    assign intent_push_entry.uop_id = dq_store_pending.uop_id;
    assign intent_push_entry.pc = dq_store_pending.pc;
    assign intent_push_entry.store_mask = dq_store_pending.store_mask;
    assign intent_push_entry.store_data_src_id = dq_store_pending.src1_id;

    // Credit crosses into DQ only at the narrow registered grant boundary.
    // DQ occupancy includes both grants and written tokens, so ownership is
    // conserved while it moves grant -> token -> Scheduler intent.
    wire [2:0] store_pending_total = {1'b0, dq_store_pending_occupancy} +
                                     {1'b0, store_intent_count_q};
    wire store_issue_admit = !flush && !system_flush &&
                              (store_pending_total < {1'b0, store_reserve_credit});

    wire dq0_lsu_ready = issue0_ready;
    wire dq1_lsu_ready = issue1_ready;

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
    assign issue0_valid = issue0_base_valid;
    assign issue0_fire = issue0_valid && issue0_ready;
    assign system_issue_valid = dq_issue_valid[0] && dq_is_system &&
                                system_at_head && !system_inflight;
    assign system_issue_fire = system_issue_valid && system_issue_ready;
    assign issue1_valid = issue1_base_valid;
    assign issue1_fire = issue1_valid && issue1_ready;
    assign occupancy = dq_occupancy;

    always_comb begin
        intent_recover_count = 0;
        intent_recover_entry0 = '0;
        intent_recover_entry1 = '0;
        for (intent_recover_i = 0; intent_recover_i < 2; intent_recover_i = intent_recover_i + 1) begin
            if ((intent_recover_i < store_intent_count_q) &&
                !uop_is_younger(store_intent_fifo_q[store_intent_head_q ^ intent_recover_i[0]].uop_id,
                                recover_id)) begin
                if (intent_recover_count == 0)
                    intent_recover_entry0 = store_intent_fifo_q[store_intent_head_q ^ intent_recover_i[0]];
                else if (intent_recover_count == 1)
                    intent_recover_entry1 = store_intent_fifo_q[store_intent_head_q ^ intent_recover_i[0]];
                intent_recover_count = intent_recover_count + 1;
            end
        end
    end

    always_ff @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            store_intent_head_q <= 1'b0;
            store_intent_tail_q <= 1'b0;
            store_intent_count_q <= 2'd0;
            store_intent_fifo_q[0] <= '0;
            store_intent_fifo_q[1] <= '0;
        end else if (system_flush || (flush && !recover_valid)) begin
            store_intent_head_q <= 1'b0;
            store_intent_tail_q <= 1'b0;
            store_intent_count_q <= 2'd0;
            store_intent_fifo_q[0] <= '0;
            store_intent_fifo_q[1] <= '0;
        end else if (flush) begin
            store_intent_head_q <= 1'b0;
            // Normalized two-entry ring: tail is count modulo two.
            store_intent_tail_q <= intent_recover_count[0];
            store_intent_count_q <= intent_recover_count[1:0];
            store_intent_fifo_q[0] <= intent_recover_entry0;
            store_intent_fifo_q[1] <= intent_recover_entry1;
        end else begin
            // The StoreQueue can acknowledge either reservation lane when it
            // has one free slot.  Keep the ring normalized for all pop/push
            // combinations instead of assuming a head-only pop.
            case (store_intent_count_q)
                2'd0: begin
                    if (intent_push) begin
                        store_intent_fifo_q[store_intent_head_q] <= intent_push_entry;
                        store_intent_tail_q <= ~store_intent_head_q;
                        store_intent_count_q <= 2'd1;
                    end
                end
                2'd1: begin
                    if (intent_pop0) begin
                        if (intent_push) begin
                            store_intent_fifo_q[store_intent_head_q] <= intent_push_entry;
                            store_intent_tail_q <= ~store_intent_head_q;
                            store_intent_count_q <= 2'd1;
                        end else begin
                            store_intent_tail_q <= store_intent_head_q;
                            store_intent_count_q <= 2'd0;
                        end
                    end else if (intent_push) begin
                        store_intent_fifo_q[store_intent_tail_q] <= intent_push_entry;
                        store_intent_tail_q <= store_intent_head_q;
                        store_intent_count_q <= 2'd2;
                    end
                end
                default: begin // two entries resident
                    case ({intent_pop1, intent_pop0, intent_push})
                        3'b010: begin // pop0 only: retain the second entry
                            store_intent_head_q <= ~store_intent_head_q;
                            store_intent_tail_q <= store_intent_head_q;
                            store_intent_count_q <= 2'd1;
                        end
                        3'b011: begin // pop0 and push: replace the head slot
                            store_intent_fifo_q[store_intent_head_q] <= intent_push_entry;
                            store_intent_head_q <= ~store_intent_head_q;
                            store_intent_tail_q <= ~store_intent_head_q;
                            store_intent_count_q <= 2'd2;
                        end
                        3'b100: begin // pop1 only: retain the FIFO head
                            store_intent_tail_q <= ~store_intent_head_q;
                            store_intent_count_q <= 2'd1;
                        end
                        3'b101: begin // pop1 and push: replace the second slot
                            store_intent_fifo_q[~store_intent_head_q] <= intent_push_entry;
                            store_intent_tail_q <= store_intent_head_q;
                            store_intent_count_q <= 2'd2;
                        end
                        3'b110: begin // both pops, no push
                            store_intent_tail_q <= store_intent_head_q;
                            store_intent_count_q <= 2'd0;
                        end
                        3'b111: begin // both pops and one new token
                            store_intent_fifo_q[store_intent_head_q] <= intent_push_entry;
                            store_intent_tail_q <= ~store_intent_head_q;
                            store_intent_count_q <= 2'd1;
                        end
                        default: begin end
                    endcase
                end
            endcase
        end
    end

    DispatchQueue #(
        .RESOURCE_AWARE_PAIRING(1'b1),
        .BRANCH_AT_ROB_HEAD    (1'b0),
        // Completion first updates the DQ's registered operand state.  Issue
        // selection begins from that state on the following cycle, keeping
        // ROB/completion routing out of the global select/hold cone.
        .REGISTERED_SELECT_WAKEUP(1'b1),
        .ROUND_ROBIN_SELECT    (1'b1),
        .REGISTERED_ORDER_SELECT(1'b1),
        .REGISTER_ISSUE_CLEAR  (1'b0)
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
        .store_issue_pending_ready(dq_store_pending_ready),
        .store_issue_pending_admit(store_issue_admit),
        .store_issue_pending_valid(dq_store_pending_valid),
        .store_issue_pending(dq_store_pending),
        .store_issue_pending_occupancy(dq_store_pending_occupancy),
        .occupancy      (dq_occupancy)
    );

    assign issue0 = dq_issue[0];
    assign system_issue = dq_issue[0];
    assign issue1 = steal_main_to_lane1 ? dq_issue[0] : dq_issue[1];

`ifndef SYNTHESIS
    always @(posedge clk) begin
        if (rstn && !flush) begin
            if (store_intent_count_q > 2'd2)
                $fatal(1, "[SCHED-ASSERT] Store intent FIFO overflow");
            if (dq_store_pending_occupancy > 2'd2)
                $fatal(1, "[SCHED-ASSERT] DQ Store token FIFO overflow");
            // Each Store crossed the single-push DQ token boundary in an
            // earlier cycle.  The LSU and StoreQueue both provide two address
            // update ports, so two distinct, already-reserved Stores may
            // legally complete address generation together.  What must never
            // happen here is the same Store payload reaching both lanes.
            if (issue0_fire && issue1_fire &&
                (dq_issue[0].is_ld_st && (dq_issue[0].store_mask != `RAM_WE_N)) &&
                (dq_issue[1].is_ld_st && (dq_issue[1].store_mask != `RAM_WE_N)) &&
                uop_id_equal(dq_issue[0].uop_id, dq_issue[1].uop_id))
                $fatal(1, "[SCHED-ASSERT] duplicate Store payload issued on both lanes");
        end
    end
`endif

endmodule
