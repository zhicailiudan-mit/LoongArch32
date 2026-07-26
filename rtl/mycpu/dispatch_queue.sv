`timescale 1ns / 1ps

`include "defines.vh"

import cpu_types_pkg::*;

module DispatchQueue #(
    // Keep the standalone queue contract strictly oldest-ready by default.
    // The Scheduler enables this option because lane0 owns branch/LSU/system
    // resources while lane1 owns the second integer/MDU execution path.
    parameter RESOURCE_AWARE_PAIRING = 1'b0,
    // The current backend uses a whole-queue branch flush.  Until recovery is
    // age-selective in every queue, resolving a branch before all older uops
    // retire can delete an older uncompleted load/store while ROB recovery
    // correctly preserves it.  Scheduler therefore enables this guard.
    parameter BRANCH_AT_ROB_HEAD = 1'b0
) (
    input  wire                  clk,
    input  wire                  rstn,
    input  wire                  flush,
    input  logic                 recover_valid,
    input  logic                 system_flush,
    input  uop_id_t              recover_id,
    input  logic                 barrier_release,
    output logic                 perf_true_source_wait,
    output logic                 perf_lsu_order,
    output logic                 perf_serializing,

    input  dispatch_uop_t        enq [0:1],
    output wire                  enq_ready [0:1],

    input  completion_t          complete [0:1],
    input  commit_t              commit [0:1],

    input  wire                  rob_head_valid,
    input  wire [`ROB_TAG_W-1:0] rob_head_tag,
    input  uop_id_t              rob_head_id,

    output wire                  issue_valid [0:1],
    input  wire                  issue_ready [0:1],
    output issue_uop_t           issue [0:1],
    output wire [3:0]            occupancy
);

    localparam DQ_DEPTH = 8;
    // One bit beyond the ROB tag is sufficient because at most ROB_DEPTH
    // uops can be live. Any two live queue entries are therefore separated
    // by less than half of this modular sequence space.
    localparam DQ_SEQ_W = `ROB_TAG_W + 1;

    reg [DQ_DEPTH-1:0] valid;
    reg [DQ_DEPTH-1:0] src0_ready;
    reg [DQ_DEPTH-1:0] src1_ready;
    uop_id_t uop_id [0:DQ_DEPTH-1];
    reg [DQ_SEQ_W-1:0] alloc_seq [0:DQ_DEPTH-1];
    uop_id_t src0_id [0:DQ_DEPTH-1];
    uop_id_t src1_id [0:DQ_DEPTH-1];
    wire [`ROB_TAG_W-1:0] src0_tag [0:DQ_DEPTH-1];
    wire [`ROB_TAG_W-1:0] src1_tag [0:DQ_DEPTH-1];
    reg [31:0] pc [0:DQ_DEPTH-1];
    reg [31:0] rD1 [0:DQ_DEPTH-1];
    reg [31:0] rD2 [0:DQ_DEPTH-1];
    reg [4:0] rR1 [0:DQ_DEPTH-1];
    reg [4:0] rR2 [0:DQ_DEPTH-1];
    reg rR1_re [0:DQ_DEPTH-1];
    reg rR2_re [0:DQ_DEPTH-1];
    reg [31:0] ext [0:DQ_DEPTH-1];
    reg [1:0] npc_op [0:DQ_DEPTH-1];
    reg rf_we [0:DQ_DEPTH-1];
    reg [4:0] wR [0:DQ_DEPTH-1];
    reg [1:0] wd_sel [0:DQ_DEPTH-1];
    reg [4:0] alu_op [0:DQ_DEPTH-1];
    reg alua_sel [0:DQ_DEPTH-1];
    reg alub_sel [0:DQ_DEPTH-1];
    reg [3:0] ram_we [0:DQ_DEPTH-1];
    reg [2:0] ram_ext_op [0:DQ_DEPTH-1];
    reg is_br_jmp [0:DQ_DEPTH-1];
    reg is_ld_st [0:DQ_DEPTH-1];
    reg is_call [0:DQ_DEPTH-1];
    reg is_ret [0:DQ_DEPTH-1];
    reg [2:0] system_op [0:DQ_DEPTH-1];
    reg [13:0] csr_num [0:DQ_DEPTH-1];
    reg [4:0] cacop_op [0:DQ_DEPTH-1];
    reg serializing [0:DQ_DEPTH-1];
    reg [DQ_DEPTH-1:0] barrier_blocked;
    reg barrier_active;
    // Both issue lanes are independent ready/valid outputs.  Once either lane
    // is presented while stalled, keep its selected entry stable even if the
    // other lane fires and changes the normal issue arbitration.
    reg main_hold_valid;
    reg [2:0] main_hold_sel;
    reg fast_hold_valid;
    reg [2:0] fast_hold_sel;
    reg [2:0] ras_ptr [0:DQ_DEPTH-1];
    reg pred_valid [0:DQ_DEPTH-1];
    reg pred_taken [0:DQ_DEPTH-1];
    reg [31:0] pred_target [0:DQ_DEPTH-1];
    reg [9:0] pred_index [0:DQ_DEPTH-1];
    reg [2:0] ras_sp_before [0:DQ_DEPTH-1];
    reg [3:0] ras_count_before [0:DQ_DEPTH-1];
    // Observation-only Fetch-time BTB lookup result.  This bit follows the
    // prediction packet but is never used by issue selection or CPU control.
    reg perf_btb_hit [0:DQ_DEPTH-1];

    reg [3:0] count;
    wire [2:0] issue_sel;
    wire [2:0] fast_issue_sel;
    reg [2:0] enq_sel;
    reg [2:0] enq1_sel;
    wire      issue_found;
    wire      fast_issue_found;
    reg       free_found;
    reg       second_free_found;
    reg [DQ_SEQ_W-1:0] next_alloc_seq;
    integer i;
    integer recover_count;
    integer j;
    integer k;

    // Keep the queue state machine below field-oriented for now, while the
    // module boundary carries typed lane packets.  These aliases are local
    // implementation names, not part of the public interface.
    wire enq_valid = enq[0].valid;
    wire enq1_valid = enq[1].valid;
    wire uop_id_t enq_uop_id = enq[0].uop.uop_id;
    wire uop_id_t enq1_uop_id = enq[1].uop.uop_id;
    wire [31:0] enq_pc = enq[0].uop.pc;
    wire [31:0] enq1_pc = enq[1].uop.pc;
    wire [31:0] enq_rD1 = enq[0].uop.src0_value;
    wire [31:0] enq1_rD1 = enq[1].uop.src0_value;
    wire [31:0] enq_rD2 = enq[0].uop.src1_value;
    wire [31:0] enq1_rD2 = enq[1].uop.src1_value;
    wire enq_src0_ready = enq[0].src0_ready;
    wire enq1_src0_ready = enq[1].src0_ready;
    wire enq_src1_ready = enq[0].src1_ready;
    wire enq1_src1_ready = enq[1].src1_ready;
    wire uop_id_t enq_src0_id = enq[0].src0_id;
    wire uop_id_t enq1_src0_id = enq[1].src0_id;
    wire uop_id_t enq_src1_id = enq[0].src1_id;
    wire uop_id_t enq1_src1_id = enq[1].src1_id;
    wire [`ROB_TAG_W-1:0] enq_src0_tag = enq_src0_id.rob_tag;
    wire [`ROB_TAG_W-1:0] enq1_src0_tag = enq1_src0_id.rob_tag;
    wire [`ROB_TAG_W-1:0] enq_src1_tag = enq_src1_id.rob_tag;
    wire [`ROB_TAG_W-1:0] enq1_src1_tag = enq1_src1_id.rob_tag;
    genvar sid;
    generate
        for (sid = 0; sid < DQ_DEPTH; sid = sid + 1) begin : GEN_SRC_TAG
            assign src0_tag[sid] = src0_id[sid].rob_tag;
            assign src1_tag[sid] = src1_id[sid].rob_tag;
        end
    endgenerate
    wire [4:0] enq_rR1 = enq[0].uop.arch_rs1;
    wire [4:0] enq1_rR1 = enq[1].uop.arch_rs1;
    wire [4:0] enq_rR2 = enq[0].uop.arch_rs2;
    wire [4:0] enq1_rR2 = enq[1].uop.arch_rs2;
    wire enq_rR1_re = enq[0].uop.src0_used;
    wire enq1_rR1_re = enq[1].uop.src0_used;
    wire enq_rR2_re = enq[0].uop.src1_used;
    wire enq1_rR2_re = enq[1].uop.src1_used;
    wire [31:0] enq_ext = enq[0].uop.imm;
    wire [31:0] enq1_ext = enq[1].uop.imm;
    wire [1:0] enq_npc_op = enq[0].uop.npc_op;
    wire [1:0] enq1_npc_op = enq[1].uop.npc_op;
    wire enq_rf_we = enq[0].uop.reg_write;
    wire enq1_rf_we = enq[1].uop.reg_write;
    wire [4:0] enq_wR = enq[0].uop.arch_rd;
    wire [4:0] enq1_wR = enq[1].uop.arch_rd;
    wire [1:0] enq_wd_sel = enq[0].uop.result_sel;
    wire [1:0] enq1_wd_sel = enq[1].uop.result_sel;
    wire [4:0] enq_alu_op = enq[0].uop.alu_op;
    wire [4:0] enq1_alu_op = enq[1].uop.alu_op;
    wire enq_alua_sel = enq[0].uop.src_a_sel;
    wire enq1_alua_sel = enq[1].uop.src_a_sel;
    wire enq_alub_sel = enq[0].uop.src_b_sel;
    wire enq1_alub_sel = enq[1].uop.src_b_sel;
    wire [3:0] enq_ram_we = enq[0].uop.store_mask;
    wire [3:0] enq1_ram_we = enq[1].uop.store_mask;
    wire [2:0] enq_ram_ext_op = enq[0].uop.load_ext_op;
    wire [2:0] enq1_ram_ext_op = enq[1].uop.load_ext_op;
    wire enq_is_br_jmp = enq[0].uop.is_br_jmp;
    wire enq1_is_br_jmp = enq[1].uop.is_br_jmp;
    wire enq_is_ld_st = enq[0].uop.is_ld_st;
    wire enq1_is_ld_st = enq[1].uop.is_ld_st;
    wire enq_is_call = enq[0].uop.is_call;
    wire enq1_is_call = enq[1].uop.is_call;
    wire enq_is_ret = enq[0].uop.is_ret;
    wire enq1_is_ret = enq[1].uop.is_ret;
    wire [2:0] enq_system_op = enq[0].uop.system_op;
    wire [2:0] enq1_system_op = enq[1].uop.system_op;
    wire [13:0] enq_csr_num = enq[0].uop.csr_num;
    wire [13:0] enq1_csr_num = enq[1].uop.csr_num;
    wire [4:0] enq_cacop_op = enq[0].uop.cacop_op;
    wire [4:0] enq1_cacop_op = enq[1].uop.cacop_op;
    wire enq_serializing = enq[0].uop.serializing;
    wire enq1_serializing = enq[1].uop.serializing;
    wire [2:0] enq_ras_ptr = enq[0].uop.pred.ras_ptr;
    wire [2:0] enq1_ras_ptr = enq[1].uop.pred.ras_ptr;
    wire enq_pred_valid = enq[0].uop.pred.valid;
    wire enq1_pred_valid = enq[1].uop.pred.valid;
    wire enq_pred_taken = enq[0].uop.pred.taken;
    wire enq1_pred_taken = enq[1].uop.pred.taken;
    wire [31:0] enq_pred_target = enq[0].uop.pred.target;
    wire [31:0] enq1_pred_target = enq[1].uop.pred.target;
    wire [9:0] enq_pred_index = enq[0].uop.pred.index;
    wire [9:0] enq1_pred_index = enq[1].uop.pred.index;
    wire [2:0] enq_ras_sp_before = enq[0].uop.pred.ras_sp_before;
    wire [2:0] enq1_ras_sp_before = enq[1].uop.pred.ras_sp_before;
    wire [3:0] enq_ras_count_before = enq[0].uop.pred.ras_count_before;
    wire [3:0] enq1_ras_count_before = enq[1].uop.pred.ras_count_before;
    wire enq_perf_btb_hit = enq[0].uop.pred.perf_btb_hit;
    wire enq1_perf_btb_hit = enq[1].uop.pred.perf_btb_hit;

    wire complete_valid = complete[0].valid;
    wire [`ROB_TAG_W-1:0] complete_tag = complete[0].uop_id.rob_tag;
    wire uop_id_t complete_id = complete[0].uop_id;
    wire [31:0] complete_value = complete[0].value;
    wire complete_rf_we = complete[0].reg_write;
    wire complete1_valid = complete[1].valid;
    wire [`ROB_TAG_W-1:0] complete1_tag = complete[1].uop_id.rob_tag;
    wire uop_id_t complete1_id = complete[1].uop_id;
    wire [31:0] complete1_value = complete[1].value;
    wire complete1_rf_we = complete[1].reg_write;
    wire commit_valid = commit[0].valid;
    wire [`ROB_TAG_W-1:0] commit_tag = commit[0].uop_id.rob_tag;
    wire uop_id_t commit_id = commit[0].uop_id;
    wire [31:0] commit_value = commit[0].value;
    wire commit_rf_we = commit[0].reg_write;
    wire commit1_valid = commit[1].valid;
    wire [`ROB_TAG_W-1:0] commit1_tag = commit[1].uop_id.rob_tag;
    wire uop_id_t commit1_id = commit[1].uop_id;
    wire [31:0] commit1_value = commit[1].value;
    wire commit1_rf_we = commit[1].reg_write;

    function seq_is_older;
        input [DQ_SEQ_W-1:0] lhs;
        input [DQ_SEQ_W-1:0] rhs;
        reg   [DQ_SEQ_W-1:0] delta;
        begin
            delta = lhs - rhs;
            seq_is_older = delta[DQ_SEQ_W-1];
        end
    endfunction

    // Balanced 8-way tournament. Pair, quarter, and final comparisons form
    // three fixed levels; no timing-critical serial priority loop is used.
    // Return value: {found, slot[2:0]}.
    function [3:0] pick_oldest8;
        input [DQ_DEPTH-1:0] mask;
        input [DQ_SEQ_W-1:0] seq0;
        input [DQ_SEQ_W-1:0] seq1;
        input [DQ_SEQ_W-1:0] seq2;
        input [DQ_SEQ_W-1:0] seq3;
        input [DQ_SEQ_W-1:0] seq4;
        input [DQ_SEQ_W-1:0] seq5;
        input [DQ_SEQ_W-1:0] seq6;
        input [DQ_SEQ_W-1:0] seq7;
        reg valid01, valid23, valid45, valid67;
        reg valid03, valid47;
        reg [2:0] sel01, sel23, sel45, sel67;
        reg [2:0] sel03, sel47;
        reg [DQ_SEQ_W-1:0] win01, win23, win45, win67;
        reg [DQ_SEQ_W-1:0] win03, win47;
        begin
            valid01 = mask[0] | mask[1];
            valid23 = mask[2] | mask[3];
            valid45 = mask[4] | mask[5];
            valid67 = mask[6] | mask[7];
            if (mask[0] && (!mask[1] || seq_is_older(seq0, seq1))) begin
                sel01 = 3'd0; win01 = seq0;
            end else begin
                sel01 = 3'd1; win01 = seq1;
            end
            if (mask[2] && (!mask[3] || seq_is_older(seq2, seq3))) begin
                sel23 = 3'd2; win23 = seq2;
            end else begin
                sel23 = 3'd3; win23 = seq3;
            end
            if (mask[4] && (!mask[5] || seq_is_older(seq4, seq5))) begin
                sel45 = 3'd4; win45 = seq4;
            end else begin
                sel45 = 3'd5; win45 = seq5;
            end
            if (mask[6] && (!mask[7] || seq_is_older(seq6, seq7))) begin
                sel67 = 3'd6; win67 = seq6;
            end else begin
                sel67 = 3'd7; win67 = seq7;
            end

            valid03 = valid01 | valid23;
            if (valid01 && (!valid23 || seq_is_older(win01, win23))) begin
                sel03 = sel01; win03 = win01;
            end else begin
                sel03 = sel23; win03 = win23;
            end
            valid47 = valid45 | valid67;
            if (valid45 && (!valid67 || seq_is_older(win45, win67))) begin
                sel47 = sel45; win47 = win45;
            end else begin
                sel47 = sel67; win47 = win67;
            end

            if (!valid03 && !valid47)
                pick_oldest8 = 4'b0000;
            else if (valid03 && (!valid47 || seq_is_older(win03, win47)))
                pick_oldest8 = {1'b1, sel03};
            else
                pick_oldest8 = {1'b1, sel47};
        end
    endfunction

    wire [DQ_DEPTH-1:0] wake0_src0_vec;
    wire [DQ_DEPTH-1:0] wake0_src1_vec;
    wire [DQ_DEPTH-1:0] wake1_src0_vec;
    wire [DQ_DEPTH-1:0] wake1_src1_vec;
    wire [DQ_DEPTH-1:0] wake2_src0_vec;
    wire [DQ_DEPTH-1:0] wake2_src1_vec;
    wire [DQ_DEPTH-1:0] wake3_src0_vec;
    wire [DQ_DEPTH-1:0] wake3_src1_vec;
    wire [DQ_DEPTH-1:0] wake_src0_vec;
    wire [DQ_DEPTH-1:0] wake_src1_vec;
    wire [DQ_DEPTH-1:0] complete0_src0_match;
    wire [DQ_DEPTH-1:0] complete0_src1_match;
    wire [DQ_DEPTH-1:0] complete1_src0_match;
    wire [DQ_DEPTH-1:0] complete1_src1_match;
    wire [DQ_DEPTH-1:0] src0_ready_eff;
    wire [DQ_DEPTH-1:0] src1_ready_eff;
    wire [31:0] src0_value_eff [0:DQ_DEPTH-1];
    wire [31:0] src1_value_eff [0:DQ_DEPTH-1];
    wire [DQ_DEPTH-1:0] slot_ready;
    wire [DQ_DEPTH-1:0] slot_restricted;
    wire [DQ_DEPTH-1:0] slot_fast_eligible;
    wire [DQ_DEPTH-1:0] slot_lane0_only;
    wire [DQ_DEPTH-1:0] serializing_mask;
    logic [DQ_DEPTH-1:0] older_branch_pending;
    logic [DQ_DEPTH-1:0] older_store_pending;
    wire [3:0] next_barrier_pick;
    wire next_barrier_found;
    wire [DQ_SEQ_W-1:0] next_barrier_seq;
    wire [DQ_DEPTH-1:0] next_barrier_blocks;
    wire barrier_blocks_new;
    wire [DQ_DEPTH-1:0] fast_hold_onehot = fast_hold_valid ?
        ({{(DQ_DEPTH-1){1'b0}}, 1'b1} << fast_hold_sel) :
        {DQ_DEPTH{1'b0}};
    wire [DQ_DEPTH-1:0] main_hold_onehot = main_hold_valid ?
        ({{(DQ_DEPTH-1){1'b0}}, 1'b1} << main_hold_sel) :
        {DQ_DEPTH{1'b0}};

    // Control-flow recovery is not composable when a younger branch is
    // allowed to redirect before an older unresolved branch.  In that case
    // the younger target can reach the frontend first and later be replaced
    // by the older target, while the wrong-path branch may already commit.
    // Keep only the oldest pending branch eligible; ordinary ALU/LSU uops
    // remain fully out-of-order.
    integer branch_q;
    integer branch_old;
    always @(*) begin
        older_branch_pending = {DQ_DEPTH{1'b0}};
        for (branch_q = 0; branch_q < DQ_DEPTH; branch_q = branch_q + 1) begin
            for (branch_old = 0; branch_old < DQ_DEPTH; branch_old = branch_old + 1) begin
                if (valid[branch_old] && is_br_jmp[branch_old] &&
                    seq_is_older(alloc_seq[branch_old], alloc_seq[branch_q]))
                    older_branch_pending[branch_q] = 1'b1;
            end
        end
    end

`ifndef SYNTHESIS
    wire [3:0] perf_oldest_valid = pick_oldest8(
        valid, alloc_seq[0], alloc_seq[1], alloc_seq[2], alloc_seq[3],
        alloc_seq[4], alloc_seq[5], alloc_seq[6], alloc_seq[7]);
    wire [2:0] perf_oldest_idx = perf_oldest_valid[2:0];
    wire perf_oldest_is_valid = perf_oldest_valid[3];
`else
    assign perf_true_source_wait = 1'b0;
    assign perf_lsu_order = 1'b0;
    assign perf_serializing = 1'b0;
`endif

    // The SQ receives an entry when address generation completes, not at
    // dispatch. Until an older Store has left this queue, its address is
    // unknown to the LSU. Conservatively keep a younger Load here rather
    // than speculate and require a memory-order-violation replay path.
    integer store_q;
    integer store_old;
    always @(*) begin
        older_store_pending = {DQ_DEPTH{1'b0}};
        for (store_q = 0; store_q < DQ_DEPTH; store_q = store_q + 1) begin
            for (store_old = 0; store_old < DQ_DEPTH; store_old = store_old + 1) begin
                if (valid[store_old] && is_ld_st[store_old] &&
                    (ram_we[store_old] != `RAM_WE_N) &&
                    seq_is_older(alloc_seq[store_old], alloc_seq[store_q]))
                    older_store_pending[store_q] = 1'b1;
            end
        end
    end

    genvar q;
    generate
        for (q = 0; q < DQ_DEPTH; q = q + 1) begin : GEN_ISSUE_STATE
            // A ready source no longer has a meaningful producer ID.  Limit
            // completion matching to unresolved sources so a wrapped ROB ID
            // cannot replace an already-authoritative operand value.
            assign complete0_src0_match[q] = complete_valid && complete_rf_we &&
                                              valid[q] && rR1_re[q] &&
                                              (rR1[q] != 5'h0) && !src0_ready[q] &&
                                              uop_id_equal(complete_id, src0_id[q]);
            assign complete0_src1_match[q] = complete_valid && complete_rf_we &&
                                              valid[q] && rR2_re[q] &&
                                              (rR2[q] != 5'h0) && !src1_ready[q] &&
                                              uop_id_equal(complete_id, src1_id[q]);
            assign complete1_src0_match[q] = complete1_valid && complete1_rf_we &&
                                              valid[q] && rR1_re[q] &&
                                              (rR1[q] != 5'h0) && !src0_ready[q] &&
                                              uop_id_equal(complete1_id, src0_id[q]);
            assign complete1_src1_match[q] = complete1_valid && complete1_rf_we &&
                                              valid[q] && rR2_re[q] &&
                                              (rR2[q] != 5'h0) && !src1_ready[q] &&
                                              uop_id_equal(complete1_id, src1_id[q]);
            assign wake0_src0_vec[q] = complete0_src0_match[q];
            assign wake0_src1_vec[q] = complete0_src1_match[q];
            assign wake1_src0_vec[q] = complete1_src0_match[q];
            assign wake1_src1_vec[q] = complete1_src1_match[q];
            assign wake2_src0_vec[q] = commit_valid && commit_rf_we &&
                                       valid[q] && rR1_re[q] &&
                                       (rR1[q] != 5'h0) && !src0_ready[q] &&
                                       uop_id_equal(commit_id, src0_id[q]);
            assign wake2_src1_vec[q] = commit_valid && commit_rf_we &&
                                       valid[q] && rR2_re[q] &&
                                       (rR2[q] != 5'h0) && !src1_ready[q] &&
                                       uop_id_equal(commit_id, src1_id[q]);
            assign wake3_src0_vec[q] = commit1_valid && commit1_rf_we &&
                                       valid[q] && rR1_re[q] &&
                                       (rR1[q] != 5'h0) && !src0_ready[q] &&
                                       uop_id_equal(commit1_id, src0_id[q]);
            assign wake3_src1_vec[q] = commit1_valid && commit1_rf_we &&
                                       valid[q] && rR2_re[q] &&
                                       (rR2[q] != 5'h0) && !src1_ready[q] &&
                                       uop_id_equal(commit1_id, src1_id[q]);
            assign wake_src0_vec[q] = wake0_src0_vec[q] || wake1_src0_vec[q] ||
                                       wake2_src0_vec[q] || wake3_src0_vec[q];
            assign wake_src1_vec[q] = wake0_src1_vec[q] || wake1_src1_vec[q] ||
                                       wake2_src1_vec[q] || wake3_src1_vec[q];
            assign src0_ready_eff[q] = src0_ready[q] ||
                                        complete0_src0_match[q] ||
                                        complete1_src0_match[q];
            assign src1_ready_eff[q] = src1_ready[q] ||
                                        complete0_src1_match[q] ||
                                        complete1_src1_match[q];
            assign src0_value_eff[q] = complete0_src0_match[q] ? complete_value :
                                       complete1_src0_match[q] ? complete1_value :
                                       rD1[q];
            assign src1_value_eff[q] = complete0_src1_match[q] ? complete_value :
                                       complete1_src1_match[q] ? complete1_value :
                                       rD2[q];
            // Device reads have an irreversible side effect (for example a
            // UART RBR read pops one RX byte).  Address generation may be
            // speculative, but the read itself must not leave the scheduler
            // until the complete uop identity is at the ROB head.  RAM loads
            // retain normal out-of-order issue.
            // Address generation is moved out to avoid long combinational path.
            // RAM loads retain normal out-of-order issue.
            // Completion wakeup is still captured into src*_ready/rD* at the
            // clock edge.  The effective state additionally lets that same
            // completion participate in select and operand delivery now.
            assign slot_ready[q] = src0_ready_eff[q] && src1_ready_eff[q] &&
                                    (!(is_ld_st[q] &&
                                       (ram_we[q] == `RAM_WE_N)) ||
                                     !older_store_pending[q]) &&
                                    (!is_br_jmp[q] || !older_branch_pending[q]) &&
                                   (!BRANCH_AT_ROB_HEAD || !is_br_jmp[q] ||
                                    (rob_head_valid &&
                                     uop_id_equal(uop_id[q], rob_head_id)));
            assign slot_restricted[q] = is_br_jmp[q] || is_ld_st[q] ||
                                        is_call[q] || is_ret[q] ||
                                        pred_taken[q] ||
                                        (system_op[q] != 3'd0);
            // Lane1 now owns a full address generator as well as ALU/MDU.
            // Branch/system operations still use the ordered lane0 path.
            assign slot_fast_eligible[q] = is_ld_st[q] ||
                                           (!slot_restricted[q] &&
                                            (wd_sel[q] == `WD_ALU));
            // System operations are deliberately excluded.  They use the
            // serializing ROB-head path and must never be pulled forward just
            // to fill an execution lane.
            assign slot_lane0_only[q] = slot_restricted[q] && !is_ld_st[q] &&
                                        (system_op[q] == 3'd0);
            assign serializing_mask[q] = valid[q] && serializing[q] &&
                                         (system_op[q] != 3'd0);
            assign next_barrier_blocks[q] = next_barrier_found &&
                                            seq_is_older(next_barrier_seq,
                                                         alloc_seq[q]);
        end
    endgenerate

    wire issue_fire;
    wire fast_issue_fire;
    wire enq_fire;
    wire enq1_fire;

    // Barrier age comparisons feed only registered state.  Release occurs
    // from the registered privilege response, after system_inflight has
    // already protected the whole execution window.
    assign next_barrier_pick = pick_oldest8(
        serializing_mask,
        alloc_seq[0], alloc_seq[1], alloc_seq[2], alloc_seq[3],
        alloc_seq[4], alloc_seq[5], alloc_seq[6], alloc_seq[7]);
    assign next_barrier_found = next_barrier_pick[3];
    assign next_barrier_seq = alloc_seq[next_barrier_pick[2:0]];
    assign barrier_blocks_new = barrier_release ? next_barrier_found :
                                                   barrier_active;

    // The general issue path is an out-of-order scheduler path.  A ready
    // branch, load/store, MDU or CSR uop does not wait for an older unresolved
    // uop.  ROB commit order remains precise, while LSU/memory-order logic is
    // responsible for load/store ordering.  Only the explicit serializing
    // barrier state blocks younger entries.
    wire [DQ_DEPTH-1:0] main_candidate = valid & slot_ready & ~barrier_blocked &
        ~fast_hold_onehot;
    wire [3:0] oldest_main_pick = pick_oldest8(
        main_candidate,
        alloc_seq[0], alloc_seq[1], alloc_seq[2], alloc_seq[3],
        alloc_seq[4], alloc_seq[5], alloc_seq[6], alloc_seq[7]);

    // When the oldest ready uop can run on ALU1, prefer a second ready uop
    // which requires lane0 (LSU/MDU/branch).  The fast selector below then
    // chooses the original oldest ALU uop, so both issue in the same cycle.
    // Eight exclusion masks avoid putting the same entry on both outputs and
    // retain the balanced selector structure used on the timing-critical path.
    wire [DQ_DEPTH-1:0] lane0_candidate = main_candidate & slot_lane0_only &
                                          ~main_hold_onehot;
    wire [3:0] lane0_pick_no0 = pick_oldest8(lane0_candidate & 8'b11111110, alloc_seq[0], alloc_seq[1], alloc_seq[2], alloc_seq[3], alloc_seq[4], alloc_seq[5], alloc_seq[6], alloc_seq[7]);
    wire [3:0] lane0_pick_no1 = pick_oldest8(lane0_candidate & 8'b11111101, alloc_seq[0], alloc_seq[1], alloc_seq[2], alloc_seq[3], alloc_seq[4], alloc_seq[5], alloc_seq[6], alloc_seq[7]);
    wire [3:0] lane0_pick_no2 = pick_oldest8(lane0_candidate & 8'b11111011, alloc_seq[0], alloc_seq[1], alloc_seq[2], alloc_seq[3], alloc_seq[4], alloc_seq[5], alloc_seq[6], alloc_seq[7]);
    wire [3:0] lane0_pick_no3 = pick_oldest8(lane0_candidate & 8'b11110111, alloc_seq[0], alloc_seq[1], alloc_seq[2], alloc_seq[3], alloc_seq[4], alloc_seq[5], alloc_seq[6], alloc_seq[7]);
    wire [3:0] lane0_pick_no4 = pick_oldest8(lane0_candidate & 8'b11101111, alloc_seq[0], alloc_seq[1], alloc_seq[2], alloc_seq[3], alloc_seq[4], alloc_seq[5], alloc_seq[6], alloc_seq[7]);
    wire [3:0] lane0_pick_no5 = pick_oldest8(lane0_candidate & 8'b11011111, alloc_seq[0], alloc_seq[1], alloc_seq[2], alloc_seq[3], alloc_seq[4], alloc_seq[5], alloc_seq[6], alloc_seq[7]);
    wire [3:0] lane0_pick_no6 = pick_oldest8(lane0_candidate & 8'b10111111, alloc_seq[0], alloc_seq[1], alloc_seq[2], alloc_seq[3], alloc_seq[4], alloc_seq[5], alloc_seq[6], alloc_seq[7]);
    wire [3:0] lane0_pick_no7 = pick_oldest8(lane0_candidate & 8'b01111111, alloc_seq[0], alloc_seq[1], alloc_seq[2], alloc_seq[3], alloc_seq[4], alloc_seq[5], alloc_seq[6], alloc_seq[7]);
    reg [3:0] lane0_pair_pick;
    always @(*) begin
        case (oldest_main_pick[2:0])
            3'd0: lane0_pair_pick = lane0_pick_no0;
            3'd1: lane0_pair_pick = lane0_pick_no1;
            3'd2: lane0_pair_pick = lane0_pick_no2;
            3'd3: lane0_pair_pick = lane0_pick_no3;
            3'd4: lane0_pair_pick = lane0_pick_no4;
            3'd5: lane0_pair_pick = lane0_pick_no5;
            3'd6: lane0_pair_pick = lane0_pick_no6;
            default: lane0_pair_pick = lane0_pick_no7;
        endcase
    end
    wire use_resource_pair = RESOURCE_AWARE_PAIRING && !main_hold_valid &&
                             oldest_main_pick[3] &&
                             slot_fast_eligible[oldest_main_pick[2:0]] &&
                             lane0_pair_pick[3];
    wire [3:0] main_pick = use_resource_pair ? lane0_pair_pick :
                                                 oldest_main_pick;
    assign issue_found = main_hold_valid ? valid[main_hold_sel] : main_pick[3];
    assign issue_sel = main_hold_valid ? main_hold_sel : main_pick[2:0];

    // Compute all fast-lane exclusion cases in parallel.  The main selector
    // chooses only the final small mux; it no longer feeds another complete
    // priority/age scan.
    wire [DQ_DEPTH-1:0] fast_candidate = valid & slot_ready & ~barrier_blocked &
        slot_fast_eligible & ~main_hold_onehot;
    wire [3:0] fast_pick_any = pick_oldest8(fast_candidate, alloc_seq[0], alloc_seq[1], alloc_seq[2], alloc_seq[3], alloc_seq[4], alloc_seq[5], alloc_seq[6], alloc_seq[7]);
    wire [3:0] fast_pick_no0 = pick_oldest8(fast_candidate & 8'b11111110, alloc_seq[0], alloc_seq[1], alloc_seq[2], alloc_seq[3], alloc_seq[4], alloc_seq[5], alloc_seq[6], alloc_seq[7]);
    wire [3:0] fast_pick_no1 = pick_oldest8(fast_candidate & 8'b11111101, alloc_seq[0], alloc_seq[1], alloc_seq[2], alloc_seq[3], alloc_seq[4], alloc_seq[5], alloc_seq[6], alloc_seq[7]);
    wire [3:0] fast_pick_no2 = pick_oldest8(fast_candidate & 8'b11111011, alloc_seq[0], alloc_seq[1], alloc_seq[2], alloc_seq[3], alloc_seq[4], alloc_seq[5], alloc_seq[6], alloc_seq[7]);
    wire [3:0] fast_pick_no3 = pick_oldest8(fast_candidate & 8'b11110111, alloc_seq[0], alloc_seq[1], alloc_seq[2], alloc_seq[3], alloc_seq[4], alloc_seq[5], alloc_seq[6], alloc_seq[7]);
    wire [3:0] fast_pick_no4 = pick_oldest8(fast_candidate & 8'b11101111, alloc_seq[0], alloc_seq[1], alloc_seq[2], alloc_seq[3], alloc_seq[4], alloc_seq[5], alloc_seq[6], alloc_seq[7]);
    wire [3:0] fast_pick_no5 = pick_oldest8(fast_candidate & 8'b11011111, alloc_seq[0], alloc_seq[1], alloc_seq[2], alloc_seq[3], alloc_seq[4], alloc_seq[5], alloc_seq[6], alloc_seq[7]);
    wire [3:0] fast_pick_no6 = pick_oldest8(fast_candidate & 8'b10111111, alloc_seq[0], alloc_seq[1], alloc_seq[2], alloc_seq[3], alloc_seq[4], alloc_seq[5], alloc_seq[6], alloc_seq[7]);
    wire [3:0] fast_pick_no7 = pick_oldest8(fast_candidate & 8'b01111111, alloc_seq[0], alloc_seq[1], alloc_seq[2], alloc_seq[3], alloc_seq[4], alloc_seq[5], alloc_seq[6], alloc_seq[7]);

    reg [3:0] fast_pick;
    always @(*) begin
        // Never present the same entry on both output lanes.  The old logic
        // allowed lane1 to select the lane0 entry when lane0 was stalled;
        // lane1 could then consume it and make lane0 valid/payload change
        // without a lane0 handshake.
        if (!issue_found) begin
            fast_pick = fast_pick_any;
        end else begin
            case (issue_sel)
                3'd0: fast_pick = fast_pick_no0;
                3'd1: fast_pick = fast_pick_no1;
                3'd2: fast_pick = fast_pick_no2;
                3'd3: fast_pick = fast_pick_no3;
                3'd4: fast_pick = fast_pick_no4;
                3'd5: fast_pick = fast_pick_no5;
                3'd6: fast_pick = fast_pick_no6;
                default: fast_pick = fast_pick_no7;
            endcase
        end
    end
    assign fast_issue_found = fast_hold_valid ? valid[fast_hold_sel] : fast_pick[3];
    assign fast_issue_sel = fast_hold_valid ? fast_hold_sel : fast_pick[2:0];

    always @(*) begin
        enq_sel = 3'h0;
        enq1_sel = 3'h0;
        free_found = 1'b0;
        second_free_found = 1'b0;
        for (k = 0; k < DQ_DEPTH; k = k + 1) begin
            // Enqueue only into slots that were already free at the start of
            // the cycle.  Do not feed issue/age selection back into every
            // queue data-register D input through same-cycle slot reuse.
            if (!valid[k]) begin
                if (!free_found) begin
                    free_found = 1'b1;
                    enq_sel = k[2:0];
                end else if (!second_free_found && (k[2:0] != enq_sel)) begin
                    second_free_found = 1'b1;
                    enq1_sel = k[2:0];
                end
            end
        end
    end

    assign issue_fire = issue_valid[0] && issue_ready[0];
    assign fast_issue_fire = issue_valid[1] && issue_ready[1];
    assign enq_fire = enq_valid && enq_ready[0];
    assign enq1_fire = enq1_valid && enq_ready[1];

    assign enq_ready[0] = free_found;
    assign enq_ready[1] = free_found && second_free_found;
    assign issue_valid[0] = issue_found;
    assign issue_valid[1] = fast_issue_found;

    always @(*) begin
        issue[0] = '0;
        issue[0].uop_id = uop_id[issue_sel];
        issue[0].pc = pc[issue_sel];
        issue[0].src0_value = src0_value_eff[issue_sel];
        issue[0].src1_value = src1_value_eff[issue_sel];
        issue[0].arch_rs1 = rR1[issue_sel];
        issue[0].arch_rs2 = rR2[issue_sel];
        issue[0].src0_used = rR1_re[issue_sel];
        issue[0].src1_used = rR2_re[issue_sel];
        issue[0].imm = ext[issue_sel];
        issue[0].npc_op = npc_op[issue_sel];
        issue[0].reg_write = rf_we[issue_sel];
        issue[0].arch_rd = wR[issue_sel];
        issue[0].result_sel = wd_sel[issue_sel];
        issue[0].alu_op = alu_op[issue_sel];
        issue[0].src_a_sel = alua_sel[issue_sel];
        issue[0].src_b_sel = alub_sel[issue_sel];
        issue[0].store_mask = ram_we[issue_sel];
        issue[0].load_ext_op = ram_ext_op[issue_sel];
        issue[0].is_br_jmp = is_br_jmp[issue_sel];
        issue[0].is_ld_st = is_ld_st[issue_sel];
        issue[0].is_call = is_call[issue_sel];
        issue[0].is_ret = is_ret[issue_sel];
        issue[0].system_op = system_op_e'(system_op[issue_sel]);
        issue[0].csr_num = csr_num[issue_sel];
        issue[0].cacop_op = cacop_op[issue_sel];
        issue[0].serializing = serializing[issue_sel];
        issue[0].pred.ras_ptr = ras_ptr[issue_sel];
        issue[0].pred.valid = pred_valid[issue_sel];
        issue[0].pred.taken = pred_taken[issue_sel];
        issue[0].pred.target = pred_target[issue_sel];
        issue[0].pred.index = pred_index[issue_sel];
        issue[0].pred.ras_sp_before = ras_sp_before[issue_sel];
        issue[0].pred.ras_count_before = ras_count_before[issue_sel];
        issue[0].pred.perf_btb_hit = perf_btb_hit[issue_sel];

`ifndef SYNTHESIS
        perf_true_source_wait = 1'b0;
        perf_lsu_order = 1'b0;
        perf_serializing = 1'b0;
        if (perf_oldest_is_valid) begin
            perf_true_source_wait = (!src0_ready_eff[perf_oldest_idx] || !src1_ready_eff[perf_oldest_idx]);
            perf_lsu_order = src0_ready_eff[perf_oldest_idx] && src1_ready_eff[perf_oldest_idx] &&
                             is_ld_st[perf_oldest_idx] && (ram_we[perf_oldest_idx] == `RAM_WE_N) && older_store_pending[perf_oldest_idx];
            perf_serializing = src0_ready_eff[perf_oldest_idx] && src1_ready_eff[perf_oldest_idx] &&
                               slot_lane0_only[perf_oldest_idx] && (system_op[perf_oldest_idx] != 3'd0) &&
                               (!rob_head_valid || !uop_id_equal(uop_id[perf_oldest_idx], rob_head_id));
        end
`endif

        issue[1] = '0;
        issue[1].uop_id = uop_id[fast_issue_sel];
        issue[1].pc = pc[fast_issue_sel];
        issue[1].src0_value = src0_value_eff[fast_issue_sel];
        issue[1].src1_value = src1_value_eff[fast_issue_sel];
        issue[1].imm = ext[fast_issue_sel];
        issue[1].reg_write = rf_we[fast_issue_sel];
        issue[1].arch_rd = wR[fast_issue_sel];
        issue[1].result_sel = wd_sel[fast_issue_sel];
        issue[1].alu_op = alu_op[fast_issue_sel];
        issue[1].src_a_sel = alua_sel[fast_issue_sel];
        issue[1].src_b_sel = alub_sel[fast_issue_sel];
        issue[1].arch_rs1 = rR1[fast_issue_sel];
        issue[1].arch_rs2 = rR2[fast_issue_sel];
        issue[1].src0_used = rR1_re[fast_issue_sel];
        issue[1].src1_used = rR2_re[fast_issue_sel];
        issue[1].npc_op = npc_op[fast_issue_sel];
        issue[1].store_mask = ram_we[fast_issue_sel];
        issue[1].load_ext_op = ram_ext_op[fast_issue_sel];
        issue[1].is_br_jmp = is_br_jmp[fast_issue_sel];
        issue[1].is_ld_st = is_ld_st[fast_issue_sel];
        issue[1].is_call = is_call[fast_issue_sel];
        issue[1].is_ret = is_ret[fast_issue_sel];
        issue[1].system_op = system_op_e'(system_op[fast_issue_sel]);
        issue[1].csr_num = csr_num[fast_issue_sel];
        issue[1].cacop_op = cacop_op[fast_issue_sel];
        issue[1].serializing = serializing[fast_issue_sel];
        issue[1].pred.ras_ptr = ras_ptr[fast_issue_sel];
        issue[1].pred.valid = pred_valid[fast_issue_sel];
        issue[1].pred.taken = pred_taken[fast_issue_sel];
        issue[1].pred.target = pred_target[fast_issue_sel];
        issue[1].pred.index = pred_index[fast_issue_sel];
        issue[1].pred.ras_sp_before = ras_sp_before[fast_issue_sel];
        issue[1].pred.ras_count_before = ras_count_before[fast_issue_sel];
        issue[1].pred.perf_btb_hit = perf_btb_hit[fast_issue_sel];
    end
    assign occupancy = count;

    // Preserve a result when the producer and dependent are accepted on the
    // same edge.  The held rename value is not sufficient in that case,
    // because the completion/commit value is the newest value.
    // Only unresolved sources may consume a tag-matched bypass.  A ready
    // source already carries the authoritative rename/RF value; its tag bits
    // are don't-care and may equal an unrelated completion after ROB wrap.
    wire enq_src0_real = enq_rR1_re && (enq_rR1 != 5'h0) &&
                         !enq_src0_ready;
    wire enq_src1_real = enq_rR2_re && (enq_rR2 != 5'h0) &&
                         !enq_src1_ready;
    wire enq1_src0_real = enq1_rR1_re && (enq1_rR1 != 5'h0) &&
                          !enq1_src0_ready;
    wire enq1_src1_real = enq1_rR2_re && (enq1_rR2 != 5'h0) &&
                          !enq1_src1_ready;

    wire c0_enq_s0 = uop_id_equal(complete_id, enq_src0_id);
    wire c1_enq_s0 = uop_id_equal(complete1_id, enq_src0_id);
    wire k0_enq_s0 = uop_id_equal(commit_id, enq_src0_id);
    wire k1_enq_s0 = uop_id_equal(commit1_id, enq_src0_id);
    wire c0_enq_s1 = uop_id_equal(complete_id, enq_src1_id);
    wire c1_enq_s1 = uop_id_equal(complete1_id, enq_src1_id);
    wire k0_enq_s1 = uop_id_equal(commit_id, enq_src1_id);
    wire k1_enq_s1 = uop_id_equal(commit1_id, enq_src1_id);
    wire c0_enq1_s0 = uop_id_equal(complete_id, enq1_src0_id);
    wire c1_enq1_s0 = uop_id_equal(complete1_id, enq1_src0_id);
    wire k0_enq1_s0 = uop_id_equal(commit_id, enq1_src0_id);
    wire k1_enq1_s0 = uop_id_equal(commit1_id, enq1_src0_id);
    wire c0_enq1_s1 = uop_id_equal(complete_id, enq1_src1_id);
    wire c1_enq1_s1 = uop_id_equal(complete1_id, enq1_src1_id);
    wire k0_enq1_s1 = uop_id_equal(commit_id, enq1_src1_id);
    wire k1_enq1_s1 = uop_id_equal(commit1_id, enq1_src1_id);

    wire enq_src0_complete = enq_src0_real &&
                             ((complete_valid && complete_rf_we && c0_enq_s0) ||
                              (complete1_valid && complete1_rf_we && c1_enq_s0));
    wire enq_src1_complete = enq_src1_real &&
                             ((complete_valid && complete_rf_we && c0_enq_s1) ||
                              (complete1_valid && complete1_rf_we && c1_enq_s1));
    wire enq_src0_commit = enq_src0_real &&
                           ((commit_valid && commit_rf_we && k0_enq_s0) ||
                            (commit1_valid && commit1_rf_we && k1_enq_s0));
    wire enq_src1_commit = enq_src1_real &&
                           ((commit_valid && commit_rf_we && k0_enq_s1) ||
                            (commit1_valid && commit1_rf_we && k1_enq_s1));
    wire enq1_src0_complete = enq1_src0_real &&
                              ((complete_valid && complete_rf_we && c0_enq1_s0) ||
                               (complete1_valid && complete1_rf_we && c1_enq1_s0));
    wire enq1_src1_complete = enq1_src1_real &&
                              ((complete_valid && complete_rf_we && c0_enq1_s1) ||
                               (complete1_valid && complete1_rf_we && c1_enq1_s1));
    wire enq1_src0_commit = enq1_src0_real &&
                            ((commit_valid && commit_rf_we && k0_enq1_s0) ||
                             (commit1_valid && commit1_rf_we && k1_enq1_s0));
    wire enq1_src1_commit = enq1_src1_real &&
                            ((commit_valid && commit_rf_we && k0_enq1_s1) ||
                             (commit1_valid && commit1_rf_we && k1_enq1_s1));

    wire [31:0] enq_src0_bypass_value =
        (enq_src0_real && complete_valid && complete_rf_we && c0_enq_s0) ?
            complete_value :
        (enq_src0_real && complete1_valid && complete1_rf_we && c1_enq_s0) ?
            complete1_value :
        (enq_src0_real && commit_valid && commit_rf_we && k0_enq_s0) ?
            commit_value :
        (enq_src0_real && commit1_valid && commit1_rf_we && k1_enq_s0) ?
            commit1_value : enq_rD1;
    wire [31:0] enq_src1_bypass_value =
        (enq_src1_real && complete_valid && complete_rf_we && c0_enq_s1) ?
            complete_value :
        (enq_src1_real && complete1_valid && complete1_rf_we && c1_enq_s1) ?
            complete1_value :
        (enq_src1_real && commit_valid && commit_rf_we && k0_enq_s1) ?
            commit_value :
        (enq_src1_real && commit1_valid && commit1_rf_we && k1_enq_s1) ?
            commit1_value : enq_rD2;
    wire [31:0] enq1_src0_bypass_value =
        (enq1_src0_real && complete_valid && complete_rf_we && c0_enq1_s0) ?
            complete_value :
        (enq1_src0_real && complete1_valid && complete1_rf_we && c1_enq1_s0) ?
            complete1_value :
        (enq1_src0_real && commit_valid && commit_rf_we && k0_enq1_s0) ?
            commit_value :
        (enq1_src0_real && commit1_valid && commit1_rf_we && k1_enq1_s0) ?
            commit1_value : enq1_rD1;
    wire [31:0] enq1_src1_bypass_value =
        (enq1_src1_real && complete_valid && complete_rf_we && c0_enq1_s1) ?
            complete_value :
        (enq1_src1_real && complete1_valid && complete1_rf_we && c1_enq1_s1) ?
            complete1_value :
        (enq1_src1_real && commit_valid && commit_rf_we && k0_enq1_s1) ?
            commit_value :
        (enq1_src1_real && commit1_valid && commit1_rf_we && k1_enq1_s1) ?
            commit1_value : enq1_rD2;

    // Operand storage is intentionally independent of flush/enq_valid.
    //
    // A free slot is architecturally invalid, so its data bits are don't-care
    // until valid is set.  Prewriting the held rename operands into free slots
    // removes the long EX branch-compare -> flush -> enq_fire -> 64-bit operand
    // register-D path seen with Vivado 2019.2.  Flush still clears valid/ready
    // in the state block below; a speculative data write on a flush cycle is
    // therefore harmless.  Completion writes only target valid slots, so they
    // cannot conflict with a free-slot prewrite.
    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            for (j = 0; j < DQ_DEPTH; j = j + 1) begin
                rD1[j] <= 32'h0;
                rD2[j] <= 32'h0;
            end
        end else begin
            if (complete_valid || complete1_valid || commit_valid || commit1_valid) begin
                for (j = 0; j < DQ_DEPTH; j = j + 1) begin
                    if (wake_src0_vec[j]) begin
                        if (wake0_src0_vec[j] && complete_rf_we)
                            rD1[j] <= complete_value;
                        else if (wake1_src0_vec[j] && complete1_rf_we)
                            rD1[j] <= complete1_value;
                        else if (wake2_src0_vec[j])
                            rD1[j] <= commit_value;
                        else if (wake3_src0_vec[j])
                            rD1[j] <= commit1_value;
                    end
                    if (wake_src1_vec[j]) begin
                        if (wake0_src1_vec[j] && complete_rf_we)
                            rD2[j] <= complete_value;
                        else if (wake1_src1_vec[j] && complete1_rf_we)
                            rD2[j] <= complete1_value;
                        else if (wake2_src1_vec[j])
                            rD2[j] <= commit_value;
                        else if (wake3_src1_vec[j])
                            rD2[j] <= commit1_value;
                    end
                end
            end

            if (free_found) begin
                rD1[enq_sel] <= (enq_src0_complete || enq_src0_commit) ?
                                enq_src0_bypass_value : enq_rD1;
                rD2[enq_sel] <= (enq_src1_complete || enq_src1_commit) ?
                                enq_src1_bypass_value : enq_rD2;
            end
            if (second_free_found) begin
                rD1[enq1_sel] <= (enq1_src0_complete || enq1_src0_commit) ?
                                 enq1_src0_bypass_value : enq1_rD1;
                rD2[enq1_sel] <= (enq1_src1_complete || enq1_src1_commit) ?
                                 enq1_src1_bypass_value : enq1_rD2;
            end
        end
    end

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            valid <= {DQ_DEPTH{1'b0}};
            src0_ready <= {DQ_DEPTH{1'b0}};
            src1_ready <= {DQ_DEPTH{1'b0}};
            barrier_blocked <= {DQ_DEPTH{1'b0}};
            barrier_active <= 1'b0;
            main_hold_valid <= 1'b0;
            main_hold_sel <= 3'h0;
            fast_hold_valid <= 1'b0;
            fast_hold_sel <= 3'h0;
            count <= 4'h0;
            next_alloc_seq <= {DQ_SEQ_W{1'b0}};
            for (i = 0; i < DQ_DEPTH; i = i + 1) begin
                uop_id[i] <= '0;
                alloc_seq[i] <= {DQ_SEQ_W{1'b0}};
                src0_id[i] <= '0;
                src1_id[i] <= '0;
                pc[i] <= 32'h0;
                rR1[i] <= 5'h0;
                rR2[i] <= 5'h0;
                rR1_re[i] <= 1'b0;
                rR2_re[i] <= 1'b0;
                ext[i] <= 32'h0;
                npc_op[i] <= 2'h0;
                rf_we[i] <= 1'b0;
                wR[i] <= 5'h0;
                wd_sel[i] <= 2'h0;
                alu_op[i] <= 5'h0;
                alua_sel[i] <= 1'b0;
                alub_sel[i] <= 1'b0;
                ram_we[i] <= 4'h0;
                ram_ext_op[i] <= 3'h0;
                is_br_jmp[i] <= 1'b0;
                is_ld_st[i] <= 1'b0;
                is_call[i] <= 1'b0;
                is_ret[i] <= 1'b0;
                system_op[i] <= 3'h0;
                csr_num[i] <= 14'h0;
                cacop_op[i] <= 5'h0;
                serializing[i] <= 1'b0;
                ras_ptr[i] <= 3'h0;
                pred_valid[i] <= 1'b0;
                pred_taken[i] <= 1'b0;
                pred_target[i] <= 32'h0;
                pred_index[i] <= 10'h0;
                ras_sp_before[i] <= 3'h0;
                ras_count_before[i] <= 4'h0;
                perf_btb_hit[i] <= 1'b0;
            end
        end else if (flush) begin
            recover_count = 0;
            for (i = 0; i < DQ_DEPTH; i = i + 1) begin
                if (valid[i] && !system_flush && recover_valid &&
                    !uop_is_younger(uop_id[i], recover_id)) begin
                    recover_count = recover_count + 1;
                end else begin
                    valid[i] <= 1'b0;
                    src0_ready[i] <= 1'b0;
                    src1_ready[i] <= 1'b0;
                    barrier_blocked[i] <= 1'b0;
                end
            end
            barrier_active <= 1'b0;
            main_hold_valid <= 1'b0;
            main_hold_sel <= 3'h0;
            fast_hold_valid <= 1'b0;
            fast_hold_sel <= 3'h0;
            count <= recover_count;
            if (system_flush)
                next_alloc_seq <= {DQ_SEQ_W{1'b0}};
        end else begin
            // Capture stalled output transfers.  Each hold state is cleared
            // only by its own handshake or by flush/reset; the opposite lane
            // excludes the held slot from its candidate set.
            if (issue_fire) begin
                main_hold_valid <= 1'b0;
            end else if (issue_valid[0] && !issue_ready[0]) begin
                main_hold_valid <= 1'b1;
                main_hold_sel <= issue_sel;
            end
            if (fast_issue_fire) begin
                fast_hold_valid <= 1'b0;
            end else if (issue_valid[1] && !issue_ready[1]) begin
                fast_hold_valid <= 1'b1;
                fast_hold_sel <= fast_issue_sel;
            end

            if (complete_valid || complete1_valid || commit_valid || commit1_valid) begin
                for (i = 0; i < DQ_DEPTH; i = i + 1) begin
                    if (wake_src0_vec[i]) begin
                        src0_ready[i] <= 1'b1;
                    end
                    if (wake_src1_vec[i]) begin
                        src1_ready[i] <= 1'b1;
                    end
                end
            end

            if (issue_fire) begin
                valid[issue_sel] <= 1'b0;
                src0_ready[issue_sel] <= 1'b0;
                src1_ready[issue_sel] <= 1'b0;
                barrier_blocked[issue_sel] <= 1'b0;
            end
            if (fast_issue_fire) begin
                valid[fast_issue_sel] <= 1'b0;
                src0_ready[fast_issue_sel] <= 1'b0;
                src1_ready[fast_issue_sel] <= 1'b0;
                barrier_blocked[fast_issue_sel] <= 1'b0;
            end

            if (barrier_release) begin
                for (i = 0; i < DQ_DEPTH; i = i + 1)
                    barrier_blocked[i] <= next_barrier_blocks[i];
                barrier_active <= next_barrier_found;
            end

            if (enq_fire) begin
                valid[enq_sel] <= 1'b1;
                uop_id[enq_sel] <= enq_uop_id;
                alloc_seq[enq_sel] <= next_alloc_seq;
                src0_ready[enq_sel] <= enq_src0_ready || enq_src0_complete ||
                                       enq_src0_commit;
                src1_ready[enq_sel] <= enq_src1_ready || enq_src1_complete ||
                                       enq_src1_commit;
                src0_id[enq_sel] <= enq_src0_id;
                src1_id[enq_sel] <= enq_src1_id;
                pc[enq_sel] <= enq_pc;
                rR1[enq_sel] <= enq_rR1;
                rR2[enq_sel] <= enq_rR2;
                rR1_re[enq_sel] <= enq_rR1_re;
                rR2_re[enq_sel] <= enq_rR2_re;
                ext[enq_sel] <= enq_ext;
                npc_op[enq_sel] <= enq_npc_op;
                rf_we[enq_sel] <= enq_rf_we;
                wR[enq_sel] <= enq_wR;
                wd_sel[enq_sel] <= enq_wd_sel;
                alu_op[enq_sel] <= enq_alu_op;
                alua_sel[enq_sel] <= enq_alua_sel;
                alub_sel[enq_sel] <= enq_alub_sel;
                ram_we[enq_sel] <= enq_ram_we;
                ram_ext_op[enq_sel] <= enq_ram_ext_op;
                is_br_jmp[enq_sel] <= enq_is_br_jmp;
                is_ld_st[enq_sel] <= enq_is_ld_st;
                is_call[enq_sel] <= enq_is_call;
                is_ret[enq_sel] <= enq_is_ret;
                system_op[enq_sel] <= enq_system_op;
                csr_num[enq_sel] <= enq_csr_num;
                cacop_op[enq_sel] <= enq_cacop_op;
                serializing[enq_sel] <= enq_serializing;
                barrier_blocked[enq_sel] <= barrier_blocks_new;
                if (enq_serializing && (enq_system_op != 3'd0))
                    barrier_active <= 1'b1;
                ras_ptr[enq_sel] <= enq_ras_ptr;
                pred_valid[enq_sel] <= enq_pred_valid;
                pred_taken[enq_sel] <= enq_pred_taken;
                pred_target[enq_sel] <= enq_pred_target;
                pred_index[enq_sel] <= enq_pred_index;
                ras_sp_before[enq_sel] <= enq_ras_sp_before;
                ras_count_before[enq_sel] <= enq_ras_count_before;
                perf_btb_hit[enq_sel] <= enq_perf_btb_hit;
            end

            if (enq1_fire) begin
                valid[enq1_sel] <= 1'b1;
                uop_id[enq1_sel] <= enq1_uop_id;
                alloc_seq[enq1_sel] <= next_alloc_seq + enq_fire;
                src0_ready[enq1_sel] <= enq1_src0_ready || enq1_src0_complete ||
                                        enq1_src0_commit;
                src1_ready[enq1_sel] <= enq1_src1_ready || enq1_src1_complete ||
                                        enq1_src1_commit;
                src0_id[enq1_sel] <= enq1_src0_id;
                src1_id[enq1_sel] <= enq1_src1_id;
                pc[enq1_sel] <= enq1_pc;
                rR1[enq1_sel] <= enq1_rR1;
                rR2[enq1_sel] <= enq1_rR2;
                rR1_re[enq1_sel] <= enq1_rR1_re;
                rR2_re[enq1_sel] <= enq1_rR2_re;
                ext[enq1_sel] <= enq1_ext;
                npc_op[enq1_sel] <= enq1_npc_op;
                rf_we[enq1_sel] <= enq1_rf_we;
                wR[enq1_sel] <= enq1_wR;
                wd_sel[enq1_sel] <= enq1_wd_sel;
                alu_op[enq1_sel] <= enq1_alu_op;
                alua_sel[enq1_sel] <= enq1_alua_sel;
                alub_sel[enq1_sel] <= enq1_alub_sel;
                ram_we[enq1_sel] <= enq1_ram_we;
                ram_ext_op[enq1_sel] <= enq1_ram_ext_op;
                is_br_jmp[enq1_sel] <= enq1_is_br_jmp;
                is_ld_st[enq1_sel] <= enq1_is_ld_st;
                is_call[enq1_sel] <= enq1_is_call;
                is_ret[enq1_sel] <= enq1_is_ret;
                system_op[enq1_sel] <= enq1_system_op;
                csr_num[enq1_sel] <= enq1_csr_num;
                cacop_op[enq1_sel] <= enq1_cacop_op;
                serializing[enq1_sel] <= enq1_serializing;
                barrier_blocked[enq1_sel] <= barrier_blocks_new ||
                    (enq_fire && enq_serializing && (enq_system_op != 3'd0));
                if (enq1_serializing && (enq1_system_op != 3'd0))
                    barrier_active <= 1'b1;
                ras_ptr[enq1_sel] <= enq1_ras_ptr;
                pred_valid[enq1_sel] <= enq1_pred_valid;
                pred_taken[enq1_sel] <= enq1_pred_taken;
                pred_target[enq1_sel] <= enq1_pred_target;
                pred_index[enq1_sel] <= enq1_pred_index;
                ras_sp_before[enq1_sel] <= enq1_ras_sp_before;
                ras_count_before[enq1_sel] <= enq1_ras_count_before;
                perf_btb_hit[enq1_sel] <= enq1_perf_btb_hit;
            end

            count <= count + enq_fire + enq1_fire -
                     issue_fire - fast_issue_fire;
            next_alloc_seq <= next_alloc_seq + enq_fire + enq1_fire;
        end
    end


endmodule
