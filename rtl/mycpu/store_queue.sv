`timescale 1ns / 1ps
`include "defines.vh"
import cpu_types_pkg::*;

module StoreQueue #(parameter integer DEPTH = 4) (
    input logic clk, input logic rstn,
    input logic flush,
    input logic recover_valid, input logic system_flush,
    input uop_id_t recover_id,

    // Legacy Accept Interface (for standalone unit testbenches)
    input logic accept_valid, input lsu_entry_t accept_entry,
    output logic accept_ready,
    input logic accept1_valid, input lsu_entry_t accept1_entry,
    output logic accept1_ready,

    // Decoupled Reservation Interface (from Scheduler / DQ at Issue)
    input logic reserve0_valid,
    output logic reserve0_ready,
    input uop_id_t reserve0_uop_id,
    input logic [31:0] reserve0_pc,
    input logic [3:0] reserve0_store_mask,
    input logic reserve0_src1_ready,
    input logic [31:0] reserve0_src1_value,
    input uop_id_t reserve0_src1_id,

    input logic reserve1_valid,
    output logic reserve1_ready,
    input uop_id_t reserve1_uop_id,
    input logic [31:0] reserve1_pc,
    input logic [3:0] reserve1_store_mask,
    input logic reserve1_src1_ready,
    input logic [31:0] reserve1_src1_value,
    input uop_id_t reserve1_src1_id,

    // Decoupled Address & Data Update Interface (from AGU Execution)
    input logic addr_update0_valid,
    output logic addr_update0_ack,
    input uop_id_t addr_update0_uop_id,
    input logic [31:0] addr_update0_address,
    input logic [3:0] addr_update0_store_wen,
    input logic addr_update0_unalign,
    input logic addr_update0_data_ready,
    input logic [31:0] addr_update0_data_value,
    input uop_id_t addr_update0_data_src_id,

    input logic addr_update1_valid,
    output logic addr_update1_ack,
    input uop_id_t addr_update1_uop_id,
    input logic [31:0] addr_update1_address,
    input logic [3:0] addr_update1_store_wen,
    input logic addr_update1_unalign,
    input logic addr_update1_data_ready,
    input logic [31:0] addr_update1_data_value,
    input uop_id_t addr_update1_data_src_id,

    // Data Snooping & Commit Interface
    input completion_t complete0, input completion_t complete1,
    input commit_t commit0, input commit_t commit1,

    // Release Interface to StoreBuffer
    output logic release_valid, output lsu_entry_t release_entry,
    input logic release_fire,

    // Flat / Vector Interface for Forwarding & Memory Order Checker
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

    typedef struct packed {
        logic valid;
        logic unaligned;
        uop_id_t uop_id;
        logic [31:0] pc;
        logic [3:0] raw_mask;
        logic addr_ready;
        logic [31:0] address;
        logic [3:0] store_wen;
    } sq_entry_t;

    sq_entry_t entries [0:DEPTH-1];
    // Keep Store-data wakeup state physically separate from address/control
    // metadata.  Completion uop matching must only drive these registers; if
    // all fields share one packed entry, Vivado can fold the match into a
    // common CE for address bits and recreate the completion -> SQ address
    // critical path even though the address value is unchanged.
    logic store_data_ready [0:DEPTH-1];
    logic [31:0] raw_store_data [0:DEPTH-1];
    uop_id_t store_data_src_id [0:DEPTH-1];
    logic committed [0:DEPTH-1];
    // Commit is still consumed combinationally below for architectural Store
    // retirement and flush preservation.  Only the data-wakeup fallback is
    // delayed: this cuts ROB done -> commit -> raw_store_data while retaining
    // completion broadcast as the zero-extra-cycle Store-data fast path.
    completion_t commit_data_wakeup0_q;
    completion_t commit_data_wakeup1_q;
    // Registered AGU packets form the timing boundary from execution-lane
    // result/uop-id registers to SQ address metadata.  The input-side ack only
    // accepts a packet for an already-reserved entry; metadata consumes the
    // registered copy on the following edge.
    logic addr_update0_q_valid;
    uop_id_t addr_update0_q_uop_id;
    logic [31:0] addr_update0_q_address;
    logic addr_update0_q_unalign;
    logic addr_update0_q_data_ready;
    logic [31:0] addr_update0_q_data_value;
    uop_id_t addr_update0_q_data_src_id;

    logic addr_update1_q_valid;
    uop_id_t addr_update1_q_uop_id;
    logic [31:0] addr_update1_q_address;
    logic addr_update1_q_unalign;
    logic addr_update1_q_data_ready;
    logic [31:0] addr_update1_q_data_value;
    uop_id_t addr_update1_q_data_src_id;

    logic [COUNT_W-1:0] count;
    logic [INDEX_W-1:0] oldest_sel;
    logic oldest_found;
    integer i, j, q, byte_i;
    integer flush_dst;

    function automatic [3:0] compute_store_wen(input [3:0] raw_mask, input [1:0] off);
        begin
            case (raw_mask)
                `RAM_WE_B: compute_store_wen = 4'b0001 << off;
                `RAM_WE_H: compute_store_wen = off[1] ? 4'b1100 : 4'b0011;
                `RAM_WE_W: compute_store_wen = 4'b1111;
                default:   compute_store_wen = raw_mask;
            endcase
        end
    endfunction

    function automatic [31:0] compute_aligned_data(input [31:0] val, input [3:0] raw_mask, input [1:0] off);
        begin
            case (raw_mask)
                `RAM_WE_B: compute_aligned_data = (val[7:0]) << (off * 8);
                `RAM_WE_H: compute_aligned_data = (val[15:0]) << (off[1] * 16);
                default:   compute_aligned_data = val;
            endcase
        end
    endfunction

    function automatic logic update_sq_data_ready(
        input logic cur_ready,
        input uop_id_t cur_entry_uop_id,
        input uop_id_t cur_src_id,
        input logic au0_q_valid,
        input uop_id_t au0_q_uop_id,
        input logic au0_q_data_ready,
        input logic au1_q_valid,
        input uop_id_t au1_q_uop_id,
        input logic au1_q_data_ready,
        input completion_t c0,
        input completion_t c1,
        input completion_t k0,
        input completion_t k1
    );
        begin
            if (cur_ready) begin
                update_sq_data_ready = 1'b1;
            end else if (au0_q_valid && uop_id_equal(cur_entry_uop_id, au0_q_uop_id) && au0_q_data_ready) begin
                update_sq_data_ready = 1'b1;
            end else if (au1_q_valid && uop_id_equal(cur_entry_uop_id, au1_q_uop_id) && au1_q_data_ready) begin
                update_sq_data_ready = 1'b1;
            end else if (c0.valid && c0.reg_write && uop_id_equal(c0.uop_id, cur_src_id)) begin
                update_sq_data_ready = 1'b1;
            end else if (c1.valid && c1.reg_write && uop_id_equal(c1.uop_id, cur_src_id)) begin
                update_sq_data_ready = 1'b1;
            end else if (k0.valid && k0.reg_write && uop_id_equal(k0.uop_id, cur_src_id)) begin
                update_sq_data_ready = 1'b1;
            end else if (k1.valid && k1.reg_write && uop_id_equal(k1.uop_id, cur_src_id)) begin
                update_sq_data_ready = 1'b1;
            end else begin
                update_sq_data_ready = 1'b0;
            end
        end
    endfunction

    function automatic logic [31:0] update_sq_data_value(
        input logic cur_ready,
        input logic [31:0] cur_value,
        input uop_id_t cur_entry_uop_id,
        input uop_id_t cur_src_id,
        input logic au0_q_valid,
        input uop_id_t au0_q_uop_id,
        input logic au0_q_data_ready,
        input logic [31:0] au0_q_data_value,
        input logic au1_q_valid,
        input uop_id_t au1_q_uop_id,
        input logic au1_q_data_ready,
        input logic [31:0] au1_q_data_value,
        input completion_t c0,
        input completion_t c1,
        input completion_t k0,
        input completion_t k1
    );
        begin
            if (cur_ready) begin
                update_sq_data_value = cur_value;
            end else if (au0_q_valid && uop_id_equal(cur_entry_uop_id, au0_q_uop_id) && au0_q_data_ready) begin
                update_sq_data_value = au0_q_data_value;
            end else if (au1_q_valid && uop_id_equal(cur_entry_uop_id, au1_q_uop_id) && au1_q_data_ready) begin
                update_sq_data_value = au1_q_data_value;
            end else if (c0.valid && c0.reg_write && uop_id_equal(c0.uop_id, cur_src_id)) begin
                update_sq_data_value = c0.value;
            end else if (c1.valid && c1.reg_write && uop_id_equal(c1.uop_id, cur_src_id)) begin
                update_sq_data_value = c1.value;
            end else if (k0.valid && k0.reg_write && uop_id_equal(k0.uop_id, cur_src_id)) begin
                update_sq_data_value = k0.value;
            end else if (k1.valid && k1.reg_write && uop_id_equal(k1.uop_id, cur_src_id)) begin
                update_sq_data_value = k1.value;
            end else begin
                update_sq_data_value = cur_value;
            end
        end
    endfunction

    // Address/control update is deliberately independent of completion buses.
    function automatic sq_entry_t update_sq_metadata(
        input sq_entry_t in_entry,
        input logic au0_valid,
        input uop_id_t au0_uop_id,
        input logic [31:0] au0_addr,
        input logic au0_unalign,
        input logic au1_valid,
        input uop_id_t au1_uop_id,
        input logic [31:0] au1_addr,
        input logic au1_unalign
    );
        sq_entry_t tmp;
        begin
            tmp = in_entry;
            if (in_entry.valid && au0_valid &&
                uop_id_equal(in_entry.uop_id, au0_uop_id)) begin
                if (au0_unalign) begin
                    tmp.unaligned = 1'b1;
                    tmp.addr_ready = 1'b0;
                end else begin
                    tmp.unaligned = 1'b0;
                    tmp.address = au0_addr;
                    tmp.store_wen = compute_store_wen(in_entry.raw_mask,
                                                       au0_addr[1:0]);
                    tmp.addr_ready = 1'b1;
                end
            end else if (in_entry.valid && au1_valid &&
                         uop_id_equal(in_entry.uop_id, au1_uop_id)) begin
                if (au1_unalign) begin
                    tmp.unaligned = 1'b1;
                    tmp.addr_ready = 1'b0;
                end else begin
                    tmp.unaligned = 1'b0;
                    tmp.address = au1_addr;
                    tmp.store_wen = compute_store_wen(in_entry.raw_mask,
                                                       au1_addr[1:0]);
                    tmp.addr_ready = 1'b1;
                end
            end
            update_sq_metadata = tmp;
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

    // Effective reservation signals combining new decoupled interface and legacy accept
    wire r0_active = (reserve0_valid === 1'b1) || accept_valid;
    wire [31:0] r0_pc = accept_valid ? accept_entry.pc : reserve0_pc;
    wire uop_id_t r0_uop_id = accept_valid ? accept_entry.uop_id : reserve0_uop_id;
    wire [3:0] r0_mask = accept_valid ? accept_entry.store_wen : reserve0_store_mask;
    wire r0_src1_ready = accept_valid ? accept_entry.store_data_ready : (reserve0_src1_ready === 1'b1);
    wire [31:0] r0_src1_value = accept_valid ? accept_entry.store_data : reserve0_src1_value;
    wire uop_id_t r0_src1_id = accept_valid ? accept_entry.store_data_src_id : reserve0_src1_id;
    wire r0_has_addr = accept_valid;
    wire [31:0] r0_addr = accept_entry.address;

    wire r1_active = (reserve1_valid === 1'b1) || accept1_valid;
    wire [31:0] r1_pc = accept1_valid ? accept1_entry.pc : reserve1_pc;
    wire uop_id_t r1_uop_id = accept1_valid ? accept1_entry.uop_id : reserve1_uop_id;
    wire [3:0] r1_mask = accept1_valid ? accept1_entry.store_wen : reserve1_store_mask;
    wire r1_src1_ready = accept1_valid ? accept1_entry.store_data_ready : (reserve1_src1_ready === 1'b1);
    wire [31:0] r1_src1_value = accept1_valid ? accept1_entry.store_data : reserve1_src1_value;
    wire uop_id_t r1_src1_id = accept1_valid ? accept1_entry.store_data_src_id : reserve1_src1_id;
    wire r1_has_addr = accept1_valid;
    wire [31:0] r1_addr = accept1_entry.address;

    wire both_active = r0_active && r1_active;
    wire r1_older = both_active && uop_is_younger(r0_uop_id, r1_uop_id);

    assign accept_ready = reserve0_ready;
    assign accept1_ready = reserve1_ready;

    wire r0_do = !flush && r0_active && reserve0_ready;
    wire r1_do = !flush && r1_active && reserve1_ready;

    wire release_do = !flush && release_fire && oldest_found &&
                      entries[oldest_sel].valid &&
                      !entries[oldest_sel].unaligned &&
                      committed[oldest_sel] &&
                      entries[oldest_sel].addr_ready &&
                      store_data_ready[oldest_sel];

    // Account for same-cycle release when computing free slots.  Without this,
    // a steady-state SQ at DEPTH sees free_slots==0 for one cycle each time it
    // releases, creating a false-full bubble that causes the Scheduler to reject
    // the next Store.  That Store then holds lane0 in the DQ via main_hold,
    // blocking branches from issuing → ROB cannot commit → SQ entries stay
    // uncommitted → SQ never drains → deadlock.
    //
    // Combinational-loop safety: release_do depends on release_fire (input from
    // LSU/SB, driven by release_valid && buffer_ready) and oldest_found /
    // committed / data_ready (all registered SQ state).  None of these depend on
    // free_slots or reserve*_ready, so the path is strictly feed-forward:
    //   release_do → free_slots → reserve*_ready → Scheduler → DQ.
    wire [COUNT_W:0] free_slots = (DEPTH - count) + {{COUNT_W{1'b0}}, release_do};

    // Combinational address-update acknowledgement only searches entries
    // which were reserved on an earlier clock edge.  In the CPU pipeline a
    // Store reservation is accepted with issue_fire, then the execution lane
    // produces its address no earlier than the following cycle.  Treating a
    // current reservation grant as an address hit is therefore unreachable,
    // and creates a false combinational cycle through reserve_ready,
    // issue_ready and DispatchQueue selection.
    always_comb begin
        addr_update0_ack = 1'b0;
        if (!flush && addr_update0_valid) begin
            for (integer k = 0; k < DEPTH; k = k + 1) begin
                if ((k < count) && entries[k].valid && !entries[k].unaligned && uop_id_equal(entries[k].uop_id, addr_update0_uop_id)) begin
                    addr_update0_ack = 1'b1;
                end
            end
        end

        addr_update1_ack = 1'b0;
        if (!flush && addr_update1_valid) begin
            for (integer k = 0; k < DEPTH; k = k + 1) begin
                if ((k < count) && entries[k].valid && !entries[k].unaligned && uop_id_equal(entries[k].uop_id, addr_update1_uop_id)) begin
                    addr_update1_ack = 1'b1;
                end
            end
        end
    end

    // Reservation Ready Calculation
    always_comb begin
        reserve0_ready = 1'b0;
        reserve1_ready = 1'b0;
        if (!flush && free_slots != 0) begin
            if (free_slots >= 2) begin
                reserve0_ready = 1'b1;
                reserve1_ready = 1'b1;
            end else if (!both_active) begin
                reserve0_ready = r0_active;
                reserve1_ready = r1_active;
            end else if (r1_older) begin
                reserve1_ready = 1'b1;
            end else begin
                reserve0_ready = 1'b1;
            end
        end

        oldest_found = 1'b0;
        oldest_sel = '0;
        for (i = 0; i < DEPTH; i = i + 1) begin
            if ((i < count) && entries[i].valid &&
                (!oldest_found || uop_is_younger(entries[oldest_sel].uop_id, entries[i].uop_id))) begin
                oldest_found = 1'b1;
                oldest_sel = i[INDEX_W-1:0];
            end
        end

        release_valid = !flush && oldest_found &&
                        entries[oldest_sel].valid &&
                        !entries[oldest_sel].unaligned &&
                        committed[oldest_sel] &&
                        entries[oldest_sel].addr_ready &&
                        store_data_ready[oldest_sel];

        release_entry = '0;
        if (release_valid) begin
            release_entry.valid = 1'b1;
            release_entry.uop_id = entries[oldest_sel].uop_id;
            release_entry.pc = entries[oldest_sel].pc;
            release_entry.address = entries[oldest_sel].address;
            release_entry.store_wen = entries[oldest_sel].store_wen;
            release_entry.store_data = compute_aligned_data(raw_store_data[oldest_sel], entries[oldest_sel].raw_mask, entries[oldest_sel].address[1:0]);
            release_entry.store_data_ready = 1'b1;
            release_entry.store_data_src_id = store_data_src_id[oldest_sel];
        end

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
            automatic logic entry_valid = !flush && (i < count) && entries[i].valid;
            valid_vec[i] = entry_valid;
            addr_ready_vec[i] = entry_valid && entries[i].addr_ready;
            store_data_ready_vec[i] = entry_valid && store_data_ready[i];
            addr_flat[i*32 +: 32] = entries[i].address;
            uop_id_flat[i*`UOP_ID_W +: `UOP_ID_W] = entries[i].uop_id;
            store_wen_flat[i*4 +: 4] = entries[i].store_wen;
            store_data_flat[i*32 +: 32] = compute_aligned_data(raw_store_data[i], entries[i].raw_mask, entries[i].address[1:0]);
            for (byte_i = 0; byte_i < 4; byte_i = byte_i + 1)
                store_byte_uop_id_flat[(i*4 + byte_i)*`UOP_ID_W +: `UOP_ID_W] = entries[i].uop_id;
        end
    end

    // Helper to construct newly reserved entry
    function automatic sq_entry_t make_reserved_sq_entry(
        input [31:0] pc,
        input uop_id_t uop_id,
        input [3:0] mask,
        input has_addr,
        input [31:0] in_addr
    );
        sq_entry_t tmp;
        begin
            tmp = '0;
            tmp.valid = 1'b1;
            tmp.unaligned = 1'b0;
            tmp.uop_id = uop_id;
            tmp.pc = pc;
            tmp.raw_mask = mask;

            if (has_addr) begin
                tmp.addr_ready = 1'b1;
                tmp.address = in_addr;
                tmp.store_wen = compute_store_wen(mask, in_addr[1:0]);
            end else begin
                tmp.addr_ready = 1'b0;
                tmp.address = 32'h0;
                tmp.store_wen = mask;
            end

            make_reserved_sq_entry = tmp;
        end
    endfunction

    // Do not clear this packet on queue flush.  A producer may retire in the
    // same cycle as recovery; a surviving Store must see it one cycle later.
    always_ff @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            commit_data_wakeup0_q <= '0;
            commit_data_wakeup1_q <= '0;
        end else begin
            commit_data_wakeup0_q.valid <= commit0.valid && commit0.reg_write;
            commit_data_wakeup0_q.uop_id <= commit0.uop_id;
            commit_data_wakeup0_q.value <= commit0.value;
            commit_data_wakeup0_q.reg_write <= commit0.reg_write;
            commit_data_wakeup1_q.valid <= commit1.valid && commit1.reg_write;
            commit_data_wakeup1_q.uop_id <= commit1.uop_id;
            commit_data_wakeup1_q.value <= commit1.value;
            commit_data_wakeup1_q.reg_write <= commit1.reg_write;
        end
    end

    // Address update handshake/pipeline.  A flush suppresses ack and drops
    // both pending packets, so an update from the discarded epoch cannot
    // mutate a later Store that reuses the ROB tag.
    always_ff @(posedge clk or negedge rstn) begin
        if (!rstn || flush) begin
            addr_update0_q_valid <= 1'b0;
            addr_update0_q_uop_id <= '0;
            addr_update0_q_address <= 32'h0;
            addr_update0_q_unalign <= 1'b0;
            addr_update0_q_data_ready <= 1'b0;
            addr_update0_q_data_value <= 32'h0;
            addr_update0_q_data_src_id <= '0;
            addr_update1_q_valid <= 1'b0;
            addr_update1_q_uop_id <= '0;
            addr_update1_q_address <= 32'h0;
            addr_update1_q_unalign <= 1'b0;
            addr_update1_q_data_ready <= 1'b0;
            addr_update1_q_data_value <= 32'h0;
            addr_update1_q_data_src_id <= '0;
        end else begin
            addr_update0_q_valid <= addr_update0_valid && addr_update0_ack;
            if (addr_update0_valid && addr_update0_ack) begin
                addr_update0_q_uop_id <= addr_update0_uop_id;
                addr_update0_q_address <= addr_update0_address;
                addr_update0_q_unalign <= addr_update0_unalign;
                addr_update0_q_data_ready <= addr_update0_data_ready;
                addr_update0_q_data_value <= addr_update0_data_value;
                addr_update0_q_data_src_id <= addr_update0_data_src_id;
            end
            addr_update1_q_valid <= addr_update1_valid && addr_update1_ack;
            if (addr_update1_valid && addr_update1_ack) begin
                addr_update1_q_uop_id <= addr_update1_uop_id;
                addr_update1_q_address <= addr_update1_address;
                addr_update1_q_unalign <= addr_update1_unalign;
                addr_update1_q_data_ready <= addr_update1_data_ready;
                addr_update1_q_data_value <= addr_update1_data_value;
                addr_update1_q_data_src_id <= addr_update1_data_src_id;
            end
        end
    end

    always_ff @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            count <= '0;
            for (q = 0; q < DEPTH; q = q + 1) begin
                entries[q] <= '0;
                store_data_ready[q] <= 1'b0;
                raw_store_data[q] <= 32'h0;
                store_data_src_id[q] <= '0;
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
                if ((q < count) && entries[q].valid && (committed[q] ||
                    (commit0.valid && uop_id_equal(entries[q].uop_id, commit0.uop_id)) ||
                    (commit1.valid && uop_id_equal(entries[q].uop_id, commit1.uop_id)) ||
                    (!system_flush && recover_valid && !uop_is_younger(entries[q].uop_id, recover_id)))) begin
                    // A packet acknowledged on the preceding cycle belongs to
                    // the Store even if recovery is asserted now.  Apply it
                    // while compacting survivors before clearing the pipeline.
                    entries[flush_dst] <= update_sq_metadata(
                        entries[q],
                        addr_update0_q_valid, addr_update0_q_uop_id,
                        addr_update0_q_address, addr_update0_q_unalign,
                        addr_update1_q_valid, addr_update1_q_uop_id,
                        addr_update1_q_address, addr_update1_q_unalign);
                    store_data_ready[flush_dst] <= update_sq_data_ready(
                        store_data_ready[q], entries[q].uop_id, store_data_src_id[q],
                        addr_update0_q_valid, addr_update0_q_uop_id, addr_update0_q_data_ready,
                        addr_update1_q_valid, addr_update1_q_uop_id, addr_update1_q_data_ready,
                        complete0, complete1,
                        commit_data_wakeup0_q, commit_data_wakeup1_q);
                    raw_store_data[flush_dst] <= update_sq_data_value(
                        store_data_ready[q], raw_store_data[q], entries[q].uop_id, store_data_src_id[q],
                        addr_update0_q_valid, addr_update0_q_uop_id, addr_update0_q_data_ready, addr_update0_q_data_value,
                        addr_update1_q_valid, addr_update1_q_uop_id, addr_update1_q_data_ready, addr_update1_q_data_value,
                        complete0, complete1,
                        commit_data_wakeup0_q, commit_data_wakeup1_q);
                    store_data_src_id[flush_dst] <= store_data_src_id[q];
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
                store_data_ready[q] <= 1'b0;
                raw_store_data[q] <= 32'h0;
                store_data_src_id[q] <= '0;
                committed[q] <= 1'b0;
`ifndef SYNTHESIS
                entry_serial[q] <= 64'd0;
