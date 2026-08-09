`timescale 1ns / 1ps

import cpu_types_pkg::*;

// Decode owns one architectural register file and two unified pure
// combinational decoders.  Control merging is in InstructionDecoder; this
// boundary only performs RF access, commit bypass and valid propagation.
module DecodeCluster (
    input  logic                     clk,
    input  logic                     flush,
    input  logic [1:0]               fetch_valid,
    output logic                     fetch_ready,
    input  fetch_uop_t               fetch_uop0,
    input  fetch_uop_t               fetch_uop1,
    output logic [1:0]               decode_valid,
    input  logic                     decode_ready,
    output decoded_uop_t             decode_uop0,
    output decoded_uop_t             decode_uop1,
    input  commit_t                  commit0,
    input  commit_t                  commit1
);

    decoded_uop_t decoded_lane0, decoded_lane1;
    wire lane_valid0, lane_valid1;
    logic [4:0] rf_rR0, rf_rR1, rf_rR2, rf_rR3;
    wire [31:0] rf_rD0, rf_rD1, rf_rD2, rf_rD3;
    wire lane0_src0_hit, lane0_src1_hit, lane1_src0_hit, lane1_src1_hit;
    wire [31:0] lane0_src0_value, lane0_src1_value;
    wire [31:0] lane1_src0_value, lane1_src1_value;

    InstructionDecoder u_instr_decoder_0 (
        .valid(fetch_valid[0]),
        .pc(fetch_uop0.pc),
        .instruction(fetch_uop0.instruction),
        .rf_rdata0(rf_rD0),
        .rf_rdata1(rf_rD1),
        .decode_valid(lane_valid0),
        .decoded_uop(decoded_lane0)
    );

    InstructionDecoder u_instr_decoder_1 (
        .valid(fetch_valid[1]),
        .pc(fetch_uop1.pc),
        .instruction(fetch_uop1.instruction),
        .rf_rdata0(rf_rD2),
        .rf_rdata1(rf_rD3),
        .decode_valid(lane_valid1),
        .decoded_uop(decoded_lane1)
    );

    assign rf_rR0 = decoded_lane0.src0.arch_reg;
    assign rf_rR1 = decoded_lane0.src1.arch_reg;
    assign rf_rR2 = decoded_lane1.src0.arch_reg;
    assign rf_rR3 = decoded_lane1.src1.arch_reg;

    RegFile u_reg_file (
        .cpu_clk(clk),
        .rR1(rf_rR0), .rR2(rf_rR1), .rR3(rf_rR2), .rR4(rf_rR3),
        .we(commit0.valid && commit0.reg_write),
        .wR(commit0.arch_rd), .wD(commit0.value),
        .we1(commit1.valid && commit1.reg_write),
        .wR1(commit1.arch_rd), .wD1(commit1.value),
        .rD1(rf_rD0), .rD2(rf_rD1), .rD3(rf_rD2), .rD4(rf_rD3)
    );

    CommitBypass u_bypass_lane0_src0 (
        .source_used(decoded_lane0.src0.used),
        .arch_reg(decoded_lane0.src0.arch_reg),
        .base_value(rf_rD0), .commit0(commit0), .commit1(commit1),
        .hit(lane0_src0_hit), .value(lane0_src0_value)
    );
    CommitBypass u_bypass_lane0_src1 (
        .source_used(decoded_lane0.src1.used),
        .arch_reg(decoded_lane0.src1.arch_reg),
        .base_value(rf_rD1), .commit0(commit0), .commit1(commit1),
        .hit(lane0_src1_hit), .value(lane0_src1_value)
    );
    CommitBypass u_bypass_lane1_src0 (
        .source_used(decoded_lane1.src0.used),
        .arch_reg(decoded_lane1.src0.arch_reg),
        .base_value(rf_rD2), .commit0(commit0), .commit1(commit1),
        .hit(lane1_src0_hit), .value(lane1_src0_value)
    );
    CommitBypass u_bypass_lane1_src1 (
        .source_used(decoded_lane1.src1.used),
        .arch_reg(decoded_lane1.src1.arch_reg),
        .base_value(rf_rD3), .commit0(commit0), .commit1(commit1),
        .hit(lane1_src1_hit), .value(lane1_src1_value)
    );

    assign fetch_ready = decode_ready;
    assign decode_valid[0] = lane_valid0 && !flush;
    assign decode_valid[1] = lane_valid1 && !flush;

    always_comb begin
        decode_uop0 = decoded_lane0;
        decode_uop0.pred = fetch_uop0.pred;
        decode_uop0.src0.value = lane0_src0_value;
        decode_uop0.src1.value = lane0_src1_value;

        decode_uop1 = decoded_lane1;
        decode_uop1.pred = fetch_uop1.pred;
        decode_uop1.src0.value = lane1_src0_value;
        decode_uop1.src1.value = lane1_src1_value;
    end

endmodule
