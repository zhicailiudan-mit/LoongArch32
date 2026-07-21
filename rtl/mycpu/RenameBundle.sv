`timescale 1ns / 1ps

import cpu_types_pkg::*;

// Two-lane elastic Decode->Rename boundary.
//
// This preserves the original RenameBundle timing and priority behavior,
// while storing decoded_uop_t directly instead of an arbitrary-width payload.
module RenameBundle (
    input  logic         clk,
    input  logic         rstn,
    input  logic         flush,
    input  logic         in_valid0,
    input  logic         in_valid1,
    output logic         in_ready,
    input  decoded_uop_t in_uop0,
    input  decoded_uop_t in_uop1,
    output logic         out_valid0,
    output logic         out_valid1,
    input  logic         out_ready,
    output decoded_uop_t out_uop0,
    output decoded_uop_t out_uop1,
    input  commit_t      commit0,
    input  commit_t      commit1
);

    decoded_uop_t uop0_q;
    decoded_uop_t uop1_q;
    decoded_uop_t uop0_next;
    decoded_uop_t uop1_next;
    logic         valid0_q;
    logic         valid1_q;
    logic         valid0_next;
    logic         valid1_next;

    assign in_ready  = !valid0_q || out_ready;
    assign out_valid0 = valid0_q;
    assign out_valid1 = valid1_q;
    assign out_uop0   = uop0_q;
    assign out_uop1   = uop1_q;

    wire commit0_dest_valid = commit0.valid && commit0.reg_write &&
                              (commit0.arch_rd != 5'h0);
    wire commit1_dest_valid = commit1.valid && commit1.reg_write &&
                              (commit1.arch_rd != 5'h0);
    wire lane0_src0_commit0 = commit0_dest_valid && valid0_q &&
        (uop0_q.src0.arch_reg == commit0.arch_rd);
    wire lane0_src1_commit0 = commit0_dest_valid && valid0_q &&
        (uop0_q.src1.arch_reg == commit0.arch_rd);
    wire lane1_src0_commit0 = commit0_dest_valid && valid1_q &&
        (uop1_q.src0.arch_reg == commit0.arch_rd);
    wire lane1_src1_commit0 = commit0_dest_valid && valid1_q &&
        (uop1_q.src1.arch_reg == commit0.arch_rd);
    wire lane0_src0_commit1 = commit1_dest_valid && valid0_q &&
        (uop0_q.src0.arch_reg == commit1.arch_rd);
    wire lane0_src1_commit1 = commit1_dest_valid && valid0_q &&
        (uop0_q.src1.arch_reg == commit1.arch_rd);
    wire lane1_src0_commit1 = commit1_dest_valid && valid1_q &&
        (uop1_q.src0.arch_reg == commit1.arch_rd);
    wire lane1_src1_commit1 = commit1_dest_valid && valid1_q &&
        (uop1_q.src1.arch_reg == commit1.arch_rd);

    always_comb begin
        uop0_next   = uop0_q;
        uop1_next   = uop1_q;
        valid0_next = valid0_q;
        valid1_next = valid1_q;

        // The old module gave the receive/replace path priority whenever
        // in_ready was true.  Consequently commit cannot modify a newly
        // accepted uop in the same cycle.
        if (in_ready) begin
            valid0_next = in_valid0;
            valid1_next = in_valid0 && in_valid1;
            if (in_valid0)
                uop0_next = in_uop0;
            if (in_valid0 && in_valid1)
                uop1_next = in_uop1;
        end else begin
            // The old payload implementation intentionally did not gate this
            // compare with rR*_re; preserve that behavior exactly.
            if (lane0_src0_commit0)
                uop0_next.src0.value = commit0.value;
            if (lane0_src1_commit0)
                uop0_next.src1.value = commit0.value;
            if (lane1_src0_commit0)
                uop1_next.src0.value = commit0.value;
            if (lane1_src1_commit0)
                uop1_next.src1.value = commit0.value;
            // commit1 is younger and therefore has priority if both commits
            // write the same architectural register in this cycle.
            if (lane0_src0_commit1)
                uop0_next.src0.value = commit1.value;
            if (lane0_src1_commit1)
                uop0_next.src1.value = commit1.value;
            if (lane1_src0_commit1)
                uop1_next.src0.value = commit1.value;
            if (lane1_src1_commit1)
                uop1_next.src1.value = commit1.value;
        end
    end

    always_ff @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            valid0_q <= 1'b0;
            valid1_q <= 1'b0;
            uop0_q   <= '0;
            uop1_q   <= '0;
        end else if (flush) begin
            valid0_q <= 1'b0;
            valid1_q <= 1'b0;
        end else begin
            valid0_q <= valid0_next;
            valid1_q <= valid1_next;
            uop0_q   <= uop0_next;
            uop1_q   <= uop1_next;
        end
    end

endmodule
