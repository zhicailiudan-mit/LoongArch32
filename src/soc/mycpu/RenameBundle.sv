`timescale 1ns / 1ps

import cpu_types_pkg::*;

// Two-entry ordered elastic buffer at the Rename -> Dispatch boundary.
// Lane 0 is always the oldest resident uop.  out_pop_count may remove zero,
// one, or both entries, and accepted input is appended behind any survivor.
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
    input  logic [1:0]   out_pop_count,
    output decoded_uop_t out_uop0,
    output decoded_uop_t out_uop1,
    output logic [1:0]   occupancy,
    input  commit_t      commit0,
    input  commit_t      commit1
);

    decoded_uop_t uop0_q, uop1_q;
    decoded_uop_t uop0_next, uop1_next;
    decoded_uop_t held0, held1;
    logic [1:0] count_q, count_next;
    logic [1:0] input_count;
    logic [1:0] survivor_count;
    logic       push_input;

    wire commit0_dest_valid = commit0.valid && commit0.reg_write &&
                              (commit0.arch_rd != 5'h0);
    wire commit1_dest_valid = commit1.valid && commit1.reg_write &&
                              (commit1.arch_rd != 5'h0);

    assign out_valid0 = (count_q != 0);
    assign out_valid1 = (count_q == 2);
    assign out_uop0 = uop0_q;
    assign out_uop1 = uop1_q;
    assign occupancy = count_q;

    always_comb begin
        input_count = in_valid0 ? (in_valid1 ? 2'd2 : 2'd1) : 2'd0;
        survivor_count = count_q - out_pop_count;
        in_ready = (input_count <= (2 - survivor_count));
        push_input = in_ready && in_valid0;

        // Commit values remain authoritative while an entry waits in the
        // buffer.  The younger commit has priority for equal destinations.
        held0 = uop0_q;
        held1 = uop1_q;
        if (commit0_dest_valid && (count_q != 0)) begin
            if (held0.src0.used && (held0.src0.arch_reg == commit0.arch_rd))
                held0.src0.value = commit0.value;
            if (held0.src1.used && (held0.src1.arch_reg == commit0.arch_rd))
                held0.src1.value = commit0.value;
        end
        if (commit0_dest_valid && (count_q == 2)) begin
            if (held1.src0.used && (held1.src0.arch_reg == commit0.arch_rd))
                held1.src0.value = commit0.value;
            if (held1.src1.used && (held1.src1.arch_reg == commit0.arch_rd))
                held1.src1.value = commit0.value;
        end
        if (commit1_dest_valid && (count_q != 0)) begin
            if (held0.src0.used && (held0.src0.arch_reg == commit1.arch_rd))
                held0.src0.value = commit1.value;
            if (held0.src1.used && (held0.src1.arch_reg == commit1.arch_rd))
                held0.src1.value = commit1.value;
        end
        if (commit1_dest_valid && (count_q == 2)) begin
            if (held1.src0.used && (held1.src0.arch_reg == commit1.arch_rd))
                held1.src0.value = commit1.value;
            if (held1.src1.used && (held1.src1.arch_reg == commit1.arch_rd))
                held1.src1.value = commit1.value;
        end

        uop0_next = '0;
        uop1_next = '0;
        case (out_pop_count)
            2'd0: begin
                if (count_q != 0) uop0_next = held0;
                if (count_q == 2) uop1_next = held1;
            end
            2'd1: begin
                if (count_q == 2) uop0_next = held1;
            end
            default: begin end
        endcase

        // Append the complete ordered input packet after the survivors.
        if (push_input) begin
            if (survivor_count == 0) begin
                uop0_next = in_uop0;
                if (in_valid1) uop1_next = in_uop1;
            end else begin
                uop1_next = in_uop0;
            end
        end
        count_next = survivor_count + (push_input ? input_count : 0);
    end

    always_ff @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            count_q <= 0;
            uop0_q <= '0;
            uop1_q <= '0;
        end else if (flush) begin
            count_q <= 0;
            uop0_q <= '0;
            uop1_q <= '0;
        end else begin
            count_q <= count_next;
            uop0_q <= uop0_next;
            uop1_q <= uop1_next;
        end
    end


endmodule
