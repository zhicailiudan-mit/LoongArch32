`timescale 1ns / 1ps

`include "defines.vh"

import cpu_types_pkg::*;

// Main execution lane 0. This lane handles ordered execution results used by
// the existing LSU and branch recovery links, as well as arithmetic and MDU operations.
module ExecutionLane0 (
    input  logic                  cpu_rstn,
    input  logic                  cpu_clk,
    input  logic                  lane0_result_stall,
    input  logic                  pred_error,
    input  logic                  recover_valid,
    input  logic                  system_flush,
    input  uop_id_t               recover_id,

    input  logic                  issue0_valid,
    input  logic                  issue0_fire,
    input  issue_uop_t            issue0,
    output logic                  issue0_ready,

    output execute_result_t       execute_result,
    output logic                  alu_done,
    output logic                  muldiv_busy,
    output logic                  branch_mispredict,
    output logic                  redirect_valid,
    output logic [31:0]           redirect_target,
    output uop_id_t               branch_recover_id,
    output logic                  pipeline_flush
);
    issue_uop_t issue0_q;
    logic       issue0_valid_q;

    wire [31:0] ex_a = issue0_q.src_a_sel ? issue0_q.src0_value : issue0_q.pc;
    wire [31:0] ex_b = issue0_q.src_b_sel ? issue0_q.src1_value : issue0_q.imm;
    wire        ex_is_mdu = (issue0_q.alu_op == `ALU_MULL) ||
                            (issue0_q.alu_op == `ALU_MULH) ||
                            (issue0_q.alu_op == `ALU_UMUL);
    wire [31:0] integer_result0;
    wire [31:0] muldiv_result;
    wire        muldiv_done;
    wire        muldiv_busy_int;
    wire [31:0] ex_alu_result = ex_is_mdu ? muldiv_result : integer_result0;
    wire        ex_valid = issue0_valid_q;
    wire        ex_complete = ex_valid && (!ex_is_mdu || muldiv_done);
    wire        ex_branch_taken;
    wire        ex_branch_condition;
    wire [31:0] ex_branch_target;

    // The unit's internal busy flag is registered and is low for the first
    // cycle after an MDU uop enters issue0_q.  Hold the uop from the issue
    // register for that start cycle as well, otherwise a following lane-0
    // issue can overwrite a division before its completion returns.
    wire        muldiv_hold = issue0_valid_q && ex_is_mdu && !muldiv_done;
    wire        kill_issue0 = pipeline_flush && issue0_valid_q &&
        (system_flush || !recover_valid ||
         uop_is_younger(issue0_q.uop_id, recover_id));

    // Branch recovery is published as one registered event.  Target and ROB
    // tag are sampled together with the resolution result; ROB/RAT/frontend
    // therefore never observe a recovery pulse paired with the next uop's
    // combinational execute payload.
    // Only lane0's own unaccepted result or in-flight MDU operation can hold
    // lane0.  Lane1 and the frontend are independent of this local stall.
    // Do not let a younger ordered-lane uop enter the execute register while
    // a branch is resolving.  Recovery is intentionally registered, so
    // without this one-cycle interlock the fall-through branch can execute
    // before the older redirect pulse reaches all consumers and replace its
    // target (for example 0x1c0015ac with the loop-back at 0x1c0015a8).
    assign issue0_ready = !lane0_result_stall & !pipeline_flush &
                              !muldiv_hold &
                              !(issue0_valid_q && issue0_q.is_br_jmp);
    assign muldiv_busy = muldiv_hold;

    // Issue-to-execute state for lane 0.  This is the former one-cycle
    // issue/EX register, now local to the execution cluster.
    always @(posedge cpu_clk) begin
        if (!cpu_rstn) begin
            issue0_valid_q <= 1'b0;
            issue0_q       <= '0;
        end else if (kill_issue0) begin
            issue0_valid_q <= 1'b0;
            issue0_q       <= '0;
        end else if (!pipeline_flush && !lane0_result_stall && !muldiv_hold) begin
            issue0_valid_q <= issue0_fire;
            issue0_q       <= issue0;
        end
    end

    IntegerAluCore u_integer_alu_core (
        .alu_op (issue0_q.alu_op),
        .a      (ex_a),
        .b      (ex_b),
        .result (integer_result0)
    );

    MulDiv u_mul_div (
        .cpu_clk (cpu_clk),
        .cpu_rstn(cpu_rstn),
        .flush   (kill_issue0),
        // Do not let an invalid execute slot start the pipelined multiplier.
        // issue0_q may contain a non-handshaken queue payload even when
        // issue0_valid_q is clear; starting that ghost operation makes the
        // next real multiply consume its stale DSP result.
        .alu_op  (issue0_valid_q ? issue0_q.alu_op : 5'h0),
        .a       (ex_a),
        .b       (ex_b),
        .result  (muldiv_result),
        .done    (muldiv_done),
        .busy    (muldiv_busy_int)
    );

    assign alu_done = ex_is_mdu ? muldiv_done : 1'b1;

    BranchUnit u_branch_unit (
        .valid  (ex_valid),
        .stalled(lane0_result_stall | muldiv_hold),
        .npc_op (issue0_q.npc_op),
        .alu_op (issue0_q.alu_op),
        .pc     (issue0_q.pc),
        .src0   (issue0_q.src0_value),
        .src1   (issue0_q.src1_value),
        .offset (issue0_q.imm),
        .condition(ex_branch_condition),
        .taken  (ex_branch_taken),
        .target (ex_branch_target)
    );

    // Register the complete branch-resolution event before it fans out to
    // global control.  All event qualifiers are one-cycle pulses.
    always @(posedge cpu_clk or negedge cpu_rstn) begin
        if (!cpu_rstn) begin
            branch_mispredict <= 1'b0;
            redirect_valid    <= 1'b0;
            redirect_target   <= `PC_INIT_VAL;
            branch_recover_id <= '0;
            pipeline_flush    <= 1'b0;
        end else begin
            branch_mispredict <= pred_error;
            redirect_valid    <= pred_error;
            pipeline_flush    <= pred_error;
            if (pred_error) begin
                redirect_target   <= ex_branch_target;
                branch_recover_id <= issue0_q.uop_id;
            end
        end
    end

    logic ldst_unalign;
    always_comb begin
        case (issue0_q.load_ext_op)
            `RAM_EXT_H_S,
            `RAM_EXT_H_Z: ldst_unalign = (ex_alu_result[1:0] != 2'h0) &&
                                         (ex_alu_result[1:0] != 2'h2);
            `RAM_EXT_N:   ldst_unalign = (ex_alu_result[1:0] != 2'h0);
            default:      ldst_unalign = 1'b0;
        endcase
    end

    always_comb begin
        execute_result = '0;
        // A multiply/divide operation occupies the lane while its local
        // unit is busy.  Do not expose its initial/latched value to the ROB
        // as a completion before the unit asserts done.
        // A registered recovery pulse may arrive while a younger lane-0 uop
        // is already resident in the execute register.  Mask that killed uop
        // immediately; otherwise a younger branch can publish a second
        // redirect during the recovery cycle and overwrite the older,
        // architecturally correct target.
        execute_result.valid           = ex_complete && !kill_issue0;
        execute_result.uop_id          = issue0_q.uop_id;
        execute_result.pc              = issue0_q.pc;
        execute_result.src0_value      = issue0_q.src0_value;
        execute_result.src1_value      = issue0_q.src1_value;
        execute_result.store_data_ready = issue0_q.src1_ready;
        execute_result.store_data_src_id = issue0_q.src1_id;
        execute_result.imm             = issue0_q.imm;
        execute_result.alu_result      = ex_alu_result;
        execute_result.reg_write       = issue0_q.reg_write;
        execute_result.arch_rd         = issue0_q.arch_rd;
        execute_result.result_sel      = issue0_q.result_sel;
        execute_result.store_mask      = issue0_q.store_mask;
        execute_result.load_ext_op     = issue0_q.load_ext_op;
        execute_result.is_ld_st        = issue0_q.is_ld_st;
        execute_result.ldst_unalign    = ldst_unalign;
        execute_result.npc_op          = issue0_q.npc_op;
        execute_result.alu_flag        = (issue0_q.npc_op == `NPC_ALU) ?
                                         ex_branch_condition : 1'b0;
        execute_result.is_br_jmp       = issue0_q.is_br_jmp;
        execute_result.is_call         = issue0_q.is_call;
        execute_result.is_ret          = issue0_q.is_ret;
        execute_result.ras_ptr         = issue0_q.pred.ras_ptr;
        execute_result.branch_taken    = ex_branch_taken;
        execute_result.branch_target   = ex_branch_target;
        execute_result.writeback_value = (issue0_q.result_sel == `WD_ALU) ?
                                          ex_alu_result : 32'h1234_5678;
        execute_result.select_ram      = (issue0_q.load_ext_op != `N_RAM_EXT);
    end
endmodule
