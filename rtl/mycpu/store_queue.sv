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

    logic release_owner_valid_q;
    logic [INDEX_W-1:0] release_owner_sel_q;
    logic release_owner_next_valid;
    logic [INDEX_W-1:0] release_owner_next_sel;

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
    integer owner_scan;
    integer alloc_scan;
    integer flush_dst;

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

`ifndef SYNTHESIS
    localparam integer RELEASE_HISTORY_DEPTH = 16;

    logic release_history_valid
        [0:RELEASE_HISTORY_DEPTH-1];

    uop_id_t release_history_id
        [0:RELEASE_HISTORY_DEPTH-1];

    logic [31:0] release_history_pc
        [0:RELEASE_HISTORY_DEPTH-1];

    logic [63:0] release_history_serial
        [0:RELEASE_HISTORY_DEPTH-1];

    logic [63:0] entry_serial [0:DEPTH-1];
    logic [63:0] next_alloc_serial;

    wire [63:0] release_serial =
        release_owner_valid_q ?
            entry_serial[release_owner_sel_q] :
            64'd0;
`endif

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
                    release_owner_valid_q &&
                    (
                        release_owner_sel_q ==
                        alloc_scan
                    )
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
        logic candidate_valid;
        uop_id_t candidate_id;
        logic [INDEX_W-1:0] candidate_sel;
        logic [INDEX_W-1:0] r1_alloc_sel;

        candidate_valid = 1'b0;
        candidate_id = '0;
        candidate_sel = '0;

        r1_alloc_sel =
            r0_do ?
                alloc1_sel :
                alloc0_sel;

        if (!flush) begin
            if (
                release_candidate_valid &&
                !release_fire
            ) begin
                candidate_valid = 1'b1;

                candidate_id =
                    entries[
                        release_owner_sel_q
                    ].uop_id;

                candidate_sel =
                    release_owner_sel_q;
            end else begin
                for (
                    owner_scan = 0;
                    owner_scan < DEPTH;
                    owner_scan = owner_scan + 1
                ) begin
                    if (
                        entries[owner_scan].valid &&
                        !(
                            release_do &&
                            release_owner_valid_q &&
                            (
                                owner_scan ==
                                release_owner_sel_q
                            )
                        )
                    ) begin
                        if (
                            !candidate_valid ||
                            uop_is_younger(
                                candidate_id,
                                entries[
                                    owner_scan
                                ].uop_id
                            )
                        ) begin
                            candidate_valid = 1'b1;

                            candidate_id =
                                entries[
                                    owner_scan
                                ].uop_id;

                            candidate_sel =
                                owner_scan[
                                    INDEX_W-1:0
                                ];
                        end
                    end
                end

                if (r0_do) begin
                    if (
                        !candidate_valid ||
                        uop_is_younger(
                            candidate_id,
                            r0_uop_id
                        )
                    ) begin
                        candidate_valid = 1'b1;
                        candidate_id = r0_uop_id;
                        candidate_sel = alloc0_sel;
                    end
                end

                if (r1_do) begin
                    if (
                        !candidate_valid ||
                        uop_is_younger(
                            candidate_id,
                            r1_uop_id
                        )
                    ) begin
                        candidate_valid = 1'b1;
                        candidate_id = r1_uop_id;
                        candidate_sel = r1_alloc_sel;
                    end
                end
            end
        end

        release_owner_next_valid =
            candidate_valid;

        release_owner_next_sel =
            candidate_sel;
    end

    always_ff @(posedge clk or negedge rstn) begin
        if (!rstn || flush) begin
            release_owner_valid_q <= 1'b0;
            release_owner_sel_q <= '0;
        end else begin
            release_owner_valid_q <=
                release_owner_next_valid;

            release_owner_sel_q <=
                release_owner_next_sel;
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

`ifndef SYNTHESIS
                    entry_serial[q] <= 64'd0;
`endif
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
`ifndef SYNTHESIS
`ifdef LSU_VERBOSE_TRACE
                $display(
                    "[%t] SQ RELEASE: PC=0x%8h, addr=0x%8h, uop_id=%d, count=%d",
                    $time,
                    entries[release_owner_sel_q].pc,
                    entries[release_owner_sel_q].address,
                    entries[release_owner_sel_q].uop_id,
                    count
                );
`endif
`endif
                entries[release_owner_sel_q] <= '0;

                store_data_ready[
                    release_owner_sel_q
                ] <= 1'b0;

                committed[
                    release_owner_sel_q
                ] <= 1'b0;

