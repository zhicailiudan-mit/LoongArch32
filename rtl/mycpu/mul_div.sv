`timescale 1ns / 1ps

`include "defines.vh"

// Lane-local multiply execution unit. DIV/MOD are intentionally not
// implemented for the supervisor build, so no divider IP is instantiated.
module MulDiv (
    input  logic        cpu_clk,
    input  logic        cpu_rstn,
    input  logic        flush,
    input  logic [4:0]  alu_op,
    input  logic [31:0] a,
    input  logic [31:0] b,
    output logic [31:0] result,
    output logic        done,
    output logic        busy
);
    wire is_mul_w   = (alu_op == `ALU_MULL);
    wire is_mulh_w  = (alu_op == `ALU_MULH);
    wire is_mulh_wu = (alu_op == `ALU_UMUL);
    wire is_mul     = is_mul_w | is_mulh_w | is_mulh_wu;
    wire is_unsigned = is_mulh_wu;

    wire [32:0] ext_a = is_unsigned ? {1'b0, a} : {a[31], a};
    wire [32:0] ext_b = is_unsigned ? {1'b0, b} : {b[31], b};
    wire [65:0] mul_dout;
    logic [2:0] mul_wait_cnt;
    logic [65:0] mul_res_latch;

    always @(posedge cpu_clk or negedge cpu_rstn) begin
        if (!cpu_rstn) begin
            mul_wait_cnt  <= 3'b000;
            mul_res_latch <= 66'h0;
        end else if (flush) begin
            // A squashed multiply must release the lane immediately. ROB
            // tags may be reused before the old DSP pipeline drains.
            mul_wait_cnt  <= 3'b000;
            mul_res_latch <= 66'h0;
        end else if (is_mul && (mul_wait_cnt == 3'b000)) begin
            mul_wait_cnt <= 3'b001;
        end else if (mul_wait_cnt != 3'b000) begin
            if (mul_wait_cnt == 3'b100) begin
                mul_wait_cnt  <= 3'b000;
                mul_res_latch <= mul_dout;
            end else begin
                mul_wait_cnt <= mul_wait_cnt + 1'b1;
            end
        end
    end

    wire mul_done = (mul_wait_cnt == 3'b100);

    mult_gen_0 u_mult (
        .CLK (cpu_clk),
        .A   (ext_a),
        .B   (ext_b),
        .P   (mul_dout)
    );

    always_comb begin
        result = 32'h0;
        case (alu_op)
            `ALU_MULL: result = mul_done ? mul_dout[31:0]  : mul_res_latch[31:0];
            `ALU_MULH,
            `ALU_UMUL: result = mul_done ? mul_dout[63:32] : mul_res_latch[63:32];
            default: result = 32'h0;
        endcase
        done = is_mul ? mul_done : 1'b1;
        busy = is_mul && (mul_wait_cnt != 3'b000) && !mul_done;
    end
endmodule
