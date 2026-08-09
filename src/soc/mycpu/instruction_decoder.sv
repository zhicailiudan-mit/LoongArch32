`timescale 1ns / 1ps

`include "mycpu_inst.vh"
`include "defines.vh"

import cpu_types_pkg::*;

// Unified pure-combinational instruction decoder.  CU owns the legacy
// integer controls; SystemDecode supplies the formats outside CU's slice.
// This module is the only place where those two control descriptions are
// merged into decoded_uop_t.
module InstructionDecoder (
    input  logic         valid,
    input  logic [31:0]  pc,
    input  logic [31:0]  instruction,
    input  logic [31:0]  rf_rdata0,
    input  logic [31:0]  rf_rdata1,
    output logic         decode_valid,
    output decoded_uop_t decoded_uop
);

    wire [2:0] id_ext_op;
    wire       id_r2_sel;
    wire       id_wr_sel;
    wire       normal_is_ld_st;
    wire       id_is_csr = (instruction[31:24] == 8'h04);
    wire       id_is_csrwr = id_is_csr && (instruction[9:5] == 5'h01);
    wire       id_is_csrxchg = id_is_csr &&
                               (instruction[9:5] != 5'h00) &&
                               (instruction[9:5] != 5'h01);

    wire [4:0] normal_src0_reg =
        (id_is_csrwr || id_is_csrxchg) ? instruction[4:0] : instruction[9:5];
    wire [4:0] normal_src1_reg = id_is_csrxchg ? instruction[9:5] :
                                 (id_r2_sel ? instruction[14:10] : instruction[4:0]);
    wire [4:0] normal_arch_rd = id_wr_sel ? instruction[4:0] : 5'h1;

    wire [1:0] normal_npc_op;
    wire       normal_is_br_jmp;
    wire       normal_is_call;
    wire       normal_is_ret;
    wire       normal_src0_used;
    wire       normal_src1_used;
    wire       normal_src_a_sel;
    wire       normal_src_b_sel;
    wire [4:0] normal_alu_op;
    wire [2:0] normal_load_ext_op;
    wire [3:0] normal_store_mask;
    wire       normal_reg_write;
    wire       alu_suspend_unused;
    wire [1:0] normal_result_sel;
    wire [31:0] normal_immediate;

    ControlUnit u_control_unit (
        .inst_31_15 (instruction[31:15]),
        .npc_op     (normal_npc_op),
        .is_br_jmp  (normal_is_br_jmp),
        .is_ld_st   (normal_is_ld_st),
        .is_call    (normal_is_call),
        .is_ret     (normal_is_ret),
        .ext_op     (id_ext_op),
        .r2_sel     (id_r2_sel),
        .rR1_re     (normal_src0_used),
        .rR2_re     (normal_src1_used),
        .alua_sel   (normal_src_a_sel),
        .alub_sel   (normal_src_b_sel),
        .alu_op     (normal_alu_op),
        .ram_ext_op (normal_load_ext_op),
        .ram_we     (normal_store_mask),
        .rf_we      (normal_reg_write),
        .alu_suspend(alu_suspend_unused),
        .wr_sel     (id_wr_sel),
        .wd_sel     (normal_result_sel)
    );

    ImmExtend u_imm_extend (
        .ext_op (id_ext_op),
        .din    (instruction[25:0]),
        .ext    (normal_immediate)
    );

    wire       system_valid;
    wire       system_active = valid && system_valid;
    system_op_e system_op;
    wire [4:0] system_src0_reg, system_src1_reg;
    wire system_src0_used, system_src1_used;
    wire system_reg_write, system_serializing;
    wire [4:0] system_arch_rd;
    wire [31:0] system_immediate;
    wire [13:0] system_csr_num;
    wire [4:0] system_cacop_op;

    SystemDecode u_system_decode (
        .instruction(instruction),
        .valid(system_valid),
        .system_op(system_op),
        .src0_reg(system_src0_reg),
        .src0_used(system_src0_used),
        .src1_reg(system_src1_reg),
        .src1_used(system_src1_used),
        .reg_write(system_reg_write),
        .arch_rd(system_arch_rd),
        .immediate(system_immediate),
        .csr_num(system_csr_num),
        .cacop_op(system_cacop_op),
        .serializing(system_serializing)
    );

    always_comb begin
        decode_valid = valid;
        decoded_uop = '0;
        decoded_uop.pc = pc;
        decoded_uop.src0.value = rf_rdata0;
        decoded_uop.src0.arch_reg = system_active ? system_src0_reg : normal_src0_reg;
        decoded_uop.src0.used = valid &&
                                (system_active ? system_src0_used : normal_src0_used);
        decoded_uop.src1.value = rf_rdata1;
        decoded_uop.src1.arch_reg = system_active ? system_src1_reg : normal_src1_reg;
        decoded_uop.src1.used = valid &&
                                (system_active ? system_src1_used : normal_src1_used);
        decoded_uop.imm = system_active ? system_immediate : normal_immediate;
        decoded_uop.npc_op = system_active ? `NPC_PC4 : normal_npc_op;
        decoded_uop.reg_write = valid &&
                                (system_active ? system_reg_write : normal_reg_write);
        decoded_uop.arch_rd = system_active ? system_arch_rd : normal_arch_rd;
        decoded_uop.result_sel = system_active ? `WD_ALU : normal_result_sel;
        decoded_uop.alu_op = system_active ? `ALU_ADD : normal_alu_op;
        decoded_uop.src_a_sel = system_active ? 1'b0 : normal_src_a_sel;
        decoded_uop.src_b_sel = system_active ? 1'b0 : normal_src_b_sel;
        decoded_uop.store_mask = system_active ? 4'b0000 : normal_store_mask;
        decoded_uop.load_ext_op = system_active ? `N_RAM_EXT : normal_load_ext_op;
        decoded_uop.is_br_jmp = valid &&
                                (system_active ? 1'b0 : normal_is_br_jmp);
        decoded_uop.is_ld_st = valid &&
                               (system_active ? 1'b0 : normal_is_ld_st);
        decoded_uop.is_call = valid &&
                              (system_active ? 1'b0 : normal_is_call);
        decoded_uop.is_ret = valid &&
                             (system_active ? 1'b0 : normal_is_ret);
        decoded_uop.system_op = system_active ? system_op : SYS_NONE;
        decoded_uop.csr_num = system_active ? system_csr_num : 14'h0;
        decoded_uop.cacop_op = system_active ? system_cacop_op : 5'h0;
        decoded_uop.serializing = system_active ? system_serializing : 1'b0;
        decoded_uop.pred = '0;
    end

endmodule
