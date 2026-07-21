`timescale 1ns / 1ps
`include "defines.vh"
import cpu_types_pkg::*;

// Queue-based LSU boundary.  The cache-side protocol is still one request
// at a time; the queues decouple execution from that latency.
module LoadStoreUnit (
    input logic cpu_rstn, input logic cpu_clk,
    input logic flush,
    // Branch recovery flush is special: the resolving branch itself is an
    // older ROB instruction and must still complete in this cycle.  The
    // generic flush continues to cancel speculative LSU state.
    input logic branch_flush,
    input execute_result_t execute_result,
    input commit_t commit0, input commit_t commit1,
    output logic ldst_suspend,
    output completion_t main_completion,
    output memory_request_t dcache_req,
    input memory_response_t dcache_rsp
);
    localparam integer QDEPTH = 4;
    lsu_entry_t load_entry, store_entry, store_release_entry;
    logic load_valid, store_valid, load_ready, store_ready;
    logic load_head_valid, buffer_head_valid;
    lsu_entry_t load_head, buffer_head;
    logic load_issue, load_pop, store_pop;
    logic store_release_valid, store_release_fire, buffer_ready;
    logic [QDEPTH-1:0] load_valid_vec, store_valid_vec, buffer_valid_vec;
    logic [QDEPTH*32-1:0] load_addr_flat, store_addr_flat, buffer_addr_flat;
    logic [2*QDEPTH-1:0] order_valid;
    logic [2*QDEPTH*32-1:0] order_addr_flat;
    logic load_blocked;
    logic arb_completion_valid;
    lsu_entry_t arb_completion_entry;
    logic [31:0] arb_completion_rdata;
    completion_t direct_completion;
    logic direct_valid;
    logic [31:0] aligned_load_data;
    logic [3:0] store_wen;
    logic [31:0] store_data;
    logic store_accept;
    logic preserve_execute_completion;

    function automatic [3:0] make_store_wen(input [3:0] mask, input [1:0] off);
        begin
            case (mask)
                `RAM_WE_B: make_store_wen = 4'b0010 << off;
                `RAM_WE_H: make_store_wen = (off[1] ? 4'b1100 : 4'b0011);
                `RAM_WE_W: make_store_wen = 4'b1111;
                default:   make_store_wen = mask;
            endcase
        end
    endfunction

    function automatic [31:0] make_store_data(input [31:0] data,
                                               input [3:0] mask,
                                               input [1:0] off);
        begin
            case (mask)
                `RAM_WE_B: make_store_data = data[7:0] << (off * 8);
                `RAM_WE_H: make_store_data = data[15:0] << (off[1] * 16);
                default:   make_store_data = data;
            endcase
        end
    endfunction

    always_comb begin
        load_valid = execute_result.valid && execute_result.is_ld_st &&
                     !execute_result.ldst_unalign &&
                     (execute_result.store_mask == `RAM_WE_N);
        store_valid = execute_result.valid && execute_result.is_ld_st &&
                      !execute_result.ldst_unalign &&
                      (execute_result.store_mask != `RAM_WE_N);
        store_accept = store_valid && store_ready && !flush;
        preserve_execute_completion = branch_flush && execute_result.valid &&
                                      execute_result.is_br_jmp;
        // Stores complete at address/data generation.  Their architectural
        // side effect remains deferred until ROB commit moves them from the
        // StoreQueue into the StoreBuffer.
        direct_valid = execute_result.valid && (!flush ||
                       preserve_execute_completion) &&
                       (!execute_result.is_ld_st || execute_result.ldst_unalign ||
                        store_accept);
        load_entry = '0;
        load_entry.valid = load_valid;
        load_entry.rob_tag = execute_result.rob_tag;
        load_entry.pc = execute_result.pc;
        load_entry.address = execute_result.alu_result;
        load_entry.load_ext_op = execute_result.load_ext_op;
        load_entry.reg_write = execute_result.reg_write;
        load_entry.arch_rd = execute_result.arch_rd;
        store_wen = make_store_wen(execute_result.store_mask,
                                   execute_result.alu_result[1:0]);
        store_data = make_store_data(execute_result.src1_value,
                                     execute_result.store_mask,
                                     execute_result.alu_result[1:0]);
        store_entry = '0;
        store_entry.valid = store_valid;
        store_entry.rob_tag = execute_result.rob_tag;
        store_entry.pc = execute_result.pc;
        store_entry.address = execute_result.alu_result;
        store_entry.store_data = store_data;
        store_entry.store_wen = store_wen;
        store_entry.reg_write = 1'b0;
        store_entry.arch_rd = 5'd0;

        direct_completion = '0;
        direct_completion.valid = direct_valid;
        direct_completion.rob_tag = execute_result.rob_tag;
        direct_completion.value = execute_result.alu_result;
        direct_completion.reg_write = execute_result.reg_write &&
                                      !execute_result.ldst_unalign &&
                                      !store_valid;

        order_valid = {buffer_valid_vec, store_valid_vec};
        order_addr_flat = {buffer_addr_flat, store_addr_flat};

        // Only a full input queue backpressures execute.  Waiting for the
        // cache response itself does not stop independent work.
        ldst_suspend = !flush && ((load_valid && !load_ready) ||
                                  (store_valid && !store_ready));
    end

    LoadQueue #(.DEPTH(QDEPTH)) u_load_queue (
        .clk(cpu_clk), .rstn(cpu_rstn),
        .flush(flush),
        .accept_valid(load_valid), .accept_entry(load_entry),
        .accept_ready(load_ready), .head_valid(load_head_valid),
        .head_entry(load_head), .issue_mark(load_issue), .pop(load_pop),
        .valid_vec(load_valid_vec), .addr_flat(load_addr_flat)
    );

    StoreQueue #(.DEPTH(QDEPTH)) u_store_queue (
        .clk(cpu_clk), .rstn(cpu_rstn),
        .flush(flush),
        .accept_valid(store_valid), .accept_entry(store_entry),
        .accept_ready(store_ready),
        .commit0(commit0), .commit1(commit1),
        .release_valid(store_release_valid), .release_entry(store_release_entry),
        .release_fire(store_release_fire),
        .valid_vec(store_valid_vec), .addr_flat(store_addr_flat)
    );

    StoreBuffer #(.DEPTH(QDEPTH)) u_store_buffer (
        .clk(cpu_clk), .rstn(cpu_rstn),
        .accept_valid(store_release_valid), .accept_entry(store_release_entry),
        .accept_ready(buffer_ready), .head_valid(buffer_head_valid),
        .head_entry(buffer_head), .pop(store_pop),
        .valid_vec(buffer_valid_vec), .addr_flat(buffer_addr_flat)
    );
    assign store_release_fire = store_release_valid && buffer_ready && !flush;

    MemoryOrderChecker #(.STORE_SLOTS(2*QDEPTH)) u_memory_order_checker (
        .load_valid(load_head_valid), .load_addr(load_head.address),
        .store_valid(order_valid), .store_addr_flat(order_addr_flat),
        .blocked(load_blocked)
    );

    LSUArbiter u_lsu_arbiter (
        .clk(cpu_clk), .rstn(cpu_rstn),
        .flush(flush),
        .load_valid(load_head_valid), .load_entry(load_head),
        .load_blocked(load_blocked), .load_issue(load_issue),
        .load_pop(load_pop), .store_valid(buffer_head_valid),
        .store_entry(buffer_head), .store_pop(store_pop),
        .direct_completion(direct_completion),
        .completion_valid(arb_completion_valid),
        .completion_entry(arb_completion_entry),
        .completion_rdata(arb_completion_rdata),
        .dcache_req(dcache_req), .dcache_rsp(dcache_rsp)
    );

    LoadDataAligner u_load_data_aligner (
        .ram_ext_op(arb_completion_entry.load_ext_op),
        .byte_offset(arb_completion_entry.address[1:0]),
        .din(arb_completion_rdata), .ext_out(aligned_load_data)
    );

    // Kept as a named signal for the existing simulation debug hierarchy.
    logic [31:0] mem_pc;
    always_comb begin
        mem_pc = 32'b0;
        // The trace observes the accepted DCache store request, which may
        // occur several cycles after execute/ROB completion.  Keep the PC
        // attached to the StoreBuffer head for that request.
        if (dcache_req.wen != `RAM_WE_N) mem_pc = buffer_head.pc;
        else if (direct_valid) mem_pc = execute_result.pc;
        else if (arb_completion_valid) mem_pc = arb_completion_entry.pc;

        main_completion = '0;
        if (direct_valid) begin
            main_completion = direct_completion;
        end else if (arb_completion_valid &&
                     (arb_completion_entry.store_wen == `RAM_WE_N)) begin
            main_completion.valid = 1'b1;
            main_completion.rob_tag = arb_completion_entry.rob_tag;
            main_completion.value = (arb_completion_entry.store_wen == `RAM_WE_N) ?
                                    aligned_load_data : 32'b0;
            main_completion.reg_write = arb_completion_entry.reg_write;
        end
    end
endmodule
