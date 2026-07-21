`timescale 1ns / 1ps
import cpu_types_pkg::*;

module StoreBuffer #(parameter integer DEPTH = 4) (
    input logic clk, input logic rstn,
    input logic accept_valid, input lsu_entry_t accept_entry,
    output logic accept_ready,
    output logic head_valid, output lsu_entry_t head_entry,
    input logic pop,
    output logic [DEPTH-1:0] valid_vec,
    output logic [DEPTH*32-1:0] addr_flat
);
    lsu_entry_t entries [0:DEPTH-1];
    integer count;
    integer i;
    integer q;
    wire pop_do = pop && (count != 0);
    wire accept_do = accept_valid && ((count < DEPTH) || pop_do);
    always_comb begin
        // The arbiter can retire the current head while a committed store is
        // released from StoreQueue in the same cycle.
        accept_ready = (count < DEPTH) || pop_do;
        head_valid = (count != 0);
        head_entry = '0;
        if (count != 0) head_entry = entries[0];
        valid_vec = '0;
        addr_flat = '0;
        for (i = 0; i < DEPTH; i = i + 1) begin
            valid_vec[i] = (i < count);
            addr_flat[i*32 +: 32] = entries[i].address;
        end
    end
    always_ff @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            count <= 0;
            for (q = 0; q < DEPTH; q = q + 1) entries[q] <= '0;
        end else begin
            if (pop_do) begin
                for (q = 0; q < DEPTH-1; q = q + 1) begin
                    if (q < count-1) entries[q] <= entries[q+1];
                    else entries[q] <= '0;
                end
                entries[DEPTH-1] <= '0;
            end
            if (accept_do) begin
                if (pop_do) begin
                    entries[count-1] <= accept_entry;
                    entries[count-1].valid <= 1'b1;
                end else begin
                    entries[count] <= accept_entry;
                    entries[count].valid <= 1'b1;
                end
            end
            case ({pop_do, accept_do})
                2'b10: count <= count - 1;
                2'b01: count <= count + 1;
                default: begin end
            endcase
        end
    end
endmodule