`endif
            end
            count <= flush_dst;
        end else begin
            // 1. Commit state for existing entries.  Payload/data/address are
            // updated atomically in the release/no-release branches below.
            for (q = 0; q < DEPTH; q = q + 1) begin
                if ((q < count) && entries[q].valid) begin
                    if ((commit0.valid && uop_id_equal(entries[q].uop_id, commit0.uop_id)) ||
                        (commit1.valid && uop_id_equal(entries[q].uop_id, commit1.uop_id)))
                        committed[q] <= 1'b1;
                end
            end

            // 2. Release shifting
            if (release_do) begin
`ifndef SYNTHESIS
`ifdef LSU_VERBOSE_TRACE
                $display("[%t] SQ RELEASE: PC=0x%8h, addr=0x%8h, uop_id=%d, count=%d", $time, entries[oldest_sel].pc, entries[oldest_sel].address, entries[oldest_sel].uop_id, count);
`endif
`endif
                for (j = 0; j < DEPTH-1; j = j + 1) begin
                    if ((j < oldest_sel) && (j < count)) begin
                        // Entries physically before the selected oldest do not
                        // shift, but must still consume one-cycle address/data
                        // wakeups while another Store is released.
                        entries[j] <= update_sq_metadata(
                            entries[j],
                            addr_update0_q_valid, addr_update0_q_uop_id,
                            addr_update0_q_address, addr_update0_q_unalign,
                            addr_update1_q_valid, addr_update1_q_uop_id,
                            addr_update1_q_address, addr_update1_q_unalign);
                        store_data_ready[j] <= update_sq_data_ready(
                            store_data_ready[j], entries[j].uop_id, store_data_src_id[j],
                            addr_update0_q_valid, addr_update0_q_uop_id, addr_update0_q_data_ready,
                            addr_update1_q_valid, addr_update1_q_uop_id, addr_update1_q_data_ready,
                            complete0, complete1,
                            commit_data_wakeup0_q, commit_data_wakeup1_q);
                        raw_store_data[j] <= update_sq_data_value(
                            store_data_ready[j], raw_store_data[j], entries[j].uop_id, store_data_src_id[j],
                            addr_update0_q_valid, addr_update0_q_uop_id, addr_update0_q_data_ready, addr_update0_q_data_value,
                            addr_update1_q_valid, addr_update1_q_uop_id, addr_update1_q_data_ready, addr_update1_q_data_value,
                            complete0, complete1,
                            commit_data_wakeup0_q, commit_data_wakeup1_q);
                    end else if ((j >= oldest_sel) && (j < count-1)) begin
                        entries[j] <= update_sq_metadata(
                            entries[j+1],
                            addr_update0_q_valid, addr_update0_q_uop_id,
                            addr_update0_q_address, addr_update0_q_unalign,
                            addr_update1_q_valid, addr_update1_q_uop_id,
                            addr_update1_q_address, addr_update1_q_unalign);
                        store_data_ready[j] <= update_sq_data_ready(
                            store_data_ready[j+1], entries[j+1].uop_id, store_data_src_id[j+1],
                            addr_update0_q_valid, addr_update0_q_uop_id, addr_update0_q_data_ready,
                            addr_update1_q_valid, addr_update1_q_uop_id, addr_update1_q_data_ready,
                            complete0, complete1,
                            commit_data_wakeup0_q, commit_data_wakeup1_q);
                        raw_store_data[j] <= update_sq_data_value(
                            store_data_ready[j+1], raw_store_data[j+1], entries[j+1].uop_id, store_data_src_id[j+1],
                            addr_update0_q_valid, addr_update0_q_uop_id, addr_update0_q_data_ready, addr_update0_q_data_value,
                            addr_update1_q_valid, addr_update1_q_uop_id, addr_update1_q_data_ready, addr_update1_q_data_value,
                            complete0, complete1,
                            commit_data_wakeup0_q, commit_data_wakeup1_q);
                        store_data_src_id[j] <= store_data_src_id[j+1];
                        committed[j] <= committed[j+1] ||
                            (commit0.valid && uop_id_equal(entries[j+1].uop_id, commit0.uop_id)) ||
                            (commit1.valid && uop_id_equal(entries[j+1].uop_id, commit1.uop_id));
`ifndef SYNTHESIS
                        entry_serial[j] <= entry_serial[j+1];
