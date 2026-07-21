`timescale 1ns/1ps
`include "defines.vh"
import cpu_types_pkg::*;

// Lightweight behavioral stand-in for the generated multiplier. The test is
// for lane control/handshake; IP latency is owned by MulDiv's wait counter.
module mult_gen_0 (
    input  wire        CLK,
    input  wire [32:0] A,
    input  wire [32:0] B,
    output wire [65:0] P
);
    assign P = $signed(A) * $signed(B);
    wire unused_clk = CLK;
endmodule

module tb_integer_lane1_mdu;
    logic clk = 0;
    logic rstn = 0;
    logic flush = 0;
    logic result_stall = 0;
    logic issue_ready;
    logic issue_valid = 0;
    logic [`ROB_TAG_W-1:0] issue_rob_tag = '0;
    logic [31:0] issue_pc = 0;
    logic [31:0] issue_src0 = 0;
    logic [31:0] issue_src1 = 0;
    logic [31:0] issue_imm = 0;
    logic issue_reg_write = 0;
    logic [4:0] issue_arch_rd = 0;
    logic [1:0] issue_result_sel = `WD_ALU;
    logic [4:0] issue_alu_op = 0;
    logic issue_src_a_sel = 1;
    logic issue_src_b_sel = 1;
    logic [3:0] issue_store_mask = `RAM_WE_N;
    logic [2:0] issue_load_ext_op = `N_RAM_EXT;
    logic issue_is_ld_st = 0;
    execute_result_t execute_result;
    logic complete_valid;
    logic [`ROB_TAG_W-1:0] complete_tag;
    logic [31:0] complete_value;
    logic complete_reg_write;

    always #5 clk = ~clk;

    IntegerAluLane1 dut (.*);

    task automatic fail(input string message);
        $display("[LANE1-MDU-FAIL] %s", message);
        $fatal(1);
    endtask

    task automatic send_mul(
        input logic [`ROB_TAG_W-1:0] tag,
        input logic [4:0] op,
        input logic [31:0] a,
        input logic [31:0] b
    );
        begin
            @(negedge clk);
            if (!issue_ready)
                fail("driver attempted multiply while lane was not ready");
            issue_valid = 1;
            issue_rob_tag = tag;
            issue_src0 = a;
            issue_src1 = b;
            issue_reg_write = 1;
            issue_alu_op = op;
            @(negedge clk);
            issue_valid = 0;
        end
    endtask

    initial begin
        integer cycles;
        repeat (3) @(posedge clk);
        rstn = 1;

        send_mul(4'h3, `ALU_MULL, 32'd7, 32'd9);
        if (issue_ready)
            fail("lane did not backpressure while multiply was in flight");
        cycles = 0;
        while (!complete_valid && cycles < 10) begin
            @(negedge clk);
            cycles = cycles + 1;
        end
        if (!complete_valid || complete_tag != 4'h3 ||
            complete_value != 32'd63 || !complete_reg_write)
            fail("lane1 multiply completion payload was incorrect");

        // Flush an in-flight multiply and ensure its old tag never completes.
        send_mul(4'h4, `ALU_MULL, 32'd11, 32'd13);
        repeat (2) @(negedge clk);
        flush = 1;
        @(negedge clk);
        flush = 0;
        if (!issue_ready)
            fail("flush did not release lane1 MDU");
        repeat (7) begin
            @(negedge clk);
            if (complete_valid && complete_tag == 4'h4)
                fail("squashed lane1 multiply completed after flush");
        end

        $display("[LANE1-MDU-PASS]");
        $finish;
    end
endmodule
