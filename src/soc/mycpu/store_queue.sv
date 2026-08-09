`timescale 1ns / 1ps
`include "defines.vh"
import cpu_types_pkg::*;

module StoreQueue #(
    parameter integer DEPTH = 4,
    // Retained for source compatibility with older focused testbenches.  The
    // release path below always uses the narrow registered owner token; the
    // old full-packet delayed-release mode is intentionally not selectable.
    parameter bit REGISTERED_RELEASE = 1'b0
) (
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
    output logic [1:0] reserve_credit,

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

    logic store_data_ready [0:DEPTH-1];
    logic [31:0] raw_store_data [0:DEPTH-1];
    uop_id_t store_data_src_id [0:DEPTH-1];
    logic committed [0:DEPTH-1];

    completion_t commit_data_wakeup0_q;
    completion_t commit_data_wakeup1_q;

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

    // Keep the owner as a one-hot token.  The previous binary index was
    // used both for variable entry reads and for the post-release reselect;
    // that made owner_q -> owner_q a wide mux/compare feedback loop.  A
    // one-hot token lets slot reuse and owner clearing stay bit-local.  The
    // binary index below is a read-only decode for the payload view.
    logic [DEPTH-1:0] release_owner_oh_q;
    logic release_owner_valid_q;
    logic [INDEX_W-1:0] release_owner_sel_q;
    logic [DEPTH-1:0] release_owner_next_oh;
    logic release_owner_next_valid;
    logic [INDEX_W-1:0] release_owner_next_sel;
    // Release acceptance is sampled before the age tree is allowed to
    // reselect.  This removes store_data_ready from the owner register D
    // cone; the one-cycle token boundary is local to SQ and does not stall
    // the rest of the LSU.
    logic release_do_q;

    logic release_candidate_valid;
    lsu_entry_t release_candidate_entry;

    logic [DEPTH-1:0] alloc_free_mask;
    logic alloc0_found;
    logic alloc1_found;
    logic [INDEX_W-1:0] alloc0_sel;
    logic [INDEX_W-1:0] alloc1_sel;

    integer i;
    integer q;
    integer byte_i;
    integer alloc_scan;
    integer flush_dst;
    integer owner_decode_i;

    always_comb begin
        release_owner_sel_q = '0;
        release_owner_valid_q = 1'b0;
        for (
            owner_decode_i = 0;
            owner_decode_i < DEPTH;
            owner_decode_i = owner_decode_i + 1
        ) begin
            if (release_owner_oh_q[owner_decode_i]) begin
                release_owner_sel_q =
                    owner_decode_i[INDEX_W-1:0];
                // Keep the valid bit tied to the same decoded slot as the
                // binary view.  This remains safe even if a transient
                // multi-hot token is observed during recovery.
                release_owner_valid_q =
                    entries[owner_decode_i].valid;
            end
        end
    end

    function automatic [3:0] compute_store_wen(
        input [3:0] raw_mask,
        input [1:0] off
    );
        begin
            case (raw_mask)
                `RAM_WE_B:
                    compute_store_wen = 4'b0001 << off;
                `RAM_WE_H:
                    compute_store_wen =
                        off[1] ? 4'b1100 : 4'b0011;
                `RAM_WE_W:
                    compute_store_wen = 4'b1111;
                default:
                    compute_store_wen = raw_mask;
            endcase
        end
    endfunction

    function automatic [31:0] compute_aligned_data(
        input [31:0] val,
        input [3:0] raw_mask,
        input [1:0] off
    );
        begin
            case (raw_mask)
                `RAM_WE_B:
                    compute_aligned_data =
                        val[7:0] << (off * 8);
                `RAM_WE_H:
                    compute_aligned_data =
                        val[15:0] << (off[1] * 16);
                default:
                    compute_aligned_data = val;
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
            end else if (
                au0_q_valid &&
                uop_id_equal(
                    cur_entry_uop_id,
                    au0_q_uop_id
                ) &&
                au0_q_data_ready
            ) begin
                update_sq_data_ready = 1'b1;
            end else if (
                au1_q_valid &&
                uop_id_equal(
                    cur_entry_uop_id,
                    au1_q_uop_id
                ) &&
                au1_q_data_ready
            ) begin
                update_sq_data_ready = 1'b1;
            end else if (
                c0.valid &&
                c0.reg_write &&
                uop_id_equal(c0.uop_id, cur_src_id)
            ) begin
                update_sq_data_ready = 1'b1;
            end else if (
                c1.valid &&
                c1.reg_write &&
                uop_id_equal(c1.uop_id, cur_src_id)
            ) begin
                update_sq_data_ready = 1'b1;
            end else if (
                k0.valid &&
                k0.reg_write &&
                uop_id_equal(k0.uop_id, cur_src_id)
            ) begin
                update_sq_data_ready = 1'b1;
            end else if (
                k1.valid &&
                k1.reg_write &&
                uop_id_equal(k1.uop_id, cur_src_id)
            ) begin
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
            end else if (
                au0_q_valid &&
                uop_id_equal(
                    cur_entry_uop_id,
                    au0_q_uop_id
                ) &&
                au0_q_data_ready
            ) begin
                update_sq_data_value =
                    au0_q_data_value;
            end else if (
                au1_q_valid &&
                uop_id_equal(
                    cur_entry_uop_id,
                    au1_q_uop_id
                ) &&
                au1_q_data_ready
            ) begin
                update_sq_data_value =
                    au1_q_data_value;
            end else if (
                c0.valid &&
                c0.reg_write &&
                uop_id_equal(c0.uop_id, cur_src_id)
            ) begin
                update_sq_data_value = c0.value;
            end else if (
                c1.valid &&
                c1.reg_write &&
                uop_id_equal(c1.uop_id, cur_src_id)
            ) begin
                update_sq_data_value = c1.value;
            end else if (
                k0.valid &&
                k0.reg_write &&
                uop_id_equal(k0.uop_id, cur_src_id)
            ) begin
                update_sq_data_value = k0.value;
            end else if (
                k1.valid &&
                k1.reg_write &&
                uop_id_equal(k1.uop_id, cur_src_id)
            ) begin
                update_sq_data_value = k1.value;
            end else begin
                update_sq_data_value = cur_value;
            end
        end
    endfunction

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

            if (
                in_entry.valid &&
                au0_valid &&
                uop_id_equal(
                    in_entry.uop_id,
                    au0_uop_id
                )
            ) begin
                if (au0_unalign) begin
                    tmp.unaligned = 1'b1;
                    tmp.addr_ready = 1'b0;
                end else begin
                    tmp.unaligned = 1'b0;
                    tmp.address = au0_addr;
                    tmp.store_wen =
                        compute_store_wen(
                            in_entry.raw_mask,
                            au0_addr[1:0]
                        );
                    tmp.addr_ready = 1'b1;
                end
            end else if (
                in_entry.valid &&
                au1_valid &&
                uop_id_equal(
                    in_entry.uop_id,
                    au1_uop_id
                )
            ) begin
                if (au1_unalign) begin
                    tmp.unaligned = 1'b1;
                    tmp.addr_ready = 1'b0;
                end else begin
                    tmp.unaligned = 1'b0;
                    tmp.address = au1_addr;
                    tmp.store_wen =
                        compute_store_wen(
                            in_entry.raw_mask,
                            au1_addr[1:0]
                        );
                    tmp.addr_ready = 1'b1;
                end
            end

            update_sq_metadata = tmp;
        end
    endfunction

    function automatic sq_entry_t make_reserved_sq_entry(
        input [31:0] pc_value,
        input uop_id_t uop_id_value,
        input [3:0] mask,
        input logic has_addr,
        input [31:0] in_addr
    );
        sq_entry_t tmp;

        begin
            tmp = '0;
            tmp.valid = 1'b1;
            tmp.unaligned = 1'b0;
            tmp.uop_id = uop_id_value;
            tmp.pc = pc_value;
            tmp.raw_mask = mask;

            if (has_addr) begin
                tmp.addr_ready = 1'b1;
                tmp.address = in_addr;
                tmp.store_wen =
                    compute_store_wen(
                        mask,
                        in_addr[1:0]
                    );
            end else begin
                tmp.addr_ready = 1'b0;
                tmp.address = 32'h0;
                tmp.store_wen = mask;
            end

            make_reserved_sq_entry = tmp;
        end
    endfunction


    wire r0_active =
        (reserve0_valid === 1'b1) ||
        accept_valid;

    wire [31:0] r0_pc =
        accept_valid ?
            accept_entry.pc :
            reserve0_pc;

    wire uop_id_t r0_uop_id =
        accept_valid ?
            accept_entry.uop_id :
            reserve0_uop_id;

    wire [3:0] r0_mask =
        accept_valid ?
            accept_entry.store_wen :
            reserve0_store_mask;

    wire r0_src1_ready =
        accept_valid ?
            accept_entry.store_data_ready :
            (reserve0_src1_ready === 1'b1);

    wire [31:0] r0_src1_value =
        accept_valid ?
            accept_entry.store_data :
            reserve0_src1_value;

    wire uop_id_t r0_src1_id =
        accept_valid ?
            accept_entry.store_data_src_id :
            reserve0_src1_id;

    wire r0_has_addr = accept_valid;
    wire [31:0] r0_addr = accept_entry.address;

    wire r1_active =
        (reserve1_valid === 1'b1) ||
        accept1_valid;

    wire [31:0] r1_pc =
        accept1_valid ?
            accept1_entry.pc :
            reserve1_pc;

    wire uop_id_t r1_uop_id =
        accept1_valid ?
            accept1_entry.uop_id :
            reserve1_uop_id;

    wire [3:0] r1_mask =
        accept1_valid ?
            accept1_entry.store_wen :
            reserve1_store_mask;

    wire r1_src1_ready =
        accept1_valid ?
            accept1_entry.store_data_ready :
            (reserve1_src1_ready === 1'b1);

    wire [31:0] r1_src1_value =
        accept1_valid ?
            accept1_entry.store_data :
            reserve1_src1_value;

    wire uop_id_t r1_src1_id =
        accept1_valid ?
            accept1_entry.store_data_src_id :
            reserve1_src1_id;

    wire r1_has_addr = accept1_valid;
    wire [31:0] r1_addr = accept1_entry.address;

    wire both_active =
        r0_active &&
        r1_active;

    wire r1_older =
        both_active &&
        uop_is_younger(
            r0_uop_id,
            r1_uop_id
        );

    assign accept_ready = reserve0_ready;
    assign accept1_ready = reserve1_ready;

    wire r0_do =
        !flush &&
        r0_active &&
        reserve0_ready;

    wire r1_do =
        !flush &&
        r1_active &&
        reserve1_ready;

    wire r0_addr_data_match0 =
        r0_do &&
        addr_update0_valid &&
        uop_id_equal(
            r0_uop_id,
            addr_update0_uop_id
        ) &&
        addr_update0_data_ready;

    wire r0_addr_data_match1 =
        r0_do &&
        addr_update1_valid &&
        uop_id_equal(
            r0_uop_id,
            addr_update1_uop_id
        ) &&
        addr_update1_data_ready;

    wire r1_addr_data_match0 =
        r1_do &&
        addr_update0_valid &&
        uop_id_equal(
            r1_uop_id,
            addr_update0_uop_id
        ) &&
        addr_update0_data_ready;

    wire r1_addr_data_match1 =
        r1_do &&
        addr_update1_valid &&
        uop_id_equal(
            r1_uop_id,
            addr_update1_uop_id
        ) &&
        addr_update1_data_ready;

    wire r0_complete_data_match0 =
        complete0.valid &&
        complete0.reg_write &&
        uop_id_equal(
            complete0.uop_id,
            r0_src1_id
        );

    wire r0_complete_data_match1 =
        complete1.valid &&
        complete1.reg_write &&
        uop_id_equal(
            complete1.uop_id,
            r0_src1_id
        );

    wire r1_complete_data_match0 =
        complete0.valid &&
        complete0.reg_write &&
        uop_id_equal(
            complete0.uop_id,
            r1_src1_id
        );

    wire r1_complete_data_match1 =
        complete1.valid &&
        complete1.reg_write &&
        uop_id_equal(
            complete1.uop_id,
            r1_src1_id
        );

    wire r0_initial_data_ready =
        r0_src1_ready ||
        r0_addr_data_match0 ||
        r0_addr_data_match1 ||
        r0_complete_data_match0 ||
        r0_complete_data_match1;

    wire r1_initial_data_ready =
        r1_src1_ready ||
        r1_addr_data_match0 ||
        r1_addr_data_match1 ||
        r1_complete_data_match0 ||
        r1_complete_data_match1;

    wire [31:0] r0_initial_data_value =
        r0_src1_ready ?
            r0_src1_value :
        r0_addr_data_match0 ?
            addr_update0_data_value :
        r0_addr_data_match1 ?
            addr_update1_data_value :
        r0_complete_data_match0 ?
            complete0.value :
        r0_complete_data_match1 ?
            complete1.value :
            32'h0;

    wire [31:0] r1_initial_data_value =
        r1_src1_ready ?
            r1_src1_value :
        r1_addr_data_match0 ?
            addr_update0_data_value :
        r1_addr_data_match1 ?
            addr_update1_data_value :
        r1_complete_data_match0 ?
            complete0.value :
        r1_complete_data_match1 ?
            complete1.value :
            32'h0;

    wire r0_commit_now =
        r0_do &&
        (
            (
                commit0.valid &&
                uop_id_equal(
                    r0_uop_id,
                    commit0.uop_id
                )
            ) ||
            (
                commit1.valid &&
                uop_id_equal(
                    r0_uop_id,
                    commit1.uop_id
                )
            )
        );

    wire r1_commit_now =
        r1_do &&
        (
            (
                commit0.valid &&
                uop_id_equal(
                    r1_uop_id,
                    commit0.uop_id
                )
            ) ||
            (
                commit1.valid &&
                uop_id_equal(
                    r1_uop_id,
                    commit1.uop_id
                )
            )
        );

    wire release_do =
        !flush &&
        release_candidate_valid &&
        release_fire;

    wire release_owner_hold =
        !flush &&
        release_candidate_valid &&
        !release_fire;

    wire release_owner_reselect =
        (
            release_do_q ||
            r0_do ||
            r1_do ||
            (
                !release_owner_valid_q &&
                (count != 0)
            )
        );

    wire [COUNT_W:0] free_slots =
        (DEPTH - count) +
        {{COUNT_W{1'b0}}, release_do};

    wire [COUNT_W:0] reserve_visible_slots =
        free_slots;

    wire [COUNT_W:0] reserve_credit_slots =
        free_slots;

    assign reserve_credit =
        flush ?
            2'd0 :
        (reserve_credit_slots >= 3) ?
            2'd3 :
            reserve_credit_slots[1:0];

    always_comb begin
        alloc_free_mask = '0;
        alloc0_found = 1'b0;
        alloc1_found = 1'b0;
        alloc0_sel = '0;
        alloc1_sel = '0;

        for (
            alloc_scan = 0;
            alloc_scan < DEPTH;
            alloc_scan = alloc_scan + 1
        ) begin
            alloc_free_mask[alloc_scan] =
                !entries[alloc_scan].valid ||
                (
                    release_do &&
                    release_owner_oh_q[alloc_scan]
                );

            if (alloc_free_mask[alloc_scan]) begin
                if (!alloc0_found) begin
                    alloc0_found = 1'b1;
                    alloc0_sel =
                        alloc_scan[INDEX_W-1:0];
                end else if (!alloc1_found) begin
                    alloc1_found = 1'b1;
                    alloc1_sel =
                        alloc_scan[INDEX_W-1:0];
                end
            end
        end
    end

    always_comb begin
        addr_update0_ack = 1'b0;

        if (!flush && addr_update0_valid) begin
            for (
                integer addr_scan0 = 0;
                addr_scan0 < DEPTH;
                addr_scan0 = addr_scan0 + 1
            ) begin
                if (
                    entries[addr_scan0].valid &&
                    !entries[addr_scan0].unaligned &&
                    uop_id_equal(
                        entries[addr_scan0].uop_id,
                        addr_update0_uop_id
                    )
                )
                    addr_update0_ack = 1'b1;
            end

            if (
                r0_do &&
                uop_id_equal(
                    r0_uop_id,
                    addr_update0_uop_id
                )
            )
                addr_update0_ack = 1'b1;

            if (
                r1_do &&
                uop_id_equal(
                    r1_uop_id,
                    addr_update0_uop_id
                )
            )
                addr_update0_ack = 1'b1;
        end

        addr_update1_ack = 1'b0;

        if (!flush && addr_update1_valid) begin
            for (
                integer addr_scan1 = 0;
                addr_scan1 < DEPTH;
                addr_scan1 = addr_scan1 + 1
            ) begin
                if (
                    entries[addr_scan1].valid &&
                    !entries[addr_scan1].unaligned &&
                    uop_id_equal(
                        entries[addr_scan1].uop_id,
                        addr_update1_uop_id
                    )
                )
                    addr_update1_ack = 1'b1;
            end

            if (
                r0_do &&
                uop_id_equal(
                    r0_uop_id,
                    addr_update1_uop_id
                )
            )
                addr_update1_ack = 1'b1;

            if (
                r1_do &&
                uop_id_equal(
                    r1_uop_id,
                    addr_update1_uop_id
                )
            )
                addr_update1_ack = 1'b1;
        end
    end

    always_comb begin
        release_candidate_valid =
            !flush &&
            release_owner_valid_q &&
            entries[release_owner_sel_q].valid &&
            !entries[release_owner_sel_q].unaligned &&
            committed[release_owner_sel_q] &&
            entries[release_owner_sel_q].addr_ready &&
            store_data_ready[release_owner_sel_q];

        release_candidate_entry = '0;

        if (release_candidate_valid) begin
            release_candidate_entry.valid = 1'b1;

            release_candidate_entry.uop_id =
                entries[release_owner_sel_q].uop_id;

            release_candidate_entry.pc =
                entries[release_owner_sel_q].pc;

            release_candidate_entry.address =
                entries[release_owner_sel_q].address;

            release_candidate_entry.store_wen =
                entries[release_owner_sel_q].store_wen;

            release_candidate_entry.store_data =
                compute_aligned_data(
                    raw_store_data[
                        release_owner_sel_q
                    ],
                    entries[
                        release_owner_sel_q
                    ].raw_mask,
                    entries[
                        release_owner_sel_q
                    ].address[1:0]
                );

            release_candidate_entry.store_data_ready =
                1'b1;

            release_candidate_entry.store_data_src_id =
                store_data_src_id[
                    release_owner_sel_q
                ];
        end
    end

    always_comb begin
        reserve0_ready = 1'b0;
        reserve1_ready = 1'b0;

        if (
            !flush &&
            (reserve_visible_slots != 0)
        ) begin
            if (reserve_visible_slots >= 2) begin
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

        release_entry = '0;
        release_valid = release_candidate_valid;

        if (release_valid)
            release_entry =
                release_candidate_entry;

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
            valid_vec[i] =
                !flush &&
                entries[i].valid;

            addr_ready_vec[i] =
                valid_vec[i] &&
                entries[i].addr_ready;

            store_data_ready_vec[i] =
                valid_vec[i] &&
                store_data_ready[i];

            addr_flat[i*32 +: 32] =
                entries[i].address;

            uop_id_flat[
                i*`UOP_ID_W +: `UOP_ID_W
            ] = entries[i].uop_id;

            store_wen_flat[i*4 +: 4] =
                entries[i].store_wen;

            store_data_flat[i*32 +: 32] =
                compute_aligned_data(
                    raw_store_data[i],
                    entries[i].raw_mask,
                    entries[i].address[1:0]
                );

            for (
                byte_i = 0;
                byte_i < 4;
                byte_i = byte_i + 1
            ) begin
                store_byte_uop_id_flat[
                    (i*4 + byte_i)*`UOP_ID_W
                    +: `UOP_ID_W
                ] = entries[i].uop_id;
            end
        end
    end

    always_comb begin : release_owner_next_logic
        logic [DEPTH-1:0] next_slot_valid;
        uop_id_t          next_slot_uop_id [0:DEPTH-1];

        // The production StoreQueue depth is four.  Use a balanced
        // tournament for the owner decision instead of the all-pairs
        // has_older matrix followed by a priority encoder.  The latter
        // replicated the age compare and encoded every physical slot in one
        // long cone ending at release_owner_sel_q.D.
        logic             pair01_valid;
        logic             pair23_valid;
        logic             root_valid;
        logic [INDEX_W-1:0] pair01_sel;
        logic [INDEX_W-1:0] pair23_sel;
        logic [INDEX_W-1:0] root_sel;
        uop_id_t           pair01_id;
        uop_id_t           pair23_id;
        uop_id_t           root_id;

        // Retain a generic fallback for focused parameterized testbenches;
        // DEPTH=4 takes only the balanced path above.
        logic [DEPTH-1:0] has_older;
        logic [DEPTH-1:0] oldest_onehot;

        logic [INDEX_W-1:0] r1_alloc_sel;
        logic select_found;

        integer owner_i;
        integer owner_j;

        for (
            owner_i = 0;
            owner_i < DEPTH;
            owner_i = owner_i + 1
        ) begin
            next_slot_valid[owner_i] =
                entries[owner_i].valid;

            next_slot_uop_id[owner_i] =
                entries[owner_i].uop_id;
        end

        if (
            release_do_q &&
            release_owner_valid_q &&
            !entries[release_owner_sel_q].valid
        ) begin
            // Clear the released slot bitwise.  Do not feed the decoded
            // binary index back through a variable array read on the owner
            // reselect path.
            for (
                owner_i = 0;
                owner_i < DEPTH;
                owner_i = owner_i + 1
            ) begin
                if (release_owner_oh_q[owner_i]) begin
                    next_slot_valid[owner_i] = 1'b0;
                    next_slot_uop_id[owner_i] = '0;
                end
            end
        end

        if (r0_do) begin
            next_slot_valid[
                alloc0_sel
            ] = 1'b1;

            next_slot_uop_id[
                alloc0_sel
            ] = r0_uop_id;
        end

        r1_alloc_sel =
            r0_do ?
                alloc1_sel :
                alloc0_sel;

        if (r1_do) begin
            next_slot_valid[
                r1_alloc_sel
            ] = 1'b1;

            next_slot_uop_id[
                r1_alloc_sel
            ] = r1_uop_id;
        end

        release_owner_next_oh = '0;
        pair01_valid = 1'b0;
        pair23_valid = 1'b0;
        root_valid = 1'b0;
        pair01_sel = '0;
        pair23_sel = '0;
        root_sel = '0;
        pair01_id = '0;
        pair23_id = '0;
        root_id = '0;

        if (DEPTH == 4) begin
            // First level: oldest of physical slots 0/1.
            if (next_slot_valid[0]) begin
                pair01_valid = 1'b1;
                pair01_sel = '0;
                pair01_id = next_slot_uop_id[0];
            end
            if (next_slot_valid[1]) begin
                if (!pair01_valid ||
                    uop_is_younger(
                        pair01_id,
                        next_slot_uop_id[1]
                    )) begin
                    pair01_valid = 1'b1;
                    pair01_sel = 1;
                    pair01_id = next_slot_uop_id[1];
                end
            end

            // First level: oldest of physical slots 2/3.
            if (next_slot_valid[2]) begin
                pair23_valid = 1'b1;
                pair23_sel = 2;
                pair23_id = next_slot_uop_id[2];
            end
            if (next_slot_valid[3]) begin
                if (!pair23_valid ||
                    uop_is_younger(
                        pair23_id,
                        next_slot_uop_id[3]
                    )) begin
                    pair23_valid = 1'b1;
                    pair23_sel = 3;
                    pair23_id = next_slot_uop_id[3];
                end
            end

            // Second level: oldest winner of the two pairs.
            if (pair01_valid) begin
                root_valid = 1'b1;
                root_sel = pair01_sel;
                root_id = pair01_id;
            end
            if (pair23_valid) begin
                if (!root_valid ||
                    uop_is_younger(
                        root_id,
                        pair23_id
                    )) begin
                    root_valid = 1'b1;
                    root_sel = pair23_sel;
                    root_id = pair23_id;
                end
            end

            release_owner_next_valid =
                !flush && root_valid;
            release_owner_next_sel =
                root_sel;
            if (!flush && root_valid)
                release_owner_next_oh[root_sel] = 1'b1;
        end else begin
            // Generic fallback for non-production queue depths.
            has_older = '0;
            for (
                owner_i = 0;
                owner_i < DEPTH;
                owner_i = owner_i + 1
            ) begin
                for (
                    owner_j = 0;
                    owner_j < DEPTH;
                    owner_j = owner_j + 1
                ) begin
                    if (
                        (owner_i != owner_j) &&
                        next_slot_valid[owner_i] &&
                        next_slot_valid[owner_j] &&
                        uop_is_younger(
                            next_slot_uop_id[owner_i],
                            next_slot_uop_id[owner_j]
                        )
                    ) begin
                        has_older[owner_i] = 1'b1;
                    end
                end
            end

            oldest_onehot = '0;
            for (
                owner_i = 0;
                owner_i < DEPTH;
                owner_i = owner_i + 1
            ) begin
                oldest_onehot[owner_i] =
                    next_slot_valid[owner_i] &&
                    !has_older[owner_i];
            end

            release_owner_next_valid = 1'b0;
            release_owner_next_sel = '0;
            select_found = 1'b0;
            if (!flush) begin
                for (
                    owner_i = 0;
                    owner_i < DEPTH;
                    owner_i = owner_i + 1
                ) begin
                    if (oldest_onehot[owner_i] && !select_found) begin
                        release_owner_next_valid = 1'b1;
                        release_owner_next_sel =
                            owner_i[INDEX_W-1:0];
                        select_found = 1'b1;
                    end
                end
            end

            if (release_owner_next_valid)
                release_owner_next_oh[release_owner_next_sel] = 1'b1;
        end
    end

    always_ff @(posedge clk or negedge rstn) begin
        if (!rstn || flush) begin
            release_owner_oh_q <= '0;
            release_do_q <= 1'b0;
        end else if (release_owner_reselect) begin
            release_owner_oh_q <=
                release_owner_next_oh;
            release_do_q <= release_do;
        end else begin
            release_do_q <= release_do;
        end
    end

    always_ff @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            commit_data_wakeup0_q <= '0;
            commit_data_wakeup1_q <= '0;
        end else begin
            commit_data_wakeup0_q.valid <=
                commit0.valid &&
                commit0.reg_write;

            commit_data_wakeup0_q.uop_id <=
                commit0.uop_id;

            commit_data_wakeup0_q.value <=
                commit0.value;

            commit_data_wakeup0_q.reg_write <=
                commit0.reg_write;

            commit_data_wakeup1_q.valid <=
                commit1.valid &&
                commit1.reg_write;

            commit_data_wakeup1_q.uop_id <=
                commit1.uop_id;

            commit_data_wakeup1_q.value <=
                commit1.value;

            commit_data_wakeup1_q.reg_write <=
                commit1.reg_write;
        end
    end

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
            addr_update0_q_valid <=
                addr_update0_valid &&
                addr_update0_ack;

            if (
                addr_update0_valid &&
                addr_update0_ack
            ) begin
                addr_update0_q_uop_id <=
                    addr_update0_uop_id;

                addr_update0_q_address <=
                    addr_update0_address;

                addr_update0_q_unalign <=
                    addr_update0_unalign;

                addr_update0_q_data_ready <=
                    addr_update0_data_ready;

                addr_update0_q_data_value <=
                    addr_update0_data_value;

                addr_update0_q_data_src_id <=
                    addr_update0_data_src_id;
            end

            addr_update1_q_valid <=
                addr_update1_valid &&
                addr_update1_ack;

            if (
                addr_update1_valid &&
                addr_update1_ack
            ) begin
                addr_update1_q_uop_id <=
                    addr_update1_uop_id;

                addr_update1_q_address <=
                    addr_update1_address;

                addr_update1_q_unalign <=
                    addr_update1_unalign;

                addr_update1_q_data_ready <=
                    addr_update1_data_ready;

                addr_update1_q_data_value <=
                    addr_update1_data_value;

                addr_update1_q_data_src_id <=
                    addr_update1_data_src_id;
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

            end

        end else if (flush) begin
            flush_dst = 0;

            for (q = 0; q < DEPTH; q = q + 1) begin
                if (
                    entries[q].valid &&
                    (
                        committed[q] ||
                        (
                            commit0.valid &&
                            uop_id_equal(
                                entries[q].uop_id,
                                commit0.uop_id
                            )
                        ) ||
                        (
                            commit1.valid &&
                            uop_id_equal(
                                entries[q].uop_id,
                                commit1.uop_id
                            )
                        ) ||
                        (
                            !system_flush &&
                            recover_valid &&
                            !uop_is_younger(
                                entries[q].uop_id,
                                recover_id
                            )
                        )
                    )
                ) begin
                    entries[q] <=
                        update_sq_metadata(
                            entries[q],
                            addr_update0_q_valid,
                            addr_update0_q_uop_id,
                            addr_update0_q_address,
                            addr_update0_q_unalign,
                            addr_update1_q_valid,
                            addr_update1_q_uop_id,
                            addr_update1_q_address,
                            addr_update1_q_unalign
                        );

                    store_data_ready[q] <=
                        update_sq_data_ready(
                            store_data_ready[q],
                            entries[q].uop_id,
                            store_data_src_id[q],
                            addr_update0_q_valid,
                            addr_update0_q_uop_id,
                            addr_update0_q_data_ready,
                            addr_update1_q_valid,
                            addr_update1_q_uop_id,
                            addr_update1_q_data_ready,
                            complete0,
                            complete1,
                            commit_data_wakeup0_q,
                            commit_data_wakeup1_q
                        );

                    raw_store_data[q] <=
                        update_sq_data_value(
                            store_data_ready[q],
                            raw_store_data[q],
                            entries[q].uop_id,
                            store_data_src_id[q],
                            addr_update0_q_valid,
                            addr_update0_q_uop_id,
                            addr_update0_q_data_ready,
                            addr_update0_q_data_value,
                            addr_update1_q_valid,
                            addr_update1_q_uop_id,
                            addr_update1_q_data_ready,
                            addr_update1_q_data_value,
                            complete0,
                            complete1,
                            commit_data_wakeup0_q,
                            commit_data_wakeup1_q
                        );

                    committed[q] <=
                        committed[q] ||
                        (
                            commit0.valid &&
                            uop_id_equal(
                                entries[q].uop_id,
                                commit0.uop_id
                            )
                        ) ||
                        (
                            commit1.valid &&
                            uop_id_equal(
                                entries[q].uop_id,
                                commit1.uop_id
                            )
                        );

                    flush_dst = flush_dst + 1;
                end else begin
                    entries[q] <= '0;
                    store_data_ready[q] <= 1'b0;
                    committed[q] <= 1'b0;

                end
            end

            count <= flush_dst;
        end else begin
            for (q = 0; q < DEPTH; q = q + 1) begin
                if (entries[q].valid) begin
                    entries[q] <=
                        update_sq_metadata(
                            entries[q],
                            addr_update0_q_valid,
                            addr_update0_q_uop_id,
                            addr_update0_q_address,
                            addr_update0_q_unalign,
                            addr_update1_q_valid,
                            addr_update1_q_uop_id,
                            addr_update1_q_address,
                            addr_update1_q_unalign
                        );

                    store_data_ready[q] <=
                        update_sq_data_ready(
                            store_data_ready[q],
                            entries[q].uop_id,
                            store_data_src_id[q],
                            addr_update0_q_valid,
                            addr_update0_q_uop_id,
                            addr_update0_q_data_ready,
                            addr_update1_q_valid,
                            addr_update1_q_uop_id,
                            addr_update1_q_data_ready,
                            complete0,
                            complete1,
                            commit_data_wakeup0_q,
                            commit_data_wakeup1_q
                        );

                    raw_store_data[q] <=
                        update_sq_data_value(
                            store_data_ready[q],
                            raw_store_data[q],
                            entries[q].uop_id,
                            store_data_src_id[q],
                            addr_update0_q_valid,
                            addr_update0_q_uop_id,
                            addr_update0_q_data_ready,
                            addr_update0_q_data_value,
                            addr_update1_q_valid,
                            addr_update1_q_uop_id,
                            addr_update1_q_data_ready,
                            addr_update1_q_data_value,
                            complete0,
                            complete1,
                            commit_data_wakeup0_q,
                            commit_data_wakeup1_q
                        );

                    if (
                        (
                            commit0.valid &&
                            uop_id_equal(
                                entries[q].uop_id,
                                commit0.uop_id
                            )
                        ) ||
                        (
                            commit1.valid &&
                            uop_id_equal(
                                entries[q].uop_id,
                                commit1.uop_id
                            )
                        )
                    )
                        committed[q] <= 1'b1;
                end
            end

            if (release_do) begin
                entries[release_owner_sel_q] <= '0;

                store_data_ready[
                    release_owner_sel_q
                ] <= 1'b0;

                committed[
                    release_owner_sel_q
                ] <= 1'b0;

            end

            if (r0_do) begin
                entries[alloc0_sel] <=
                    make_reserved_sq_entry(
                        r0_pc,
                        r0_uop_id,
                        r0_mask,
                        r0_has_addr,
                        r0_addr
                    );

                store_data_ready[alloc0_sel] <=
                    r0_initial_data_ready;

                raw_store_data[alloc0_sel] <=
                    r0_initial_data_value;

                store_data_src_id[alloc0_sel] <=
                    r0_src1_id;

                committed[alloc0_sel] <=
                    r0_commit_now;

            end

            if (r1_do) begin
                entries[
                    r0_do ?
                        alloc1_sel :
                        alloc0_sel
                ] <= make_reserved_sq_entry(
                    r1_pc,
                    r1_uop_id,
                    r1_mask,
                    r1_has_addr,
                    r1_addr
                );

                store_data_ready[
                    r0_do ?
                        alloc1_sel :
                        alloc0_sel
                ] <= r1_initial_data_ready;

                raw_store_data[
                    r0_do ?
                        alloc1_sel :
                        alloc0_sel
                ] <= r1_initial_data_value;

                store_data_src_id[
                    r0_do ?
                        alloc1_sel :
                        alloc0_sel
                ] <= r1_src1_id;

                committed[
                    r0_do ?
                        alloc1_sel :
                        alloc0_sel
                ] <= r1_commit_now;

            end


            count <=
                count -
                release_do +
                r0_do +
                r1_do;
        end
    end


endmodule
