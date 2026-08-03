`timescale 1ns / 1ps

`include "defines.vh"

import cpu_types_pkg::*;

module DispatchQueue #(
    parameter RESOURCE_AWARE_PAIRING = 1'b0,
    parameter BRANCH_AT_ROB_HEAD = 1'b0,
    parameter SAME_CYCLE_COMPLETION_BYPASS = 1'b1,
    parameter REGISTERED_SELECT_WAKEUP = 1'b1,
    parameter ROUND_ROBIN_SELECT = 1'b0,
    parameter REGISTERED_ORDER_SELECT = 1'b0,
    parameter REGISTER_ISSUE_CLEAR = 1'b0
) (
    input  wire                  clk,
    input  wire                  rstn,
    input  wire                  flush,
    input  logic                 recover_valid,
    input  logic                 system_flush,
    input  uop_id_t              recover_id,
    input  logic                 barrier_release,
    output logic                 perf_true_source_wait,
    output logic                 perf_source_wait_dep_load,
    output logic                 perf_source_wait_dep_muldiv,
    output logic                 perf_source_wait_dep_alu,
    output logic                 perf_source_wait_dep_branch,
    output logic                 perf_source_wait_store_addr,
    output logic                 perf_source_wait_store_data,
    output logic                 perf_iq_no_ready,
    output logic                 perf_lsu_order,
    output logic                 perf_serializing,

    input  dispatch_uop_t        enq [0:1],
    output wire                  enq_ready [0:1],

    input  completion_t          complete [0:1],
    input  completion_t          system_complete,
    input  commit_t              commit [0:1],

    input  wire                  rob_head_valid,
    input  wire [`ROB_TAG_W-1:0] rob_head_tag,
    input  uop_id_t              rob_head_id,

    output wire                  issue_valid [0:1],
    input  wire                  issue_ready [0:1],
    output issue_uop_t           issue [0:1],

    input  wire                  store_issue_pending_ready,
    input  wire                  store_issue_pending_admit,
    output logic                 store_issue_pending_valid,
    output issue_uop_t           store_issue_pending,
    output logic [1:0]           store_issue_pending_occupancy,
    output wire [3:0]            occupancy
);

    localparam DQ_DEPTH = 8;
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

    reg main_hold_valid;
    reg [2:0] main_hold_sel;
    reg fast_hold_valid;
    reg [2:0] fast_hold_sel;
    reg main_hold_store_grant_q;
    reg fast_hold_store_grant_q;
    reg [2:0] main_rr_ptr;
    reg [2:0] fast_rr_ptr;
    reg main_ownership_transfer_q;
    reg fast_ownership_transfer_q;
    reg [DQ_DEPTH-1:0] older_branch_pending_q;
    reg [DQ_DEPTH-1:0] older_store_pending_q;
    reg older_store_any_q;

    issue_uop_t issue_payload_q [0:1];
    logic issue_payload_valid_q;
    logic fast_payload_valid_q;
    reg issue_pending_valid;
    reg [2:0] issue_pending_sel;
    reg fast_pending_valid;
    reg [2:0] fast_pending_sel;

    typedef struct packed {
        uop_id_t     uop_id;
        logic [31:0] pc;
        logic [3:0]  store_mask;
        uop_id_t     src1_id;
    } store_token_t;

    store_token_t store_token_fifo_q [0:1];
    logic store_token_head_q;
    logic store_token_tail_q;
    logic [1:0] store_token_count_q;
    logic store_select_credit_q;

    reg [2:0] ras_ptr [0:DQ_DEPTH-1];
    reg pred_valid [0:DQ_DEPTH-1];
    reg pred_taken [0:DQ_DEPTH-1];
    reg [31:0] pred_target [0:DQ_DEPTH-1];
    reg [9:0] pred_index [0:DQ_DEPTH-1];
    reg [2:0] ras_sp_before [0:DQ_DEPTH-1];
    reg [3:0] ras_count_before [0:DQ_DEPTH-1];
    reg perf_btb_hit [0:DQ_DEPTH-1];

    reg [3:0] count;
    wire [2:0] issue_sel;
    wire [2:0] fast_issue_sel;
    reg [2:0] enq_sel;
    reg [2:0] enq1_sel;
    wire issue_found;
    wire fast_issue_found;
    reg free_found;
    reg second_free_found;
    reg [DQ_SEQ_W-1:0] next_alloc_seq;
    integer i;
    integer recover_count;
    integer j;
    integer k;
    integer occupancy_i;
    issue_uop_t issue_selected_payload [0:1];

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

    wire wakeup0_valid = complete_valid &&
        !(recover_valid && uop_is_younger(complete_id, recover_id));
    wire uop_id_t wakeup0_id = complete_id;
    wire [31:0] wakeup0_value = complete_value;
    wire wakeup0_rf_we = complete_rf_we;

    wire wakeup1_valid = complete1_valid &&
        !(recover_valid && uop_is_younger(complete1_id, recover_id));
    wire uop_id_t wakeup1_id = complete1_id;
    wire [31:0] wakeup1_value = complete1_value;
    wire wakeup1_rf_we = complete1_rf_we;

    completion_t system_wakeup_q;

    always_ff @(posedge clk or negedge rstn) begin
        if (!rstn)
            system_wakeup_q <= '0;
        else if (system_flush)
            system_wakeup_q <= '0;
        else
            system_wakeup_q <= system_complete;
    end

    wire system_wakeup_valid = system_wakeup_q.valid;
    wire uop_id_t system_wakeup_id = system_wakeup_q.uop_id;
    wire [31:0] system_wakeup_value = system_wakeup_q.value;
    wire system_wakeup_rf_we = system_wakeup_q.reg_write;

    commit_t commit_wakeup_q [0:1];

    always_ff @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            commit_wakeup_q[0] <= '0;
            commit_wakeup_q[1] <= '0;
        end else begin
            commit_wakeup_q[0] <= commit[0];
            commit_wakeup_q[1] <= commit[1];
        end
    end

    wire commit_valid = commit_wakeup_q[0].valid;
    wire uop_id_t commit_id = commit_wakeup_q[0].uop_id;
    wire [31:0] commit_value = commit_wakeup_q[0].value;
    wire commit_rf_we = commit_wakeup_q[0].reg_write;
    wire commit1_valid = commit_wakeup_q[1].valid;
    wire uop_id_t commit1_id = commit_wakeup_q[1].uop_id;
    wire [31:0] commit1_value = commit_wakeup_q[1].value;
    wire commit1_rf_we = commit_wakeup_q[1].reg_write;

    function seq_is_older;
        input [DQ_SEQ_W-1:0] lhs;
        input [DQ_SEQ_W-1:0] rhs;
        reg [DQ_SEQ_W-1:0] delta;
        begin
            delta = lhs - rhs;
            seq_is_older = delta[DQ_SEQ_W-1];
        end
    endfunction

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
        reg valid01;
        reg valid23;
        reg valid45;
        reg valid67;
        reg valid03;
        reg valid47;
        reg [2:0] sel01;
        reg [2:0] sel23;
        reg [2:0] sel45;
        reg [2:0] sel67;
        reg [2:0] sel03;
        reg [2:0] sel47;
        reg [DQ_SEQ_W-1:0] win01;
        reg [DQ_SEQ_W-1:0] win23;
        reg [DQ_SEQ_W-1:0] win45;
        reg [DQ_SEQ_W-1:0] win67;
        reg [DQ_SEQ_W-1:0] win03;
        reg [DQ_SEQ_W-1:0] win47;
        begin
            valid01 = mask[0] | mask[1];
            valid23 = mask[2] | mask[3];
            valid45 = mask[4] | mask[5];
            valid67 = mask[6] | mask[7];

            if (mask[0] && (!mask[1] || seq_is_older(seq0, seq1))) begin
                sel01 = 3'd0;
                win01 = seq0;
            end else begin
                sel01 = 3'd1;
                win01 = seq1;
            end

            if (mask[2] && (!mask[3] || seq_is_older(seq2, seq3))) begin
                sel23 = 3'd2;
                win23 = seq2;
            end else begin
                sel23 = 3'd3;
                win23 = seq3;
            end

            if (mask[4] && (!mask[5] || seq_is_older(seq4, seq5))) begin
                sel45 = 3'd4;
                win45 = seq4;
            end else begin
                sel45 = 3'd5;
                win45 = seq5;
            end

            if (mask[6] && (!mask[7] || seq_is_older(seq6, seq7))) begin
                sel67 = 3'd6;
                win67 = seq6;
            end else begin
                sel67 = 3'd7;
                win67 = seq7;
            end

            valid03 = valid01 | valid23;
            if (valid01 && (!valid23 || seq_is_older(win01, win23))) begin
                sel03 = sel01;
                win03 = win01;
            end else begin
                sel03 = sel23;
                win03 = win23;
            end

            valid47 = valid45 | valid67;
            if (valid45 && (!valid67 || seq_is_older(win45, win67))) begin
                sel47 = sel45;
                win47 = win45;
            end else begin
                sel47 = sel67;
                win47 = win67;
            end

            if (!valid03 && !valid47)
                pick_oldest8 = 4'b0000;
            else if (valid03 && (!valid47 || seq_is_older(win03, win47)))
                pick_oldest8 = {1'b1, sel03};
            else
                pick_oldest8 = {1'b1, sel47};
        end
    endfunction

    function [3:0] pick_first8;
        input [DQ_DEPTH-1:0] mask;
        begin
            if (mask[0])
                pick_first8 = 4'b1000;
            else if (mask[1])
                pick_first8 = 4'b1001;
            else if (mask[2])
                pick_first8 = 4'b1010;
            else if (mask[3])
                pick_first8 = 4'b1011;
            else if (mask[4])
                pick_first8 = 4'b1100;
            else if (mask[5])
                pick_first8 = 4'b1101;
            else if (mask[6])
                pick_first8 = 4'b1110;
            else if (mask[7])
                pick_first8 = 4'b1111;
            else
                pick_first8 = 4'b0000;
        end
    endfunction

    function [3:0] pick_round_robin8;
        input [DQ_DEPTH-1:0] mask;
        input [2:0] start;
        reg [DQ_DEPTH-1:0] rotated;
        reg [3:0] first;
        reg [2:0] offset;
        begin
            case (start)
                3'd0:
                    rotated = {
                        mask[7], mask[6], mask[5], mask[4],
                        mask[3], mask[2], mask[1], mask[0]
                    };
                3'd1:
                    rotated = {
                        mask[0], mask[7], mask[6], mask[5],
                        mask[4], mask[3], mask[2], mask[1]
                    };
                3'd2:
                    rotated = {
                        mask[1], mask[0], mask[7], mask[6],
                        mask[5], mask[4], mask[3], mask[2]
                    };
                3'd3:
                    rotated = {
                        mask[2], mask[1], mask[0], mask[7],
                        mask[6], mask[5], mask[4], mask[3]
                    };
                3'd4:
                    rotated = {
                        mask[3], mask[2], mask[1], mask[0],
                        mask[7], mask[6], mask[5], mask[4]
                    };
                3'd5:
                    rotated = {
                        mask[4], mask[3], mask[2], mask[1],
                        mask[0], mask[7], mask[6], mask[5]
                    };
                3'd6:
                    rotated = {
                        mask[5], mask[4], mask[3], mask[2],
                        mask[1], mask[0], mask[7], mask[6]
                    };
                default:
                    rotated = {
                        mask[6], mask[5], mask[4], mask[3],
                        mask[2], mask[1], mask[0], mask[7]
                    };
            endcase

            first = pick_first8(rotated);
            offset = first[2:0];

            pick_round_robin8 =
                first[3] ? {1'b1, start + offset} : 4'b0000;
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
    wire [DQ_DEPTH-1:0] system_src0_match;
    wire [DQ_DEPTH-1:0] system_src1_match;
    wire [DQ_DEPTH-1:0] src0_ready_eff;
    wire [DQ_DEPTH-1:0] src1_ready_eff;
    wire [DQ_DEPTH-1:0] src0_select_ready;
    wire [DQ_DEPTH-1:0] src1_select_ready;
    wire [31:0] src0_value_eff [0:DQ_DEPTH-1];
    wire [31:0] src1_value_eff [0:DQ_DEPTH-1];
    wire [DQ_DEPTH-1:0] slot_ready;
    wire [DQ_DEPTH-1:0] slot_restricted;
    wire [DQ_DEPTH-1:0] slot_fast_eligible;
    wire [DQ_DEPTH-1:0] slot_lane0_only;
    wire [DQ_DEPTH-1:0] serializing_mask;
    logic [DQ_DEPTH-1:0] older_branch_pending;
    logic [DQ_DEPTH-1:0] older_store_pending;
    wire [DQ_DEPTH-1:0] live_branch_mask;
    wire [DQ_DEPTH-1:0] live_store_mask;

    wire [DQ_DEPTH-1:0] branch_pending_for_select =
        REGISTERED_ORDER_SELECT
            ? older_branch_pending_q
            : older_branch_pending;

    wire [DQ_DEPTH-1:0] store_pending_for_select =
        REGISTERED_ORDER_SELECT
            ? {DQ_DEPTH{older_store_any_q}}
            : older_store_pending;

    wire [2:0] store_reserved_count =
        {1'b0, store_token_count_q} +
        main_hold_store_grant_q +
        fast_hold_store_grant_q;

    wire store_reservation_available = store_select_credit_q;

    wire [DQ_DEPTH-1:0] store_select_block =
        live_store_mask &
        {DQ_DEPTH{!store_reservation_available}};

    wire [3:0] next_barrier_pick;
    wire next_barrier_found;
    wire [DQ_SEQ_W-1:0] next_barrier_seq;
    wire [DQ_DEPTH-1:0] next_barrier_blocks;
    wire barrier_blocks_new;

    wire [DQ_DEPTH-1:0] fast_hold_onehot =
        fast_hold_valid
            ? ({{(DQ_DEPTH-1){1'b0}}, 1'b1} << fast_hold_sel)
            : {DQ_DEPTH{1'b0}};

    wire [DQ_DEPTH-1:0] main_hold_onehot =
        main_hold_valid
            ? ({{(DQ_DEPTH-1){1'b0}}, 1'b1} << main_hold_sel)
            : {DQ_DEPTH{1'b0}};

    wire [DQ_DEPTH-1:0] issue_pending_onehot =
        (REGISTER_ISSUE_CLEAR && issue_pending_valid)
            ? ({{(DQ_DEPTH-1){1'b0}}, 1'b1} << issue_pending_sel)
            : {DQ_DEPTH{1'b0}};

    wire [DQ_DEPTH-1:0] fast_pending_onehot =
        (REGISTER_ISSUE_CLEAR && fast_pending_valid)
            ? ({{(DQ_DEPTH-1){1'b0}}, 1'b1} << fast_pending_sel)
            : {DQ_DEPTH{1'b0}};

    wire main_payload_space;
    wire fast_payload_space;
    wire main_payload_capture;
    wire fast_payload_capture;
    wire main_refill_valid;
    wire fast_refill_valid;
    wire main_select_capture;
    wire fast_select_capture;
    wire [3:0] main_refill_pick;
    wire [3:0] fast_refill_pick;

    typedef struct packed {
        logic valid;
        logic [`UOP_EPOCH_W-1:0] epoch;
        producer_type_e ptype;
    } producer_entry_t;

    producer_entry_t producer_table [0:(1<<`ROB_TAG_W)-1];

    integer branch_q;
    integer branch_old;

    always @(*) begin
        older_branch_pending = {DQ_DEPTH{1'b0}};

        for (
            branch_q = 0;
            branch_q < DQ_DEPTH;
            branch_q = branch_q + 1
        ) begin
            for (
                branch_old = 0;
                branch_old < DQ_DEPTH;
                branch_old = branch_old + 1
            ) begin
                if (
                    valid[branch_old] &&
                    is_br_jmp[branch_old] &&
                    seq_is_older(
                        alloc_seq[branch_old],
                        alloc_seq[branch_q]
                    )
                )
                    older_branch_pending[branch_q] = 1'b1;
            end
        end
    end

`ifndef SYNTHESIS
    wire [3:0] perf_oldest_valid = pick_oldest8(
        valid,
        alloc_seq[0],
        alloc_seq[1],
        alloc_seq[2],
        alloc_seq[3],
        alloc_seq[4],
        alloc_seq[5],
        alloc_seq[6],
        alloc_seq[7]
    );

    wire [2:0] perf_oldest_idx = perf_oldest_valid[2:0];
    wire perf_oldest_is_valid = perf_oldest_valid[3];
`else
    assign perf_true_source_wait = 1'b0;
    assign perf_lsu_order = 1'b0;
    assign perf_serializing = 1'b0;
`endif

    integer store_q;
    integer store_old;

    always @(*) begin
        older_store_pending = {DQ_DEPTH{1'b0}};

        for (
            store_q = 0;
            store_q < DQ_DEPTH;
            store_q = store_q + 1
        ) begin
            for (
                store_old = 0;
                store_old < DQ_DEPTH;
                store_old = store_old + 1
            ) begin
                if (
                    valid[store_old] &&
                    is_ld_st[store_old] &&
                    (ram_we[store_old] != `RAM_WE_N) &&
                    valid[store_q] &&
                    is_ld_st[store_q] &&
                    (ram_we[store_q] == `RAM_WE_N) &&
                    seq_is_older(
                        alloc_seq[store_old],
                        alloc_seq[store_q]
                    )
                )
                    older_store_pending[store_q] = 1'b1;
            end
        end
    end

    genvar q;
    generate
        for (q = 0; q < DQ_DEPTH; q = q + 1) begin : GEN_ISSUE_STATE
            assign complete0_src0_match[q] =
                wakeup0_valid &&
                wakeup0_rf_we &&
                valid[q] &&
                rR1_re[q] &&
                (rR1[q] != 5'h0) &&
                !src0_ready[q] &&
                uop_id_equal(wakeup0_id, src0_id[q]);

            assign complete0_src1_match[q] =
                wakeup0_valid &&
                wakeup0_rf_we &&
                valid[q] &&
                rR2_re[q] &&
                (rR2[q] != 5'h0) &&
                !src1_ready[q] &&
                uop_id_equal(wakeup0_id, src1_id[q]);

            assign complete1_src0_match[q] =
                wakeup1_valid &&
                wakeup1_rf_we &&
                valid[q] &&
                rR1_re[q] &&
                (rR1[q] != 5'h0) &&
                !src0_ready[q] &&
                uop_id_equal(wakeup1_id, src0_id[q]);

            assign complete1_src1_match[q] =
                wakeup1_valid &&
                wakeup1_rf_we &&
                valid[q] &&
                rR2_re[q] &&
                (rR2[q] != 5'h0) &&
                !src1_ready[q] &&
                uop_id_equal(wakeup1_id, src1_id[q]);

            assign system_src0_match[q] =
                system_wakeup_valid &&
                system_wakeup_rf_we &&
                valid[q] &&
                rR1_re[q] &&
                (rR1[q] != 5'h0) &&
                !src0_ready[q] &&
                uop_id_equal(system_wakeup_id, src0_id[q]);

            assign system_src1_match[q] =
                system_wakeup_valid &&
                system_wakeup_rf_we &&
                valid[q] &&
                rR2_re[q] &&
                (rR2[q] != 5'h0) &&
                !src1_ready[q] &&
                uop_id_equal(system_wakeup_id, src1_id[q]);

            assign wake0_src0_vec[q] = complete0_src0_match[q];
            assign wake0_src1_vec[q] = complete0_src1_match[q];
            assign wake1_src0_vec[q] = complete1_src0_match[q];
            assign wake1_src1_vec[q] = complete1_src1_match[q];

            assign wake2_src0_vec[q] =
                commit_valid &&
                commit_rf_we &&
                valid[q] &&
                rR1_re[q] &&
                (rR1[q] != 5'h0) &&
                !src0_ready[q] &&
                uop_id_equal(commit_id, src0_id[q]);

            assign wake2_src1_vec[q] =
                commit_valid &&
                commit_rf_we &&
                valid[q] &&
                rR2_re[q] &&
                (rR2[q] != 5'h0) &&
                !src1_ready[q] &&
                uop_id_equal(commit_id, src1_id[q]);

            assign wake3_src0_vec[q] =
                commit1_valid &&
                commit1_rf_we &&
                valid[q] &&
                rR1_re[q] &&
                (rR1[q] != 5'h0) &&
                !src0_ready[q] &&
                uop_id_equal(commit1_id, src0_id[q]);

            assign wake3_src1_vec[q] =
                commit1_valid &&
                commit1_rf_we &&
                valid[q] &&
                rR2_re[q] &&
                (rR2[q] != 5'h0) &&
                !src1_ready[q] &&
                uop_id_equal(commit1_id, src1_id[q]);

            assign wake_src0_vec[q] =
                wake0_src0_vec[q] ||
                wake1_src0_vec[q] ||
                system_src0_match[q] ||
                wake2_src0_vec[q] ||
                wake3_src0_vec[q];

            assign wake_src1_vec[q] =
                wake0_src1_vec[q] ||
                wake1_src1_vec[q] ||
                system_src1_match[q] ||
                wake2_src1_vec[q] ||
                wake3_src1_vec[q];

            assign src0_ready_eff[q] =
                src0_ready[q] ||
                (
                    SAME_CYCLE_COMPLETION_BYPASS &&
                    (
                        complete0_src0_match[q] ||
                        complete1_src0_match[q]
                    )
                ) ||
                wake0_src0_vec[q] ||
                wake1_src0_vec[q] ||
                wake2_src0_vec[q] ||
                wake3_src0_vec[q];

            assign src1_ready_eff[q] =
                src1_ready[q] ||
                (
                    SAME_CYCLE_COMPLETION_BYPASS &&
                    (
                        complete0_src1_match[q] ||
                        complete1_src1_match[q]
                    )
                ) ||
                wake0_src1_vec[q] ||
                wake1_src1_vec[q] ||
                wake2_src1_vec[q] ||
                wake3_src1_vec[q];

            assign src0_value_eff[q] =
                (
                    SAME_CYCLE_COMPLETION_BYPASS &&
                    complete0_src0_match[q]
                ) ? complete_value :
                (
                    SAME_CYCLE_COMPLETION_BYPASS &&
                    complete1_src0_match[q]
                ) ? complete1_value :
                wake0_src0_vec[q] ? wakeup0_value :
                wake1_src0_vec[q] ? wakeup1_value :
                wake2_src0_vec[q] ? commit_value :
                wake3_src0_vec[q] ? commit1_value :
                rD1[q];

            assign src1_value_eff[q] =
                (
                    SAME_CYCLE_COMPLETION_BYPASS &&
                    complete0_src1_match[q]
                ) ? complete_value :
                (
                    SAME_CYCLE_COMPLETION_BYPASS &&
                    complete1_src1_match[q]
                ) ? complete1_value :
                wake0_src1_vec[q] ? wakeup0_value :
                wake1_src1_vec[q] ? wakeup1_value :
                wake2_src1_vec[q] ? commit_value :
                wake3_src1_vec[q] ? commit1_value :
                rD2[q];

            assign src0_select_ready[q] = src0_ready[q];
            assign src1_select_ready[q] = src1_ready[q];

            assign slot_ready[q] =
                src0_select_ready[q] &&
                (
                    src1_select_ready[q] ||
                    (
                        is_ld_st[q] &&
                        (ram_we[q] != `RAM_WE_N)
                    )
                ) &&
                (
                    !(
                        is_ld_st[q] &&
                        (ram_we[q] == `RAM_WE_N)
                    ) ||
                    !store_pending_for_select[q]
                ) &&
                (
                    !is_br_jmp[q] ||
                    !branch_pending_for_select[q]
                ) &&
                (
                    !BRANCH_AT_ROB_HEAD ||
                    !is_br_jmp[q] ||
                    (
                        rob_head_valid &&
                        uop_id_equal(uop_id[q], rob_head_id)
                    )
                );

            assign slot_restricted[q] =
                is_br_jmp[q] ||
                is_ld_st[q] ||
                is_call[q] ||
                is_ret[q] ||
                pred_taken[q] ||
                (system_op[q] != 3'd0);

            assign slot_fast_eligible[q] =
                (
                    is_ld_st[q] &&
                    (
                        (ram_we[q] == `RAM_WE_N) ||
                        src1_select_ready[q]
                    )
                ) ||
                (
                    !slot_restricted[q] &&
                    (wd_sel[q] == `WD_ALU)
                );

            assign slot_lane0_only[q] =
                slot_restricted[q] &&
                !is_ld_st[q] &&
                (system_op[q] == 3'd0);

            assign live_branch_mask[q] =
                valid[q] &&
                is_br_jmp[q];

            assign live_store_mask[q] =
                valid[q] &&
                is_ld_st[q] &&
                (ram_we[q] != `RAM_WE_N);

            assign serializing_mask[q] =
                valid[q] &&
                serializing[q];

            assign next_barrier_blocks[q] =
                next_barrier_found &&
                seq_is_older(
                    next_barrier_seq,
                    alloc_seq[q]
                );
        end
    endgenerate

    wire issue_fire;
    wire fast_issue_fire;
    wire enq_fire;
    wire enq1_fire;

    wire [DQ_DEPTH-1:0] issue_clear_vec =
        main_payload_capture
            ? ({{(DQ_DEPTH-1){1'b0}}, 1'b1} << main_hold_sel)
            : {DQ_DEPTH{1'b0}};

    wire [DQ_DEPTH-1:0] fast_issue_clear_vec =
        fast_payload_capture
            ? ({{(DQ_DEPTH-1){1'b0}}, 1'b1} << fast_hold_sel)
            : {DQ_DEPTH{1'b0}};

    wire [DQ_DEPTH-1:0] state_clear_vec =
        issue_clear_vec |
        fast_issue_clear_vec;

    reg barrier_release_reg;

    wire has_serializing_op = |serializing_mask;

    assign next_barrier_pick = pick_oldest8(
        serializing_mask,
        alloc_seq[0],
        alloc_seq[1],
        alloc_seq[2],
        alloc_seq[3],
        alloc_seq[4],
        alloc_seq[5],
        alloc_seq[6],
        alloc_seq[7]
    );

    assign next_barrier_found =
        has_serializing_op &&
        next_barrier_pick[3];

    assign next_barrier_seq =
        alloc_seq[next_barrier_pick[2:0]];

    assign barrier_blocks_new = barrier_active;

    wire [DQ_DEPTH-1:0] main_candidate =
        valid &
        slot_ready &
        ~barrier_blocked &
        ~store_select_block &
        ~fast_hold_onehot &
        ~issue_pending_onehot &
        ~fast_pending_onehot;

    wire [3:0] oldest_main_pick = pick_oldest8(
        main_candidate,
        alloc_seq[0],
        alloc_seq[1],
        alloc_seq[2],
        alloc_seq[3],
        alloc_seq[4],
        alloc_seq[5],
        alloc_seq[6],
        alloc_seq[7]
    );

    wire [DQ_DEPTH-1:0] lane0_candidate =
        main_candidate &
        slot_lane0_only &
        ~main_hold_onehot;

    wire [3:0] lane0_pair_pick = pick_oldest8(
        lane0_candidate,
        alloc_seq[0],
        alloc_seq[1],
        alloc_seq[2],
        alloc_seq[3],
        alloc_seq[4],
        alloc_seq[5],
        alloc_seq[6],
        alloc_seq[7]
    );

    wire [3:0] rr_main_pick =
        pick_round_robin8(
            main_candidate,
            main_rr_ptr
        );

    wire use_resource_pair =
        RESOURCE_AWARE_PAIRING &&
        !ROUND_ROBIN_SELECT &&
        !main_hold_valid &&
        oldest_main_pick[3] &&
        slot_fast_eligible[oldest_main_pick[2:0]] &&
        lane0_pair_pick[3];

    wire [3:0] main_pick =
        ROUND_ROBIN_SELECT
            ? rr_main_pick
            : (
                use_resource_pair
                    ? lane0_pair_pick
                    : oldest_main_pick
            );

    wire [DQ_DEPTH-1:0] main_refill_candidate =
        main_candidate &
        ~main_hold_onehot;

    assign main_refill_pick =
        ROUND_ROBIN_SELECT
            ? pick_round_robin8(
                main_refill_candidate,
                main_rr_ptr
            )
            : pick_oldest8(
                main_refill_candidate,
                alloc_seq[0],
                alloc_seq[1],
                alloc_seq[2],
                alloc_seq[3],
                alloc_seq[4],
                alloc_seq[5],
                alloc_seq[6],
                alloc_seq[7]
            );

    assign issue_found =
        main_hold_valid
            ? (
                valid[main_hold_sel] &&
                !issue_pending_onehot[main_hold_sel] &&
                !fast_pending_onehot[main_hold_sel]
            )
            : main_pick[3];

    assign issue_sel =
        main_hold_valid
            ? main_hold_sel
            : main_pick[2:0];

    wire [DQ_DEPTH-1:0] fast_candidate =
        valid &
        slot_ready &
        ~barrier_blocked &
        slot_fast_eligible &
        ~store_select_block &
        ~main_hold_onehot &
        ~issue_pending_onehot &
        ~fast_pending_onehot;

    wire [3:0] oldest_fast_pick = pick_oldest8(
        fast_candidate,
        alloc_seq[0],
        alloc_seq[1],
        alloc_seq[2],
        alloc_seq[3],
        alloc_seq[4],
        alloc_seq[5],
        alloc_seq[6],
        alloc_seq[7]
    );

    wire [3:0] rr_fast_pick =
        pick_round_robin8(
            fast_candidate,
            fast_rr_ptr
        );

    wire [3:0] fast_pick =
        ROUND_ROBIN_SELECT
            ? rr_fast_pick
            : oldest_fast_pick;

    wire registered_select_collision =
        main_hold_valid &&
        fast_hold_valid &&
        (main_hold_sel == fast_hold_sel);

    assign fast_issue_found =
        fast_hold_valid
            ? (
                valid[fast_hold_sel] &&
                !issue_pending_onehot[fast_hold_sel] &&
                !fast_pending_onehot[fast_hold_sel] &&
                !registered_select_collision
            )
            : fast_pick[3];

    assign fast_issue_sel =
        fast_hold_valid
            ? fast_hold_sel
            : fast_pick[2:0];

    always @(*) begin
        enq_sel = 3'h0;
        enq1_sel = 3'h0;
        free_found = 1'b0;
        second_free_found = 1'b0;

        for (k = 0; k < DQ_DEPTH; k = k + 1) begin
            if (!valid[k]) begin
                if (!free_found) begin
                    free_found = 1'b1;
                    enq_sel = k[2:0];
                end else if (
                    !second_free_found &&
                    (k[2:0] != enq_sel)
                ) begin
                    second_free_found = 1'b1;
                    enq1_sel = k[2:0];
                end
            end
        end
    end

    assign issue_fire =
        issue_valid[0] &&
        issue_ready[0];

    assign fast_issue_fire =
        issue_valid[1] &&
        issue_ready[1];

    assign enq_fire =
        enq_valid &&
        enq_ready[0];

    assign enq1_fire =
        enq1_valid &&
        enq_ready[1];

    wire main_hold_is_store =
        main_hold_valid &&
        valid[main_hold_sel] &&
        is_ld_st[main_hold_sel] &&
        (ram_we[main_hold_sel] != `RAM_WE_N);

    wire fast_hold_is_store =
        fast_hold_valid &&
        valid[fast_hold_sel] &&
        is_ld_st[fast_hold_sel] &&
        (ram_we[fast_hold_sel] != `RAM_WE_N);

    wire store_lane1_is_older =
        main_hold_is_store &&
        fast_hold_is_store &&
        uop_is_younger(
            uop_id[main_hold_sel],
            uop_id[fast_hold_sel]
        );

    wire main_store_needs_grant =
        main_hold_is_store &&
        !main_hold_store_grant_q;

    wire fast_store_needs_grant =
        fast_hold_is_store &&
        !fast_hold_store_grant_q;

    wire main_new_store_candidate =
        !main_hold_valid &&
        main_pick[3] &&
        is_ld_st[main_pick[2:0]] &&
        (ram_we[main_pick[2:0]] != `RAM_WE_N);

    wire fast_new_store_candidate =
        !fast_hold_valid &&
        fast_issue_found &&
        is_ld_st[fast_pick[2:0]] &&
        (ram_we[fast_pick[2:0]] != `RAM_WE_N);

    wire new_store_lane1_is_older =
        main_new_store_candidate &&
        fast_new_store_candidate &&
        uop_is_younger(
            uop_id[main_pick[2:0]],
            uop_id[fast_pick[2:0]]
        );

    wire new_store_grant_available =
        store_reservation_available &&
        !main_store_needs_grant &&
        !fast_store_needs_grant;

    wire main_new_store_grant =
        main_new_store_candidate &&
        new_store_grant_available &&
        (
            !fast_new_store_candidate ||
            !new_store_lane1_is_older
        );

    wire fast_new_store_grant =
        fast_new_store_candidate &&
        new_store_grant_available &&
        (
            !main_new_store_candidate ||
            new_store_lane1_is_older
        );

    assign main_select_capture =
        !flush &&
        !system_flush &&
        !main_hold_valid &&
        main_pick[3] &&
        (
            !main_new_store_candidate ||
            main_new_store_grant
        );

    assign fast_select_capture =
        !flush &&
        !system_flush &&
        !fast_hold_valid &&
        fast_issue_found &&
        (
            !fast_new_store_candidate ||
            fast_new_store_grant
        );

    wire main_store_grant_set =
        store_reservation_available &&
        main_store_needs_grant &&
        (
            !fast_store_needs_grant ||
            !store_lane1_is_older
        );

    wire fast_store_grant_set =
        store_reservation_available &&
        fast_store_needs_grant &&
        (
            !main_store_needs_grant ||
            store_lane1_is_older
        );

    wire main_store_payload_allow =
        main_hold_store_grant_q &&
        (
            !fast_hold_store_grant_q ||
            !fast_hold_is_store ||
            !store_lane1_is_older
        );

    wire fast_store_payload_allow =
        fast_hold_store_grant_q &&
        (
            !main_hold_store_grant_q ||
            !main_hold_is_store ||
            store_lane1_is_older
        );

    wire main_hold_store_blocked =
        main_hold_is_store &&
        !main_hold_store_grant_q &&
        !main_store_grant_set &&
        !store_reservation_available;

    wire fast_hold_store_blocked =
        fast_hold_is_store &&
        !fast_hold_store_grant_q &&
        !fast_store_grant_set &&
        !store_reservation_available;

    assign main_payload_space =
        !issue_payload_valid_q ||
        issue_fire;

    assign fast_payload_space =
        !fast_payload_valid_q ||
        fast_issue_fire;

    assign main_payload_capture =
        !flush &&
        !system_flush &&
        main_hold_valid &&
        issue_found &&
        main_payload_space &&
        (
            !main_hold_is_store ||
            main_store_payload_allow
        );

    assign fast_payload_capture =
        !flush &&
        !system_flush &&
        fast_hold_valid &&
        fast_issue_found &&
        fast_payload_space &&
        (
            !fast_hold_is_store ||
            fast_store_payload_allow
        );

    wire main_refill_selected_store =
        main_refill_pick[3] &&
        is_ld_st[main_refill_pick[2:0]] &&
        (ram_we[main_refill_pick[2:0]] != `RAM_WE_N);

    wire fast_refill_selected_store =
        fast_refill_pick[3] &&
        is_ld_st[fast_refill_pick[2:0]] &&
        (ram_we[fast_refill_pick[2:0]] != `RAM_WE_N);

    assign main_refill_valid =
        main_payload_capture &&
        !main_hold_is_store &&
        !main_refill_selected_store &&
        main_refill_pick[3];

    assign fast_refill_valid =
        fast_payload_capture &&
        !fast_hold_is_store &&
        !fast_refill_selected_store &&
        fast_refill_pick[3];

    wire issue_store_fire =
        main_payload_capture &&
        main_hold_is_store;

    wire fast_store_fire =
        fast_payload_capture &&
        fast_hold_is_store;

    wire store_token_push =
        issue_store_fire ||
        fast_store_fire;

    wire store_token_pop =
        (store_token_count_q != 2'd0) &&
        store_issue_pending_ready;

    wire store_token_push_accept =
        store_token_push;

    store_token_t store_token_push_entry;
    integer token_recover_i;
    integer token_recover_count;
    store_token_t token_recover_entry0;
    store_token_t token_recover_entry1;

    always @(*) begin
        store_token_push_entry = '0;

        if (issue_store_fire) begin
            store_token_push_entry.uop_id =
                uop_id[main_hold_sel];

            store_token_push_entry.pc =
                pc[main_hold_sel];

            store_token_push_entry.store_mask =
                ram_we[main_hold_sel];

            store_token_push_entry.src1_id =
                src1_id[main_hold_sel];
        end else if (fast_store_fire) begin
            store_token_push_entry.uop_id =
                uop_id[fast_hold_sel];

            store_token_push_entry.pc =
                pc[fast_hold_sel];

            store_token_push_entry.store_mask =
                ram_we[fast_hold_sel];

            store_token_push_entry.src1_id =
                src1_id[fast_hold_sel];
        end

        token_recover_count = 0;
        token_recover_entry0 = '0;
        token_recover_entry1 = '0;

        for (
            token_recover_i = 0;
            token_recover_i < 2;
            token_recover_i = token_recover_i + 1
        ) begin
            if (
                (token_recover_i < store_token_count_q) &&
                !uop_is_younger(
                    store_token_fifo_q[
                        store_token_head_q ^
                        token_recover_i[0]
                    ].uop_id,
                    recover_id
                )
            ) begin
                if (token_recover_count == 0)
                    token_recover_entry0 =
                        store_token_fifo_q[
                            store_token_head_q ^
                            token_recover_i[0]
                        ];
                else if (token_recover_count == 1)
                    token_recover_entry1 =
                        store_token_fifo_q[
                            store_token_head_q ^
                            token_recover_i[0]
                        ];

                token_recover_count =
                    token_recover_count + 1;
            end
        end
    end

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            store_token_head_q <= 1'b0;
            store_token_tail_q <= 1'b0;
            store_token_count_q <= 2'd0;
            store_token_fifo_q[0] <= '0;
            store_token_fifo_q[1] <= '0;
        end else if (
            system_flush ||
            (flush && !recover_valid)
        ) begin
            store_token_head_q <= 1'b0;
            store_token_tail_q <= 1'b0;
            store_token_count_q <= 2'd0;
        end else if (flush) begin
            store_token_head_q <= 1'b0;
            store_token_tail_q <= token_recover_count[0];
            store_token_count_q <= token_recover_count[1:0];
            store_token_fifo_q[0] <= token_recover_entry0;
            store_token_fifo_q[1] <= token_recover_entry1;
        end else begin
            case ({
                store_token_push_accept,
                store_token_pop
            })
                2'b10: begin
                    store_token_fifo_q[store_token_tail_q] <=
                        store_token_push_entry;

                    store_token_tail_q <=
                        ~store_token_tail_q;

                    store_token_count_q <=
                        store_token_count_q + 2'd1;
                end

                2'b01: begin
                    store_token_head_q <=
                        ~store_token_head_q;

                    store_token_count_q <=
                        store_token_count_q - 2'd1;
                end

                2'b11: begin
                    store_token_fifo_q[store_token_tail_q] <=
                        store_token_push_entry;

                    store_token_tail_q <=
                        ~store_token_tail_q;

                    store_token_head_q <=
                        ~store_token_head_q;
                end

                default: begin
                end
            endcase
        end
    end

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            store_select_credit_q <= 1'b0;
        end else if (flush || system_flush) begin
            store_select_credit_q <= 1'b0;
        end else begin
            store_select_credit_q <=
                store_issue_pending_admit &&
                (store_reserved_count == 3'd0);
        end
    end

    wire enq_has_older_store =
        |live_store_mask;

    wire enq_has_older_branch =
        |live_branch_mask;

    wire enq_is_load =
        enq_is_ld_st &&
        (enq_ram_we == `RAM_WE_N);

    wire enq1_is_load =
        enq1_is_ld_st &&
        (enq1_ram_we == `RAM_WE_N);

    wire enq_is_store =
        enq_is_ld_st &&
        (enq_ram_we != `RAM_WE_N);

    wire enq1_is_store =
        enq1_is_ld_st &&
        (enq1_ram_we != `RAM_WE_N);

    wire enq_order_store_blocked =
        enq_is_load &&
        enq_has_older_store;

    wire enq1_order_store_blocked =
        enq1_is_load &&
        (
            enq_has_older_store ||
            (enq_fire && enq_is_store)
        );

    wire enq_order_branch_blocked =
        enq_is_br_jmp &&
        enq_has_older_branch;

    wire enq1_order_branch_blocked =
        enq1_is_br_jmp &&
        (
            enq_has_older_branch ||
            (enq_fire && enq_is_br_jmp)
        );

    reg [DQ_DEPTH-1:0] older_store_pending_refresh;
    reg [DQ_DEPTH-1:0] store_order_next_valid;
    reg [DQ_DEPTH-1:0] store_order_next_is_load;
    reg [DQ_DEPTH-1:0] store_order_next_is_store;
    reg [DQ_SEQ_W-1:0] store_order_next_seq [0:DQ_DEPTH-1];
    wire older_store_any_refresh =
        |older_store_pending_refresh;

    integer store_next_q;
    integer store_next_old;

    always @(*) begin
        older_store_pending_refresh =
            {DQ_DEPTH{1'b0}};

        store_order_next_valid =
            valid;

        store_order_next_is_load =
            {DQ_DEPTH{1'b0}};

        store_order_next_is_store =
            {DQ_DEPTH{1'b0}};

        for (
            store_next_q = 0;
            store_next_q < DQ_DEPTH;
            store_next_q = store_next_q + 1
        ) begin
            store_order_next_seq[store_next_q] =
                alloc_seq[store_next_q];

            store_order_next_is_load[store_next_q] =
                valid[store_next_q] &&
                is_ld_st[store_next_q] &&
                (ram_we[store_next_q] == `RAM_WE_N);

            store_order_next_is_store[store_next_q] =
                valid[store_next_q] &&
                is_ld_st[store_next_q] &&
                (ram_we[store_next_q] != `RAM_WE_N);
        end

        if (flush || system_flush) begin
            store_order_next_valid =
                {DQ_DEPTH{1'b0}};

            store_order_next_is_load =
                {DQ_DEPTH{1'b0}};

            store_order_next_is_store =
                {DQ_DEPTH{1'b0}};

            if (
                flush &&
                recover_valid &&
                !system_flush
            ) begin
                for (
                    store_next_q = 0;
                    store_next_q < DQ_DEPTH;
                    store_next_q = store_next_q + 1
                ) begin
                    if (
                        valid[store_next_q] &&
                        !uop_is_younger(
                            uop_id[store_next_q],
                            recover_id
                        )
                    ) begin
                        store_order_next_valid[store_next_q] =
                            1'b1;

                        store_order_next_is_load[store_next_q] =
                            is_ld_st[store_next_q] &&
                            (
                                ram_we[store_next_q] ==
                                `RAM_WE_N
                            );

                        store_order_next_is_store[store_next_q] =
                            is_ld_st[store_next_q] &&
                            (
                                ram_we[store_next_q] !=
                                `RAM_WE_N
                            );
                    end
                end
            end
        end else begin
            if (enq_fire) begin
                store_order_next_valid[enq_sel] =
                    1'b1;

                store_order_next_is_load[enq_sel] =
                    enq_is_load;

                store_order_next_is_store[enq_sel] =
                    enq_is_store;

                store_order_next_seq[enq_sel] =
                    next_alloc_seq;
            end

            if (enq1_fire) begin
                store_order_next_valid[enq1_sel] =
                    1'b1;

                store_order_next_is_load[enq1_sel] =
                    enq1_is_load;

                store_order_next_is_store[enq1_sel] =
                    enq1_is_store;

                store_order_next_seq[enq1_sel] =
                    next_alloc_seq + enq_fire;
            end
        end

        for (
            store_next_q = 0;
            store_next_q < DQ_DEPTH;
            store_next_q = store_next_q + 1
        ) begin
            for (
                store_next_old = 0;
                store_next_old < DQ_DEPTH;
                store_next_old = store_next_old + 1
            ) begin
                if (
                    store_order_next_valid[store_next_q] &&
                    store_order_next_is_load[store_next_q] &&
                    store_order_next_valid[store_next_old] &&
                    store_order_next_is_store[store_next_old] &&
                    seq_is_older(
                        store_order_next_seq[store_next_old],
                        store_order_next_seq[store_next_q]
                    )
                )
                    older_store_pending_refresh[store_next_q] =
                        1'b1;
            end
        end

        if (!flush && !system_flush) begin
            if (enq_fire)
                older_store_pending_refresh[enq_sel] =
                    enq_order_store_blocked;

            if (enq1_fire)
                older_store_pending_refresh[enq1_sel] =
                    enq1_order_store_blocked;
        end
    end

    assign enq_ready[0] =
        free_found;

    assign enq_ready[1] =
        free_found &&
        second_free_found;

    assign issue_valid[0] =
        issue_payload_valid_q &&
        !flush &&
        !system_flush;

    assign issue_valid[1] =
        fast_payload_valid_q &&
        !flush &&
        !system_flush;

    always @(*) begin
        issue_selected_payload[0] = '0;
        issue_selected_payload[0].uop_id =
            uop_id[issue_sel];
        issue_selected_payload[0].pc =
            pc[issue_sel];
        issue_selected_payload[0].src0_value =
            rD1[issue_sel];

        issue_selected_payload[0].src1_value =
            main_hold_is_store
                ? src1_value_eff[issue_sel]
                : rD2[issue_sel];

        issue_selected_payload[0].src1_ready =
            main_hold_is_store
                ? src1_ready_eff[issue_sel]
                : src1_ready[issue_sel];

        issue_selected_payload[0].src1_id =
            src1_id[issue_sel];

        issue_selected_payload[0].arch_rs1 =
            rR1[issue_sel];

        issue_selected_payload[0].arch_rs2 =
            rR2[issue_sel];

        issue_selected_payload[0].src0_used =
            rR1_re[issue_sel];

        issue_selected_payload[0].src1_used =
            rR2_re[issue_sel];

        issue_selected_payload[0].imm =
            ext[issue_sel];

        issue_selected_payload[0].npc_op =
            npc_op[issue_sel];

        issue_selected_payload[0].reg_write =
            rf_we[issue_sel];

        issue_selected_payload[0].arch_rd =
            wR[issue_sel];

        issue_selected_payload[0].result_sel =
            wd_sel[issue_sel];

        issue_selected_payload[0].alu_op =
            alu_op[issue_sel];

        issue_selected_payload[0].src_a_sel =
            alua_sel[issue_sel];

        issue_selected_payload[0].src_b_sel =
            alub_sel[issue_sel];

        issue_selected_payload[0].store_mask =
            ram_we[issue_sel];

        issue_selected_payload[0].load_ext_op =
            ram_ext_op[issue_sel];

        issue_selected_payload[0].is_br_jmp =
            is_br_jmp[issue_sel];

        issue_selected_payload[0].is_ld_st =
            is_ld_st[issue_sel];

        issue_selected_payload[0].is_call =
            is_call[issue_sel];

        issue_selected_payload[0].is_ret =
            is_ret[issue_sel];

        issue_selected_payload[0].system_op =
            system_op_e'(system_op[issue_sel]);

        issue_selected_payload[0].csr_num =
            csr_num[issue_sel];

        issue_selected_payload[0].cacop_op =
            cacop_op[issue_sel];

        issue_selected_payload[0].serializing =
            serializing[issue_sel];

        issue_selected_payload[0].pred.ras_ptr =
            ras_ptr[issue_sel];

        issue_selected_payload[0].pred.valid =
            pred_valid[issue_sel];

        issue_selected_payload[0].pred.taken =
            pred_taken[issue_sel];

        issue_selected_payload[0].pred.target =
            pred_target[issue_sel];

        issue_selected_payload[0].pred.index =
            pred_index[issue_sel];

        issue_selected_payload[0].pred.ras_sp_before =
            ras_sp_before[issue_sel];

        issue_selected_payload[0].pred.ras_count_before =
            ras_count_before[issue_sel];

        issue_selected_payload[0].pred.perf_btb_hit =
            perf_btb_hit[issue_sel];

`ifndef SYNTHESIS
        perf_true_source_wait = 1'b0;
        perf_source_wait_dep_load = 1'b0;
        perf_source_wait_dep_muldiv = 1'b0;
        perf_source_wait_dep_alu = 1'b0;
        perf_source_wait_dep_branch = 1'b0;
        perf_source_wait_store_addr = 1'b0;
        perf_source_wait_store_data = 1'b0;

        perf_iq_no_ready =
            (valid != {DQ_DEPTH{1'b0}}) &&
            (
                (valid & slot_ready) ==
                {DQ_DEPTH{1'b0}}
            );

        perf_lsu_order = 1'b0;
        perf_serializing = 1'b0;

        if (perf_oldest_is_valid) begin
            begin : PERF_SOURCE_WAIT_EVAL
                logic s0_wait;
                logic s1_wait;
                logic is_store_oldest;
                logic [`ROB_TAG_W-1:0] s0_t;
                logic [`ROB_TAG_W-1:0] s1_t;
                producer_type_e s0_p;
                producer_type_e s1_p;

                s0_wait =
                    rR1_re[perf_oldest_idx] &&
                    (rR1[perf_oldest_idx] != 5'd0) &&
                    !src0_ready_eff[perf_oldest_idx];

                s1_wait =
                    rR2_re[perf_oldest_idx] &&
                    (rR2[perf_oldest_idx] != 5'd0) &&
                    !src1_ready_eff[perf_oldest_idx];

                s0_t =
                    src0_id[perf_oldest_idx].rob_tag;

                s1_t =
                    src1_id[perf_oldest_idx].rob_tag;

                s0_p =
                    (
                        s0_wait &&
                        producer_table[s0_t].valid &&
                        (
                            producer_table[s0_t].epoch ==
                            src0_id[perf_oldest_idx].epoch
                        )
                    )
                        ? producer_table[s0_t].ptype
                        : PROD_UNKNOWN;

                s1_p =
                    (
                        s1_wait &&
                        producer_table[s1_t].valid &&
                        (
                            producer_table[s1_t].epoch ==
                            src1_id[perf_oldest_idx].epoch
                        )
                    )
                        ? producer_table[s1_t].ptype
                        : PROD_UNKNOWN;

                is_store_oldest =
                    is_ld_st[perf_oldest_idx] &&
                    (
                        ram_we[perf_oldest_idx] !=
                        `RAM_WE_N
                    );

                perf_true_source_wait =
                    is_store_oldest
                        ? s0_wait
                        : (s0_wait || s1_wait);

                if (perf_true_source_wait) begin
                    if (is_store_oldest) begin
                        perf_source_wait_dep_load =
                            (s0_p == PROD_LOAD);

                        perf_source_wait_dep_muldiv =
                            (s0_p == PROD_MULDIV);

                        perf_source_wait_dep_alu =
                            (s0_p == PROD_ALU);

                        perf_source_wait_dep_branch =
                            (s0_p == PROD_BRANCH);
                    end else begin
                        perf_source_wait_dep_load =
                            (
                                s0_wait &&
                                (s0_p == PROD_LOAD)
                            ) ||
                            (
                                s1_wait &&
                                (s1_p == PROD_LOAD)
                            );

                        perf_source_wait_dep_muldiv =
                            (
                                s0_wait &&
                                (s0_p == PROD_MULDIV)
                            ) ||
                            (
                                s1_wait &&
                                (s1_p == PROD_MULDIV)
                            );

                        perf_source_wait_dep_alu =
                            (
                                s0_wait &&
                                (s0_p == PROD_ALU)
                            ) ||
                            (
                                s1_wait &&
                                (s1_p == PROD_ALU)
                            );

                        perf_source_wait_dep_branch =
                            (
                                s0_wait &&
                                (s0_p == PROD_BRANCH)
                            ) ||
                            (
                                s1_wait &&
                                (s1_p == PROD_BRANCH)
                            );
                    end
                end

                if (is_store_oldest) begin
                    perf_source_wait_store_addr =
                        s0_wait;

                    perf_source_wait_store_data =
                        s1_wait;
                end
            end

            perf_lsu_order =
                src0_ready_eff[perf_oldest_idx] &&
                src1_ready_eff[perf_oldest_idx] &&
                is_ld_st[perf_oldest_idx] &&
                (
                    ram_we[perf_oldest_idx] ==
                    `RAM_WE_N
                ) &&
                older_store_pending[perf_oldest_idx];

            perf_serializing =
                src0_ready_eff[perf_oldest_idx] &&
                src1_ready_eff[perf_oldest_idx] &&
                slot_lane0_only[perf_oldest_idx] &&
                (
                    system_op[perf_oldest_idx] !=
                    3'd0
                ) &&
                (
                    !rob_head_valid ||
                    !uop_id_equal(
                        uop_id[perf_oldest_idx],
                        rob_head_id
                    )
                );
        end
`endif

        issue_selected_payload[1] = '0;

        issue_selected_payload[1].uop_id =
            uop_id[fast_issue_sel];

        issue_selected_payload[1].pc =
            pc[fast_issue_sel];

        issue_selected_payload[1].src0_value =
            rD1[fast_issue_sel];

        issue_selected_payload[1].src1_value =
            fast_hold_is_store
                ? src1_value_eff[fast_issue_sel]
                : rD2[fast_issue_sel];

        issue_selected_payload[1].src1_ready =
            fast_hold_is_store
                ? src1_ready_eff[fast_issue_sel]
                : src1_ready[fast_issue_sel];

        issue_selected_payload[1].src1_id =
            src1_id[fast_issue_sel];

        issue_selected_payload[1].imm =
            ext[fast_issue_sel];

        issue_selected_payload[1].reg_write =
            rf_we[fast_issue_sel];

        issue_selected_payload[1].arch_rd =
            wR[fast_issue_sel];

        issue_selected_payload[1].result_sel =
            wd_sel[fast_issue_sel];

        issue_selected_payload[1].alu_op =
            alu_op[fast_issue_sel];

        issue_selected_payload[1].src_a_sel =
            alua_sel[fast_issue_sel];

        issue_selected_payload[1].src_b_sel =
            alub_sel[fast_issue_sel];

        issue_selected_payload[1].arch_rs1 =
            rR1[fast_issue_sel];

        issue_selected_payload[1].arch_rs2 =
            rR2[fast_issue_sel];

        issue_selected_payload[1].src0_used =
            rR1_re[fast_issue_sel];

        issue_selected_payload[1].src1_used =
            rR2_re[fast_issue_sel];

        issue_selected_payload[1].npc_op =
            npc_op[fast_issue_sel];

        issue_selected_payload[1].store_mask =
            ram_we[fast_issue_sel];

        issue_selected_payload[1].load_ext_op =
            ram_ext_op[fast_issue_sel];

        issue_selected_payload[1].is_br_jmp =
            is_br_jmp[fast_issue_sel];

        issue_selected_payload[1].is_ld_st =
            is_ld_st[fast_issue_sel];

        issue_selected_payload[1].is_call =
            is_call[fast_issue_sel];

        issue_selected_payload[1].is_ret =
            is_ret[fast_issue_sel];

        issue_selected_payload[1].system_op =
            system_op_e'(system_op[fast_issue_sel]);

        issue_selected_payload[1].csr_num =
            csr_num[fast_issue_sel];

        issue_selected_payload[1].cacop_op =
            cacop_op[fast_issue_sel];

        issue_selected_payload[1].serializing =
            serializing[fast_issue_sel];

        issue_selected_payload[1].pred.ras_ptr =
            ras_ptr[fast_issue_sel];

        issue_selected_payload[1].pred.valid =
            pred_valid[fast_issue_sel];

        issue_selected_payload[1].pred.taken =
            pred_taken[fast_issue_sel];

        issue_selected_payload[1].pred.target =
            pred_target[fast_issue_sel];

        issue_selected_payload[1].pred.index =
            pred_index[fast_issue_sel];

        issue_selected_payload[1].pred.ras_sp_before =
            ras_sp_before[fast_issue_sel];

        issue_selected_payload[1].pred.ras_count_before =
            ras_count_before[fast_issue_sel];

        issue_selected_payload[1].pred.perf_btb_hit =
            perf_btb_hit[fast_issue_sel];
    end

    wire [DQ_DEPTH-1:0] fast_refill_candidate =
        fast_candidate &
        ~fast_hold_onehot;

    assign fast_refill_pick =
        ROUND_ROBIN_SELECT
            ? pick_round_robin8(
                fast_refill_candidate,
                fast_rr_ptr
            )
            : pick_oldest8(
                fast_refill_candidate,
                alloc_seq[0],
                alloc_seq[1],
                alloc_seq[2],
                alloc_seq[3],
                alloc_seq[4],
                alloc_seq[5],
                alloc_seq[6],
                alloc_seq[7]
            );

    always_comb begin
        issue[0] = '0;
        issue[1] = '0;

        if (issue_payload_valid_q && !flush)
            issue[0] = issue_payload_q[0];

        if (fast_payload_valid_q && !flush)
            issue[1] = issue_payload_q[1];
    end

    assign store_issue_pending_valid =
        (store_token_count_q != 2'd0);

    always @(*) begin
        store_issue_pending = '0;

        if (store_token_count_q != 2'd0) begin
            store_issue_pending.uop_id =
                store_token_fifo_q[
                    store_token_head_q
                ].uop_id;

            store_issue_pending.pc =
                store_token_fifo_q[
                    store_token_head_q
                ].pc;

            store_issue_pending.store_mask =
                store_token_fifo_q[
                    store_token_head_q
                ].store_mask;

            store_issue_pending.src1_id =
                store_token_fifo_q[
                    store_token_head_q
                ].src1_id;
        end
    end

    assign store_issue_pending_occupancy =
        store_reserved_count[1:0];

    reg [3:0] valid_occupancy;
    reg [2:0] valid_clear_count;

    always @(*) begin
        valid_occupancy = 4'd0;
        valid_clear_count = 3'd0;

        for (
            occupancy_i = 0;
            occupancy_i < DQ_DEPTH;
            occupancy_i = occupancy_i + 1
        ) begin
            valid_occupancy =
                valid_occupancy +
                valid[occupancy_i];

            valid_clear_count =
                valid_clear_count +
                state_clear_vec[occupancy_i];
        end
    end

    assign occupancy =
        valid_occupancy;

    wire enq_src0_real =
        enq_rR1_re &&
        (enq_rR1 != 5'h0) &&
        !enq_src0_ready;

    wire enq_src1_real =
        enq_rR2_re &&
        (enq_rR2 != 5'h0) &&
        !enq_src1_ready;

    wire enq1_src0_real =
        enq1_rR1_re &&
        (enq1_rR1 != 5'h0) &&
        !enq1_src0_ready;

    wire enq1_src1_real =
        enq1_rR2_re &&
        (enq1_rR2 != 5'h0) &&
        !enq1_src1_ready;

    wire c0_enq_s0 =
        uop_id_equal(
            wakeup0_id,
            enq_src0_id
        );

    wire c1_enq_s0 =
        uop_id_equal(
            wakeup1_id,
            enq_src0_id
        );

    wire cs_enq_s0 =
        uop_id_equal(
            system_wakeup_id,
            enq_src0_id
        );

    wire k0_enq_s0 =
        uop_id_equal(
            commit_id,
            enq_src0_id
        );

    wire k1_enq_s0 =
        uop_id_equal(
            commit1_id,
            enq_src0_id
        );

    wire c0_enq_s1 =
        uop_id_equal(
            wakeup0_id,
            enq_src1_id
        );

    wire c1_enq_s1 =
        uop_id_equal(
            wakeup1_id,
            enq_src1_id
        );

    wire cs_enq_s1 =
        uop_id_equal(
            system_wakeup_id,
            enq_src1_id
        );

    wire k0_enq_s1 =
        uop_id_equal(
            commit_id,
            enq_src1_id
        );

    wire k1_enq_s1 =
        uop_id_equal(
            commit1_id,
            enq_src1_id
        );

    wire c0_enq1_s0 =
        uop_id_equal(
            wakeup0_id,
            enq1_src0_id
        );

    wire c1_enq1_s0 =
        uop_id_equal(
            wakeup1_id,
            enq1_src0_id
        );

    wire cs_enq1_s0 =
        uop_id_equal(
            system_wakeup_id,
            enq1_src0_id
        );

    wire k0_enq1_s0 =
        uop_id_equal(
            commit_id,
            enq1_src0_id
        );

    wire k1_enq1_s0 =
        uop_id_equal(
            commit1_id,
            enq1_src0_id
        );

    wire c0_enq1_s1 =
        uop_id_equal(
            wakeup0_id,
            enq1_src1_id
        );

    wire c1_enq1_s1 =
        uop_id_equal(
            wakeup1_id,
            enq1_src1_id
        );

    wire cs_enq1_s1 =
        uop_id_equal(
            system_wakeup_id,
            enq1_src1_id
        );

    wire k0_enq1_s1 =
        uop_id_equal(
            commit_id,
            enq1_src1_id
        );

    wire k1_enq1_s1 =
        uop_id_equal(
            commit1_id,
            enq1_src1_id
        );

    wire enq_src0_complete =
        enq_src0_real &&
        (
            (
                wakeup0_valid &&
                wakeup0_rf_we &&
                c0_enq_s0
            ) ||
            (
                wakeup1_valid &&
                wakeup1_rf_we &&
                c1_enq_s0
            ) ||
            (
                system_wakeup_valid &&
                system_wakeup_rf_we &&
                cs_enq_s0
            )
        );

    wire enq_src1_complete =
        enq_src1_real &&
        (
            (
                wakeup0_valid &&
                wakeup0_rf_we &&
                c0_enq_s1
            ) ||
            (
                wakeup1_valid &&
                wakeup1_rf_we &&
                c1_enq_s1
            ) ||
            (
                system_wakeup_valid &&
                system_wakeup_rf_we &&
                cs_enq_s1
            )
        );

    wire enq_src0_commit =
        enq_src0_real &&
        (
            (
                commit_valid &&
                commit_rf_we &&
                k0_enq_s0
            ) ||
            (
                commit1_valid &&
                commit1_rf_we &&
                k1_enq_s0
            )
        );

    wire enq_src1_commit =
        enq_src1_real &&
        (
            (
                commit_valid &&
                commit_rf_we &&
                k0_enq_s1
            ) ||
            (
                commit1_valid &&
                commit1_rf_we &&
                k1_enq_s1
            )
        );

    wire enq1_src0_complete =
        enq1_src0_real &&
        (
            (
                wakeup0_valid &&
                wakeup0_rf_we &&
                c0_enq1_s0
            ) ||
            (
                wakeup1_valid &&
                wakeup1_rf_we &&
                c1_enq1_s0
            ) ||
            (
                system_wakeup_valid &&
                system_wakeup_rf_we &&
                cs_enq1_s0
            )
        );

    wire enq1_src1_complete =
        enq1_src1_real &&
        (
            (
                wakeup0_valid &&
                wakeup0_rf_we &&
                c0_enq1_s1
            ) ||
            (
                wakeup1_valid &&
                wakeup1_rf_we &&
                c1_enq1_s1
            ) ||
            (
                system_wakeup_valid &&
                system_wakeup_rf_we &&
                cs_enq1_s1
            )
        );

    wire enq1_src0_commit =
        enq1_src0_real &&
        (
            (
                commit_valid &&
                commit_rf_we &&
                k0_enq1_s0
            ) ||
            (
                commit1_valid &&
                commit1_rf_we &&
                k1_enq1_s0
            )
        );

    wire enq1_src1_commit =
        enq1_src1_real &&
        (
            (
                commit_valid &&
                commit_rf_we &&
                k0_enq1_s1
            ) ||
            (
                commit1_valid &&
                commit1_rf_we &&
                k1_enq1_s1
            )
        );

    wire [31:0] enq_src0_bypass_value =
        (
            enq_src0_real &&
            wakeup0_valid &&
            wakeup0_rf_we &&
            c0_enq_s0
        ) ? wakeup0_value :
        (
            enq_src0_real &&
            wakeup1_valid &&
            wakeup1_rf_we &&
            c1_enq_s0
        ) ? wakeup1_value :
        (
            enq_src0_real &&
            system_wakeup_valid &&
            system_wakeup_rf_we &&
            cs_enq_s0
        ) ? system_wakeup_value :
        (
            enq_src0_real &&
            commit_valid &&
            commit_rf_we &&
            k0_enq_s0
        ) ? commit_value :
        (
            enq_src0_real &&
            commit1_valid &&
            commit1_rf_we &&
            k1_enq_s0
        ) ? commit1_value :
        enq_rD1;

    wire [31:0] enq_src1_bypass_value =
        (
            enq_src1_real &&
            wakeup0_valid &&
            wakeup0_rf_we &&
            c0_enq_s1
        ) ? wakeup0_value :
        (
            enq_src1_real &&
            wakeup1_valid &&
            wakeup1_rf_we &&
            c1_enq_s1
        ) ? wakeup1_value :
        (
            enq_src1_real &&
            system_wakeup_valid &&
            system_wakeup_rf_we &&
            cs_enq_s1
        ) ? system_wakeup_value :
        (
            enq_src1_real &&
            commit_valid &&
            commit_rf_we &&
            k0_enq_s1
        ) ? commit_value :
        (
            enq_src1_real &&
            commit1_valid &&
            commit1_rf_we &&
            k1_enq_s1
        ) ? commit1_value :
        enq_rD2;

    wire [31:0] enq1_src0_bypass_value =
        (
            enq1_src0_real &&
            wakeup0_valid &&
            wakeup0_rf_we &&
            c0_enq1_s0
        ) ? wakeup0_value :
        (
            enq1_src0_real &&
            wakeup1_valid &&
            wakeup1_rf_we &&
            c1_enq1_s0
        ) ? wakeup1_value :
        (
            enq1_src0_real &&
            system_wakeup_valid &&
            system_wakeup_rf_we &&
            cs_enq1_s0
        ) ? system_wakeup_value :
        (
            enq1_src0_real &&
            commit_valid &&
            commit_rf_we &&
            k0_enq1_s0
        ) ? commit_value :
        (
            enq1_src0_real &&
            commit1_valid &&
            commit1_rf_we &&
            k1_enq1_s0
        ) ? commit1_value :
        enq1_rD1;

    wire [31:0] enq1_src1_bypass_value =
        (
            enq1_src1_real &&
            wakeup0_valid &&
            wakeup0_rf_we &&
            c0_enq1_s1
        ) ? wakeup0_value :
        (
            enq1_src1_real &&
            wakeup1_valid &&
            wakeup1_rf_we &&
            c1_enq1_s1
        ) ? wakeup1_value :
        (
            enq1_src1_real &&
            system_wakeup_valid &&
            system_wakeup_rf_we &&
            cs_enq1_s1
        ) ? system_wakeup_value :
        (
            enq1_src1_real &&
            commit_valid &&
            commit_rf_we &&
            k0_enq1_s1
        ) ? commit_value :
        (
            enq1_src1_real &&
            commit1_valid &&
            commit1_rf_we &&
            k1_enq1_s1
        ) ? commit1_value :
        enq1_rD2;

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            for (j = 0; j < DQ_DEPTH; j = j + 1) begin
                rD1[j] <= 32'h0;
                rD2[j] <= 32'h0;
            end
        end else begin
            if (
                wakeup0_valid ||
                wakeup1_valid ||
                system_wakeup_valid ||
                commit_valid ||
                commit1_valid
            ) begin
                for (j = 0; j < DQ_DEPTH; j = j + 1) begin
                    if (wake_src0_vec[j]) begin
                        if (wake0_src0_vec[j])
                            rD1[j] <= wakeup0_value;
                        else if (wake1_src0_vec[j])
                            rD1[j] <= wakeup1_value;
                        else if (system_src0_match[j])
                            rD1[j] <= system_wakeup_value;
                        else if (wake2_src0_vec[j])
                            rD1[j] <= commit_value;
                        else if (wake3_src0_vec[j])
                            rD1[j] <= commit1_value;
                    end

                    if (wake_src1_vec[j]) begin
                        if (wake0_src1_vec[j])
                            rD2[j] <= wakeup0_value;
                        else if (wake1_src1_vec[j])
                            rD2[j] <= wakeup1_value;
                        else if (system_src1_match[j])
                            rD2[j] <= system_wakeup_value;
                        else if (wake2_src1_vec[j])
                            rD2[j] <= commit_value;
                        else if (wake3_src1_vec[j])
                            rD2[j] <= commit1_value;
                    end
                end
            end

            if (free_found) begin
                rD1[enq_sel] <=
                    (
                        enq_src0_complete ||
                        enq_src0_commit
                    )
                        ? enq_src0_bypass_value
                        : enq_rD1;

                rD2[enq_sel] <=
                    (
                        enq_src1_complete ||
                        enq_src1_commit
                    )
                        ? enq_src1_bypass_value
                        : enq_rD2;
            end

            if (second_free_found) begin
                rD1[enq1_sel] <=
                    (
                        enq1_src0_complete ||
                        enq1_src0_commit
                    )
                        ? enq1_src0_bypass_value
                        : enq1_rD1;

                rD2[enq1_sel] <=
                    (
                        enq1_src1_complete ||
                        enq1_src1_commit
                    )
                        ? enq1_src1_bypass_value
                        : enq1_rD2;
            end
        end
    end

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            issue_payload_valid_q <= 1'b0;
            fast_payload_valid_q <= 1'b0;
            issue_payload_q[0] <= '0;
            issue_payload_q[1] <= '0;
        end else if (system_flush) begin
            issue_payload_valid_q <= 1'b0;
            fast_payload_valid_q <= 1'b0;
        end else if (flush) begin
            if (
                !(
                    recover_valid &&
                    issue_payload_valid_q &&
                    !uop_is_younger(
                        issue_payload_q[0].uop_id,
                        recover_id
                    )
                )
            )
                issue_payload_valid_q <= 1'b0;

            if (
                !(
                    recover_valid &&
                    fast_payload_valid_q &&
                    !uop_is_younger(
                        issue_payload_q[1].uop_id,
                        recover_id
                    )
                )
            )
                fast_payload_valid_q <= 1'b0;
        end else begin
            if (main_payload_capture) begin
                issue_payload_valid_q <= 1'b1;
                issue_payload_q[0] <=
                    issue_selected_payload[0];
            end else if (issue_fire) begin
                issue_payload_valid_q <= 1'b0;
            end

            if (fast_payload_capture) begin
                fast_payload_valid_q <= 1'b1;
                issue_payload_q[1] <=
                    issue_selected_payload[1];
            end else if (fast_issue_fire) begin
                fast_payload_valid_q <= 1'b0;
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
            barrier_release_reg <= 1'b0;
            main_hold_valid <= 1'b0;
            main_hold_sel <= 3'h0;
            main_hold_store_grant_q <= 1'b0;
            fast_hold_valid <= 1'b0;
            fast_hold_sel <= 3'h0;
            fast_hold_store_grant_q <= 1'b0;
            main_rr_ptr <= 3'h0;
            fast_rr_ptr <= 3'h0;
            main_ownership_transfer_q <= 1'b0;
            fast_ownership_transfer_q <= 1'b0;
            older_branch_pending_q <= {DQ_DEPTH{1'b0}};
            older_store_pending_q <= {DQ_DEPTH{1'b0}};
            older_store_any_q <= 1'b0;
            issue_pending_valid <= 1'b0;
            issue_pending_sel <= 3'h0;
            fast_pending_valid <= 1'b0;
            fast_pending_sel <= 3'h0;
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

            for (
                i = 0;
                i < (1 << `ROB_TAG_W);
                i = i + 1
            ) begin
                producer_table[i] <= '0;
            end
        end else if (flush || system_flush) begin
            recover_count = 0;

            for (i = 0; i < DQ_DEPTH; i = i + 1) begin
                if (
                    valid[i] &&
                    !system_flush &&
                    recover_valid &&
                    !uop_is_younger(
                        uop_id[i],
                        recover_id
                    )
                ) begin
                    recover_count =
                        recover_count + 1;

                    if (wake_src0_vec[i])
                        src0_ready[i] <= 1'b1;

                    if (wake_src1_vec[i])
                        src1_ready[i] <= 1'b1;
                end else begin
                    valid[i] <= 1'b0;
                    src0_ready[i] <= 1'b0;
                    src1_ready[i] <= 1'b0;
                    barrier_blocked[i] <= 1'b0;
                end
            end

            barrier_active <= 1'b0;
            barrier_release_reg <= 1'b0;
            main_rr_ptr <= 3'h0;
            fast_rr_ptr <= 3'h0;
            main_ownership_transfer_q <= 1'b0;
            fast_ownership_transfer_q <= 1'b0;
            older_branch_pending_q <= {DQ_DEPTH{1'b1}};
            older_store_pending_q <= older_store_pending_refresh;
            older_store_any_q <= older_store_any_refresh;

            if (
                recover_valid &&
                !system_flush &&
                main_hold_valid &&
                valid[main_hold_sel] &&
                !uop_is_younger(
                    uop_id[main_hold_sel],
                    recover_id
                )
            ) begin
                main_hold_valid <= 1'b1;
            end else begin
                main_hold_valid <= 1'b0;
                main_hold_sel <= 3'h0;
                main_hold_store_grant_q <= 1'b0;
            end

            if (
                recover_valid &&
                !system_flush &&
                fast_hold_valid &&
                valid[fast_hold_sel] &&
                !uop_is_younger(
                    uop_id[fast_hold_sel],
                    recover_id
                )
            ) begin
                fast_hold_valid <= 1'b1;
            end else begin
                fast_hold_valid <= 1'b0;
                fast_hold_sel <= 3'h0;
                fast_hold_store_grant_q <= 1'b0;
            end

            if (
                recover_valid &&
                !system_flush &&
                issue_pending_valid &&
                valid[issue_pending_sel] &&
                !uop_is_younger(
                    uop_id[issue_pending_sel],
                    recover_id
                )
            ) begin
                issue_pending_valid <= 1'b1;
            end else begin
                issue_pending_valid <= 1'b0;
                issue_pending_sel <= 3'h0;
            end

            if (
                recover_valid &&
                !system_flush &&
                fast_pending_valid &&
                valid[fast_pending_sel] &&
                !uop_is_younger(
                    uop_id[fast_pending_sel],
                    recover_id
                )
            ) begin
                fast_pending_valid <= 1'b1;
            end else begin
                fast_pending_valid <= 1'b0;
                fast_pending_sel <= 3'h0;
            end

            count <= recover_count;

            if (system_flush)
                next_alloc_seq <=
                    {DQ_SEQ_W{1'b0}};
        end else begin
            main_ownership_transfer_q <=
                main_select_capture ||
                main_refill_valid;

            fast_ownership_transfer_q <=
                fast_select_capture ||
                fast_refill_valid;

            barrier_release_reg <=
                barrier_release;

            if (main_payload_capture) begin
                main_hold_store_grant_q <= 1'b0;

                if (main_refill_valid) begin
                    main_hold_valid <= 1'b1;
                    main_hold_sel <=
                        main_refill_pick[2:0];
                end else begin
                    main_hold_valid <= 1'b0;
                    main_hold_sel <= 3'h0;
                end
            end else if (
                main_hold_valid &&
                (
                    !valid[main_hold_sel] ||
                    main_hold_store_blocked
                )
            ) begin
                main_hold_valid <= 1'b0;
                main_hold_sel <= 3'h0;
                main_hold_store_grant_q <= 1'b0;
            end else if (main_select_capture) begin
                main_hold_valid <= 1'b1;
                main_hold_sel <= main_pick[2:0];
                main_hold_store_grant_q <=
                    main_new_store_grant;
            end else if (main_store_grant_set) begin
                main_hold_store_grant_q <= 1'b1;
            end

            if (registered_select_collision) begin
                fast_hold_valid <= 1'b0;
                fast_hold_sel <= 3'h0;
                fast_hold_store_grant_q <= 1'b0;
            end else if (fast_payload_capture) begin
                fast_hold_store_grant_q <= 1'b0;

                if (fast_refill_valid) begin
                    fast_hold_valid <= 1'b1;
                    fast_hold_sel <=
                        fast_refill_pick[2:0];
                end else begin
                    fast_hold_valid <= 1'b0;
                    fast_hold_sel <= 3'h0;
                end
            end else if (
                fast_hold_valid &&
                (
                    !valid[fast_hold_sel] ||
                    fast_hold_store_blocked
                )
            ) begin
                fast_hold_valid <= 1'b0;
                fast_hold_sel <= 3'h0;
                fast_hold_store_grant_q <= 1'b0;
            end else if (fast_select_capture) begin
                fast_hold_valid <= 1'b1;
                fast_hold_sel <= fast_pick[2:0];
                fast_hold_store_grant_q <=
                    fast_new_store_grant;
            end else if (fast_store_grant_set) begin
                fast_hold_store_grant_q <= 1'b1;
            end

            if (REGISTER_ISSUE_CLEAR) begin
                issue_pending_valid <= 1'b0;
                fast_pending_valid <= 1'b0;
            end else begin
                if (main_ownership_transfer_q)
                    main_rr_ptr <=
                        main_rr_ptr + 3'd1;

                if (
                    fast_ownership_transfer_q &&
                    !registered_select_collision
                )
                    fast_rr_ptr <=
                        fast_rr_ptr + 3'd1;
            end

            if (REGISTERED_ORDER_SELECT) begin
                older_branch_pending_q <=
                    older_branch_pending;

                older_store_pending_q <=
                    older_store_pending_refresh;

                older_store_any_q <=
                    older_store_any_refresh;
            end

            if (
                wakeup0_valid ||
                wakeup1_valid ||
                system_wakeup_valid ||
                commit_valid ||
                commit1_valid
            ) begin
                for (i = 0; i < DQ_DEPTH; i = i + 1) begin
                    if (wake_src0_vec[i])
                        src0_ready[i] <= 1'b1;

                    if (wake_src1_vec[i])
                        src1_ready[i] <= 1'b1;
                end
            end

            for (i = 0; i < DQ_DEPTH; i = i + 1) begin
                if (state_clear_vec[i])
                    valid[i] <= 1'b0;
            end

            if (!has_serializing_op) begin
                barrier_blocked <=
                    {DQ_DEPTH{1'b0}};

                barrier_active <= 1'b0;
            end else if (barrier_release_reg) begin
                barrier_active <= 1'b1;
            end

            if (enq_fire) begin
                valid[enq_sel] <= 1'b1;

                if (REGISTERED_ORDER_SELECT) begin
                    older_branch_pending_q[enq_sel] <=
                        enq_order_branch_blocked;

                    older_store_pending_q[enq_sel] <=
                        enq_order_store_blocked;
                end

                uop_id[enq_sel] <= enq_uop_id;
                alloc_seq[enq_sel] <= next_alloc_seq;

                src0_ready[enq_sel] <=
                    enq_src0_ready ||
                    enq_src0_complete ||
                    enq_src0_commit;

                src1_ready[enq_sel] <=
                    enq_src1_ready ||
                    enq_src1_complete ||
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
                barrier_blocked[enq_sel] <=
                    barrier_blocks_new;

                if (
                    enq_serializing &&
                    (enq_system_op != 3'd0)
                )
                    barrier_active <= 1'b1;

                ras_ptr[enq_sel] <= enq_ras_ptr;
                pred_valid[enq_sel] <= enq_pred_valid;
                pred_taken[enq_sel] <= enq_pred_taken;
                pred_target[enq_sel] <= enq_pred_target;
                pred_index[enq_sel] <= enq_pred_index;
                ras_sp_before[enq_sel] <=
                    enq_ras_sp_before;
                ras_count_before[enq_sel] <=
                    enq_ras_count_before;
                perf_btb_hit[enq_sel] <=
                    enq_perf_btb_hit;

                producer_table[
                    enq_uop_id.rob_tag
                ].valid <= 1'b1;

                producer_table[
                    enq_uop_id.rob_tag
                ].epoch <= enq_uop_id.epoch;

                producer_table[
                    enq_uop_id.rob_tag
                ].ptype <=
                    (
                        enq_is_ld_st &&
                        (enq_ram_we == `RAM_WE_N)
                    )
                        ? PROD_LOAD
                        : (
                            (
                                (enq_alu_op == `ALU_MULL) ||
                                (enq_alu_op == `ALU_MULH) ||
                                (enq_alu_op == `ALU_UMUL)
                            )
                                ? PROD_MULDIV
                                : (
                                    enq_is_br_jmp
                                        ? PROD_BRANCH
                                        : PROD_ALU
                                )
                        );
            end

            if (enq1_fire) begin
                valid[enq1_sel] <= 1'b1;

                if (REGISTERED_ORDER_SELECT) begin
                    older_branch_pending_q[enq1_sel] <=
                        enq1_order_branch_blocked;

                    older_store_pending_q[enq1_sel] <=
                        enq1_order_store_blocked;
                end

                uop_id[enq1_sel] <= enq1_uop_id;

                alloc_seq[enq1_sel] <=
                    next_alloc_seq + enq_fire;

                src0_ready[enq1_sel] <=
                    enq1_src0_ready ||
                    enq1_src0_complete ||
                    enq1_src0_commit;

                src1_ready[enq1_sel] <=
                    enq1_src1_ready ||
                    enq1_src1_complete ||
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

                barrier_blocked[enq1_sel] <=
                    barrier_blocks_new ||
                    (
                        enq_fire &&
                        enq_serializing &&
                        (enq_system_op != 3'd0)
                    );

                if (
                    enq1_serializing &&
                    (enq1_system_op != 3'd0)
                )
                    barrier_active <= 1'b1;

                ras_ptr[enq1_sel] <= enq1_ras_ptr;
                pred_valid[enq1_sel] <= enq1_pred_valid;
                pred_taken[enq1_sel] <= enq1_pred_taken;
                pred_target[enq1_sel] <= enq1_pred_target;
                pred_index[enq1_sel] <= enq1_pred_index;
                ras_sp_before[enq1_sel] <=
                    enq1_ras_sp_before;
                ras_count_before[enq1_sel] <=
                    enq1_ras_count_before;
                perf_btb_hit[enq1_sel] <=
                    enq1_perf_btb_hit;

                producer_table[
                    enq1_uop_id.rob_tag
                ].valid <= 1'b1;

                producer_table[
                    enq1_uop_id.rob_tag
                ].epoch <= enq1_uop_id.epoch;

                producer_table[
                    enq1_uop_id.rob_tag
                ].ptype <=
                    (
                        enq1_is_ld_st &&
                        (enq1_ram_we == `RAM_WE_N)
                    )
                        ? PROD_LOAD
                        : (
                            (
                                (enq1_alu_op == `ALU_MULL) ||
                                (enq1_alu_op == `ALU_MULH) ||
                                (enq1_alu_op == `ALU_UMUL)
                            )
                                ? PROD_MULDIV
                                : (
                                    enq1_is_br_jmp
                                        ? PROD_BRANCH
                                        : PROD_ALU
                                )
                        );
            end

            count <=
                valid_occupancy +
                enq_fire +
                enq1_fire -
                valid_clear_count;

            next_alloc_seq <=
                next_alloc_seq +
                enq_fire +
                enq1_fire;
        end
    end

`ifndef SYNTHESIS
    always @(posedge clk) begin
        if (
            rstn &&
            !flush &&
            !system_flush &&
            registered_select_collision &&
            fast_payload_capture
        )
            $fatal(
                1,
                "DispatchQueue registered select collision reached lane1 payload"
            );

        if (
            rstn &&
            !flush &&
            !system_flush
        ) begin
            if (store_reserved_count > 3'd2)
                $fatal(
                    1,
                    "DispatchQueue Store ownership overflow: tokens=%0d main_grant=%0d fast_grant=%0d",
                    store_token_count_q,
                    main_hold_store_grant_q,
                    fast_hold_store_grant_q
                );

            if (
                store_token_push &&
                (store_token_count_q == 2'd2) &&
                !store_token_pop
            )
                $fatal(
                    1,
                    "DispatchQueue granted Store pushed into a full token FIFO"
                );

            if (
                issue_store_fire &&
                !main_hold_store_grant_q
            )
                $fatal(
                    1,
                    "DispatchQueue lane0 Store crossed without ownership grant"
                );

            if (
                fast_store_fire &&
                !fast_hold_store_grant_q
            )
                $fatal(
                    1,
                    "DispatchQueue lane1 Store crossed without ownership grant"
                );

            if (
                main_hold_store_grant_q &&
                !main_hold_is_store
            )
                $fatal(
                    1,
                    "DispatchQueue lane0 Store grant lost its owner"
                );

            if (
                fast_hold_store_grant_q &&
                !fast_hold_is_store
            )
                $fatal(
                    1,
                    "DispatchQueue lane1 Store grant lost its owner"
                );
        end

        if (
            rstn &&
            !flush &&
            !system_flush &&
            issue_store_fire &&
            fast_store_fire
        )
            $fatal(
                1,
                "DispatchQueue dual Store capture crossed single-push token boundary"
            );
    end
`endif

endmodule