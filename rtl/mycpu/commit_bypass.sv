`timescale 1ns / 1ps

import cpu_types_pkg::*;

// Architectural-register commit bypass used at the decode/RF boundary.
// commit1 is younger than commit0 and therefore has priority on a same-cycle
// write-after-write collision.
module CommitBypass (
    input  logic       source_used,
    input  logic [4:0] arch_reg,
    input  logic [31:0] base_value,
    input  commit_t    commit0,
    input  commit_t    commit1,
    output logic       hit,
    output logic [31:0] value
);
    always_comb begin
        hit = 1'b0;
        value = base_value;
        if (source_used && (arch_reg != 5'h0) &&
            commit0.valid && commit0.reg_write &&
            (arch_reg == commit0.arch_rd)) begin
            hit = 1'b1;
            value = commit0.value;
        end
        if (source_used && (arch_reg != 5'h0) &&
            commit1.valid && commit1.reg_write &&
            (arch_reg == commit1.arch_rd)) begin
            hit = 1'b1;
            value = commit1.value;
        end
    end
endmodule
