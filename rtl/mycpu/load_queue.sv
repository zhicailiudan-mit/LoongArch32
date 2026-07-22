`timescale 1ns / 1ps
`include "defines.vh"
import cpu_types_pkg::*;

module LoadQueue #(parameter integer DEPTH = 4) (
    input  logic clk, input logic rstn,
    input  logic flush,
    input  logic recover_valid, input logic system_flush,
    input  uop_id_t recover_id,
    input  logic accept_valid, input lsu_entry_t accept_entry,
    output logic accept_ready,
    input  logic accept1_valid, input lsu_entry_t accept1_entry,
    output logic accept1_ready,
    output logic head_valid, output lsu_entry_t head_entry,
    input logic issue_mark, input logic pop,
    output logic [DEPTH-1:0] unissued_vec,
    output lsu_entry_t entries_flat [0:DEPTH-1],
    input  logic [$clog2(DEPTH>1?$clog2(DEPTH):1):0] issue_idx,
    output logic [DEPTH-1:0] valid_vec,
    output logic [DEPTH*32-1:0] addr_flat,
    output logic [$clog2(DEPTH+1)-1:0] occupancy
);
    localparam integer COUNT_W = $clog2(DEPTH + 1);
    lsu_entry_t entries [0:DEPTH-1];
    logic issued [0:DEPTH-1];
    logic [COUNT_W-1:0] count;
    integer i;
    integer q;
    integer flush_dst;
    wire pop_do = pop && (count != 0);
    wire accept_do = accept_valid && accept_ready;
    wire accept1_do = accept1_valid && accept1_ready;
    wire [COUNT_W:0] free_slots = DEPTH - count;
    wire both_load_valid = accept_valid && accept1_valid;
    wire accept1_older = both_load_valid &&
                         uop_is_younger(accept_entry.uop_id,
                                        accept1_entry.uop_id);

    always_comb begin
        accept_ready = 1'b0;
        accept1_ready = 1'b0;
        if (!flush && (free_slots != 0)) begin
            if (free_slots >= 2) begin
                accept_ready = 1'b1;
                accept1_ready = 1'b1;
            end else if (!both_load_valid) begin
                accept_ready = accept_valid;
                accept1_ready = accept1_valid;
            end else if (accept1_older) begin
                accept1_ready = 1'b1;
            end else begin
                accept_ready = 1'b1;
            end
        end
        head_valid = !flush && (count != 0) && !issued[0];
        head_entry = '0;
        if (count != 0) head_entry = entries[0];
        valid_vec = '0;
        unissued_vec = '0;
        addr_flat = '0;
        occupancy = count;
        for (i = 0; i < DEPTH; i = i + 1) begin
            valid_vec[i] = !flush && (i < count);
            unissued_vec[i] = !flush && (i < count) && !issued[i];
            entries_flat[i] = entries[i];
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
            flush_dst = 0;
            for (q = 0; q < DEPTH; q = q + 1) begin
                if (!(pop_do && (q == 0)) &&
                    !system_flush && recover_valid && (q < count) &&
                    !uop_is_younger(entries[q].uop_id, recover_id)) begin
                    entries[flush_dst] <= entries[q];
                    issued[flush_dst] <= issued[q];
                    flush_dst = flush_dst + 1;
                end
            end
            for (q = 0; q < DEPTH; q = q + 1) begin
                if (q >= flush_dst) begin
                    entries[q] <= '0;
                    issued[q] <= 1'b0;
                end
            end
            count <= flush_dst;
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
                if (accept1_do && accept_do && accept1_older) begin
                    entries[count-1] <= accept1_entry;
                    entries[count-1].valid <= 1'b1;
                    issued[count-1] <= 1'b0;
                    entries[count] <= accept_entry;
                    entries[count].valid <= 1'b1;
                    issued[count] <= 1'b0;
                end else begin
                    if (accept_do) begin
                        entries[count-1] <= accept_entry;
                        entries[count-1].valid <= 1'b1;
                        issued[count-1] <= 1'b0;
                    end
                    if (accept1_do) begin
                        entries[count-1 + accept_do] <= accept1_entry;
                        entries[count-1 + accept_do].valid <= 1'b1;
                        issued[count-1 + accept_do] <= 1'b0;
                    end
                end
            end else begin
                if (accept1_do && accept_do && accept1_older) begin
                    entries[count] <= accept1_entry;
                    entries[count].valid <= 1'b1;
                    issued[count] <= 1'b0;
                    entries[count+1] <= accept_entry;
                    entries[count+1].valid <= 1'b1;
                    issued[count+1] <= 1'b0;
                end else begin
                    if (accept_do) begin
                        entries[count] <= accept_entry;
                        entries[count].valid <= 1'b1;
                        issued[count] <= 1'b0;
                    end
                    if (accept1_do) begin
                        entries[count + accept_do] <= accept1_entry;
                        entries[count + accept_do].valid <= 1'b1;
                        issued[count + accept_do] <= 1'b0;
                    end
                end
            end
            count <= count - pop_do + accept_do + accept1_do;
            if (issue_mark) begin
                if (pop_do) begin
                    if (issue_idx > 0) issued[issue_idx - 1] <= 1'b1;
                end else begin
                    if (issue_idx < count) issued[issue_idx] <= 1'b1;
                end
            end
        end
    end

`ifndef SYNTHESIS
    always @(posedge clk) begin
        if (rstn) begin
            if (count > DEPTH) $fatal(1, "LoadQueue count overflow");
            if (pop && count == 0) $error("LoadQueue pop when empty");
        end
    end
`endif

endmodule
