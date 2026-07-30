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

        accept_ready = rstn && ((count < DEPTH) || pop_do);
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
`ifndef SYNTHESIS
`ifdef LSU_VERBOSE_TRACE
                    $display("[%t] SB PUSH: PC=0x%8h, addr=0x%8h, uop_id=%d, count=%d", $time, accept_entry.pc, accept_entry.address, accept_entry.uop_id, count);
`endif
`endif
                    entries[write_ptr] <= accepted_entry_aligned;
                    write_ptr <= ptr_next(write_ptr);
                    count <= count + 1'b1;
                end
                2'b01: begin
`ifndef SYNTHESIS
`ifdef LSU_VERBOSE_TRACE
                    $display("[%t] SB POP: PC=0x%8h, addr=0x%8h, uop_id=%d, count=%d", $time, entries[read_ptr].pc, entries[read_ptr].address, entries[read_ptr].uop_id, count);
`endif
`endif
                    entries[read_ptr].valid <= 1'b0;
                    read_ptr <= ptr_next(read_ptr);
                    count <= count - 1'b1;
                end
                2'b11: begin
`ifndef SYNTHESIS
`ifdef LSU_VERBOSE_TRACE
                    $display("[%t] SB PUSH+POP: push PC=0x%8h, pop PC=0x%8h, count=%d", $time, accept_entry.pc, entries[read_ptr].pc, count);
`endif
`endif
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

`ifndef SYNTHESIS
    // Immediate assertions are simulation-only and do not affect hardware.
    always @(posedge clk) begin : store_buffer_assertions
        integer j;
        integer check_idx;
        if (rstn) begin
            if (pop && (count == 0))
                $error("StoreBuffer pop while empty");
            if ((count == DEPTH) && push_do && !pop_do)
                $error("StoreBuffer push while full without pop");
            if (count_next > DEPTH)
                $error("StoreBuffer count overflow");
            if ((count == 0) && pop_do)
                $error("StoreBuffer count underflow");

            if (line_alloc_valid)
                $error("line_alloc_valid must remain low");

            // The head payload and every flat forwarding field must describe
            // one and the same FIFO slot (including its PC/uop identity).
            if (head_valid) begin
                if (uop_id_flat[0 +: `UOP_ID_W] !== head_entry.uop_id)
                    $error("StoreBuffer head uop mismatch");
                if (addr_flat[0 +: 32] !== head_entry.address)
                    $error("StoreBuffer head address mismatch");
                if (store_data_flat[0 +: 32] !== head_entry.store_data)
                    $error("StoreBuffer head data mismatch");
                if (store_wen_flat[0 +: 4] !== head_entry.store_wen)
                    $error("StoreBuffer head wen mismatch");
            end

            for (j = 0; j < DEPTH; j = j + 1) begin
                check_idx = read_ptr + j;
                if (check_idx >= DEPTH)
                    check_idx = check_idx - DEPTH;
                if ((j < count) && valid_vec[j]) begin
                    if (addr_flat[j*32 +: 32] !== entries[check_idx].address)
                        $error("StoreBuffer flat address mismatch");
                    if (store_data_flat[j*32 +: 32] !== entries[check_idx].store_data)
                        $error("StoreBuffer flat data mismatch");
                    if (store_wen_flat[j*4 +: 4] !== entries[check_idx].store_wen)
                        $error("StoreBuffer flat wen mismatch");
                    if (uop_id_flat[j*`UOP_ID_W +: `UOP_ID_W] !==
                        entries[check_idx].uop_id)
                        $error("StoreBuffer flat uop mismatch");
                end
            end
        end
    end


`endif
endmodule