`ifndef SYNTHESIS
                entry_serial[
                    release_owner_sel_q
                ] <= 64'd0;
`endif
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

`ifndef SYNTHESIS
                entry_serial[alloc0_sel] <=
                    next_alloc_serial;
`endif
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

`ifndef SYNTHESIS
                entry_serial[
                    r0_do ?
                        alloc1_sel :
                        alloc0_sel
                ] <= next_alloc_serial + r0_do;
`endif
            end

`ifndef SYNTHESIS
            if (r0_do || r1_do)
                next_alloc_serial <=
                    next_alloc_serial +
                    r0_do +
                    r1_do;
`endif

            count <=
                count -
                release_do +
                r0_do +
                r1_do;
        end
    end

`ifndef SYNTHESIS
    always @(posedge clk or negedge rstn) begin
        integer history_index;

        if (!rstn || flush) begin
            for (
                history_index = 0;
                history_index < RELEASE_HISTORY_DEPTH;
                history_index = history_index + 1
            ) begin
                release_history_valid[
                    history_index
                ] <= 1'b0;

                release_history_id[
                    history_index
                ] <= '0;

                release_history_pc[
                    history_index
                ] <= 32'h0;

                release_history_serial[
                    history_index
                ] <= 64'd0;
            end
        end else if (release_do) begin
            for (
                history_index = 0;
                history_index < RELEASE_HISTORY_DEPTH;
                history_index = history_index + 1
            ) begin
                if (
                    release_history_valid[
                        history_index
                    ] &&
                    (
                        release_history_serial[
                            history_index
                        ] == release_serial
                    )
                )
                    $fatal(
                        1,
                        "StoreQueue released the same entry more than once"
                    );
            end

            for (
                history_index = RELEASE_HISTORY_DEPTH-1;
                history_index > 0;
                history_index = history_index - 1
            ) begin
                release_history_valid[
                    history_index
                ] <= release_history_valid[
                    history_index-1
                ];

                release_history_id[
                    history_index
                ] <= release_history_id[
                    history_index-1
                ];

                release_history_pc[
                    history_index
                ] <= release_history_pc[
                    history_index-1
                ];

                release_history_serial[
                    history_index
                ] <= release_history_serial[
                    history_index-1
                ];
            end

            release_history_valid[0] <= 1'b1;
            release_history_id[0] <= release_entry.uop_id;
            release_history_pc[0] <= release_entry.pc;
            release_history_serial[0] <= release_serial;
        end
    end

    always @(posedge clk) begin
        if (rstn && !flush) begin
            if (
                release_valid &&
                (
                    !release_entry.store_data_ready ||
                    !release_entry.valid
                )
            )
                $fatal(
                    1,
                    "StoreQueue Assertion Violation: Releasing unready store entry to SB! uop_id=%p, pc=%x",
                    release_entry.uop_id,
                    release_entry.pc
                );

            if (
                addr_update0_q_valid &&
                addr_update1_q_valid &&
                uop_id_equal(
                    addr_update0_q_uop_id,
                    addr_update1_q_uop_id
                )
            ) begin
                if (
                    (
                        addr_update0_q_address !==
                        addr_update1_q_address
                    ) ||
                    (
                        addr_update0_q_unalign !==
                        addr_update1_q_unalign
                    )
                )
                    $fatal(
                        1,
                        "StoreQueue Assertion Violation: Dual addr_update metadata mismatch for same uop_id"
                    );

                if (
                    addr_update0_q_data_ready &&
                    addr_update1_q_data_ready &&
                    (
                        addr_update0_q_data_value !==
                        addr_update1_q_data_value
                    )
                )
                    $fatal(
                        1,
                        "StoreQueue Assertion Violation: Dual addr_update data value mismatch for same uop_id"
                    );
            end

            if (r0_do && !alloc0_found)
                $fatal(
                    1,
                    "StoreQueue reservation0 accepted without a free slot"
                );

            if (
                r1_do &&
                r0_do &&
                !alloc1_found
            )
                $fatal(
                    1,
                    "StoreQueue reservation1 accepted without a second free slot"
                );

            if (
                r1_do &&
                !r0_do &&
                !alloc0_found
            )
                $fatal(
                    1,
                    "StoreQueue reservation1 accepted without a free slot"
                );
        end
    end
`endif

endmodule