`timescale 1ns / 1ps
`include "defines.vh"
import cpu_types_pkg::*;

module LoadQueue #(parameter integer DEPTH = 4) (
    input  logic clk, input logic rstn,
    input  logic flush,
    input  logic accept_valid, input lsu_entry_t accept_entry,
    output logic accept_ready,
    output logic head_valid, output lsu_entry_t head_entry,
    input logic issue_mark, input logic pop,
    output logic [DEPTH-1:0] valid_vec,
    output logic [DEPTH*32-1:0] addr_flat
);
    lsu_entry_t entries [0:DEPTH-1];
    logic issued [0:DEPTH-1];
    integer count;
    integer i;
    integer q;
    wire pop_do = pop && (count != 0);
    wire accept_do = accept_valid && accept_ready;

    always_comb begin
        // A response and a new load may share the last free slot.  This is
        // the normal one-entry replacement case for a serialized cache port.
        accept_ready = !flush && ((count < DEPTH) || pop_do);
        head_valid = !flush && (count != 0) && !issued[0];
        head_entry = '0;
        if (count != 0) head_entry = entries[0];
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
            for (q = 0; q < DEPTH; q = q + 1) begin
                entries[q] <= '0;
                issued[q] <= 1'b0;
            end
        end else if (flush) begin
            count <= 0;
            for (q = 0; q < DEPTH; q = q + 1) begin
                entries[q] <= '0;
                issued[q] <= 1'b0;
            end
        end else begin
            if (pop_do) begin
                for (q = 0; q < DEPTH-1; q = q + 1) begin
                    if (q < count-1) begin
                        entries[q] <= entries[q+1];
                        issued[q] <= issued[q+1];
                    end else begin
                        entries[q] <= '0;
                        issued[q] <= 1'b0;
                    end
                end
                entries[DEPTH-1] <= '0;
                issued[DEPTH-1] <= 1'b0;
                if (accept_do) begin
                    // Replace the slot removed from the tail after the
                    // compaction.  The queue occupancy remains unchanged.
                    entries[count-1] <= accept_entry;
                    entries[count-1].valid <= 1'b1;
                    issued[count-1] <= 1'b0;
                end else begin
                    count <= count - 1;
                end
            end else if (accept_do) begin
                entries[count] <= accept_entry;
                entries[count].valid <= 1'b1;
                issued[count] <= 1'b0;
                count <= count + 1;
            end
            if (issue_mark && !pop_do && (count != 0)) issued[0] <= 1'b1;
        end
    end
endmodule
