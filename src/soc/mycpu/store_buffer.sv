`timescale 1ns / 1ps
import cpu_types_pkg::*;

// Correctness-mode committed Store FIFO.
// Each architectural Store occupies one entry and leaves in FIFO order.
module StoreBuffer #(parameter integer DEPTH = 4) (
    input  logic clk,
    input  logic rstn,
    input  logic accept_valid,
    input  lsu_entry_t accept_entry,
    output logic accept_ready,
    output logic head_valid,
    output lsu_entry_t head_entry,
    input  logic pop,
    output logic [DEPTH-1:0] valid_vec,
    output logic [DEPTH*32-1:0] addr_flat,
    output logic [DEPTH*`UOP_ID_W-1:0] uop_id_flat,
    output logic [DEPTH*4-1:0] store_wen_flat,
    output logic [DEPTH*32-1:0] store_data_flat,
    output logic [DEPTH*4*`UOP_ID_W-1:0] store_byte_uop_id_flat,
    output logic [$clog2(DEPTH+1)-1:0] occupancy,
    // Kept for wrapper compatibility.  Full-line allocation is disabled.
    input  logic line_alloc_ready,
    output logic line_alloc_valid,
    output logic [31:0] line_alloc_addr,
    output logic [`CACHE_BLK_SIZE-1:0] line_alloc_data,
    output logic [`CACHE_BLK_LEN-1:0] line_alloc_word_mask
);
    localparam integer PTR_W = (DEPTH <= 1) ? 1 : $clog2(DEPTH);
    localparam integer COUNT_W = $clog2(DEPTH + 1);

    lsu_entry_t entries [0:DEPTH-1];
    logic [PTR_W-1:0] read_ptr;
    logic [PTR_W-1:0] write_ptr;
    logic [COUNT_W-1:0] count;

    wire pop_do = pop && (count != 0);
    wire push_do = accept_valid && accept_ready;
    wire [31:0] accept_addr_aligned = accept_entry.address;
    wire [COUNT_W:0] count_next = {1'b0, count} +
                                   {{COUNT_W{1'b0}}, push_do} -
                                   {{COUNT_W{1'b0}}, pop_do};
    lsu_entry_t accepted_entry_aligned;

    function automatic [PTR_W-1:0] ptr_next(input [PTR_W-1:0] ptr);
        begin
            if (ptr == DEPTH-1)
                ptr_next = 0;
            else
                ptr_next = ptr + 1'b1;
        end
    endfunction

    always @(*) begin
        accepted_entry_aligned = accept_entry;
        accepted_entry_aligned.valid = 1'b1;
        accepted_entry_aligned.address = accept_addr_aligned;
    end

    always @(*) begin : fifo_outputs
        integer i;
        integer b;
        integer idx;

        accept_ready = rstn && (count < DEPTH);
        head_valid = (count != 0);
        head_entry = '0;
        if (head_valid)
            head_entry = entries[read_ptr];

        valid_vec = '0;
        addr_flat = '0;
        uop_id_flat = '0;
        store_wen_flat = '0;
        store_data_flat = '0;
        store_byte_uop_id_flat = '0;
        occupancy = count;

        // The flat forwarding view is the same FIFO in age order.  All
        // fields in one slot come from one fifo_mem entry.
        for (i = 0; i < DEPTH; i = i + 1) begin
            idx = read_ptr + i;
            if (idx >= DEPTH)
                idx = idx - DEPTH;
            if (i < count) begin
                valid_vec[i] = entries[idx].valid;
                addr_flat[i*32 +: 32] = entries[idx].address;
                uop_id_flat[i*`UOP_ID_W +: `UOP_ID_W] = entries[idx].uop_id;
                store_wen_flat[i*4 +: 4] = entries[idx].store_wen;
                store_data_flat[i*32 +: 32] = entries[idx].store_data;
                for (b = 0; b < 4; b = b + 1)
                    store_byte_uop_id_flat[(i*4+b)*`UOP_ID_W +: `UOP_ID_W] =
                        entries[idx].uop_id;
            end
        end

        line_alloc_valid = 1'b0;
        line_alloc_addr = 32'h00000000;
        line_alloc_data = '0;
        line_alloc_word_mask = '0;
    end

    always @(posedge clk or negedge rstn) begin
        integer i;
        if (!rstn) begin
            read_ptr <= 0;
            write_ptr <= 0;
            count <= 0;
            for (i = 0; i < DEPTH; i = i + 1)
                entries[i] <= '0;
        end else begin
            case ({push_do, pop_do})
                2'b10: begin
                    entries[write_ptr] <= accepted_entry_aligned;
                    write_ptr <= ptr_next(write_ptr);
                    count <= count + 1'b1;
                end
                2'b01: begin
                    entries[read_ptr].valid <= 1'b0;
                    read_ptr <= ptr_next(read_ptr);
                    count <= count - 1'b1;
                end
                2'b11: begin
                    entries[write_ptr] <= accepted_entry_aligned;
                    write_ptr <= ptr_next(write_ptr);
                    read_ptr <= ptr_next(read_ptr);
                    count <= count;
                end
                default: begin
                    count <= count;
                end
            endcase
        end
    end

endmodule
