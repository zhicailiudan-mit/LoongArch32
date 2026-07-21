`timescale 1ns / 1ps
`include "defines.vh"
import cpu_types_pkg::*;

// Dispatch allocates stores in program order. Execution only fills its
// already allocated entry; only the committed queue head can reach SB.
module StoreQueue #(parameter integer DEPTH = 4) (
    input logic clk, input logic rstn, input logic flush,
    input logic recover_valid, input logic system_flush, input uop_id_t recover_id,
    input logic alloc0_valid, input uop_id_t alloc0_id, input logic [31:0] alloc0_pc, output logic alloc0_ready,
    input logic alloc1_valid, input uop_id_t alloc1_id, input logic [31:0] alloc1_pc, output logic alloc1_ready,
    input logic write_valid, input lsu_entry_t write_entry,
    input commit_t commit0, input commit_t commit1,
    output logic release_valid, output lsu_entry_t release_entry, input logic release_fire,
    output logic [DEPTH-1:0] valid_vec, output logic [DEPTH-1:0] addr_ready_vec,
    output logic [DEPTH*32-1:0] addr_flat, output logic [DEPTH*`UOP_ID_W-1:0] uop_id_flat,
    output logic [DEPTH*4-1:0] store_wen_flat, output logic [DEPTH*32-1:0] store_data_flat,
    output logic [DEPTH*4*`UOP_ID_W-1:0] store_byte_uop_id_flat,
    output logic [$clog2(DEPTH+1)-1:0] occupancy
);
    localparam integer IW = (DEPTH <= 1) ? 1 : $clog2(DEPTH);
    localparam integer CW = $clog2(DEPTH+1);
    lsu_entry_t entries [0:DEPTH-1];
    logic valid [0:DEPTH-1], addr_ready [0:DEPTH-1], data_ready [0:DEPTH-1], committed [0:DEPTH-1];
    logic [IW-1:0] head, tail;
    logic [CW-1:0] count;
    // Keep loop variables local to one procedural process.  XSim otherwise
    // reports the shared variable as having multiple procedural drivers.
    integer comb_i, comb_b;
    integer seq_i, idx, kept;
    wire pop_do = release_fire && release_valid && !flush;
    wire alloc0_do = alloc0_valid && alloc0_ready;
    wire alloc1_do = alloc1_valid && alloc1_ready;
    wire [CW:0] free_slots = DEPTH - count;

    always_comb begin
        alloc0_ready = !flush && (free_slots != 0);
        alloc1_ready = !flush && (free_slots >= 2);
        release_valid = !flush && (count != 0) && valid[head] && committed[head] && addr_ready[head] && data_ready[head];
        release_entry = release_valid ? entries[head] : '0;
        valid_vec = '0; addr_ready_vec = '0; addr_flat = '0; uop_id_flat = '0;
        store_wen_flat = '0; store_data_flat = '0; store_byte_uop_id_flat = '0; occupancy = count;
        for (comb_i=0; comb_i<DEPTH; comb_i=comb_i+1) begin
            valid_vec[comb_i] = valid[comb_i]; addr_ready_vec[comb_i] = addr_ready[comb_i];
            addr_flat[comb_i*32 +: 32] = entries[comb_i].address;
            uop_id_flat[comb_i*`UOP_ID_W +: `UOP_ID_W] = entries[comb_i].uop_id;
            store_wen_flat[comb_i*4 +: 4] = entries[comb_i].store_wen;
            store_data_flat[comb_i*32 +: 32] = entries[comb_i].store_data;
            for (comb_b=0; comb_b<4; comb_b=comb_b+1) store_byte_uop_id_flat[(comb_i*4+comb_b)*`UOP_ID_W +: `UOP_ID_W] = entries[comb_i].uop_id;
        end
    end

    always_ff @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            head <= '0; tail <= '0; count <= '0;
            for (seq_i=0; seq_i<DEPTH; seq_i=seq_i+1) begin entries[seq_i] <= '0; valid[seq_i] <= 0; addr_ready[seq_i] <= 0; data_ready[seq_i] <= 0; committed[seq_i] <= 0; end
        end else if (flush) begin
            kept = 0;
            for (seq_i=0; seq_i<DEPTH; seq_i=seq_i+1) begin
                idx = (head + seq_i) & (DEPTH-1);
                if ((seq_i < count) && !system_flush && recover_valid && !uop_is_younger(entries[idx].uop_id, recover_id)) kept = kept + 1;
                else begin valid[idx] <= 0; addr_ready[idx] <= 0; data_ready[idx] <= 0; committed[idx] <= 0; entries[idx] <= '0; end
            end
            count <= kept[CW-1:0]; tail <= head + kept;
        end else begin
            for (seq_i=0; seq_i<DEPTH; seq_i=seq_i+1) begin
                if (valid[seq_i] && ((commit0.valid && uop_id_equal(entries[seq_i].uop_id, commit0.uop_id)) || (commit1.valid && uop_id_equal(entries[seq_i].uop_id, commit1.uop_id)))) committed[seq_i] <= 1'b1;
                if (write_valid && valid[seq_i] && uop_id_equal(entries[seq_i].uop_id, write_entry.uop_id)) begin
                    entries[seq_i].address <= write_entry.address; entries[seq_i].store_wen <= write_entry.store_wen; entries[seq_i].store_data <= write_entry.store_data;
                    addr_ready[seq_i] <= 1'b1; data_ready[seq_i] <= 1'b1;
                end
            end
            if (pop_do) begin valid[head] <= 0; addr_ready[head] <= 0; data_ready[head] <= 0; committed[head] <= 0; entries[head] <= '0; head <= head + 1'b1; end
            if (alloc0_do) begin entries[tail] <= '{valid:1'b1,uop_id:alloc0_id,pc:alloc0_pc,default:'0}; valid[tail] <= 1; addr_ready[tail] <= 0; data_ready[tail] <= 0; committed[tail] <= 0; end
            if (alloc1_do) begin entries[tail+alloc0_do] <= '{valid:1'b1,uop_id:alloc1_id,pc:alloc1_pc,default:'0}; valid[tail+alloc0_do] <= 1; addr_ready[tail+alloc0_do] <= 0; data_ready[tail+alloc0_do] <= 0; committed[tail+alloc0_do] <= 0; end
            if (alloc0_do || alloc1_do) tail <= tail + alloc0_do + alloc1_do;
            count <= count + alloc0_do + alloc1_do - pop_do;
        end
    end
endmodule
