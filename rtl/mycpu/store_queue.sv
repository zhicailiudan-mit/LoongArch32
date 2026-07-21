`timescale 1ns / 1ps
`include "defines.vh"
import cpu_types_pkg::*;

module StoreQueue #(parameter integer DEPTH = 4) (
    input logic clk, input logic rstn,
    input logic flush,
    input logic recover_valid, input logic system_flush,
    input uop_id_t recover_id,
    input logic accept_valid, input lsu_entry_t accept_entry,
    output logic accept_ready,
    input logic accept1_valid, input lsu_entry_t accept1_entry,
    output logic accept1_ready,
    input commit_t commit0, input commit_t commit1,
    output logic release_valid, output lsu_entry_t release_entry,
    input logic release_fire,
    output logic [DEPTH-1:0] valid_vec,
    output logic [DEPTH-1:0] addr_ready_vec,
    output logic [DEPTH*32-1:0] addr_flat,
    output logic [DEPTH*`UOP_ID_W-1:0] uop_id_flat,
    output logic [DEPTH*4-1:0] store_wen_flat,
    output logic [DEPTH*32-1:0] store_data_flat,
    output logic [DEPTH*4*`UOP_ID_W-1:0] store_byte_uop_id_flat,
    output logic [$clog2(DEPTH+1)-1:0] occupancy
);
    localparam integer COUNT_W = $clog2(DEPTH + 1);
    localparam integer INDEX_W = (DEPTH <= 1) ? 1 : $clog2(DEPTH);
    lsu_entry_t entries [0:DEPTH-1];
    logic committed [0:DEPTH-1];
    logic [COUNT_W-1:0] count;
    logic [INDEX_W-1:0] oldest_sel;
    logic oldest_found;
    integer i, j, q, byte_i;
    integer flush_dst;
