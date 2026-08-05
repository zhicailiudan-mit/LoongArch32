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

    // Allocation payload registers.  Reservation only writes the narrow
    // entry header; the wide store data (value + readiness) is captured
    // into these two fixed registers on the reservation edge and written
    // back into the physical raw_store_data array on the following cycle
    // by uop_id match.  This removes the variable-indexed wide write from
    // the reservation D cone (credit loop -> alloc select -> raw_store_data
    // write port).  The effective_* bypass below keeps release and
    // forwarding visibility unchanged.
    typedef struct packed {
        logic        valid;
        uop_id_t     uop_id;
        logic        data_ready;
        logic [31:0] data_value;
    } sq_alloc_data_t;

    sq_alloc_data_t alloc_data0_q;
    sq_alloc_data_t alloc_data1_q;

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
    // Oldest and second-oldest pre-selections, registered every cycle from
    // a bounded age tournament over the release-cleared entry array.  The
    // owner register D cone is then only a two-input mux of registered
    // one-hot tokens; the deep age tree reaches the owner one cycle later
    // through these pre-select registers instead of being recomputed on the
    // release cycle.  The registered ids exist for invariant assertions.
    logic [DEPTH-1:0] release_first_oh_q;
    logic release_first_valid_q;
    uop_id_t release_first_id_q;
    logic [DEPTH-1:0] release_second_oh_q;
    logic release_second_valid_q;
    uop_id_t release_second_id_q;
    logic [DEPTH-1:0] release_first_next_oh;
    logic release_first_next_valid;
    uop_id_t release_first_next_id;
    logic [DEPTH-1:0] release_second_next_oh;
    logic release_second_next_valid;
    uop_id_t release_second_next_id;
