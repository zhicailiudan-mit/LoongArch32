`timescale 1ns / 1ps

`include "defines.vh"

import cpu_types_pkg::*;

// Decode/rename/dispatch boundary. Lane identity is represented by array
// indices: index 0 is the older lane and index 1 is the younger lane.
module RenameDispatch (
    input  logic                    clk,
    input  logic                    rstn,
    input  logic                    flush,
    input  logic                    system_flush,
    input  logic                    redirect_valid,
    input  logic [1:0]              decode_valid,
    output logic                    decode_ready,
    input  decoded_uop_t             decode_uop [0:1],
    input  commit_t                  commit [0:1],

    input  logic                    recover_valid,
    input  uop_id_t                 recover_id,
    input  logic [`ROB_DEPTH-1:0]   rob_live_mask,

    input  logic [1:0]              rob_alloc_ready,
    input  uop_id_t                 rob_alloc_id [0:1],
    input  logic [1:0]              scheduler_dispatch_ready,

    input  logic                    rob_query_done [0:3],
    input  logic [31:0]             rob_query_value [0:3],
    output uop_id_t                 rob_query_id [0:3],

    input  completion_t              complete [0:1],

    output dispatch_uop_t            dispatch [0:1],
    // Registered dispatch stage (resolved payload + registered fires) drives
    // the DQ/Scheduler enqueue one cycle after the fire.  The combinational
    // `dispatch` output and the exposed combinational fires keep the RAT and
    // ROB allocations aligned with the rename's rob_alloc_id read (same-cycle
    // alloc -> in-order renaming preserved; only the DQ enqueue is delayed).
    output dispatch_uop_t            dispatch_q [0:1],
    output logic                     dispatch0_fire_q,
    output logic                     dispatch1_fire_q,
    output logic                     dispatch0_fire_comb,
    output logic                     dispatch1_fire_comb
);

    wire rn_valid [0:1];
    wire decoded_uop_t renamed_uop [0:1];
    wire rat_pending [0:3];
    wire [`ROB_TAG_W-1:0] rat_tag [0:3];
    wire [`UOP_EPOCH_W-1:0] rat_epoch [0:3];
    wire uop_id_t rat_id [0:3];
    wire source_used [0:3];
    wire [4:0] source_arch [0:3];
    wire [31:0] source_base_value [0:3];
    // A producer may have completed before a consumer reaches the DQ while
    // the RAT mapping is still visible for this rename cycle.  Keep the
    // completion value local to the rename packet in that case; the DQ still
    // owns all later broadcasts and wakeups.
    wire rob_done_value_valid [0:3];
    wire commit0_bypass [0:3];
    wire commit1_bypass [0:3];
    wire [31:0] source_value [0:3];
    wire dispatch_src_ready [0:1][0:1];
    wire [1:0] rename_pop_count;
    wire [1:0] rename_occupancy;
    wire lane0_resources_ready;
    wire lane1_resources_ready;
    wire dispatch0_fire;
    wire dispatch1_fire;
    wire lane0_query_alloc_valid;

    // Registered dispatch stage.  The resolved operands (RAT query, ROB-done
    // and commit bypass) form the deep combinational cone into the DQ enqueue;
    // the full-chip critical path ran pipeline_flush -> commit broadcast ->
    // alias map -> src1_ready/rD2 -> DQ rD2_reg.  The resolved payload is now
    // captured with the fire and the DQ/Scheduler enqueue happens one cycle
    // later.  The RAT alloc and the rename bundle pop stay on the combinational
    // fire so the in-order alloc->query ordering is unchanged; only the DQ
    // enqueue is delayed.  The DQ's dispatch-ready is pending-adjusted so the
    // fire cannot over-commit the DQ capacity.
    dispatch_uop_t dispatch_comb [0:1];

    assign source_used[0] = renamed_uop[0].src0.used;
    assign source_used[1] = renamed_uop[0].src1.used;
    assign source_used[2] = renamed_uop[1].src0.used;
    assign source_used[3] = renamed_uop[1].src1.used;
    assign source_arch[0] = renamed_uop[0].src0.arch_reg;
    assign source_arch[1] = renamed_uop[0].src1.arch_reg;
    assign source_arch[2] = renamed_uop[1].src0.arch_reg;
    assign source_arch[3] = renamed_uop[1].src1.arch_reg;
    assign source_base_value[0] = renamed_uop[0].src0.value;
    assign source_base_value[1] = renamed_uop[0].src1.value;
    assign source_base_value[2] = renamed_uop[1].src0.value;
    assign source_base_value[3] = renamed_uop[1].src1.value;

    genvar q;
    generate
        for (q = 0; q < 4; q = q + 1) begin : GEN_COMMIT_BYPASS
            assign rob_done_value_valid[q] = source_used[q] &&
                                              (source_arch[q] != 5'h0) &&
                                              rat_pending[q] &&
                                              rob_query_done[q];
            assign commit0_bypass[q] = commit[0].valid && commit[0].reg_write &&
                                       rat_pending[q] && source_used[q] &&
                                       (source_arch[q] != 5'h0) &&
                                       uop_id_equal(commit[0].uop_id, rat_id[q]);
            assign commit1_bypass[q] = commit[1].valid && commit[1].reg_write &&
                                       rat_pending[q] && source_used[q] &&
                                       (source_arch[q] != 5'h0) &&
                                       uop_id_equal(commit[1].uop_id, rat_id[q]);
            assign source_value[q] = rob_done_value_valid[q] ?
                                     rob_query_value[q] :
                                     commit0_bypass[q] ? commit[0].value :
                                     commit1_bypass[q] ? commit[1].value :
                                     source_base_value[q];
        end
    endgenerate

    assign lane0_resources_ready = rob_alloc_ready[0] &&
                                   scheduler_dispatch_ready[0];
    assign lane1_resources_ready = rob_alloc_ready[1] &&
                                   scheduler_dispatch_ready[1];
    assign dispatch0_fire = rn_valid[0] && lane0_resources_ready &&
                            !redirect_valid;
    assign dispatch1_fire = rn_valid[1] && dispatch0_fire &&
                            lane1_resources_ready;
    // The registered rename bundle already owns both uops.  Use that stable
    // presence to describe the potential lane0->lane1 dependency; actual RAT
    // mutation remains qualified by dispatch_comb[0].valid below.
    assign lane0_query_alloc_valid = rn_valid[0] && rn_valid[1] &&
                                     !redirect_valid;
    assign rename_pop_count = dispatch1_fire ? 2'd2 :
                              dispatch0_fire ? 2'd1 : 2'd0;

    // ROB done is a read-only, identity-checked fallback.  It does not
    // replace DQ's completion broadcast; it only prevents a consumer from
    // entering the queue with an already-retired producer tag and no future
    // wakeup event.
    assign dispatch_src_ready[0][0] = !source_used[0] || !rat_pending[0] ||
                                      rob_done_value_valid[0] ||
                                      commit0_bypass[0] || commit1_bypass[0];
    assign dispatch_src_ready[0][1] = !source_used[1] || !rat_pending[1] ||
                                      rob_done_value_valid[1] ||
                                      commit0_bypass[1] || commit1_bypass[1];
    assign dispatch_src_ready[1][0] = !source_used[2] || !rat_pending[2] ||
                                      rob_done_value_valid[2] ||
                                      commit0_bypass[2] || commit1_bypass[2];
    assign dispatch_src_ready[1][1] = !source_used[3] || !rat_pending[3] ||
                                      rob_done_value_valid[3] ||
                                      commit0_bypass[3] || commit1_bypass[3];

    RenameBundle u_DECODE_RENAME (
        .clk         (clk),
        .rstn        (rstn),
        .flush       (flush),
        .in_valid0   (decode_valid[0]),
        .in_valid1   (decode_valid[1]),
        .in_ready    (decode_ready),
        .in_uop0     (decode_uop[0]),
        .in_uop1     (decode_uop[1]),
        .out_valid0  (rn_valid[0]),
        .out_valid1  (rn_valid[1]),
        .out_pop_count(rename_pop_count),
        .out_uop0    (renamed_uop[0]),
        .out_uop1    (renamed_uop[1]),
        .occupancy   (rename_occupancy),
        .commit0     (commit[0]),
        .commit1     (commit[1])
    );

    RegAliasTable u_reg_alias_table (
        .clk             (clk),
        .rstn            (rstn),
        .alloc_valid     (dispatch_comb[0].valid),
        .query_alloc_valid(lane0_query_alloc_valid),
        .alloc_rf_we     (renamed_uop[0].reg_write),
        .alloc_rd        (renamed_uop[0].arch_rd),
        .alloc_tag       (rob_alloc_id[0].rob_tag),
        .alloc_epoch     (rob_alloc_id[0].epoch),
        .alloc_checkpoint(renamed_uop[0].is_br_jmp |
                          renamed_uop[0].pred.taken),
        .alloc1_valid    (dispatch_comb[1].valid),
        .alloc1_rf_we    (renamed_uop[1].reg_write),
        .alloc1_rd       (renamed_uop[1].arch_rd),
        .alloc1_tag      (rob_alloc_id[1].rob_tag),
        .alloc1_epoch    (rob_alloc_id[1].epoch),
        .alloc1_checkpoint(renamed_uop[1].is_br_jmp |
                           renamed_uop[1].pred.taken),
        .recover_valid(recover_valid),
        .system_flush(system_flush),
        .recover_tag  (recover_id.rob_tag),
        .recover_epoch   (recover_id.epoch),
        .rob_live_mask   (rob_live_mask),
        .commit_valid    (commit[0].valid),
        .commit_has_dest (commit[0].has_dest),
        .commit_rd       (commit[0].arch_rd),
        .commit_tag      (commit[0].uop_id.rob_tag),
        .commit_epoch    (commit[0].uop_id.epoch),
        .commit1_valid   (commit[1].valid),
        .commit1_has_dest(commit[1].has_dest),
        .commit1_rd      (commit[1].arch_rd),
        .commit1_tag     (commit[1].uop_id.rob_tag),
        .commit1_epoch   (commit[1].uop_id.epoch),
        .query_rs0       (renamed_uop[0].src0.arch_reg),
        .query_pending0  (rat_pending[0]),
        .query_tag0      (rat_tag[0]),
        .query_epoch0    (rat_epoch[0]),
        .query_rs1       (renamed_uop[0].src1.arch_reg),
        .query_pending1  (rat_pending[1]),
        .query_tag1      (rat_tag[1]),
        .query_epoch1    (rat_epoch[1]),
        .query_rs2       (renamed_uop[1].src0.arch_reg),
        .query_pending2  (rat_pending[2]),
        .query_tag2      (rat_tag[2]),
        .query_epoch2    (rat_epoch[2]),
        .query_rs3       (renamed_uop[1].src1.arch_reg),
        .query_pending3  (rat_pending[3]),
        .query_tag3      (rat_tag[3]),
        .query_epoch3    (rat_epoch[3])
    );

    generate
        for (q = 0; q < 4; q = q + 1) begin : GEN_RAT_ID
            assign rat_id[q].rob_tag = rat_tag[q];
            assign rat_id[q].epoch = rat_epoch[q];
            assign rob_query_id[q] = rat_id[q];
        end
    endgenerate

    always_comb begin
        dispatch_comb[0] = '0;
        dispatch_comb[0].valid = dispatch0_fire;
        dispatch_comb[0].src0_ready = dispatch_src_ready[0][0];
        dispatch_comb[0].src0_id = rat_id[0];
        dispatch_comb[0].src1_ready = dispatch_src_ready[0][1];
        dispatch_comb[0].src1_id = rat_id[1];
        dispatch_comb[0].uop.uop_id = rob_alloc_id[0];
        dispatch_comb[0].uop.pc = renamed_uop[0].pc;
        dispatch_comb[0].uop.src0_value = source_value[0];
        dispatch_comb[0].uop.src1_value = source_value[1];
        dispatch_comb[0].uop.arch_rs1 = renamed_uop[0].src0.arch_reg;
        dispatch_comb[0].uop.arch_rs2 = renamed_uop[0].src1.arch_reg;
        dispatch_comb[0].uop.src0_used = renamed_uop[0].src0.used;
        dispatch_comb[0].uop.src1_used = renamed_uop[0].src1.used;
        dispatch_comb[0].uop.imm = renamed_uop[0].imm;
        dispatch_comb[0].uop.npc_op = renamed_uop[0].npc_op;
        dispatch_comb[0].uop.reg_write = renamed_uop[0].reg_write;
        dispatch_comb[0].uop.arch_rd = renamed_uop[0].arch_rd;
        dispatch_comb[0].uop.result_sel = renamed_uop[0].result_sel;
        dispatch_comb[0].uop.alu_op = renamed_uop[0].alu_op;
        dispatch_comb[0].uop.src_a_sel = renamed_uop[0].src_a_sel;
        dispatch_comb[0].uop.src_b_sel = renamed_uop[0].src_b_sel;
        dispatch_comb[0].uop.store_mask = renamed_uop[0].store_mask;
        dispatch_comb[0].uop.load_ext_op = renamed_uop[0].load_ext_op;
        dispatch_comb[0].uop.is_br_jmp = renamed_uop[0].is_br_jmp;
        dispatch_comb[0].uop.is_ld_st = renamed_uop[0].is_ld_st;
        dispatch_comb[0].uop.is_call = renamed_uop[0].is_call;
        dispatch_comb[0].uop.is_ret = renamed_uop[0].is_ret;
        dispatch_comb[0].uop.system_op = renamed_uop[0].system_op;
        dispatch_comb[0].uop.csr_num = renamed_uop[0].csr_num;
        dispatch_comb[0].uop.cacop_op = renamed_uop[0].cacop_op;
        dispatch_comb[0].uop.serializing = renamed_uop[0].serializing;
        dispatch_comb[0].uop.pred = renamed_uop[0].pred;

        dispatch_comb[1] = '0;
        dispatch_comb[1].valid = dispatch1_fire;
        dispatch_comb[1].src0_ready = dispatch_src_ready[1][0];
        dispatch_comb[1].src0_id = rat_id[2];
        dispatch_comb[1].src1_ready = dispatch_src_ready[1][1];
        dispatch_comb[1].src1_id = rat_id[3];
        dispatch_comb[1].uop.uop_id = rob_alloc_id[1];
        dispatch_comb[1].uop.pc = renamed_uop[1].pc;
        dispatch_comb[1].uop.src0_value = source_value[2];
        dispatch_comb[1].uop.src1_value = source_value[3];
        dispatch_comb[1].uop.arch_rs1 = renamed_uop[1].src0.arch_reg;
        dispatch_comb[1].uop.arch_rs2 = renamed_uop[1].src1.arch_reg;
        dispatch_comb[1].uop.src0_used = renamed_uop[1].src0.used;
        dispatch_comb[1].uop.src1_used = renamed_uop[1].src1.used;
        dispatch_comb[1].uop.imm = renamed_uop[1].imm;
        dispatch_comb[1].uop.npc_op = renamed_uop[1].npc_op;
        dispatch_comb[1].uop.reg_write = renamed_uop[1].reg_write;
        dispatch_comb[1].uop.arch_rd = renamed_uop[1].arch_rd;
        dispatch_comb[1].uop.result_sel = renamed_uop[1].result_sel;
        dispatch_comb[1].uop.alu_op = renamed_uop[1].alu_op;
        dispatch_comb[1].uop.src_a_sel = renamed_uop[1].src_a_sel;
        dispatch_comb[1].uop.src_b_sel = renamed_uop[1].src_b_sel;
        dispatch_comb[1].uop.store_mask = renamed_uop[1].store_mask;
        dispatch_comb[1].uop.load_ext_op = renamed_uop[1].load_ext_op;
        dispatch_comb[1].uop.is_br_jmp = renamed_uop[1].is_br_jmp;
        dispatch_comb[1].uop.is_ld_st = renamed_uop[1].is_ld_st;
        dispatch_comb[1].uop.is_call = renamed_uop[1].is_call;
        dispatch_comb[1].uop.is_ret = renamed_uop[1].is_ret;
        dispatch_comb[1].uop.system_op = renamed_uop[1].system_op;
        dispatch_comb[1].uop.csr_num = renamed_uop[1].csr_num;
        dispatch_comb[1].uop.cacop_op = renamed_uop[1].cacop_op;
        dispatch_comb[1].uop.serializing = renamed_uop[1].serializing;
        dispatch_comb[1].uop.pred = renamed_uop[1].pred;
    end

    // Registered dispatch stage drives the DQ/Scheduler enqueue port one
    // cycle after the fire.  The valid is the registered fire (one-shot: the
    // bundle pops only on the combinational fire, so a fire_q is never
    // repeated), and the payload is the resolution captured at the fire edge.
    // The combinational `dispatch` output (below) keeps the RAT/ROB allocs on
    // the fire cycle.
    assign dispatch[0] = dispatch_comb[0];
    assign dispatch[1] = dispatch_comb[1];

    assign dispatch0_fire_comb = dispatch0_fire;
    assign dispatch1_fire_comb = dispatch1_fire;

    always_ff @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            dispatch_q[0] <= '0;
            dispatch_q[1] <= '0;
            dispatch0_fire_q <= 1'b0;
            dispatch1_fire_q <= 1'b0;
        end else begin
            dispatch0_fire_q <= dispatch0_fire;
            dispatch1_fire_q <= dispatch1_fire;
            if (dispatch0_fire)
                dispatch_q[0] <= dispatch_comb[0];
            if (dispatch1_fire)
                dispatch_q[1] <= dispatch_comb[1];
        end
    end

`ifndef SYNTHESIS
    reg [63:0] elastic_cycle_count;
    reg [63:0] partial_dispatch_count;
    reg [1:0] elastic_max_occupancy;
    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            elastic_cycle_count <= 0;
            partial_dispatch_count <= 0;
            elastic_max_occupancy <= 0;
        end else begin
            elastic_cycle_count <= elastic_cycle_count + 1;
            if (dispatch0_fire && rn_valid[1] && !dispatch1_fire)
                partial_dispatch_count <= partial_dispatch_count + 1;
            if (rename_occupancy > elastic_max_occupancy)
                elastic_max_occupancy <= rename_occupancy;

            if (dispatch_comb[1].valid && !dispatch_comb[0].valid)
                $fatal(1, "Dispatch lane1 advanced before lane0");
            if (dispatch_comb[0].valid &&
                (!rob_alloc_ready[0] || !scheduler_dispatch_ready[0]))
                $fatal(1, "Dispatch lane0 was not atomic across ROB and Scheduler");
            if (dispatch_comb[1].valid &&
                (!rob_alloc_ready[1] || !scheduler_dispatch_ready[1]))
                $fatal(1, "Dispatch lane1 was not atomic across ROB and Scheduler");
            if (dispatch_comb[1].valid &&
                (rob_alloc_id[1] !== (rob_alloc_id[0] + 1'b1)))
                $fatal(1, "Dual dispatch ROB IDs are not consecutive in age order");

            if (((elastic_cycle_count + 1) % 100000) == 0)
                $display("[DISPATCH-ELASTIC] cycles=%0d partial_dispatch=%0d max_occupancy=%0d occupancy=%0d",
                         elastic_cycle_count + 1,
                         partial_dispatch_count +
                         (dispatch0_fire && rn_valid[1] && !dispatch1_fire),
                         (rename_occupancy > elastic_max_occupancy) ?
                          rename_occupancy : elastic_max_occupancy,
                         rename_occupancy);
        end
    end
`endif

endmodule
