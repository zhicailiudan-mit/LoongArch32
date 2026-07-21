`timescale 1ns / 1ps
`include "defines.vh"
import cpu_types_pkg::*;

// One-load/one-store LSU boundary. The two integer lanes may finish memory
// address generation together, but only one Load is admitted to the DCache
// pipeline and only one Store is admitted to SQ in a cycle. This keeps the
// externally visible memory path single-ported and age ordered.
module LoadStoreUnit (
    input logic cpu_rstn, input logic cpu_clk,
    input logic flush,
    // Branch recovery flush is special: the resolving branch itself is an
    // older ROB instruction and must still complete in this cycle.  The
    // generic flush continues to cancel speculative LSU state.
    input logic branch_flush,
    input logic recover_valid,
    input logic system_flush,
    input uop_id_t recover_id,
    input execute_result_t execute_result,
    input execute_result_t execute_result1,
    input commit_t commit0, input commit_t commit1,
    output logic ldst_suspend,
    output logic ldst1_suspend,
    output completion_t main_completion,
    output completion_t lane1_completion,
    output memory_request_t dcache_req,
    input memory_response_t dcache_rsp,
    output logic [2:0] perf_lq_occupancy,
    output logic [2:0] perf_sq_occupancy,
    output logic [2:0] perf_sb_occupancy,
    output logic perf_order_block,
    output logic perf_dcache_wait,
    output logic perf_dcache_backpressure,
    // Simulation-only memory events used by the phase-0 performance counters.
    output logic perf_load_issue,
    output logic perf_load_forward,
    output logic perf_load_response,
    output logic perf_store_issue,
    output logic perf_store_release,
    output logic perf_store_drain,
    input logic store_line_alloc_ready,
    output logic store_line_alloc_valid,
    output logic [31:0] store_line_alloc_addr,
    output logic [`CACHE_BLK_SIZE-1:0] store_line_alloc_data,
    output logic [`CACHE_BLK_LEN-1:0] store_line_alloc_word_mask
);
    localparam integer QDEPTH = 4;
    lsu_entry_t load_entry, store_entry, load1_entry, store1_entry,
                store_release_entry;
    logic load_valid, store_valid, load_ready, store_ready;
    logic load1_valid, store1_valid, load1_ready, store1_ready;
    logic load0_raw, load1_raw, store0_raw, store1_raw;
    logic load0_selected, load1_selected;
    logic store0_selected, store1_selected;
    logic load1_older, store1_older;
    logic store0_accept, store1_accept;
    lsu_entry_t load_accept_entry, store_accept_entry;
    logic load_head_valid, buffer_head_valid;
    lsu_entry_t load_head, buffer_head;
    logic load_issue, load_pop, store_pop;
    logic store_release_valid, store_release_fire, buffer_ready;
    logic [QDEPTH-1:0] load_valid_vec, store_valid_vec, buffer_valid_vec;
    logic [QDEPTH*32-1:0] load_addr_flat, store_addr_flat, buffer_addr_flat;
    logic [QDEPTH*`UOP_ID_W-1:0] store_uop_id_flat;
    logic [QDEPTH*4-1:0] store_wen_flat, buffer_wen_flat;
    logic [QDEPTH*32-1:0] store_data_flat, buffer_data_flat;
    logic [QDEPTH*`UOP_ID_W-1:0] buffer_uop_id_flat;
    logic [QDEPTH*4*`UOP_ID_W-1:0] store_byte_uop_id_flat;
    logic [QDEPTH*4*`UOP_ID_W-1:0] buffer_byte_uop_id_flat;
    logic [2*QDEPTH:0] order_valid;
    logic [QDEPTH-1:0] store_order_valid;
    logic [QDEPTH-1:0] store_addr_ready_vec;
    logic [2*QDEPTH:0] order_addr_ready;
    logic [(2*QDEPTH+1)*32-1:0] order_addr_flat;
    logic [(2*QDEPTH+1)*4-1:0] order_wen_flat;
    logic [(2*QDEPTH+1)*32-1:0] order_data_flat;
    logic [(2*QDEPTH+1)*`UOP_ID_W-1:0] order_uop_id_flat;
    logic [(2*QDEPTH+1)*4*`UOP_ID_W-1:0] order_byte_uop_id_flat;
    logic executing_store_is_older;
    logic load_blocked;
    logic [3:0] load_ren;
    logic [3:0] load_forward_mask;
    logic [31:0] load_forward_data;
    logic [4*`UOP_ID_W-1:0] load_forward_id_flat;
    logic load_forward_valid;
    // L0/L1 load-order stage.  The wide SQ/SB search is completed before
    // this register; the arbiter and DCache only see the registered result.
    logic load_l1_valid;
    lsu_entry_t load_l1_entry;
    logic load_l1_blocked;
    logic load_l1_forward_valid;
    logic [31:0] load_l1_forward_data;
    logic arb_completion_valid;
    lsu_entry_t arb_completion_entry;
    logic [31:0] arb_completion_rdata;
    completion_t direct_completion;
    completion_t direct1_completion;
    logic direct_valid;
    logic direct1_valid;
    logic [31:0] aligned_load_data;
    logic [3:0] store_wen;
    logic [31:0] store_data;
    logic [2:0] lq_occupancy;
    logic [2:0] sq_occupancy;
    logic [2:0] sb_occupancy;
    completion_t main_completion_next;
    integer order_i;
    integer order_byte;

    // Full-line allocation is disabled in the correctness phase.
    assign store_line_alloc_valid = 1'b0;
    assign store_line_alloc_addr = 32'h00000000;
    assign store_line_alloc_data = 0;
    assign store_line_alloc_word_mask = 0;

    function automatic [3:0] make_store_wen(input [3:0] mask, input [1:0] off);
        begin
            case (mask)
                `RAM_WE_B: make_store_wen = 4'b0001 << off;
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

    function automatic [3:0] make_load_ren(input [2:0] ext_op,
                                            input [1:0] byte_offset);
        begin
            case (ext_op)
                `RAM_EXT_B_Z, `RAM_EXT_B_S:
                    make_load_ren = 4'b0001 << byte_offset;
                `RAM_EXT_H_Z, `RAM_EXT_H_S:
                    make_load_ren = byte_offset[1] ? 4'b1100 : 4'b0011;
                default:
                    make_load_ren = 4'b1111;
            endcase
        end
    endfunction

    always_comb begin
        load0_raw = execute_result.valid && execute_result.is_ld_st &&
                    !execute_result.ldst_unalign &&
                    (execute_result.store_mask == `RAM_WE_N);
        store0_raw = execute_result.valid && execute_result.is_ld_st &&
                     !execute_result.ldst_unalign &&
                     (execute_result.store_mask != `RAM_WE_N);
        load1_raw = execute_result1.valid && execute_result1.is_ld_st &&
                    !execute_result1.ldst_unalign &&
                    (execute_result1.store_mask == `RAM_WE_N);
        store1_raw = execute_result1.valid && execute_result1.is_ld_st &&
                     !execute_result1.ldst_unalign &&
                     (execute_result1.store_mask != `RAM_WE_N);

        // Lane number is not an age guarantee once a stalled result is held.
        // On a same-cycle conflict admit the older uop and hold the other
        // execution result until the following cycle.
        load1_older = load0_raw && load1_raw &&
                      uop_is_younger(execute_result.uop_id,
                                     execute_result1.uop_id);
        store1_older = store0_raw && store1_raw &&
                       uop_is_younger(execute_result.uop_id,
                                      execute_result1.uop_id);
        load0_selected = load0_raw && (!load1_raw || !load1_older);
        load1_selected = load1_raw && (!load0_raw || load1_older);
        store0_selected = store0_raw && (!store1_raw || !store1_older);
        store1_selected = store1_raw && (!store0_raw || store1_older);

        // LoadQueue and StoreQueue have retained their two-input interface
        // for compatibility, but this LSU intentionally drives one ingress
        // per queue per cycle.
        load_valid = load0_selected || load1_selected;
        load1_valid = 1'b0;
        store_valid = store0_selected || store1_selected;
        store1_valid = 1'b0;
        store0_accept = store0_selected && store_ready && !flush;
        store1_accept = store1_selected && store_ready && !flush;
        // Stores complete at address/data generation.  Their architectural
        // side effect remains deferred until ROB commit moves them from the
        // StoreQueue into the StoreBuffer.
        // Branch recovery is now a registered event.  The resolving uop's
        // completion was captured by main_completion one cycle before flush;
        // execute_result during the flush cycle belongs to a younger uop and
        // must not be preserved, otherwise a stale completion can corrupt a
        // quickly reused ROB tag (ABA).
        direct_valid = execute_result.valid && !flush &&
                       (!execute_result.is_ld_st || execute_result.ldst_unalign ||
                        store0_accept);
        direct1_valid = execute_result1.valid && !flush &&
                        (execute_result1.ldst_unalign || store1_accept);
        load_entry = '0;
        load_entry.valid = load0_raw;
        load_entry.uop_id = execute_result.uop_id;
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
        store_entry.valid = store0_raw;
        store_entry.uop_id = execute_result.uop_id;
        store_entry.pc = execute_result.pc;
        store_entry.address = execute_result.alu_result;
        store_entry.store_data = store_data;
        store_entry.store_wen = store_wen;
        store_entry.reg_write = 1'b0;
        store_entry.arch_rd = 5'd0;

        load1_entry = '0;
        load1_entry.valid = load1_raw;
        load1_entry.uop_id = execute_result1.uop_id;
        load1_entry.pc = execute_result1.pc;
        load1_entry.address = execute_result1.alu_result;
        load1_entry.load_ext_op = execute_result1.load_ext_op;
        load1_entry.reg_write = execute_result1.reg_write;
        load1_entry.arch_rd = execute_result1.arch_rd;
        store1_entry = '0;
        store1_entry.valid = store1_raw;
        store1_entry.uop_id = execute_result1.uop_id;
        store1_entry.pc = execute_result1.pc;
        store1_entry.address = execute_result1.alu_result;
        store1_entry.store_wen = make_store_wen(execute_result1.store_mask,
                                                execute_result1.alu_result[1:0]);
        store1_entry.store_data = make_store_data(execute_result1.src1_value,
                                                  execute_result1.store_mask,
                                                  execute_result1.alu_result[1:0]);

        load_accept_entry = load0_selected ? load_entry : load1_entry;
        store_accept_entry = store0_selected ? store_entry : store1_entry;

        direct_completion = '0;
        direct_completion.valid = direct_valid;
        direct_completion.uop_id = execute_result.uop_id;
        direct_completion.value = execute_result.alu_result;
        direct_completion.reg_write = execute_result.reg_write &&
                                      !execute_result.ldst_unalign &&
                                      !store0_raw;
        direct1_completion = '0;
        direct1_completion.valid = direct1_valid;
        direct1_completion.uop_id = execute_result1.uop_id;
        direct1_completion.value = execute_result1.alu_result;
        direct1_completion.reg_write = execute_result1.reg_write &&
                                       !execute_result1.ldst_unalign &&
                                       !store1_raw;

        // A load waits only for older same-word stores.  StoreQueue also
        // contains speculative younger stores; treating those as dependencies
        // creates a circular wait because they cannot commit until this load
        // retires.  StoreBuffer entries have already committed and are thus
        // necessarily older than every live, unretired load.
        for (order_i = 0; order_i < QDEPTH; order_i = order_i + 1)
            store_order_valid[order_i] = store_valid_vec[order_i] &&
                !uop_is_younger(store_uop_id_flat[order_i*`UOP_ID_W +: `UOP_ID_W],
                                load_head.uop_id);
        // Include an older Store currently held at the execution boundary.
        // Without this extra slot, a younger queued Load could issue in the
        // cycle before that Store becomes visible in SQ and observe stale
        // DCache data.
        executing_store_is_older = store_valid && load_head_valid &&
            !uop_is_younger(store_accept_entry.uop_id, load_head.uop_id);
        order_valid = {executing_store_is_older,
                       buffer_valid_vec, store_order_valid};
        order_addr_ready = {executing_store_is_older,
                            {QDEPTH{1'b1}}, store_addr_ready_vec};
        order_addr_flat = {store_accept_entry.address,
                           buffer_addr_flat, store_addr_flat};
        order_wen_flat = {store_accept_entry.store_wen,
                          buffer_wen_flat, store_wen_flat};
        order_data_flat = {store_accept_entry.store_data,
                           buffer_data_flat, store_data_flat};
        order_uop_id_flat = {store_accept_entry.uop_id,
                             buffer_uop_id_flat, store_uop_id_flat};
        order_byte_uop_id_flat = {{4{store_accept_entry.uop_id}},
                                  buffer_byte_uop_id_flat,
                                  store_byte_uop_id_flat};

        // Merge the newest older store for each byte lane.  A complete
        // coverage of the load mask can return locally without waiting for
        // DCache/SRAM, which breaks store->load backpressure chains while
        // preserving byte-accurate ordering for partial stores.
        load_ren = make_load_ren(load_head.load_ext_op, load_head.address[1:0]);
        load_forward_mask = 4'b0;
        load_forward_data = 32'b0;
        load_forward_id_flat = '0;
        for (order_i = 0; order_i < 2*QDEPTH+1; order_i = order_i + 1) begin
            if (order_valid[order_i] &&
                ((order_addr_flat[order_i*32 +: 32] & 32'hffff_fffc) ==
                 (load_head.address & 32'hffff_fffc))) begin
                for (order_byte = 0; order_byte < 4; order_byte = order_byte + 1) begin
                    if (order_wen_flat[order_i*4 + order_byte] &&
                        (!load_forward_mask[order_byte] ||
                         uop_is_younger(
                           order_byte_uop_id_flat[(order_i*4 + order_byte)*`UOP_ID_W +: `UOP_ID_W],
                           load_forward_id_flat[order_byte*`UOP_ID_W +: `UOP_ID_W]))) begin
                        load_forward_mask[order_byte] = 1'b1;
                        load_forward_data[order_byte*8 +: 8] =
                            order_data_flat[order_i*32 + order_byte*8 +: 8];
                        load_forward_id_flat[order_byte*`UOP_ID_W +: `UOP_ID_W] =
                            order_byte_uop_id_flat[(order_i*4 + order_byte)*`UOP_ID_W +: `UOP_ID_W];
                    end
                end
            end
        end
        load_forward_valid = load_head_valid &&
                             ((load_forward_mask & load_ren) == load_ren);

        // Only a full input queue backpressures execute.  Waiting for the
        // cache response itself does not stop independent work.
        ldst_suspend = !flush &&
                       ((load0_raw && (!load0_selected || !load_ready)) ||
                        (store0_raw && (!store0_selected || !store_ready)));
        ldst1_suspend = !flush &&
                        ((load1_raw && (!load1_selected || !load_ready)) ||
                         (store1_raw && (!store1_selected || !store_ready)));
        perf_lq_occupancy = lq_occupancy;
        perf_sq_occupancy = sq_occupancy;
        perf_sb_occupancy = sb_occupancy;
        perf_order_block = load_l1_valid && load_l1_blocked &&
                           !load_l1_forward_valid;
        perf_load_issue = load_issue;
        // load_issue is generated from the registered L1 decision.  Use the
        // same registered qualifier here so the debug counter cannot report a
        // forward for a different (newer) L0 head.
        perf_load_forward = load_issue && load_l1_forward_valid;
        perf_load_response = load_pop;
        perf_store_issue = store0_accept || store1_accept;
        perf_store_release = store_release_fire;
        perf_store_drain = store_pop;
    end

    LoadQueue #(.DEPTH(QDEPTH)) u_load_queue (
        .clk(cpu_clk), .rstn(cpu_rstn),
        .flush(flush),
        .recover_valid(recover_valid), .system_flush(system_flush),
        .recover_id(recover_id),
        .accept_valid(load_valid), .accept_entry(load_accept_entry),
        .accept_ready(load_ready), .head_valid(load_head_valid),
        .accept1_valid(1'b0), .accept1_entry('0),
        .accept1_ready(load1_ready),
        .head_entry(load_head), .issue_mark(load_issue), .pop(load_pop),
        .valid_vec(load_valid_vec), .addr_flat(load_addr_flat),
        .occupancy(lq_occupancy)
    );

    StoreQueue #(.DEPTH(QDEPTH)) u_store_queue (
        .clk(cpu_clk), .rstn(cpu_rstn),
        .flush(flush),
        .recover_valid(recover_valid), .system_flush(system_flush),
        .recover_id(recover_id),
        .accept_valid(store_valid), .accept_entry(store_accept_entry),
        .accept_ready(store_ready),
        .accept1_valid(1'b0), .accept1_entry('0),
        .accept1_ready(store1_ready),
        .commit0(commit0), .commit1(commit1),
        .release_valid(store_release_valid), .release_entry(store_release_entry),
        .release_fire(store_release_fire),
        .valid_vec(store_valid_vec), .addr_ready_vec(store_addr_ready_vec),
        .addr_flat(store_addr_flat),
        .uop_id_flat(store_uop_id_flat),
        .store_wen_flat(store_wen_flat), .store_data_flat(store_data_flat),
        .store_byte_uop_id_flat(store_byte_uop_id_flat),
        .occupancy(sq_occupancy)
    );

    StoreBuffer #(.DEPTH(QDEPTH)) u_store_buffer (
        .clk(cpu_clk), .rstn(cpu_rstn),
        .accept_valid(store_release_valid), .accept_entry(store_release_entry),
        .accept_ready(buffer_ready), .head_valid(buffer_head_valid),
        .head_entry(buffer_head), .pop(store_pop),
        .valid_vec(buffer_valid_vec), .addr_flat(buffer_addr_flat),
        .uop_id_flat(buffer_uop_id_flat),
        .store_wen_flat(buffer_wen_flat), .store_data_flat(buffer_data_flat),
        .store_byte_uop_id_flat(buffer_byte_uop_id_flat),
        .occupancy(sb_occupancy),
        .line_alloc_ready(1'b0),
        .line_alloc_valid(),
        .line_alloc_addr(),
        .line_alloc_data(),
        .line_alloc_word_mask()
    );
    assign store_release_fire = store_release_valid && buffer_ready && !flush;

    MemoryOrderChecker #(.STORE_SLOTS(2*QDEPTH+1)) u_memory_order_checker (
        .load_valid(load_head_valid), .load_addr(load_head.address),
        .load_ren(load_ren), .store_valid(order_valid),
        .store_addr_ready(order_addr_ready),
        .store_addr_flat(order_addr_flat), .store_wen_flat(order_wen_flat),
        .blocked(load_blocked)
    );

    // L1 register for the load-order result.  This breaks the combinational
    // path from SQ/SB byte-age comparison through the DCache ready and
    // completion network.  A flush kills the stage before it can issue.
    always_ff @(posedge cpu_clk or negedge cpu_rstn) begin
        if (!cpu_rstn) begin
            load_l1_valid <= 1'b0;
            load_l1_entry <= '0;
            load_l1_blocked <= 1'b0;
            load_l1_forward_valid <= 1'b0;
            load_l1_forward_data <= 32'h0;
        end else if (flush) begin
            load_l1_valid <= 1'b0;
            load_l1_entry <= '0;
            load_l1_blocked <= 1'b0;
            load_l1_forward_valid <= 1'b0;
            load_l1_forward_data <= 32'h0;
        end else begin
            if (load_l1_valid && load_pop)
                load_l1_valid <= 1'b0;
            if (!load_l1_valid && load_head_valid && (!load_blocked || load_forward_valid)) begin
                load_l1_valid <= 1'b1;
                load_l1_entry <= load_head;
                load_l1_blocked <= load_blocked;
                load_l1_forward_valid <= load_forward_valid;
                load_l1_forward_data <= load_forward_data;
            end
        end
    end

    LsuArbiter u_lsu_arbiter (
        .clk(cpu_clk), .rstn(cpu_rstn),
        .flush(flush),
        .branch_flush(branch_flush),
        .recover_valid(recover_valid), .system_flush(system_flush),
        .recover_id(recover_id),
        .load_valid(load_l1_valid), .load_entry(load_l1_entry),
        .load_blocked(load_l1_blocked),
        .load_forward_valid(load_l1_forward_valid),
        .load_forward_rdata(load_l1_forward_data), .load_issue(load_issue),
        .load_pop(load_pop),
        .store_valid(buffer_head_valid),
        .store_entry(buffer_head), .store_pop(store_pop),
        .store_line_alloc_valid(store_line_alloc_valid),
        .store_line_alloc_addr(store_line_alloc_addr),
        .direct_completion(direct_completion),
        .completion_valid(arb_completion_valid),
        .completion_entry(arb_completion_entry),
        .completion_rdata(arb_completion_rdata),
        .dcache_req(dcache_req), .dcache_rsp(dcache_rsp),
        .perf_dcache_wait(perf_dcache_wait),
        .perf_dcache_backpressure(perf_dcache_backpressure)
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

        main_completion_next = '0;
        if (direct_valid) begin
            main_completion_next = direct_completion;
        end else begin
            // Cut the long completion path that includes StoreBuffer and LsuArbiter:
            // unconditionally map the datapath fields. The backend only uses them if valid.
            main_completion_next.valid = arb_completion_valid &&
                                         (arb_completion_entry.store_wen == `RAM_WE_N);
            main_completion_next.uop_id = arb_completion_entry.uop_id;
            main_completion_next.value = aligned_load_data;
            main_completion_next.reg_write = arb_completion_entry.reg_write;
        end
    end

    // The LSU may perform queue selection, ordering checks, response
    // arbitration and load alignment in one cycle.  Do not extend that path
    // through CompletionRouter/ROB/DQ operand wakeup.  This register is also
    // the ownership point for the lane-0 completion payload.
    always_ff @(posedge cpu_clk or negedge cpu_rstn) begin
        if (!cpu_rstn)
            main_completion <= '0;
        else if (flush)
            main_completion <= '0;
        else
            main_completion <= main_completion_next;

        if (!cpu_rstn)
            lane1_completion <= '0;
        else if (flush)
            lane1_completion <= '0;
        else
            lane1_completion <= direct1_completion;
    end

`ifndef SYNTHESIS
    always @(posedge cpu_clk) begin
        if (cpu_rstn && direct_valid && arb_completion_valid)
            $fatal(1, "LSU completion collision");
        if (cpu_rstn && flush && main_completion_next.valid)
            $error("flushed LSU operation generated a main completion");
        if (cpu_rstn && flush && direct1_completion.valid)
            $error("flushed LSU operation generated a lane1 completion");
    end
`endif

endmodule
