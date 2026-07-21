`timescale 1ns/1ps

`include "defines.vh"

import cpu_types_pkg::*;

module tb_instruction_decoder;
    logic valid;
    logic [31:0] pc;
    logic [31:0] instruction;
    logic [31:0] rf_rdata0;
    logic [31:0] rf_rdata1;
    logic decode_valid;
    decoded_uop_t decoded_uop;

    InstructionDecoder dut (.*);

    task automatic check(input logic condition, input string message);
        if (!condition) begin
            $error("[DECODER-FAIL] %s", message);
            $fatal(1);
        end
    endtask

    initial begin
        valid = 1'b1;
        pc = 32'h1c02bd58;
        instruction = 32'h001c358f; // mul.w r15, r12, r13
        rf_rdata0 = 32'h56bedfa4;
        rf_rdata1 = 32'h20831400;
        #1;

        check(decode_valid, "mul.w must be a valid decoded uop");
        check(decoded_uop.system_op == SYS_NONE,
              "mul.w must not overlap a system instruction");
        check(decoded_uop.src0.used && decoded_uop.src1.used,
              "mul.w must consume both source registers");
        check(decoded_uop.src0.arch_reg == 5'h0c &&
              decoded_uop.src1.arch_reg == 5'h0d,
              "mul.w source register decode is wrong");
        check(decoded_uop.reg_write && decoded_uop.arch_rd == 5'h0f,
              "mul.w must write r15");
        check(decoded_uop.alu_op == `ALU_MULL,
              "mul.w must select ALU_MULL");
        check(decoded_uop.result_sel == `WD_ALU,
              "mul.w must select the MDU/ALU result path");

        $display("[DECODER-PASS] mul.w 0x001c358f control fields are correct");
        $finish;
    end
endmodule
