`timescale 1ns / 1ps

`include "defines.vh"

// Integer execution lane 0.  Multiply/divide and branch comparison are
// deliberately separate units; this unit contains only the single-cycle
// integer result operations used by the main execution lane.
module IntegerAluCore (
    input  logic [4:0]  alu_op,
    input  logic [31:0] a,
    input  logic [31:0] b,
    output logic [31:0] result
);
    always_comb begin
        case (alu_op)
            `ALU_ADD : result = a + b;
            `ALU_SUB : result = a - b;
            `ALU_AND : result = a & b;
            `ALU_OR  : result = a | b;
            `ALU_XOR : result = a ^ b;
            `ALU_NOR : result = ~(a | b);
            `ALU_SLL : result = a << b[4:0];
            `ALU_SRL : result = a >> b[4:0];
            `ALU_SRA : result = $signed(a) >>> b[4:0];
            `ALU_COP : result = b;
            `ALU_PC4 : result = a + 32'd4;
            `ALU_COM : result = ($signed(a) < $signed(b)) ? 32'h1 : 32'h0;
            `ALU_UCOM: result = (a < b) ? 32'h1 : 32'h0;
            default  : result = 32'h0;
        endcase
    end
endmodule

