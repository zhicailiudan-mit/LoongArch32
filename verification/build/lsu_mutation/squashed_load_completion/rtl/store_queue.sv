`timescale 1ns / 1ps
`include "defines.vh"
import cpu_types_pkg::*;

module StoreQueue #(parameter integer DEPTH = 4) (
    input logic clk, input logic rstn,
    input logic flush,
    input logic accept_valid, input lsu_entry_t accept_entry,
    output logic accept_ready,
    input commit_t commit0, input commit_t commit1,
    output logic release_valid, output lsu_entry_t release_entry,
    input logic release_fire,
    output logic [DEPTH-1:0] valid_vec,
    output logic [DEPTH*32-1:0] addr_flat
);
    lsu_entry_t entries [0:DEPTH-1];
    logic committed [0:DEPTH-1];
    logic [15:0] seq [0:DEPTH-1];
    logic [15:0] next_seq;
    integer count;
    integer i;
    integer j;
    integer q;
    integer sel;
    integer flush_dst;
    logic found;
    wire accept_commit0 = commit0.valid &&
                          (commit0.rob_tag == accept_entry.rob_tag);
    wire accept_commit1 = commit1.valid &&
                          (commit1.rob_tag == accept_entry.rob_tag);
    wire release_do = !flush && release_fire && found;
    wire accept_do = !flush && accept_valid && accept_ready;

    always_comb begin
        // A release and a new execute-side store may occupy the same slot.
        accept_ready = !flush && ((count < DEPTH) || release_do);
        release_valid = 1'b0;
        release_entry = '0;
        found = 1'b0;
        sel = 0;
        for (i = 0; i < DEPTH; i = i + 1) begin
            if ((i < count) && committed[i] && (!found || (seq[i] < seq[sel]))) begin
                found = 1'b1;
                sel = i;
            end
        end
        if (found && !flush) begin
            release_valid = 1'b1;
            release_entry = entries[sel];
        end
        valid_vec = '0;
        addr_flat = '0;
        for (i = 0; i < DEPTH; i = i + 1) begin
            valid_vec[i] = !flush && (i < count);
            addr_flat[i*32 +: 32] = entries[i].address;
        end
    end

    always_ff @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            count <= 0;
            next_seq <= 0;
            for (q = 0; q < DEPTH; q = q + 1) begin
                entries[q] <= '0; committed[q] <= 1'b0; seq[q] <= '0;
            end
        end else if (flush) begin
            // Entries already marked committed represent architectural stores
            // and must survive a younger-branch recovery.  Remove only
            // speculative StoreQueue entries; StoreBuffer contents are already
            // committed and are intentionally left untouched by LSU flush.
            flush_dst = 0;
            for (q = 0; q < DEPTH; q = q + 1) begin
                if ((q < count) && (committed[q] ||
                    (commit0.valid && entries[q].rob_tag == commit0.rob_tag) ||
                    (commit1.valid && entries[q].rob_tag == commit1.rob_tag))) begin
                    entries[flush_dst] <= entries[q];
                    entries[flush_dst].valid <= 1'b1;
                    committed[flush_dst] <= 1'b1;
                    seq[flush_dst] <= seq[q];
                    flush_dst = flush_dst + 1;
                end
            end
            for (q = flush_dst; q < DEPTH; q = q + 1) begin
                entries[q] <= '0;
                committed[q] <= 1'b0;
                seq[q] <= '0;
            end
            count <= flush_dst;
        end else begin
            // Commit tags make stores eligible for the store buffer.  This
            // is deliberately tag based; the ROB remains the age authority.
            for (q = 0; q < DEPTH; q = q + 1) begin
                if ((q < count) && !committed[q] && commit0.valid &&
                    (entries[q].rob_tag == commit0.rob_tag)) begin
                    committed[q] <= 1'b1;
                    seq[q] <= next_seq;
                end else if ((q < count) && !committed[q] && commit1.valid &&
                             (entries[q].rob_tag == commit1.rob_tag)) begin
                    committed[q] <= 1'b1;
                    seq[q] <= next_seq + (commit0.valid ? 16'd1 : 16'd0);
                end
            end
            if (commit0.valid || commit1.valid)
                next_seq <= next_seq + commit0.valid + commit1.valid;
            if (release_do) begin
                for (j = 0; j < DEPTH-1; j = j + 1) begin
                    if (j >= sel && j < count-1) begin
                        entries[j] <= entries[j+1];
                        // Compaction and commit may target the same destination
                        // slot in this cycle.  Fold commit into the entry being
                        // moved; otherwise this later NBA would overwrite the
                        // commit-loop update made at the old array index.
                        if (committed[j+1]) begin
                            committed[j] <= 1'b1;
                            seq[j] <= seq[j+1];
                        end else if (commit0.valid &&
                                     (entries[j+1].rob_tag == commit0.rob_tag)) begin
                            committed[j] <= 1'b1;
                            seq[j] <= next_seq;
                        end else if (commit1.valid &&
                                     (entries[j+1].rob_tag == commit1.rob_tag)) begin
                            committed[j] <= 1'b1;
                            seq[j] <= next_seq +
                                      (commit0.valid ? 16'd1 : 16'd0);
                        end else begin
                            committed[j] <= 1'b0;
                            seq[j] <= seq[j+1];
                        end
                    end else if (j >= sel) begin
                        entries[j] <= '0; committed[j] <= 1'b0; seq[j] <= '0;
                    end
                end
                entries[DEPTH-1] <= '0; committed[DEPTH-1] <= 1'b0; seq[DEPTH-1] <= '0;
            end
            if (accept_do) begin
                if (release_do) begin
                    entries[count-1] <= accept_entry;
                    entries[count-1].valid <= 1'b1;
                    committed[count-1] <= accept_commit0 || accept_commit1;
                    seq[count-1] <= next_seq +
                                    ((commit0.valid && !accept_commit0) ? 16'd1 : 16'd0);
                end else begin
                    entries[count] <= accept_entry;
                    entries[count].valid <= 1'b1;
                    committed[count] <= accept_commit0 || accept_commit1;
                    seq[count] <= next_seq +
                                  ((commit0.valid && !accept_commit0) ? 16'd1 : 16'd0);
                end
            end
            case ({release_do, accept_do})
                2'b10: count <= count - 1;
                2'b01: count <= count + 1;
                default: begin end
            endcase
        end
    end
endmodule