`ifndef SYNTHESIS
    logic release_stall_q;
    logic release_owner_valid_prev_q;
    logic [INDEX_W-1:0] release_owner_sel_prev_q;
`endif

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
        input logic ad0_q_valid,
        input uop_id_t ad0_q_uop_id,
        input logic ad0_q_data_ready,
        input logic ad1_q_valid,
        input uop_id_t ad1_q_uop_id,
        input logic ad1_q_data_ready,
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
                ad0_q_valid &&
                uop_id_equal(
                    cur_entry_uop_id,
                    ad0_q_uop_id
                ) &&
                ad0_q_data_ready
            ) begin
                update_sq_data_ready = 1'b1;
            end else if (
                ad1_q_valid &&
                uop_id_equal(
                    cur_entry_uop_id,
                    ad1_q_uop_id
                ) &&
                ad1_q_data_ready
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
        input logic ad0_q_valid,
        input uop_id_t ad0_q_uop_id,
        input logic ad0_q_data_ready,
        input logic [31:0] ad0_q_data_value,
        input logic ad1_q_valid,
        input uop_id_t ad1_q_uop_id,
        input logic ad1_q_data_ready,
        input logic [31:0] ad1_q_data_value,
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
                ad0_q_valid &&
                uop_id_equal(
                    cur_entry_uop_id,
                    ad0_q_uop_id
                ) &&
                ad0_q_data_ready
            ) begin
                update_sq_data_value =
                    ad0_q_data_value;
            end else if (
                ad1_q_valid &&
                uop_id_equal(
                    cur_entry_uop_id,
                    ad1_q_uop_id
                ) &&
                ad1_q_data_ready
            ) begin
                update_sq_data_value =
                    ad1_q_data_value;
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
                (
                    !entries[alloc_scan].valid &&
                    !(
                        reserve0_payload_q.valid &&
                        (
                            reserve0_payload_q.alloc_sel ==
                            alloc_scan[INDEX_W-1:0]
                        )
                    ) &&
                    !(
                        reserve1_payload_q.valid &&
                        (
                            reserve1_payload_q.alloc_sel ==
                            alloc_scan[INDEX_W-1:0]
                        )
                    )
                ) || (
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

`ifndef SYNTHESIS
    // Deadlock-diagnosis trace: store address pipeline events.
    always @(posedge clk) begin
        if (rstn && !flush) begin
            if (r0_do)
                $display("[SQ-TRACE %0t] r0_do uop={ep:%0d,tag:%0d} has_addr=%b addr=%x ack=%b",
                         $time, r0_uop_id.epoch, r0_uop_id.rob_tag, r0_has_addr, r0_addr, addr_update0_ack);
            if (r1_do)
                $display("[SQ-TRACE %0t] r1_do uop={ep:%0d,tag:%0d} has_addr=%b addr=%x ack=%b",
                         $time, r1_uop_id.epoch, r1_uop_id.rob_tag, r1_has_addr, r1_addr, addr_update1_ack);
            if (addr_update0_valid)
                $display("[SQ-TRACE %0t] au0 uop={ep:%0d,tag:%0d} addr=%x ack=%b",
                         $time, addr_update0_uop_id.epoch, addr_update0_uop_id.rob_tag, addr_update0_address, addr_update0_ack);
            if (addr_update1_valid)
                $display("[SQ-TRACE %0t] au1 uop={ep:%0d,tag:%0d} addr=%x ack=%b",
                         $time, addr_update1_uop_id.epoch, addr_update1_uop_id.rob_tag, addr_update1_address, addr_update1_ack);
            if (addr_update0_q_valid)
                $display("[SQ-TRACE %0t] au0_q uop={ep:%0d,tag:%0d} addr=%x",
                         $time, addr_update0_q_uop_id.epoch, addr_update0_q_uop_id.rob_tag, addr_update0_q_address);
            if (addr_update1_q_valid)
                $display("[SQ-TRACE %0t] au1_q uop={ep:%0d,tag:%0d} addr=%x",
                         $time, addr_update1_q_uop_id.epoch, addr_update1_q_uop_id.rob_tag, addr_update1_q_address);
            if (release_do)
                $display("[SQ-TRACE %0t] release uop={ep:%0d,tag:%0d} addr=%x",
                         $time, entries[release_owner_sel_q].uop_id.epoch,
                         entries[release_owner_sel_q].uop_id.rob_tag,
                         entries[release_owner_sel_q].address);
        end
    end
`endif

    // Registered allocation-payload bypass.  A store reserved with its data
    // already present is captured into alloc_data*_q on the reservation
    // edge and written into the physical array one cycle later.  Until that
    // write-back lands, release, store-to-load forwarding and the memory
    // order checker must observe the effective value (registered payload
    // matched by uop_id), not the stale array contents.  This keeps the
    // data visible in the same cycle as before the split.
    logic [DEPTH-1:0] alloc_data0_match;
    logic [DEPTH-1:0] alloc_data1_match;
    logic [DEPTH-1:0] effective_store_data_ready;
    logic [DEPTH*32-1:0] effective_raw_store_data;

    always_comb begin
        for (integer eff_i = 0; eff_i < DEPTH; eff_i = eff_i + 1) begin
            alloc_data0_match[eff_i] =
                alloc_data0_q.valid &&
                entries[eff_i].valid &&
                uop_id_equal(
                    entries[eff_i].uop_id,
                    alloc_data0_q.uop_id
                );

            alloc_data1_match[eff_i] =
                alloc_data1_q.valid &&
                entries[eff_i].valid &&
                uop_id_equal(
                    entries[eff_i].uop_id,
                    alloc_data1_q.uop_id
                );

            effective_store_data_ready[eff_i] =
                store_data_ready[eff_i] ||
                alloc_data0_match[eff_i] ||
                alloc_data1_match[eff_i];

            effective_raw_store_data[
                eff_i*32 +: 32
            ] =
                alloc_data0_match[eff_i] ?
                    alloc_data0_q.data_value :
                alloc_data1_match[eff_i] ?
                    alloc_data1_q.data_value :
                    raw_store_data[eff_i];
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
            // Array data-ready only, not the alloc-data bypass: the release
            // is bound by the owner's address (the addr_update travels
            // through the registered addr_update*_q stage), which lands no
            // earlier than the alloc write-back, so the effective/array
            // distinction can never change the release cycle.  Dropping the
            // bypass here keeps the credit loop (release -> free_slots ->
            // reserve_ready) out of the alloc_data*_q match cone.
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
                    effective_raw_store_data[
                        release_owner_sel_q*32 +: 32
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
                effective_store_data_ready[i];

            addr_flat[i*32 +: 32] =
                entries[i].address;

            uop_id_flat[
                i*`UOP_ID_W +: `UOP_ID_W
            ] = entries[i].uop_id;

            store_wen_flat[i*4 +: 4] =
                entries[i].store_wen;

            store_data_flat[i*32 +: 32] =
                compute_aligned_data(
                    effective_raw_store_data[
                        i*32 +: 32
                    ],
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

    always_comb begin : preselect_next_logic
        // The production StoreQueue depth is four.  Use a balanced
        // tournament for the owner decision instead of the all-pairs
        // has_older matrix followed by a priority encoder.  The latter
        // replicated the age compare and encoded every physical slot in one
        // long cone ending at release_owner_sel_q.D.  The tournament now
        // pre-selects the two oldest stores (first/second) into registers;
        // the owner register only muxes the registered one-hot tokens, so
        // the deep age tree leaves the owner D cone entirely.
        //
        // The candidates are the physical entries read at fixed addresses
        // (no variable write-port bypass, so the alloc selection and the
        // released owner slot stay out of the age compare) plus the two
        // in-flight accepted stores r0/r1 as independent items.  The
        // released owner slot is excluded bitwise; re-allocating it in the
        // same cycle simply turns that store into an independent item.
        logic [DEPTH-1:0] slot_valid;
        uop_id_t          slot_id [0:DEPTH-1];

        logic             pair01_valid;
        logic             pair23_valid;
        logic             root_valid;
        logic [INDEX_W-1:0] pair01_sel;
        logic [INDEX_W-1:0] pair23_sel;
        logic [INDEX_W-1:0] root_sel;
        logic             pair01_loser_valid;
        logic             pair23_loser_valid;
        logic [INDEX_W-1:0] pair01_loser_sel;
        logic [INDEX_W-1:0] pair23_loser_sel;
        uop_id_t           pair01_id;
        uop_id_t           pair23_id;
        uop_id_t           root_id;
        uop_id_t           pair01_loser_id;
        uop_id_t           pair23_loser_id;
        uop_id_t           root_loser_id;

        // Retain a generic fallback for focused parameterized testbenches;
        // DEPTH=4 takes only the balanced path above.
        logic [DEPTH-1:0] next_slot_valid;
        uop_id_t          next_slot_uop_id [0:DEPTH-1];
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
            slot_valid[owner_i] =
                entries[owner_i].valid &&
                !(
                    release_do &&
                    release_owner_oh_q[owner_i]
                );

            slot_id[owner_i] =
                entries[owner_i].uop_id;
        end

        release_first_next_oh = '0;
        release_first_next_valid = 1'b0;
        release_first_next_id = '0;
        release_second_next_oh = '0;
        release_second_next_valid = 1'b0;
        release_second_next_id = '0;

        if (DEPTH == 4) begin
            // First level: oldest of physical slots 0/1, tracking the
            // loser of the pair as a runner-up candidate.
            pair01_valid = 1'b0;
            pair01_loser_valid = 1'b0;
            pair01_sel = '0;
            pair01_loser_sel = '0;
            pair01_id = '0;
            pair01_loser_id = '0;
            if (slot_valid[0]) begin
                pair01_valid = 1'b1;
                pair01_sel = '0;
                pair01_id = slot_id[0];
            end
            if (slot_valid[1]) begin
                if (!pair01_valid ||
                    uop_is_younger(
                        pair01_id,
                        slot_id[1]
                    )) begin
                    if (pair01_valid) begin
                        pair01_loser_valid = 1'b1;
                        pair01_loser_sel = pair01_sel;
                        pair01_loser_id = pair01_id;
                    end
                    pair01_valid = 1'b1;
                    pair01_sel = 1;
                    pair01_id = slot_id[1];
                end else begin
                    pair01_loser_valid = 1'b1;
                    pair01_loser_sel = 1;
                    pair01_loser_id = slot_id[1];
                end
            end

            // First level: oldest of physical slots 2/3, tracking its
            // runner-up.
            pair23_valid = 1'b0;
            pair23_loser_valid = 1'b0;
            pair23_sel = '0;
            pair23_loser_sel = '0;
            pair23_id = '0;
            pair23_loser_id = '0;
            if (slot_valid[2]) begin
                pair23_valid = 1'b1;
                pair23_sel = 2;
                pair23_id = slot_id[2];
            end
            if (slot_valid[3]) begin
                if (!pair23_valid ||
                    uop_is_younger(
                        pair23_id,
                        slot_id[3]
                    )) begin
                    if (pair23_valid) begin
                        pair23_loser_valid = 1'b1;
                        pair23_loser_sel = pair23_sel;
                        pair23_loser_id = pair23_id;
                    end
                    pair23_valid = 1'b1;
                    pair23_sel = 3;
                    pair23_id = slot_id[3];
                end else begin
                    pair23_loser_valid = 1'b1;
                    pair23_loser_sel = 3;
                    pair23_loser_id = slot_id[3];
                end
            end

            // Second level: oldest of the two pair winners; the losing
            // pair winner becomes the root loser.
            root_valid = 1'b0;
            root_sel = '0;
            root_id = '0;
            root_loser_id = '0;
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
                    if (root_valid)
                        root_loser_id = root_id;
                    root_valid = 1'b1;
                    root_sel = pair23_sel;
                    root_id = pair23_id;
                end else begin
                    root_loser_id = pair23_id;
                end
            end

            if (!flush && root_valid) begin
                release_first_next_valid = 1'b1;
                release_first_next_oh[root_sel] = 1'b1;
                release_first_next_id = root_id;

                // Runner-up: the older of the two stores that lost
                // directly to the winner, i.e. the loser of the winner's
                // first-level pair and the losing pair winner.
                if (root_sel[1] == 1'b0) begin
                    if (
                        pair01_loser_valid &&
                        (
                            !pair23_valid ||
                            uop_is_younger(
                                pair23_id,
                                pair01_loser_id
                            )
                        )
                    ) begin
                        release_second_next_valid = 1'b1;
                        release_second_next_oh[
                            pair01_loser_sel
                        ] = 1'b1;
                        release_second_next_id =
                            pair01_loser_id;
                    end else if (pair23_valid) begin
                        release_second_next_valid = 1'b1;
                        release_second_next_oh[
                            pair23_sel
                        ] = 1'b1;
                        release_second_next_id =
                            pair23_id;
                    end
                end else begin
                    if (
                        pair23_loser_valid &&
                        (
                            !pair01_valid ||
                            uop_is_younger(
                                pair01_id,
                                pair23_loser_id
                            )
                        )
                    ) begin
                        release_second_next_valid = 1'b1;
                        release_second_next_oh[
                            pair23_loser_sel
                        ] = 1'b1;
                        release_second_next_id =
                            pair23_loser_id;
                    end else if (pair01_valid) begin
                        release_second_next_valid = 1'b1;
                        release_second_next_oh[
                            pair01_sel
                        ] = 1'b1;
                        release_second_next_id =
                            pair01_id;
                    end
                end
            end
        end else begin
            // Generic fallback for non-production queue depths: build the
            // next-slot view (released slot cleared, accepted stores
            // written into the allocated slots) and run the all-pairs
            // matrix twice, excluding the first pick from the second pass.
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
                release_do &&
                release_owner_valid_q
            ) begin
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
            select_found = 1'b0;
            if (!flush) begin
                for (
                    owner_i = 0;
                    owner_i < DEPTH;
                    owner_i = owner_i + 1
                ) begin
                    if (oldest_onehot[owner_i] && !select_found) begin
                        release_first_next_valid = 1'b1;
                        release_first_next_oh[owner_i] = 1'b1;
                        release_first_next_id =
                            next_slot_uop_id[owner_i];
                        select_found = 1'b1;
                    end
                end
            end

            // Runner-up: rerun the matrix excluding the first slot.
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
                        (release_first_next_oh[owner_i] == 1'b0) &&
                        (release_first_next_oh[owner_j] == 1'b0) &&
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
            select_found = 1'b0;
            if (!flush) begin
                for (
                    owner_i = 0;
                    owner_i < DEPTH;
                    owner_i = owner_i + 1
                ) begin
                    if (
                        oldest_onehot[owner_i] &&
                        (release_first_next_oh[owner_i] == 1'b0) &&
                        !select_found
                    ) begin
                        release_second_next_valid = 1'b1;
                        release_second_next_oh[owner_i] = 1'b1;
                        release_second_next_id =
                            next_slot_uop_id[owner_i];
                        select_found = 1'b1;
                    end
                end
            end
        end
    end

    always_ff @(posedge clk or negedge rstn) begin
        if (!rstn || flush) begin
            release_owner_oh_q <= '0;
            release_first_oh_q <= '0;
            release_first_valid_q <= 1'b0;
            release_first_id_q <= '0;
            release_second_oh_q <= '0;
            release_second_valid_q <= 1'b0;
            release_second_id_q <= '0;
        end else begin
            release_owner_oh_q <=
                release_do ?
                    release_second_oh_q :
                    release_first_oh_q;
            release_first_oh_q <=
                release_first_next_oh;
            release_first_valid_q <=
                release_first_next_valid;
            release_first_id_q <=
                release_first_next_id;
            release_second_oh_q <=
                release_second_next_oh;
            release_second_valid_q <=
                release_second_next_valid;
            release_second_id_q <=
                release_second_next_id;
        end
    end

`ifndef SYNTHESIS
    // Owner/preselection invariants.  The owner token always equals the
    // pre-selected first token, except the single-cycle handover gap when
    // the released slot is re-allocated in the same cycle (owner zeroed,
    // first already pointing at the incoming store).
    assert property (
        @(posedge clk) disable iff (!rstn || flush)
        (
            (release_owner_oh_q === release_first_oh_q) ||
            (release_owner_oh_q == '0)
        )
    );

    assert property (
        @(posedge clk) disable iff (!rstn || flush)
        (release_do == 1'b0) ||
        (release_owner_oh_q === release_first_oh_q)
    );

    assert property (
        @(posedge clk) disable iff (!rstn || flush)
        $onehot0(release_owner_oh_q)
    );

    assert property (
        @(posedge clk) disable iff (!rstn || flush)
        $onehot0(release_first_oh_q)
    );

    assert property (
        @(posedge clk) disable iff (!rstn || flush)
        $onehot0(release_second_oh_q)
    );

    assert property (
        @(posedge clk) disable iff (!rstn || flush)
        !(release_first_valid_q && release_second_valid_q) ||
        (release_first_oh_q !== release_second_oh_q)
    );

    assert property (
        @(posedge clk) disable iff (!rstn || flush)
        !(release_first_valid_q && release_second_valid_q) ||
        !uop_is_younger(
            release_first_id_q,
            release_second_id_q
        )
    );
`endif

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
            if (addr_update0_valid && addr_update0_ack)
                addr_update0_q_valid <= 1'b1;
            else if (!addr_update0_valid)
                addr_update0_q_valid <= 1'b0;

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

            if (addr_update1_valid && addr_update1_ack)
                addr_update1_q_valid <= 1'b1;
            else if (!addr_update1_valid)
                addr_update1_q_valid <= 1'b0;

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

    // Fixed allocation-payload capture.  Every cycle, a reservation that
    // arrives with its store data already available is latched here; the
    // wide value is written into raw_store_data on the following edge by
    // uop_id match (see update_sq_data_ready/value).  The register D cone
    // is just the reservation inputs, so the credit/allocator/priority
    // chain no longer feeds a variable-indexed wide write port.
    // Deferred reservation write.  The reservation acceptance (r0_do/r1_do)
    // stays combinational -- the credit given to the DQ/scheduler and the
    // address-update ack still see the same-cycle acceptance, so the
    // store-loop credit bubble the previous experiments hit cannot return.
    // Only the physical entry creation is deferred one cycle: the allocated
    // slot and the narrow header are latched at the acceptance edge and
    // written into the array on the next edge.  This moves the endpoint of
    // the credit loop (release -> free_slots -> reserve_ready -> r0_do/r1_do
    // -> variable-indexed entry write) behind a fixed register; the entry is
    // always present before the lane's address update lands, because the
    // update travels through addr_update*_q (registered) and the reservation
    // pipeline precedes the store's execution.
    typedef struct packed {
        logic                valid;
        logic [INDEX_W-1:0]  alloc_sel;
        uop_id_t             uop_id;
        logic [31:0]         pc;
        logic [3:0]          store_mask;
        logic                has_addr;
        logic [31:0]         address;
        uop_id_t             src1_id;
        logic                commit_now;
`ifndef SYNTHESIS
        logic [63:0]         serial;
`endif
    } sq_reserve_payload_t;

    sq_reserve_payload_t reserve0_payload_q;
    sq_reserve_payload_t reserve1_payload_q;

    always_ff @(posedge clk or negedge rstn) begin
        if (!rstn || flush) begin
            reserve0_payload_q <= '0;
            reserve1_payload_q <= '0;
        end else begin
            reserve0_payload_q.valid <= r0_do;
            reserve0_payload_q.alloc_sel <= alloc0_sel;
            reserve0_payload_q.uop_id <= r0_uop_id;
            reserve0_payload_q.pc <= r0_pc;
            reserve0_payload_q.store_mask <= r0_mask;
            reserve0_payload_q.has_addr <= r0_has_addr;
            reserve0_payload_q.address <= r0_addr;
            reserve0_payload_q.src1_id <= r0_src1_id;
            reserve0_payload_q.commit_now <= r0_commit_now;
`ifndef SYNTHESIS
            reserve0_payload_q.serial <= next_alloc_serial;
`endif

            reserve1_payload_q.valid <= r1_do;
            reserve1_payload_q.alloc_sel <=
                r0_do ? alloc1_sel : alloc0_sel;
            reserve1_payload_q.uop_id <= r1_uop_id;
            reserve1_payload_q.pc <= r1_pc;
            reserve1_payload_q.store_mask <= r1_mask;
            reserve1_payload_q.has_addr <= r1_has_addr;
            reserve1_payload_q.address <= r1_addr;
            reserve1_payload_q.src1_id <= r1_src1_id;
            reserve1_payload_q.commit_now <= r1_commit_now;
`ifndef SYNTHESIS
            reserve1_payload_q.serial <=
                next_alloc_serial + r0_do;
`endif
        end
    end

    always_ff @(posedge clk or negedge rstn) begin
        if (!rstn || flush) begin
            alloc_data0_q <= '0;
            alloc_data1_q <= '0;
        end else begin
            alloc_data0_q.valid <=
                r0_do &&
                r0_initial_data_ready;

            alloc_data0_q.uop_id <=
                r0_uop_id;

            alloc_data0_q.data_ready <=
                r0_initial_data_ready;

            alloc_data0_q.data_value <=
                r0_initial_data_value;

            alloc_data1_q.valid <=
                r1_do &&
                r1_initial_data_ready;

            alloc_data1_q.uop_id <=
                r1_uop_id;

            alloc_data1_q.data_ready <=
                r1_initial_data_ready;

            alloc_data1_q.data_value <=
                r1_initial_data_value;
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
                            alloc_data0_q.valid,
                            alloc_data0_q.uop_id,
                            alloc_data0_q.data_ready,
                            alloc_data1_q.valid,
                            alloc_data1_q.uop_id,
                            alloc_data1_q.data_ready,
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
                            alloc_data0_q.valid,
                            alloc_data0_q.uop_id,
                            alloc_data0_q.data_ready,
                            alloc_data0_q.data_value,
                            alloc_data1_q.valid,
                            alloc_data1_q.uop_id,
                            alloc_data1_q.data_ready,
                            alloc_data1_q.data_value,
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
                            alloc_data0_q.valid,
                            alloc_data0_q.uop_id,
                            alloc_data0_q.data_ready,
                            alloc_data1_q.valid,
                            alloc_data1_q.uop_id,
                            alloc_data1_q.data_ready,
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
                            alloc_data0_q.valid,
                            alloc_data0_q.uop_id,
                            alloc_data0_q.data_ready,
                            alloc_data0_q.data_value,
                            alloc_data1_q.valid,
                            alloc_data1_q.uop_id,
                            alloc_data1_q.data_ready,
                            alloc_data1_q.data_value,
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

            if (reserve0_payload_q.valid) begin
                entries[reserve0_payload_q.alloc_sel] <=
                    make_reserved_sq_entry(
                        reserve0_payload_q.pc,
                        reserve0_payload_q.uop_id,
                        reserve0_payload_q.store_mask,
                        reserve0_payload_q.has_addr,
                        reserve0_payload_q.address
                    );

                store_data_ready[
                    reserve0_payload_q.alloc_sel
                ] <= 1'b0;

                store_data_src_id[
                    reserve0_payload_q.alloc_sel
                ] <= reserve0_payload_q.src1_id;

                committed[
                    reserve0_payload_q.alloc_sel
                ] <= reserve0_payload_q.commit_now;
                // raw_store_data is intentionally not written on the
                // reservation write-back edge; the wide data travels through
                // alloc_data0_q and lands by uop_id match (see
                // update_sq_data_ready/value).

`ifndef SYNTHESIS
                entry_serial[
                    reserve0_payload_q.alloc_sel
                ] <= reserve0_payload_q.serial;
`endif
            end

            if (reserve1_payload_q.valid) begin
                entries[reserve1_payload_q.alloc_sel] <=
                    make_reserved_sq_entry(
                        reserve1_payload_q.pc,
                        reserve1_payload_q.uop_id,
                        reserve1_payload_q.store_mask,
                        reserve1_payload_q.has_addr,
                        reserve1_payload_q.address
                    );

                store_data_ready[
                    reserve1_payload_q.alloc_sel
                ] <= 1'b0;

                store_data_src_id[
                    reserve1_payload_q.alloc_sel
                ] <= reserve1_payload_q.src1_id;

                committed[
                    reserve1_payload_q.alloc_sel
                ] <= reserve1_payload_q.commit_now;
                // raw_store_data write removed here as well; see
                // alloc_data1_q and the uop_id write-back next cycle.

`ifndef SYNTHESIS
                entry_serial[
                    reserve1_payload_q.alloc_sel
                ] <= reserve1_payload_q.serial;
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

        always @(posedge clk or negedge rstn) begin
            if (!rstn || flush) begin
                release_stall_q <= 1'b0;
                release_owner_valid_prev_q <= 1'b0;
                release_owner_sel_prev_q <= '0;
            end else begin
                if (release_stall_q) begin
                    assert (release_owner_valid_q == release_owner_valid_prev_q)
                        else $fatal(1, "SQ owner valid changed while release was stalled");
                    assert (release_owner_sel_q == release_owner_sel_prev_q)
                        else $fatal(1, "SQ owner changed while release was stalled");
                end
                release_stall_q <= release_valid && !release_fire;
                release_owner_valid_prev_q <= release_owner_valid_q;
                release_owner_sel_prev_q <= release_owner_sel_q;
            end
        end

        always @(posedge clk) begin
            if (rstn && !flush && release_owner_valid_q) begin
                assert (entries[release_owner_sel_q].valid)
                    else $fatal(1, "SQ release owner points to an invalid slot");
            end
        end

        always @(posedge clk) begin : check_release_owner_oldest
            integer check_i;
            if (rstn && !flush && release_owner_valid_q) begin
                for (check_i = 0; check_i < DEPTH; check_i = check_i + 1) begin
                    if (entries[check_i].valid && (check_i != release_owner_sel_q)) begin
                        assert (!uop_is_younger(entries[release_owner_sel_q].uop_id, entries[check_i].uop_id))
                            else $fatal(1, "SQ release owner is not the oldest entry");
                    end
                end
            end
        end
`endif

endmodule
