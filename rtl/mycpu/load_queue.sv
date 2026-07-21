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
    output logic [DEPTH-1:0] valid_vec,
    output logic [DEPTH*32-1:0] addr_flat,
    output logic [$clog2(DEPTH+1)-1:0] occupancy
);
    localparam integer COUNT_W = $clog2(DEPTH + 1);
    lsu_entry_t entries [0:DEPTH-1];
    logic issued [0:DEPTH-1];
    // Keep the synthesized occupancy arithmetic at its architectural width.
    // An integer made this four-entry queue a 32-bit counter/comparator and
    // placed three CARRY4 levels on the LSU completion critical path.
    logic [COUNT_W-1:0] count;
    integer i;
    integer q;
    integer flush_dst;
    wire pop_do = pop && (count != 0);
    wire accept_do = accept_valid && accept_ready;
    wire accept1_do = accept1_valid && accept1_ready;
    // Deliberately do not include pop_do here.  The queue no longer exposes
    // a combinational pop-to-ready bypass: a response frees the slot on the
    // clock edge, and a new load is admitted on the following cycle.  This
    // removes the queue/cache/LSU ready loop from the load completion path.
    wire [COUNT_W:0] free_slots = DEPTH - count;
    wire both_load_valid = accept_valid && accept1_valid;
    // Lane 1 may be an older held result than the current lane-0 result.
    // When only one slot is available, the older load must win admission;
    // otherwise repeated younger lane-0 loads can starve lane 1.
    wire accept1_older = both_load_valid &&
                         uop_is_younger(accept_entry.uop_id,
                                        accept1_entry.uop_id);

    always_comb begin
        // Do not let a same-cycle pop feed back into ready.  This costs one
        // cycle only when the queue is full, but cuts the long completion
        // path through the LSU and DCache handshake.
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
        addr_flat = '0;
        occupancy = count;
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
            flush_dst = 0;
            for (q = 0; q < DEPTH; q = q + 1) begin
                // A cache response may arrive in the same cycle as branch
                // recovery.  The arbiter has already completed ownership of
                // entry zero in that case, so recovery must not preserve its
                // stale issued copy.  Otherwise an issued head remains while
                // the arbiter is IDLE and permanently blocks all later loads.
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
                    // Lane 1 is older, so preserve age order after the pop.
                    entries[count-1] <= accept1_entry;
                    entries[count-1].valid <= 1'b1;
                    issued[count-1] <= 1'b0;
                    entries[count] <= accept_entry;
                    entries[count].valid <= 1'b1;
                    issued[count] <= 1'b0;
                end else begin
                    if (accept_do) begin
                        // Replace the slot removed from the tail after the
                        // compaction.  The queue occupancy remains unchanged.
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
                    // Lane 1 is older, so insert it before lane 0.
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
            if (issue_mark && !pop_do && (count != 0)) issued[0] <= 1'b1;
        end
    end

endmodule
