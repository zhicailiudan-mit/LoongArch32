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

    output dispatch_uop_t            dispatch [0:1]
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
    // mutation remains qualified by dispatch[0].valid below.
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
        .alloc_valid     (dispatch[0].valid),
        .query_alloc_valid(lane0_query_alloc_valid),
        .alloc_rf_we     (renamed_uop[0].reg_write),
        .alloc_rd        (renamed_uop[0].arch_rd),
        .alloc_tag       (rob_alloc_id[0].rob_tag),
        .alloc_epoch     (rob_alloc_id[0].epoch),
        .alloc_checkpoint(renamed_uop[0].is_br_jmp |
                          renamed_uop[0].pred.taken),
        .alloc1_valid    (dispatch[1].valid),
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
        dispatch[0] = '0;
        dispatch[0].valid = dispatch0_fire;
        dispatch[0].src0_ready = dispatch_src_ready[0][0];
        dispatch[0].src0_id = rat_id[0];
        dispatch[0].src1_ready = dispatch_src_ready[0][1];
        dispatch[0].src1_id = rat_id[1];
        dispatch[0].uop.uop_id = rob_alloc_id[0];
        dispatch[0].uop.pc = renamed_uop[0].pc;
        dispatch[0].uop.src0_value = source_value[0];
        dispatch[0].uop.src1_value = source_value[1];
        dispatch[0].uop.arch_rs1 = renamed_uop[0].src0.arch_reg;
        dispatch[0].uop.arch_rs2 = renamed_uop[0].src1.arch_reg;
        dispatch[0].uop.src0_used = renamed_uop[0].src0.used;
        dispatch[0].uop.src1_used = renamed_uop[0].src1.used;
        dispatch[0].uop.imm = renamed_uop[0].imm;
        dispatch[0].uop.npc_op = renamed_uop[0].npc_op;
        dispatch[0].uop.reg_write = renamed_uop[0].reg_write;
        dispatch[0].uop.arch_rd = renamed_uop[0].arch_rd;
        dispatch[0].uop.result_sel = renamed_uop[0].result_sel;
        dispatch[0].uop.alu_op = renamed_uop[0].alu_op;
        dispatch[0].uop.src_a_sel = renamed_uop[0].src_a_sel;
        dispatch[0].uop.src_b_sel = renamed_uop[0].src_b_sel;
        dispatch[0].uop.store_mask = renamed_uop[0].store_mask;
        dispatch[0].uop.load_ext_op = renamed_uop[0].load_ext_op;
        dispatch[0].uop.is_br_jmp = renamed_uop[0].is_br_jmp;
        dispatch[0].uop.is_ld_st = renamed_uop[0].is_ld_st;
        dispatch[0].uop.is_call = renamed_uop[0].is_call;
        dispatch[0].uop.is_ret = renamed_uop[0].is_ret;
        dispatch[0].uop.system_op = renamed_uop[0].system_op;
        dispatch[0].uop.csr_num = renamed_uop[0].csr_num;
        dispatch[0].uop.cacop_op = renamed_uop[0].cacop_op;
        dispatch[0].uop.serializing = renamed_uop[0].serializing;
        dispatch[0].uop.pred = renamed_uop[0].pred;

        dispatch[1] = '0;
        dispatch[1].valid = dispatch1_fire;
        dispatch[1].src0_ready = dispatch_src_ready[1][0];
        dispatch[1].src0_id = rat_id[2];
        dispatch[1].src1_ready = dispatch_src_ready[1][1];
        dispatch[1].src1_id = rat_id[3];
        dispatch[1].uop.uop_id = rob_alloc_id[1];
        dispatch[1].uop.pc = renamed_uop[1].pc;
        dispatch[1].uop.src0_value = source_value[2];
        dispatch[1].uop.src1_value = source_value[3];
        dispatch[1].uop.arch_rs1 = renamed_uop[1].src0.arch_reg;
        dispatch[1].uop.arch_rs2 = renamed_uop[1].src1.arch_reg;
        dispatch[1].uop.src0_used = renamed_uop[1].src0.used;
        dispatch[1].uop.src1_used = renamed_uop[1].src1.used;
        dispatch[1].uop.imm = renamed_uop[1].imm;
        dispatch[1].uop.npc_op = renamed_uop[1].npc_op;
        dispatch[1].uop.reg_write = renamed_uop[1].reg_write;
        dispatch[1].uop.arch_rd = renamed_uop[1].arch_rd;
        dispatch[1].uop.result_sel = renamed_uop[1].result_sel;
        dispatch[1].uop.alu_op = renamed_uop[1].alu_op;
        dispatch[1].uop.src_a_sel = renamed_uop[1].src_a_sel;
        dispatch[1].uop.src_b_sel = renamed_uop[1].src_b_sel;
        dispatch[1].uop.store_mask = renamed_uop[1].store_mask;
        dispatch[1].uop.load_ext_op = renamed_uop[1].load_ext_op;
        dispatch[1].uop.is_br_jmp = renamed_uop[1].is_br_jmp;
        dispatch[1].uop.is_ld_st = renamed_uop[1].is_ld_st;
        dispatch[1].uop.is_call = renamed_uop[1].is_call;
        dispatch[1].uop.is_ret = renamed_uop[1].is_ret;
        dispatch[1].uop.system_op = renamed_uop[1].system_op;
        dispatch[1].uop.csr_num = renamed_uop[1].csr_num;
        dispatch[1].uop.cacop_op = renamed_uop[1].cacop_op;
        dispatch[1].uop.serializing = renamed_uop[1].serializing;
        dispatch[1].uop.pred = renamed_uop[1].pred;
    end


endmodule