`endif
                    end else if (j >= oldest_sel) begin
                        entries[j] <= '0;
                        store_data_ready[j] <= 1'b0;
                        raw_store_data[j] <= 32'h0;
                        store_data_src_id[j] <= '0;
                        committed[j] <= 1'b0;
`ifndef SYNTHESIS
                        entry_serial[j] <= 64'd0;
`endif
                    end
                end
                entries[DEPTH-1] <= '0;
                store_data_ready[DEPTH-1] <= 1'b0;
                raw_store_data[DEPTH-1] <= 32'h0;
                store_data_src_id[DEPTH-1] <= '0;
                committed[DEPTH-1] <= 1'b0;
`ifndef SYNTHESIS
                entry_serial[DEPTH-1] <= 64'd0;
`endif
            end else begin
                for (q = 0; q < DEPTH; q = q + 1) begin
                    if ((q < count) && entries[q].valid) begin
                        entries[q] <= update_sq_metadata(
                            entries[q],
                            addr_update0_q_valid, addr_update0_q_uop_id,
                            addr_update0_q_address, addr_update0_q_unalign,
                            addr_update1_q_valid, addr_update1_q_uop_id,
                            addr_update1_q_address, addr_update1_q_unalign);
                        store_data_ready[q] <= update_sq_data_ready(
                            store_data_ready[q], entries[q].uop_id, store_data_src_id[q],
                            addr_update0_q_valid, addr_update0_q_uop_id, addr_update0_q_data_ready,
                            addr_update1_q_valid, addr_update1_q_uop_id, addr_update1_q_data_ready,
                            complete0, complete1,
                            commit_data_wakeup0_q, commit_data_wakeup1_q);
                        raw_store_data[q] <= update_sq_data_value(
                            store_data_ready[q], raw_store_data[q], entries[q].uop_id, store_data_src_id[q],
                            addr_update0_q_valid, addr_update0_q_uop_id, addr_update0_q_data_ready, addr_update0_q_data_value,
                            addr_update1_q_valid, addr_update1_q_uop_id, addr_update1_q_data_ready, addr_update1_q_data_value,
                            complete0, complete1,
                            commit_data_wakeup0_q, commit_data_wakeup1_q);
                    end
                end
            end

            // 3. New Reservations Insertion
            if (r0_do && r1_do) begin
`ifndef SYNTHESIS
                if (r1_older) begin
                    entry_serial[release_do ? count-1 : count] <= next_alloc_serial;
                    entry_serial[(release_do ? count-1 : count) + 1] <= next_alloc_serial + 64'd1;
                end else begin
                    entry_serial[release_do ? count-1 : count] <= next_alloc_serial;
                    entry_serial[(release_do ? count-1 : count) + 1] <= next_alloc_serial + 64'd1;
                end
                next_alloc_serial <= next_alloc_serial + 64'd2;
