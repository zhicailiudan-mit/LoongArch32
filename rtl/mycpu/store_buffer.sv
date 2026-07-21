`timescale 1ns / 1ps
import cpu_types_pkg::*;

// Committed-store buffer.
//
// Entries are still appended in ROB/StoreQueue order.  Adjacent stores to
// the same cache line share one line entry, while each word retains an age
// ordered list.  The external interface deliberately remains one word wide:
// the arbiter drains the oldest pending word, so line merging cannot reorder
// stores relative to a different line.
module StoreBuffer #(parameter integer DEPTH = 4) (
    input logic clk, input logic rstn,
    input logic accept_valid, input lsu_entry_t accept_entry,
    output logic accept_ready,
    output logic head_valid, output lsu_entry_t head_entry,
    input logic pop,
    output logic [DEPTH-1:0] valid_vec,
    output logic [DEPTH*32-1:0] addr_flat,
    output logic [DEPTH*`UOP_ID_W-1:0] uop_id_flat,
    output logic [DEPTH*4-1:0] store_wen_flat,
    output logic [DEPTH*32-1:0] store_data_flat,
    output logic [DEPTH*4*`UOP_ID_W-1:0] store_byte_uop_id_flat,
    output logic [$clog2(DEPTH+1)-1:0] occupancy,
    // Full-line notification used by the DCache direct-allocation path.
    input logic line_alloc_ready,
    output logic line_alloc_valid,
    output logic [31:0] line_alloc_addr,
    output logic [`CACHE_BLK_SIZE-1:0] line_alloc_data,
    output logic [`CACHE_BLK_LEN-1:0] line_alloc_word_mask
);
    localparam integer COUNT_W = $clog2(DEPTH + 1);
    localparam integer LINE_WORDS = `CACHE_BLK_LEN;
    localparam integer WORD_IW = (LINE_WORDS <= 1) ? 1 : $clog2(LINE_WORDS);
    localparam integer WORD_CW = $clog2(LINE_WORDS + 1);

    logic [31:5] line_addr [0:DEPTH-1];
    logic [31:0] word_data [0:DEPTH-1][0:LINE_WORDS-1];
    logic [3:0]  word_wen  [0:DEPTH-1][0:LINE_WORDS-1];
    logic [31:0] word_pc   [0:DEPTH-1][0:LINE_WORDS-1];
    uop_id_t     word_uop  [0:DEPTH-1][0:LINE_WORDS-1];
    uop_id_t     byte_uop  [0:DEPTH-1][0:LINE_WORDS-1][0:3];
    logic [LINE_WORDS-1:0] word_valid [0:DEPTH-1];
    logic [WORD_IW-1:0]    word_order [0:DEPTH-1][0:LINE_WORDS-1];
    logic [WORD_CW-1:0]    word_order_count [0:DEPTH-1];
    logic                   line_alloc_sent [0:DEPTH-1];
    logic [COUNT_W-1:0]     line_count;
    logic [COUNT_W-1:0]     word_count;


    wire [31:5] accept_line = accept_entry.address[31:5];
    wire [WORD_IW-1:0] accept_word = accept_entry.address[4 +: WORD_IW];
    wire tail_same_line = (line_count != 0) &&
                          (line_addr[line_count-1] == accept_line);
    wire tail_word_present = tail_same_line &&
                             word_valid[line_count-1][accept_word];
    wire can_append_line = (line_count < DEPTH);
    wire can_merge_line = tail_same_line &&
                          ((word_count < DEPTH) || tail_word_present);
    wire pop_do = pop && (line_count != 0) &&
                  (word_order_count[0] != 0);

    // Do not feed cache-side pop timing back into the StoreQueue ready path.
    // A simultaneous drain/accept is intentionally converted into a one-cycle
    // bubble; this is safe and keeps the critical path bounded.
    always_comb begin
        integer i, j, b;
        integer out_slot;
        integer word_idx;
        accept_ready = rstn && (can_merge_line || can_append_line) && !pop_do;
        line_alloc_valid = 1'b0;
        line_alloc_addr = 32'h0;
        line_alloc_data = '0;
        line_alloc_word_mask = '0;
        if ((line_count != 0) &&
            (word_order_count[0] == LINE_WORDS) &&
            !line_alloc_sent[0] &&
            (line_addr[0][31:16] != 16'hBFAF) &&
            (line_addr[0][31:16] != 16'hBFD0)) begin
            line_alloc_valid = 1'b1;
            // A word-count-complete line is not necessarily byte-complete:
            // eight byte stores can cover eight words only partially.  Direct
            // allocation is allowed only when every byte is supplied.
            for (j = 0; j < LINE_WORDS; j = j + 1)
                if (word_wen[0][j] != 4'hF)
                    line_alloc_valid = 1'b0;
            line_alloc_addr = {line_addr[0], 5'b0};
            line_alloc_word_mask = word_valid[0];
            for (j = 0; j < LINE_WORDS; j = j + 1)
                line_alloc_data[j*32 +: 32] = word_data[0][j];
        end

        head_valid = (line_count != 0) && (word_order_count[0] != 0);
        head_entry = '0;
        if (head_valid) begin
            word_idx = word_order[0][0];
            head_entry.valid = 1'b1;
            head_entry.uop_id = word_uop[0][word_idx];
            head_entry.pc = word_pc[0][word_idx];
            head_entry.address = {line_addr[0], 5'b0} | (word_idx << 2);
            head_entry.store_data = word_data[0][word_idx];
            head_entry.store_wen = word_wen[0][word_idx];
        end

        valid_vec = '0;
        addr_flat = '0;
        uop_id_flat = '0;
        store_wen_flat = '0;
        store_data_flat = '0;
        store_byte_uop_id_flat = '0;
        out_slot = 0;
        for (i = 0; i < DEPTH; i = i + 1) begin
            for (j = 0; j < LINE_WORDS; j = j + 1) begin
                if ((j < word_order_count[i]) && (out_slot < DEPTH)) begin
                    word_idx = word_order[i][j];
                    valid_vec[out_slot] = 1'b1;
                    addr_flat[out_slot*32 +: 32] = {line_addr[i], 5'b0} |
                                                   (word_idx << 2);
                    uop_id_flat[out_slot*`UOP_ID_W +: `UOP_ID_W] =
                        word_uop[i][word_idx];
                    store_wen_flat[out_slot*4 +: 4] = word_wen[i][word_idx];
                    store_data_flat[out_slot*32 +: 32] = word_data[i][word_idx];
                    for (b = 0; b < 4; b = b + 1)
                        store_byte_uop_id_flat[(out_slot*4+b)*`UOP_ID_W +: `UOP_ID_W] =
                            byte_uop[i][word_idx][b];
                    out_slot = out_slot + 1;
                end
            end
        end
        occupancy = word_count;
    end

    always_ff @(posedge clk or negedge rstn) begin
        integer i, j, b, k;
        integer found_word;
        integer merge_idx;
        if (!rstn) begin
            line_count <= '0;
            word_count <= '0;
            for (i = 0; i < DEPTH; i = i + 1) begin
                line_addr[i] <= '0;
                word_valid[i] <= '0;
                word_order_count[i] <= '0;
                line_alloc_sent[i] <= 1'b0;
                for (j = 0; j < LINE_WORDS; j = j + 1) begin
                    word_data[i][j] <= '0;
                    word_wen[i][j] <= '0;
                    word_pc[i][j] <= '0;
                    word_uop[i][j] <= '0;
                    word_order[i][j] <= '0;
                    for (b = 0; b < 4; b = b + 1)
                        byte_uop[i][j][b] <= '0;
                end
            end
        end else begin
            // The full-line request is accepted before any word drain.  The
            // LSU suppresses the normal StoreBuffer head while this valid bit
            // is asserted, so there is no cache write/allocation collision.
            if (line_alloc_valid && line_alloc_ready)
                line_alloc_sent[0] <= 1'b1;

            if (pop_do) begin
                if (word_order_count[0] > 1) begin
                    word_valid[0][word_order[0][0]] <= 1'b0;
                    for (j = 0; j < LINE_WORDS-1; j = j + 1) begin
                        if (j < word_order_count[0]-1)
                            word_order[0][j] <= word_order[0][j+1];
                        else
                            word_order[0][j] <= '0;
                    end
                    word_order[0][LINE_WORDS-1] <= '0;
                    word_order_count[0] <= word_order_count[0] - 1'b1;
                    word_count <= word_count - 1'b1;
                end else begin
                    for (i = 0; i < DEPTH-1; i = i + 1) begin
                        line_addr[i] <= line_addr[i+1];
                        word_valid[i] <= word_valid[i+1];
                        word_order_count[i] <= word_order_count[i+1];
                        line_alloc_sent[i] <= line_alloc_sent[i+1];
                        for (j = 0; j < LINE_WORDS; j = j + 1) begin
                            word_data[i][j] <= word_data[i+1][j];
                            word_wen[i][j] <= word_wen[i+1][j];
                            word_pc[i][j] <= word_pc[i+1][j];
                            word_uop[i][j] <= word_uop[i+1][j];
                            word_order[i][j] <= word_order[i+1][j];
                            for (b = 0; b < 4; b = b + 1)
                                byte_uop[i][j][b] <= byte_uop[i+1][j][b];
                        end
                    end
                    line_addr[DEPTH-1] <= '0;
                    word_valid[DEPTH-1] <= '0;
                    word_order_count[DEPTH-1] <= '0;
                    line_alloc_sent[DEPTH-1] <= 1'b0;
                    for (j = 0; j < LINE_WORDS; j = j + 1) begin
                        word_data[DEPTH-1][j] <= '0;
                        word_wen[DEPTH-1][j] <= '0;
                        word_pc[DEPTH-1][j] <= '0;
                        word_uop[DEPTH-1][j] <= '0;
                        word_order[DEPTH-1][j] <= '0;
                        for (b = 0; b < 4; b = b + 1)
                            byte_uop[DEPTH-1][j][b] <= '0;
                    end
                    line_count <= line_count - 1'b1;
                    word_count <= word_count - 1'b1;
                end
            end

            if (accept_valid && accept_ready) begin
                merge_idx = (line_count == 0) ? 0 : line_count - 1;
                if (tail_same_line) begin
                    // Find an existing word in the tail line.  If it exists,
                    // merge only the newly written bytes; otherwise append a
                    // new word to the line's age list.
                    found_word = 0;
                    for (k = 0; k < LINE_WORDS; k = k + 1)
                        if ((k < word_order_count[merge_idx]) &&
                            (word_order[merge_idx][k] == accept_word))
                            found_word = 1;
                    if (!found_word) begin
                        word_order[merge_idx][word_order_count[merge_idx]] <= accept_word;
                        word_order_count[merge_idx] <= word_order_count[merge_idx] + 1'b1;
                        word_count <= word_count + 1'b1;
                    end
                    for (b = 0; b < 4; b = b + 1) begin
                        if (accept_entry.store_wen[b]) begin
                            word_data[merge_idx][accept_word][b*8 +: 8] <=
                                accept_entry.store_data[b*8 +: 8];
                            byte_uop[merge_idx][accept_word][b] <= accept_entry.uop_id;
                        end
                    end
                    word_wen[merge_idx][accept_word] <=
                        word_wen[merge_idx][accept_word] | accept_entry.store_wen;
                    if (!found_word) begin
                        word_pc[merge_idx][accept_word] <= accept_entry.pc;
                        word_uop[merge_idx][accept_word] <= accept_entry.uop_id;
                        word_valid[merge_idx][accept_word] <= 1'b1;
                    end
                    line_alloc_sent[merge_idx] <= 1'b0;
                end else if (can_append_line) begin
                    line_addr[line_count] <= accept_line;
                    word_valid[line_count] <= '0;
                    word_order_count[line_count] <= 1;
                    line_alloc_sent[line_count] <= 1'b0;
                    word_order[line_count][0] <= accept_word;
                    word_valid[line_count][accept_word] <= 1'b1;
                    word_data[line_count][accept_word] <= accept_entry.store_data;
                    word_wen[line_count][accept_word] <= accept_entry.store_wen;
                    word_pc[line_count][accept_word] <= accept_entry.pc;
                    word_uop[line_count][accept_word] <= accept_entry.uop_id;
                    for (b = 0; b < 4; b = b + 1)
                        byte_uop[line_count][accept_word][b] <= accept_entry.uop_id;
                    line_count <= line_count + 1'b1;
                    word_count <= word_count + 1'b1;
                end
            end
        end
    end
endmodule
