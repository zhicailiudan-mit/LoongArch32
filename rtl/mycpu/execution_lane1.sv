`timescale 1ns / 1ps

`include "defines.vh"

import cpu_types_pkg::*;

// Independent second integer/MDU/address-generation lane. Ordered branch and
// system side effects remain on lane 0; memory packets use LSU input 1.
module ExecutionLane1 (
    input  logic                    clk,
    input  logic                    rstn,
    input  logic                    flush,
    input  logic                    recover_valid,
    input  logic                    system_flush,
    input  uop_id_t                 recover_id,
    input  completion_t             store_data_complete0,
    input  completion_t             store_data_complete1,
    input  logic                    result_stall,
    output logic                    issue_ready,
    input  logic                    issue_valid,
    input  uop_id_t                 issue_uop_id,
    input  logic [31:0]             issue_pc,
    input  logic [31:0]             issue_src0,
    input  logic [31:0]             issue_src1,
    input  logic                    issue_src1_ready,
    input  uop_id_t                 issue_src1_id,
    input  logic [31:0]             issue_imm,
    input  logic                    issue_reg_write,
    input  logic [4:0]              issue_arch_rd,
    input  logic [1:0]              issue_result_sel,
    input  logic [4:0]              issue_alu_op,
    input  logic                    issue_src_a_sel,
    input  logic                    issue_src_b_sel,
    input  logic [3:0]              issue_store_mask,
    input  logic [2:0]              issue_load_ext_op,
    input  logic                    issue_is_ld_st,
    output execute_result_t         execute_result,
    output logic                    complete_valid,
    output uop_id_t                 complete_uop_id,
    output logic [31:0]             complete_value,
    output logic                    complete_reg_write
);
    logic                    valid_q;
    uop_id_t                 uop_id_q;
    logic [31:0]             pc_q;
    logic [31:0]             src0_q;
    logic [31:0]             src1_q;
    logic                    src1_ready_q;
    uop_id_t                 src1_id_q;
    logic [31:0]             imm_q;
    logic                    reg_write_q;
    logic [4:0]              arch_rd_q;
    logic [1:0]              result_sel_q;
    logic [4:0]              alu_op_q;
    logic                    src_a_sel_q;
    logic                    src_b_sel_q;
    logic [3:0]              store_mask_q;
    logic [2:0]              load_ext_op_q;
    logic                    is_ld_st_q;
    logic [31:0]             alu_result;
    logic [31:0]             muldiv_result;
    logic                    muldiv_done;
    logic                    muldiv_busy;
    wire                     is_mdu_q = valid_q &&
        ((alu_op_q == `ALU_MULL) || (alu_op_q == `ALU_MULH) ||
         (alu_op_q == `ALU_UMUL));
    wire                     result_done = valid_q &&
                                              (!is_mdu_q || muldiv_done);
    wire                     result_fire = result_done && !result_stall;
    wire                     kill_valid_q = flush && valid_q &&
        (system_flush || !recover_valid ||
         uop_is_younger(uop_id_q, recover_id));
    wire [31:0]              lane_result = is_mdu_q ? muldiv_result :
                                                               alu_result;

    wire valid_q_is_store =
        valid_q &&
        is_ld_st_q &&
        (store_mask_q != `RAM_WE_N);

    wire store_data_wake0 =
        valid_q_is_store &&
        !src1_ready_q &&
        store_data_complete0.valid &&
        store_data_complete0.reg_write &&
        uop_id_equal(store_data_complete0.uop_id,
                     src1_id_q);

    wire store_data_wake1 =
        valid_q_is_store &&
        !src1_ready_q &&
        store_data_complete1.valid &&
        store_data_complete1.reg_write &&
        uop_id_equal(store_data_complete1.uop_id,
                     src1_id_q);

    wire store_data_wake =
        store_data_wake0 || store_data_wake1;

    wire [31:0] store_data_wake_value =
        store_data_wake0 ? store_data_complete0.value :
                           store_data_complete1.value;

    assign issue_ready = !valid_q || result_fire;

    logic ldst_unalign;
    always_comb begin
        case (load_ext_op_q)
            `RAM_EXT_H_S,
            `RAM_EXT_H_Z: ldst_unalign = (lane_result[1:0] != 2'h0) &&
                                         (lane_result[1:0] != 2'h2);
            `RAM_EXT_N:   ldst_unalign = (lane_result[1:0] != 2'h0);
            default:      ldst_unalign = 1'b0;
        endcase

        execute_result = '0;
        execute_result.valid = result_done && is_ld_st_q;
        execute_result.uop_id = uop_id_q;
        execute_result.pc = pc_q;
        execute_result.src0_value = src0_q;
        execute_result.src1_value = src1_q;
        execute_result.store_data_ready = src1_ready_q;
        execute_result.store_data_src_id = src1_id_q;
        execute_result.imm = imm_q;
        execute_result.alu_result = lane_result;
        execute_result.reg_write = reg_write_q;
        execute_result.arch_rd = arch_rd_q;
        execute_result.result_sel = result_sel_q;
        execute_result.store_mask = store_mask_q;
        execute_result.load_ext_op = load_ext_op_q;
        execute_result.is_ld_st = is_ld_st_q;
        execute_result.ldst_unalign = ldst_unalign;
        execute_result.writeback_value = lane_result;
        execute_result.select_ram = (load_ext_op_q != `N_RAM_EXT);
    end

    IntegerAluCore u_integer_alu_core (
        .alu_op (alu_op_q),
        .a      (src_a_sel_q ? src0_q : pc_q),
        .b      (src_b_sel_q ? src1_q : imm_q),
        .result (alu_result)
    );

    // Lane1 owns an independent multiplier so two MDU operations may remain
    // in flight concurrently. The current build has multiply only, no divider.
    MulDiv u_mul_div_lane1 (
        .cpu_clk (clk),
        .cpu_rstn(rstn),
        .flush   (kill_valid_q),
        .alu_op  (valid_q ? alu_op_q : 5'h0),
        .a       (src_a_sel_q ? src0_q : pc_q),
        .b       (src_b_sel_q ? src1_q : imm_q),
        .result  (muldiv_result),
        .done    (muldiv_done),
        .busy    (muldiv_busy)
    );

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            valid_q          <= 1'b0;
            uop_id_q         <= '0;
            pc_q             <= 32'h0;
            src0_q           <= 32'h0;
            src1_q           <= 32'h0;
            src1_ready_q     <= 1'b0;
            src1_id_q        <= '0;
            imm_q            <= 32'h0;
            reg_write_q      <= 1'b0;
            arch_rd_q        <= 5'h0;
            result_sel_q     <= 2'h0;
            alu_op_q         <= 5'h0;
            src_a_sel_q      <= 1'b0;
            src_b_sel_q      <= 1'b0;
            store_mask_q     <= `RAM_WE_N;
            load_ext_op_q    <= `N_RAM_EXT;
            is_ld_st_q       <= 1'b0;
            complete_valid   <= 1'b0;
            complete_uop_id  <= '0;
            complete_value   <= 32'h0;
            complete_reg_write <= 1'b0;
        end else if (kill_valid_q) begin
            // A branch recovery may immediately reuse a ROB tag.  Kill both
            // stages so a squashed lane-1 uop cannot complete into the new
            // occupant of the same tag (ABA corruption).
            valid_q             <= 1'b0;
            complete_valid      <= 1'b0;
            complete_reg_write  <= 1'b0;
        end else begin
            // ALU operations accept a new packet every cycle. An MDU packet
            // holds this register until the lane-local DSP pipeline is done.
            if (!flush && issue_ready) begin
                valid_q     <= issue_valid;
                uop_id_q    <= issue_uop_id;
                pc_q        <= issue_pc;
                src0_q      <= issue_src0;
                src1_q      <= issue_src1;
                src1_ready_q <= issue_src1_ready;
                src1_id_q   <= issue_src1_id;
                imm_q       <= issue_imm;
                reg_write_q <= issue_reg_write;
                arch_rd_q   <= issue_arch_rd;
                result_sel_q <= issue_result_sel;
                alu_op_q    <= issue_alu_op;
                src_a_sel_q <= issue_src_a_sel;
                src_b_sel_q <= issue_src_b_sel;
                store_mask_q <= issue_store_mask;
                load_ext_op_q <= issue_load_ext_op;
                is_ld_st_q <= issue_is_ld_st;
            end else if (store_data_wake) begin
                // The Store is resident in lane1 because SQ has not accepted
                // it yet.  Capture its data producer completion locally.
                src1_q       <= store_data_wake_value;
                src1_ready_q <= 1'b1;
            end

            complete_valid     <= result_fire && !is_ld_st_q;
            complete_uop_id    <= uop_id_q;
            complete_reg_write <= result_fire && !is_ld_st_q && reg_write_q;
            if (result_fire && !is_ld_st_q)
                complete_value <= lane_result;
        end
    end

    wire unused_muldiv_busy = muldiv_busy;
endmodule