`endif
            end else if (r0_do || r1_do) begin
`ifndef SYNTHESIS
                entry_serial[release_do ? count-1 : count] <= next_alloc_serial;
                next_alloc_serial <= next_alloc_serial + 64'd1;
`endif
            end

            if (r0_do && r1_do && r1_older) begin
                entries[release_do ? count-1 : count] <= make_reserved_sq_entry(
                    r1_pc, r1_uop_id, r1_mask,
                    r1_has_addr, r1_addr
                );
                store_data_ready[release_do ? count-1 : count] <= 1'b0;
                raw_store_data[release_do ? count-1 : count] <= 32'h0;
                store_data_src_id[release_do ? count-1 : count] <= r1_src1_id;
                committed[release_do ? count-1 : count] <=
                    (commit0.valid && uop_id_equal(r1_uop_id, commit0.uop_id)) ||
                    (commit1.valid && uop_id_equal(r1_uop_id, commit1.uop_id));
                entries[(release_do ? count-1 : count) + 1] <= make_reserved_sq_entry(
                    r0_pc, r0_uop_id, r0_mask,
                    r0_has_addr, r0_addr
                );
                store_data_ready[(release_do ? count-1 : count) + 1] <= 1'b0;
                raw_store_data[(release_do ? count-1 : count) + 1] <= 32'h0;
                store_data_src_id[(release_do ? count-1 : count) + 1] <= r0_src1_id;
                committed[(release_do ? count-1 : count) + 1] <=
                    (commit0.valid && uop_id_equal(r0_uop_id, commit0.uop_id)) ||
                    (commit1.valid && uop_id_equal(r0_uop_id, commit1.uop_id));
            end else begin
                if (r0_do) begin
                    entries[release_do ? count-1 : count] <= make_reserved_sq_entry(
                        r0_pc, r0_uop_id, r0_mask,
                        r0_has_addr, r0_addr
                    );
                    store_data_ready[release_do ? count-1 : count] <= 1'b0;
                    raw_store_data[release_do ? count-1 : count] <= 32'h0;
                    store_data_src_id[release_do ? count-1 : count] <= r0_src1_id;
                    committed[release_do ? count-1 : count] <=
                        (commit0.valid && uop_id_equal(r0_uop_id, commit0.uop_id)) ||
                        (commit1.valid && uop_id_equal(r0_uop_id, commit1.uop_id));
                end
                if (r1_do) begin
                    entries[(release_do ? count-1 : count) + r0_do] <= make_reserved_sq_entry(
                        r1_pc, r1_uop_id, r1_mask,
                        r1_has_addr, r1_addr
                    );
                    store_data_ready[(release_do ? count-1 : count) + r0_do] <= 1'b0;
                    raw_store_data[(release_do ? count-1 : count) + r0_do] <= 32'h0;
                    store_data_src_id[(release_do ? count-1 : count) + r0_do] <= r1_src1_id;
                    committed[(release_do ? count-1 : count) + r0_do] <=
                        (commit0.valid && uop_id_equal(r1_uop_id, commit0.uop_id)) ||
                        (commit1.valid && uop_id_equal(r1_uop_id, commit1.uop_id));
                end
            end
            count <= count - release_do + r0_do + r1_do;
        end

    end

`ifndef SYNTHESIS
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

    always @(posedge clk) begin
        if (rstn && !flush) begin
            if (release_valid && (!release_entry.store_data_ready || !release_entry.valid)) begin
                $fatal(1, "StoreQueue Assertion Violation: Releasing unready store entry to SB! uop_id=%p, pc=%x", release_entry.uop_id, release_entry.pc);
            end
            if (addr_update0_q_valid && addr_update1_q_valid && uop_id_equal(addr_update0_q_uop_id, addr_update1_q_uop_id)) begin
                if (addr_update0_q_address !== addr_update1_q_address || addr_update0_q_unalign !== addr_update1_q_unalign)
                    $fatal(1, "StoreQueue Assertion Violation: Dual addr_update metadata mismatch for same uop_id");
                if (addr_update0_q_data_ready && addr_update1_q_data_ready && (addr_update0_q_data_value !== addr_update1_q_data_value))
                    $fatal(1, "StoreQueue Assertion Violation: Dual addr_update data value mismatch for same uop_id");
            end
        end
    end
`endif
endmodule
