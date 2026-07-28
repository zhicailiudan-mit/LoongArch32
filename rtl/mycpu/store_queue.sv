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
    input completion_t complete0, input completion_t complete1,
    input commit_t commit0, input commit_t commit1,
    output logic release_valid, output lsu_entry_t release_entry,
    input logic release_fire,
    output logic [DEPTH-1:0] valid_vec,
    output logic [DEPTH-1:0] addr_ready_vec,
    output logic [DEPTH-1:0] store_data_ready_vec,
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

    function automatic [31:0] align_store_data(input [31:0] val, input [3:0] wen);
        begin
            case (wen)
                4'b0001: align_store_data = val[7:0] << 0;
                4'b0010: align_store_data = val[7:0] << 8;
                4'b0100: align_store_data = val[7:0] << 16;
                4'b1000: align_store_data = val[7:0] << 24;
                4'b0011: align_store_data = val[15:0] << 0;
                4'b1100: align_store_data = val[15:0] << 16;
                default: align_store_data = val;
            endcase
        end
    endfunction

    function automatic lsu_entry_t snoop_entry(
        input lsu_entry_t in_entry,
        input completion_t c0,
        input completion_t c1
    );
        begin
            snoop_entry = in_entry;
            if (in_entry.valid && !in_entry.store_data_ready) begin
                if (c0.valid && c0.reg_write && uop_id_equal(c0.uop_id, in_entry.store_data_src_id)) begin
                    snoop_entry.store_data = align_store_data(c0.value, in_entry.store_wen);
                    snoop_entry.store_data_ready = 1'b1;
                end else if (c1.valid && c1.reg_write && uop_id_equal(c1.uop_id, in_entry.store_data_src_id)) begin
                    snoop_entry.store_data = align_store_data(c1.value, in_entry.store_wen);
                    snoop_entry.store_data_ready = 1'b1;
                end
            end
        end
    endfunction

`ifndef SYNTHESIS
    localparam integer RELEASE_HISTORY_DEPTH = 16;
    logic release_history_valid [0:RELEASE_HISTORY_DEPTH-1];
    uop_id_t release_history_id [0:RELEASE_HISTORY_DEPTH-1];
    logic [31:0] release_history_pc [0:RELEASE_HISTORY_DEPTH-1];
    logic [63:0] release_history_serial [0:RELEASE_HISTORY_DEPTH-1];
    logic [63:0] entry_serial [0:DEPTH-1];
    logic [63:0] next_alloc_serial;
    wire [63:0] release_serial = oldest_found ? entry_serial[oldest_sel] : 64'd0;
`endif
    wire [COUNT_W:0] free_slots = DEPTH - count;
    wire both_valid = accept_valid && accept1_valid;
    wire accept1_older = both_valid && uop_is_younger(accept_entry.uop_id, accept1_entry.uop_id);
    wire accept_do = !flush && accept_valid && accept_ready;
    wire accept1_do = !flush && accept1_valid && accept1_ready;
    // A committed younger Store must never bypass an older Store which is
    // still waiting for its own ROB commit or its data to become ready.
    wire release_do = !flush && release_fire && oldest_found &&
                      committed[oldest_sel] && entries[oldest_sel].store_data_ready;

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
        release_valid = !flush && oldest_found && committed[oldest_sel] && entries[oldest_sel].store_data_ready;
        release_entry = release_valid ? entries[oldest_sel] : '0;
        valid_vec = '0;
        addr_ready_vec = '0;
        store_data_ready_vec = '0;
        addr_flat = '0;
        uop_id_flat = '0;
        store_wen_flat = '0;
        store_data_flat = '0;
        store_byte_uop_id_flat = '0;
        occupancy = count;
        for (i = 0; i < DEPTH; i = i + 1) begin
            valid_vec[i] = !flush && (i < count);
            addr_ready_vec[i] = !flush && (i < count);
            store_data_ready_vec[i] = !flush && (i < count) && entries[i].store_data_ready;
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
            for (q = 0; q < DEPTH; q = q + 1) begin
                entries[q] <= '0;
                committed[q] <= 1'b0;
`ifndef SYNTHESIS
                entry_serial[q] <= 64'd0;
`endif
            end
`ifndef SYNTHESIS
            next_alloc_serial <= 64'd1;
`endif
        end else if (flush) begin
            flush_dst = 0;
            for (q = 0; q < DEPTH; q = q + 1) begin
                if ((q < count) && (committed[q] ||
                    (commit0.valid && uop_id_equal(entries[q].uop_id, commit0.uop_id)) ||
                    (commit1.valid && uop_id_equal(entries[q].uop_id, commit1.uop_id)) ||
                    (!system_flush && recover_valid && !uop_is_younger(entries[q].uop_id, recover_id)))) begin
                    entries[flush_dst] <= snoop_entry(entries[q], complete0, complete1);
                    committed[flush_dst] <= committed[q] ||
                        (commit0.valid && uop_id_equal(entries[q].uop_id, commit0.uop_id)) ||
                        (commit1.valid && uop_id_equal(entries[q].uop_id, commit1.uop_id));