`ifndef SYNTHESIS
    localparam integer RELEASE_HISTORY_DEPTH = 16;
    logic release_history_valid [0:RELEASE_HISTORY_DEPTH-1];
    uop_id_t release_history_id [0:RELEASE_HISTORY_DEPTH-1];
    logic [31:0] release_history_pc [0:RELEASE_HISTORY_DEPTH-1];
`endif
    wire [COUNT_W:0] free_slots = DEPTH - count;
    wire both_valid = accept_valid && accept1_valid;
    wire accept1_older = both_valid && uop_is_younger(accept_entry.uop_id, accept1_entry.uop_id);
    wire accept_do = !flush && accept_valid && accept_ready;
    wire accept1_do = !flush && accept1_valid && accept1_ready;
    // A committed younger Store must never bypass an older Store which is
    // still waiting for its own ROB commit. Select the oldest queue entry
    // first, then test that entry's commit bit.
    wire release_do = !flush && release_fire && oldest_found &&
                      committed[oldest_sel];

    always_comb begin
        accept_ready = 1'b0;
        accept1_ready = 1'b0;
        if (!flush && free_slots != 0) begin
            if (free_slots >= 2) begin
                accept_ready = 1'b1;
                accept1_ready = 1'b1;
            end else if (!both_valid) begin
                accept_ready = accept_valid;
                accept1_ready = accept1_valid;
            end else if (accept1_older) accept1_ready = 1'b1;
            else accept_ready = 1'b1;
        end
        oldest_found = 1'b0;
        oldest_sel = '0;
        for (i = 0; i < DEPTH; i = i + 1)
            if ((i < count) &&
                (!oldest_found ||
                 uop_is_younger(entries[oldest_sel].uop_id, entries[i].uop_id))) begin
                oldest_found = 1'b1;
                oldest_sel = i[INDEX_W-1:0];
            end
        release_valid = !flush && oldest_found && committed[oldest_sel];
        release_entry = release_valid ? entries[oldest_sel] : '0;
        valid_vec = '0;
        addr_ready_vec = '0;
        addr_flat = '0;
        uop_id_flat = '0;
        store_wen_flat = '0;
        store_data_flat = '0;
        store_byte_uop_id_flat = '0;
        occupancy = count;
        for (i = 0; i < DEPTH; i = i + 1) begin
            valid_vec[i] = !flush && (i < count);
            addr_ready_vec[i] = !flush && (i < count);
            addr_flat[i*32 +: 32] = entries[i].address;
            uop_id_flat[i*`UOP_ID_W +: `UOP_ID_W] = entries[i].uop_id;
            store_wen_flat[i*4 +: 4] = entries[i].store_wen;
            store_data_flat[i*32 +: 32] = entries[i].store_data;
            for (byte_i = 0; byte_i < 4; byte_i = byte_i + 1)
                store_byte_uop_id_flat[(i*4 + byte_i)*`UOP_ID_W +: `UOP_ID_W] = entries[i].uop_id;
        end
    end

    always_ff @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            count <= '0;
            for (q = 0; q < DEPTH; q = q + 1) begin entries[q] <= '0; committed[q] <= 1'b0; end
        end else if (flush) begin
            flush_dst = 0;
            for (q = 0; q < DEPTH; q = q + 1) begin
                if ((q < count) && (committed[q] ||
                    (commit0.valid && uop_id_equal(entries[q].uop_id, commit0.uop_id)) ||
                    (commit1.valid && uop_id_equal(entries[q].uop_id, commit1.uop_id)) ||
                    (!system_flush && recover_valid && !uop_is_younger(entries[q].uop_id, recover_id)))) begin
                    entries[flush_dst] <= entries[q];
                    committed[flush_dst] <= committed[q] ||
                        (commit0.valid && uop_id_equal(entries[q].uop_id, commit0.uop_id)) ||
                        (commit1.valid && uop_id_equal(entries[q].uop_id, commit1.uop_id));
                    flush_dst = flush_dst + 1;
                end
            end
            for (q = 0; q < DEPTH; q = q + 1) if (q >= flush_dst) begin entries[q] <= '0; committed[q] <= 1'b0; end
            count <= flush_dst;
        end else begin
            for (q = 0; q < DEPTH; q = q + 1)
                if ((q < count) && ((commit0.valid && uop_id_equal(entries[q].uop_id, commit0.uop_id)) ||
                                    (commit1.valid && uop_id_equal(entries[q].uop_id, commit1.uop_id)))) committed[q] <= 1'b1;
            if (release_do) begin
                for (j = 0; j < DEPTH-1; j = j + 1) begin
                    if ((j >= oldest_sel) && (j < count-1)) begin
                        entries[j] <= entries[j+1];
                        committed[j] <= committed[j+1] ||
                            (commit0.valid && uop_id_equal(entries[j+1].uop_id, commit0.uop_id)) ||
                            (commit1.valid && uop_id_equal(entries[j+1].uop_id, commit1.uop_id));
                    end else if (j >= oldest_sel) begin entries[j] <= '0; committed[j] <= 1'b0; end
                end
                entries[DEPTH-1] <= '0; committed[DEPTH-1] <= 1'b0;
            end
            if (accept_do) begin
                entries[release_do ? count-1 : count] <= accept_entry;
                committed[release_do ? count-1 : count] <=
                    (commit0.valid && uop_id_equal(accept_entry.uop_id, commit0.uop_id)) ||
                    (commit1.valid && uop_id_equal(accept_entry.uop_id, commit1.uop_id));
            end
            if (accept1_do) begin
                entries[(release_do ? count-1 : count) + accept_do] <= accept1_entry;
                committed[(release_do ? count-1 : count) + accept_do] <=
                    (commit0.valid && uop_id_equal(accept1_entry.uop_id, commit0.uop_id)) ||
                    (commit1.valid && uop_id_equal(accept1_entry.uop_id, commit1.uop_id));
            end
            count <= count - release_do + accept_do + accept1_do;
        end
    end

`ifndef SYNTHESIS
    // A StoreQueue release is a one-way transfer into StoreBuffer.  If the
    // same queue entry is presented for release twice, the architectural
    // memory trace would contain a duplicate Store.  Keep a bounded history
    // so a duplicate separated by other releases is caught as well.
    always @(posedge clk or negedge rstn) begin
        integer h;
        if (!rstn || flush) begin
            for (h = 0; h < RELEASE_HISTORY_DEPTH; h = h + 1) begin
                release_history_valid[h] <= 1'b0;
                release_history_id[h] <= '0;
                release_history_pc[h] <= 32'h0;
            end
        end else if (release_do) begin
            for (h = 0; h < RELEASE_HISTORY_DEPTH; h = h + 1)
                if (release_history_valid[h] &&
                    uop_id_equal(release_history_id[h], release_entry.uop_id) &&
                    (release_history_pc[h] == release_entry.pc))
                    $fatal(1, "StoreQueue released the same entry more than once");
            for (h = RELEASE_HISTORY_DEPTH-1; h > 0; h = h - 1) begin
                release_history_valid[h] <= release_history_valid[h-1];
                release_history_id[h] <= release_history_id[h-1];
                release_history_pc[h] <= release_history_pc[h-1];
            end
            release_history_valid[0] <= 1'b1;
            release_history_id[0] <= release_entry.uop_id;
            release_history_pc[0] <= release_entry.pc;
        end
    end


`endif
endmodule
