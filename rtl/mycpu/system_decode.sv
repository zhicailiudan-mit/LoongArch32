`timescale 1ns / 1ps

import cpu_types_pkg::*;

// Decode the system formats that do not fit the legacy CU input slice.
// Operand 0 is the value/source operand and operand 1 is the CSRXCHG mask.
module SystemDecode (
    input  logic [31:0] instruction,
    output logic        valid,
    output system_op_e  system_op,
    output logic [4:0]  src0_reg,
    output logic        src0_used,
    output logic [4:0]  src1_reg,
    output logic        src1_used,
    output logic        reg_write,
    output logic [4:0]  arch_rd,
    output logic [31:0] immediate,
    output logic [13:0] csr_num,
    output logic [4:0]  cacop_op,
    output logic        serializing
);

    wire is_cpucfg = (instruction[31:15] == 17'h0001b);
    wire is_cacop  = (instruction[31:22] == 10'h018);
    wire is_csr    = (instruction[31:24] == 8'h04);

    always_comb begin
        valid       = is_cpucfg | is_cacop | is_csr;
        system_op   = SYS_NONE;
        src0_reg    = 5'h0;
        src0_used   = 1'b0;
        src1_reg    = 5'h0;
        src1_used   = 1'b0;
        reg_write   = 1'b0;
        arch_rd     = instruction[4:0];
        immediate   = 32'h0;
        csr_num     = instruction[23:10];
        cacop_op    = instruction[4:0];
        serializing = 1'b0;

        if (is_cpucfg) begin
            system_op = SYS_CPUCFG;
            src0_reg  = instruction[9:5];
            src0_used = 1'b1;
            reg_write = 1'b1;
        end else if (is_cacop) begin
            system_op   = SYS_CACOP;
            src0_reg    = instruction[9:5];
            src0_used   = 1'b1;
            immediate   = {{20{instruction[21]}}, instruction[21:10]};
            reg_write   = 1'b0;
            serializing = 1'b1;
        end else if (is_csr) begin
            reg_write = 1'b1;
            if (instruction[9:5] == 5'h00) begin
                system_op = SYS_CSRRD;
            end else if (instruction[9:5] == 5'h01) begin
                system_op   = SYS_CSRWR;
                src0_reg    = instruction[4:0];
                src0_used   = 1'b1;
                serializing = 1'b1;
            end else begin
                system_op   = SYS_CSRXCHG;
                src0_reg    = instruction[4:0];
                src0_used   = 1'b1;
                src1_reg    = instruction[9:5];
                src1_used   = 1'b1;
                serializing = 1'b1;
            end
        end
    end

endmodule