`ifndef SYNTHESIS
                    entry_serial[flush_dst] <= entry_serial[q];
`endif
                    flush_dst = flush_dst + 1;
                end
            end
            for (q = 0; q < DEPTH; q = q + 1) if (q >= flush_dst) begin
                entries[q] <= '0;
                committed[q] <= 1'b0;
`ifndef SYNTHESIS
                entry_serial[q] <= 64'd0;
`endif
            end
            count <= flush_dst;
        end else begin
            for (q = 0; q < DEPTH; q = q + 1)
                if ((q < count) && ((commit0.valid && uop_id_equal(entries[q].uop_id, commit0.uop_id)) ||
                                    (commit1.valid && uop_id_equal(entries[q].uop_id, commit1.uop_id)))) committed[q] <= 1'b1;
            if (release_do) begin
                for (j = 0; j < DEPTH-1; j = j + 1) begin
                    if ((j >= oldest_sel) && (j < count-1)) begin
                        entries[j] <= snoop_entry(entries[j+1], complete0, complete1);
                        committed[j] <= committed[j+1] ||
                            (commit0.valid && uop_id_equal(entries[j+1].uop_id, commit0.uop_id)) ||
                            (commit1.valid && uop_id_equal(entries[j+1].uop_id, commit1.uop_id));
`ifndef SYNTHESIS
                        entry_serial[j] <= entry_serial[j+1];
`endif
                    end else if (j >= oldest_sel) begin
                        entries[j] <= '0;
                        committed[j] <= 1'b0;
`ifndef SYNTHESIS
                        entry_serial[j] <= 64'd0;
`endif
                    end
                end
                entries[DEPTH-1] <= '0; committed[DEPTH-1] <= 1'b0;
`ifndef SYNTHESIS
                entry_serial[DEPTH-1] <= 64'd0;
`endif
            end else begin
                for (q = 0; q < DEPTH; q = q + 1) begin
                    if (q < count) begin
                        entries[q] <= snoop_entry(entries[q], complete0, complete1);
                    end
                end
            end
            if (accept_do && accept1_do) begin
`ifndef SYNTHESIS
                if (accept1_older) begin
                    entry_serial[release_do ? count-1 : count] <= next_alloc_serial + 64'd1;
                    entry_serial[(release_do ? count-1 : count) + 1] <= next_alloc_serial;
                end else begin
                    entry_serial[release_do ? count-1 : count] <= next_alloc_serial;
                    entry_serial[(release_do ? count-1 : count) + 1] <= next_alloc_serial + 64'd1;
                end
                next_alloc_serial <= next_alloc_serial + 64'd2;
`endif
            end else if (accept_do) begin
`ifndef SYNTHESIS
                entry_serial[release_do ? count-1 : count] <= next_alloc_serial;
                next_alloc_serial <= next_alloc_serial + 64'd1;
`endif
            end else if (accept1_do) begin
`ifndef SYNTHESIS
                entry_serial[release_do ? count-1 : count] <= next_alloc_serial;
                next_alloc_serial <= next_alloc_serial + 64'd1;
`endif
            end
            if (accept_do) begin
                entries[release_do ? count-1 : count] <= snoop_entry(accept_entry, complete0, complete1);
                committed[release_do ? count-1 : count] <=
                    (commit0.valid && uop_id_equal(accept_entry.uop_id, commit0.uop_id)) ||
                    (commit1.valid && uop_id_equal(accept_entry.uop_id, commit1.uop_id));
            end
            if (accept1_do) begin
                entries[(release_do ? count-1 : count) + accept_do] <= snoop_entry(accept1_entry, complete0, complete1);
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
                release_history_serial[h] <= 64'd0;
            end
        end else if (release_do) begin
            for (h = 0; h < RELEASE_HISTORY_DEPTH; h = h + 1)
                if (release_history_valid[h] &&
                    (release_history_serial[h] == release_serial))
                    $fatal(1, "StoreQueue released the same entry more than once");
            for (h = RELEASE_HISTORY_DEPTH-1; h > 0; h = h - 1) begin
                release_history_valid[h] <= release_history_valid[h-1];
                release_history_id[h] <= release_history_id[h-1];
                release_history_pc[h] <= release_history_pc[h-1];
                release_history_serial[h] <= release_history_serial[h-1];
            end
            release_history_valid[0] <= 1'b1;
            release_history_id[0] <= release_entry.uop_id;
            release_history_pc[0] <= release_entry.pc;
            release_history_serial[0] <= release_serial;
        end
    end

    // Simulation assertions for Store Address/Data Decoupling correctness
    always @(posedge clk) begin
        if (rstn && !flush) begin
            if (release_valid && !release_entry.store_data_ready) begin
                $fatal(1, "StoreQueue Assertion Violation: Releasing unready store entry to SB! uop_id=%p, pc=%x", release_entry.uop_id, release_entry.pc);
            end
        end
    end

`endif
endmodule
