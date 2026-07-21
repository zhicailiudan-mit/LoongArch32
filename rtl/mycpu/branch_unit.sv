`timescale 1ns / 1ps

`include "defines.vh"

// Branch resolution unit for the main execution lane.  It preserves the
// existing NPC choices and comparison encodings while making branch result
// generation an explicit execution-cluster unit.
module BranchUnit (
    input  logic        valid,
    input  logic        stalled,
    input  logic [1:0]  npc_op,
    input  logic [4:0]  alu_op,
    input  logic [31:0] pc,
    input  logic [31:0] src0,
    input  logic [31:0] src1,
    input  logic [31:0] offset,
    output logic        condition,
    output logic        taken,
    output logic [31:0] target
);
    logic compare_taken;

    always_comb begin
        case (alu_op)
            `ALU_EQU : compare_taken = (src0 == src1);
            `ALU_UEQU: compare_taken = (src0 != src1);
            `ALU_LES : compare_taken = ($signed(src0) <  $signed(src1));
            `ALU_ULES: compare_taken = (src0 < src1);
            `ALU_MOR : compare_taken = ($signed(src0) >= $signed(src1));
            `ALU_UMOR: compare_taken = (src0 >= src1);
            default  : compare_taken = 1'b0;
        endcase

        target = pc + 32'd4;
        case (npc_op)
            `NPC_ALU : if (compare_taken) target = pc + offset;
            `NPC_RET : target = src0 + offset;
            `NPC_CALL: target = pc + offset;
            default  : target = pc + 32'd4;
        endcase

        condition = compare_taken;
        taken = valid && !stalled &&
                (((npc_op == `NPC_ALU) && compare_taken) ||
                 (npc_op == `NPC_RET) ||
                 (npc_op == `NPC_CALL));
    end
endmodule

