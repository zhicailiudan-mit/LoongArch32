`timescale 1ns / 1ps
`include "defines.vh"
import cpu_types_pkg::*;

// One-load/one-store LSU boundary. The two integer lanes may finish memory
// address generation together, but only one Load is admitted to the DCache
// pipeline and only one Store is admitted to SQ in a cycle. This keeps the
// externally visible memory path single-ported and age ordered.
module LoadStoreUnit #(
    // Unit tests and legacy wrappers may still inject a fully formed Store at
    // the AGU boundary.  The real CPU enables the persistent issue-time SQ
    // reservation path and disables that legacy insertion path.
    parameter bit DECOUPLED_STORE_RESERVATION = 1'b0
) (
    input logic cpu_rstn, input logic cpu_clk,
    input logic flush,
    // Branch recovery flush is special: the resolving branch itself is an
    // older ROB instruction and must still complete in this cycle.  The
    // generic flush continues to cancel speculative LSU state.
    input logic branch_flush,
    input logic recover_valid,
    input logic system_flush,
    input uop_id_t recover_id,
    input logic rob_head_valid,
    input uop_id_t rob_head_id,
    input execute_result_t execute_result,
    input execute_result_t execute_result1,
    input completion_t store_data_complete0,
    input completion_t store_data_complete1,
    input commit_t commit0, input commit_t commit1,
    output logic ldst_suspend,
    output logic ldst1_suspend,
    output completion_t main_completion,
    output completion_t lane1_completion,
    output memory_request_t dcache_req,
    input memory_response_t dcache_rsp,
    output logic [3:0] perf_lq_occupancy,
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
    output logic [`CACHE_BLK_LEN-1:0] store_line_alloc_word_mask,
    // Decoupled Reservation Ports (optional inputs for top-level scheduler connection)
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
    output logic [1:0] store_reserve_credit
);
    localparam integer LQ_DEPTH = 8;
    localparam integer SQ_DEPTH = 4;
    localparam integer SB_DEPTH = 4;
    localparam integer STORE_SLOTS = SQ_DEPTH + SB_DEPTH + 2;

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
    logic [LQ_DEPTH-1:0] load_valid_vec;
    logic [SQ_DEPTH-1:0] store_valid_vec;
    logic [SB_DEPTH-1:0] buffer_valid_vec;
    logic [LQ_DEPTH*32-1:0] load_addr_flat;
    logic [SQ_DEPTH*32-1:0] store_addr_flat;
    logic [SB_DEPTH*32-1:0] buffer_addr_flat;
    logic [SQ_DEPTH*`UOP_ID_W-1:0] store_uop_id_flat;
    logic [SQ_DEPTH*4-1:0] store_wen_flat;
    logic [SB_DEPTH*4-1:0] buffer_wen_flat;
    logic [SQ_DEPTH*32-1:0] store_data_flat;
    logic [SB_DEPTH*32-1:0] buffer_data_flat;
    logic [SB_DEPTH*`UOP_ID_W-1:0] buffer_uop_id_flat;
    logic [SQ_DEPTH*4*`UOP_ID_W-1:0] store_byte_uop_id_flat;
    logic [SB_DEPTH*4*`UOP_ID_W-1:0] buffer_byte_uop_id_flat;
    logic [STORE_SLOTS-1:0] order_valid;
    logic [SQ_DEPTH-1:0] store_order_valid;
    logic [SQ_DEPTH-1:0] store_addr_ready_vec;
    logic [SQ_DEPTH-1:0] store_data_ready_vec;
    logic [STORE_SLOTS-1:0] order_addr_ready;
    logic [STORE_SLOTS-1:0] order_store_data_ready;
    logic [STORE_SLOTS*32-1:0] order_addr_flat;
    logic [STORE_SLOTS*4-1:0] order_wen_flat;
    logic [STORE_SLOTS*32-1:0] order_data_flat;
    logic [STORE_SLOTS*`UOP_ID_W-1:0] order_uop_id_flat;
    logic [STORE_SLOTS*4*`UOP_ID_W-1:0] order_byte_uop_id_flat;
    logic load_blocked;
    logic [3:0] load_ren;
    logic [3:0] load_forward_mask;
    logic [31:0] load_forward_data;
    logic [4*`UOP_ID_W-1:0] load_forward_id_flat;
    logic load_forward_valid;
    logic load_l1_valid;
    lsu_entry_t load_l1_entry;
    logic load_l1_blocked;
    logic load_l1_forward_valid;
    logic [31:0] load_l1_forward_data;
    // Elastic forwarding owner FIFO.  The forwarding tree may finish while
    // the DCache/request arbiter is still consuming the previous Load; the
    // payload remains owned here until load_issue transfers it onward.
    lsu_entry_t load_fwd_fifo_entry_q [0:1];
    logic       load_fwd_fifo_blocked_q [0:1];
    logic       load_fwd_fifo_valid_q [0:1];
    logic       load_fwd_fifo_forward_valid_q [0:1];
    logic [31:0] load_fwd_fifo_data_q [0:1];
    logic       load_fwd_fifo_head_q;
    logic       load_fwd_fifo_tail_q;
    logic [1:0] load_fwd_fifo_count_q;
    logic       load_fwd_fifo_push;
    logic       load_fwd_fifo_pop;
    integer     load_fwd_fifo_i;
    integer     load_fwd_recover_i;
    integer     load_fwd_recover_count;
    lsu_entry_t load_fwd_recover_entry0;
    lsu_entry_t load_fwd_recover_entry1;
    logic       load_fwd_recover_blocked0;
    logic       load_fwd_recover_blocked1;
    logic       load_fwd_recover_valid0;
    logic       load_fwd_recover_valid1;
    logic       load_fwd_recover_forward0;
    logic       load_fwd_recover_forward1;
    logic [31:0] load_fwd_recover_data0;
    logic [31:0] load_fwd_recover_data1;
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
    logic [3:0] lq_occupancy;
    logic [2:0] sq_occupancy;
    logic [2:0] sb_occupancy;
    completion_t main_completion_next;
    integer order_i;
    integer order_byte;

    // Address Update Signals for SQ
    logic addr_update0_valid;
    logic addr_update0_ack;
    uop_id_t addr_update0_uop_id;
    logic [31:0] addr_update0_address;
    logic [3:0] addr_update0_store_wen;
    logic addr_update0_unalign;
    logic addr_update0_data_ready;
    logic [31:0] addr_update0_data_value;
    uop_id_t addr_update0_data_src_id;

    logic addr_update1_valid;
    logic addr_update1_ack;
    uop_id_t addr_update1_uop_id;
    logic [31:0] addr_update1_address;
    logic [3:0] addr_update1_store_wen;
    logic addr_update1_unalign;
    logic addr_update1_data_ready;
    logic [31:0] addr_update1_data_value;
    uop_id_t addr_update1_data_src_id;

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

    typedef struct packed {
        logic valid;
        logic data_ready;
        uop_id_t uop_id;
        logic [7:0] data;
    } forward_candidate_t;

    function automatic forward_candidate_t select_younger(
        input forward_candidate_t a,
        input forward_candidate_t b
    );
        begin
            if (!a.valid)
                select_younger = b;
            else if (!b.valid)
                select_younger = a;
            else if (uop_is_younger(b.uop_id, a.uop_id))
                select_younger = b;
            else
                select_younger = a;
        end
    endfunction

    forward_candidate_t fwd_cand [0:3][0:15];
    forward_candidate_t tree_stg1 [0:3][0:7];
    forward_candidate_t tree_stg2 [0:3][0:3];
    forward_candidate_t tree_stg3 [0:3][0:1];
    forward_candidate_t tree_winner [0:3];

    // The byte-wise forwarding tree is intentionally split at the 16-to-8
    // reduction.  The first half captures a complete snapshot of the selected
    // Load and the eight stage-1 winners; the second half resolves the final
    // three reductions and feeds the existing load_l1 register.  Store-to-load
    // ordering remains conservative: a newly arriving Store is younger than
    // the snapshotted Load and is therefore not eligible as its forward
    // source, while an older Store remains in SQ/SB until its physical store
    // completion.  Flush clears the snapshot before it can issue.
    forward_candidate_t tree_stg1_q [0:3][0:7];
    forward_candidate_t tree_stg2_p [0:3][0:3];
    forward_candidate_t tree_stg3_p [0:3][0:1];
    forward_candidate_t tree_winner_p [0:3];
    lsu_entry_t load_order_head_q;
    logic load_order_head_valid_q;
    logic [2:0] load_order_idx_q;
    logic [3:0] load_order_ren_q;
    logic order_unresolved_q;
    logic [3:0] load_forward_mask_p;
    logic [31:0] load_forward_data_p;
    logic load_forward_valid_p;
    logic load_order_blocked_p;
    logic load_blocked_candidate_p;
    integer forward_q;
    integer forward_p;

    always @(*) begin
        load0_raw = execute_result.valid && execute_result.is_ld_st &&
                    !execute_result.ldst_unalign &&
                    (execute_result.store_mask == `RAM_WE_N);
        store0_raw = execute_result.valid && execute_result.is_ld_st &&
                     (execute_result.store_mask != `RAM_WE_N);
        load1_raw = execute_result1.valid && execute_result1.is_ld_st &&
                    !execute_result1.ldst_unalign &&
                    (execute_result1.store_mask == `RAM_WE_N);
        store1_raw = execute_result1.valid && execute_result1.is_ld_st &&
                     (execute_result1.store_mask != `RAM_WE_N);

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

        load_valid = load0_raw;
        load1_valid = load1_raw;
        store_valid = store0_raw && !execute_result.ldst_unalign;
        store1_valid = store1_raw && !execute_result1.ldst_unalign;
        store0_accept = !DECOUPLED_STORE_RESERVATION &&
                        store0_raw && store_ready && !flush;
        store1_accept = !DECOUPLED_STORE_RESERVATION &&
                        store1_raw && store1_ready && !flush;

        // Address update signals from AGU execution to StoreQueue
        addr_update0_valid = store0_raw && !flush;
        addr_update0_uop_id = execute_result.uop_id;
        addr_update0_address = execute_result.alu_result;
        addr_update0_store_wen = make_store_wen(execute_result.store_mask,
                                                 execute_result.alu_result[1:0]);
        addr_update0_unalign = execute_result.ldst_unalign;
        addr_update0_data_ready = execute_result.store_data_ready;
        addr_update0_data_value = execute_result.src1_value;
        addr_update0_data_src_id = execute_result.store_data_src_id;

        addr_update1_valid = store1_raw && !flush;
        addr_update1_uop_id = execute_result1.uop_id;
        addr_update1_address = execute_result1.alu_result;
        addr_update1_store_wen = make_store_wen(execute_result1.store_mask,
                                                 execute_result1.alu_result[1:0]);
        addr_update1_unalign = execute_result1.ldst_unalign;
        addr_update1_data_ready = execute_result1.store_data_ready;
        addr_update1_data_value = execute_result1.src1_value;
        addr_update1_data_src_id = execute_result1.store_data_src_id;

        // In the CPU configuration a Store completes only after its previously
        // reserved SQ entry acknowledges this address update.  The legacy
        // accept term exists solely for direct LSU unit-test compatibility.
        direct_valid = execute_result.valid && !flush &&
                       (!execute_result.is_ld_st || execute_result.ldst_unalign ||
                        (store0_raw &&
                         (DECOUPLED_STORE_RESERVATION ? addr_update0_ack :
                                                       store0_accept)));
        direct1_valid = execute_result1.valid && !flush &&
                        (execute_result1.ldst_unalign ||
                         (store1_raw &&
                          (DECOUPLED_STORE_RESERVATION ? addr_update1_ack :
                                                        store1_accept)));

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
        store_entry.valid = store0_raw && !execute_result.ldst_unalign;
        store_entry.uop_id = execute_result.uop_id;
        store_entry.pc = execute_result.pc;
        store_entry.address = execute_result.alu_result;
        store_entry.store_data = execute_result.src1_value;
        store_entry.store_wen = execute_result.store_mask;
        store_entry.store_data_ready = execute_result.store_data_ready || store0_accept;
        store_entry.store_data_src_id = execute_result.store_data_src_id;
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
        store1_entry.valid = store1_raw && !execute_result1.ldst_unalign;
        store1_entry.uop_id = execute_result1.uop_id;
        store1_entry.pc = execute_result1.pc;
        store1_entry.address = execute_result1.alu_result;
        store1_entry.store_wen = execute_result1.store_mask;
        store1_entry.store_data = execute_result1.src1_value;
        store1_entry.store_data_ready = execute_result1.store_data_ready || store1_accept;
        store1_entry.store_data_src_id = execute_result1.store_data_src_id;

        load_accept_entry = (load1_raw && (!load0_raw || load1_older)) ? load1_entry : load_entry;
        store_accept_entry = (store1_raw && (!store0_raw || store1_older)) ? store1_entry : store_entry;

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

    end

    always @(*) begin
        for (order_i = 0; order_i < SQ_DEPTH; order_i = order_i + 1)
            store_order_valid[order_i] = store_valid_vec[order_i] &&
                !uop_is_younger(store_uop_id_flat[order_i*`UOP_ID_W +: `UOP_ID_W],
                                load_head.uop_id);

        // Reservation intents have no address yet, but only intents older
        // than the current Load may block it.  Treating every reservation as
        // older creates a cycle when SQ is full: an old Load waits for younger
        // Stores, while those Stores cannot reserve until the Load retires.
        order_valid = {
            reserve1_valid && load_head_valid &&
                !uop_is_younger(reserve1_uop_id, load_head.uop_id),
            reserve0_valid && load_head_valid &&
                !uop_is_younger(reserve0_uop_id, load_head.uop_id),
            buffer_valid_vec,
            store_order_valid
        };
        order_addr_ready = {2'b00, {SB_DEPTH{1'b1}}, store_addr_ready_vec};
        order_store_data_ready = {2'b00, {SB_DEPTH{1'b1}}, store_data_ready_vec};
        order_addr_flat = {32'h0, 32'h0, buffer_addr_flat, store_addr_flat};
        order_wen_flat = {reserve1_store_mask, reserve0_store_mask, buffer_wen_flat, store_wen_flat};
        order_data_flat = {32'h0, 32'h0, buffer_data_flat, store_data_flat};
        order_uop_id_flat = {reserve1_uop_id, reserve0_uop_id, buffer_uop_id_flat, store_uop_id_flat};
        order_byte_uop_id_flat = {{4{reserve1_uop_id}}, {4{reserve0_uop_id}}, buffer_byte_uop_id_flat, store_byte_uop_id_flat};

        load_ren = make_load_ren(load_head.load_ext_op, load_head.address[1:0]);
        load_forward_mask = 4'b0;
        load_forward_data = 32'b0;
        load_forward_id_flat = '0;

        for (order_byte = 0; order_byte < 4; order_byte = order_byte + 1) begin
            for (order_i = 0; order_i < 16; order_i = order_i + 1) begin
                if (order_i < STORE_SLOTS) begin
                    fwd_cand[order_byte][order_i].valid = order_valid[order_i] &&
                        order_addr_ready[order_i] &&
                        ((order_addr_flat[order_i*32 +: 32] & 32'hffff_fffc) == (load_head.address & 32'hffff_fffc)) &&
                        order_wen_flat[order_i*4 + order_byte];
                    fwd_cand[order_byte][order_i].data_ready = order_store_data_ready[order_i];
                    fwd_cand[order_byte][order_i].uop_id = order_byte_uop_id_flat[(order_i*4 + order_byte)*`UOP_ID_W +: `UOP_ID_W];
                    fwd_cand[order_byte][order_i].data = order_data_flat[order_i*32 + order_byte*8 +: 8];
                end else begin
                    fwd_cand[order_byte][order_i].valid = 1'b0;
                    fwd_cand[order_byte][order_i].data_ready = 1'b0;
                    fwd_cand[order_byte][order_i].uop_id = '0;
                    fwd_cand[order_byte][order_i].data = 8'h0;
                end
            end
            
            // Stage 1 (16 to 8)
            for (order_i = 0; order_i < 8; order_i = order_i + 1) begin
                tree_stg1[order_byte][order_i] = select_younger(fwd_cand[order_byte][order_i*2], fwd_cand[order_byte][order_i*2+1]);
            end
            // Stage 2 (8 to 4)
            for (order_i = 0; order_i < 4; order_i = order_i + 1) begin
                tree_stg2[order_byte][order_i] = select_younger(tree_stg1[order_byte][order_i*2], tree_stg1[order_byte][order_i*2+1]);
            end
            // Stage 3 (4 to 2)
            for (order_i = 0; order_i < 2; order_i = order_i + 1) begin
                tree_stg3[order_byte][order_i] = select_younger(tree_stg2[order_byte][order_i*2], tree_stg2[order_byte][order_i*2+1]);
            end
            // Stage 4 (2 to 1)
            tree_winner[order_byte] = select_younger(tree_stg3[order_byte][0], tree_stg3[order_byte][1]);
            
            load_forward_mask[order_byte] = tree_winner[order_byte].valid && tree_winner[order_byte].data_ready;
            load_forward_data[order_byte*8 +: 8] = tree_winner[order_byte].data;
            load_forward_id_flat[order_byte*`UOP_ID_W +: `UOP_ID_W] = tree_winner[order_byte].uop_id;
        end


        load_forward_valid = load_head_valid &&
                             ((load_forward_mask & load_ren) == load_ren);

        ldst_suspend = !flush &&
                       ((load0_raw && !load_ready) ||
                        (store0_raw &&
                         !(DECOUPLED_STORE_RESERVATION ? addr_update0_ack :
                                                           store_ready)));
        ldst1_suspend = !flush &&
                        ((load1_raw && !load1_ready) ||
                         (store1_raw &&
                          !(DECOUPLED_STORE_RESERVATION ? addr_update1_ack :
                                                            store1_ready)));
        perf_lq_occupancy = lq_occupancy;
        perf_sq_occupancy = sq_occupancy;
        perf_sb_occupancy = sb_occupancy;
        perf_order_block = load_l1_valid && load_l1_blocked &&
                           !load_l1_forward_valid;
        perf_load_issue = load_issue;
        perf_load_forward = load_issue && load_l1_forward_valid;
        perf_load_response = load_pop;
        perf_store_issue = DECOUPLED_STORE_RESERVATION ?
                           ((reserve0_valid && reserve0_ready) ||
                            (reserve1_valid && reserve1_ready)) :
                           (store0_accept || store1_accept);
        perf_store_release = store_release_fire;
        perf_store_drain = store_pop;
    end

    logic [LQ_DEPTH-1:0] lq_unissued_vec;
    lsu_entry_t lq_entries [0:LQ_DEPTH-1];
    logic [2:0] selected_lq_idx;
    logic selected_lq_found;

    always @(*) begin
        selected_lq_found = 1'b0;
        selected_lq_idx = 3'd0;
        load_head = '0;
        for (integer idx = 0; idx < LQ_DEPTH; idx = idx + 1) begin
            if (!selected_lq_found && lq_unissued_vec[idx] &&
                ((lq_entries[idx].address[31:16] != 16'h1f00) ||
                 (rob_head_valid && uop_id_equal(lq_entries[idx].uop_id,
                                                 rob_head_id)))) begin
                selected_lq_found = 1'b1;
                selected_lq_idx = idx[2:0];
                load_head = lq_entries[idx];
            end
        end
        if (!selected_lq_found && (lq_occupancy != 0)) begin
            load_head = lq_entries[0];
        end
    end
    assign load_head_valid = selected_lq_found;

    uop_id_t load_pop_uop_id;
    logic load_pop_owner_valid_q;
    uop_id_t load_pop_owner_id_q;
    logic lq_pop_match_valid;
    logic [2:0] lq_pop_match_idx;
    logic [2:0] selected_lq_idx_after_pop;

    // The elastic forwarding FIFO is the only LoadQueue ownership transfer.
    // Mark exactly the registered snapshot when its complete order/forwarding
    // payload enters that FIFO.  The index is captured with the full snapshot;
    // a same-cycle LQ pop is adjusted inside LoadQueue before the mark lands.
    logic load_queue_issue_mark;
    always_comb begin
        load_queue_issue_mark = load_fwd_fifo_push;
    end

    LoadQueue #(.DEPTH(LQ_DEPTH)) u_load_queue (
        .clk(cpu_clk), .rstn(cpu_rstn),
        .flush(flush),
        .recover_valid(recover_valid), .system_flush(system_flush),
        .recover_id(recover_id),
        .accept_valid(load0_raw), .accept_entry(load_entry),
        .accept_ready(load_ready), .head_valid(),
        .accept1_valid(load1_raw), .accept1_entry(load1_entry),
        .accept1_ready(load1_ready),
        .head_entry(), .issue_mark(load_queue_issue_mark), .issue_idx(load_order_idx_q),
        .pop(load_pop_owner_valid_q), .pop_uop_id(load_pop_owner_id_q),
        .pop_match_valid(lq_pop_match_valid), .pop_match_idx(lq_pop_match_idx),
        .unissued_vec(lq_unissued_vec), .entries_flat(lq_entries),
        .valid_vec(load_valid_vec), .addr_flat(load_addr_flat),
        .occupancy(lq_occupancy)
    );

    // The pop owner is registered at the arbiter boundary.  If it removes an
    // older entry on the same edge that a new order snapshot is captured, the
    // selected index is one slot lower in the post-pop queue.  Track only this
    // narrow index; the wide FIFO payload never feeds the queue views or the
    // issue-mark path.
    always_comb begin
        selected_lq_idx_after_pop = selected_lq_idx;
        if (load_pop_owner_valid_q && lq_pop_match_valid &&
            (lq_pop_match_idx < selected_lq_idx)) begin
            selected_lq_idx_after_pop = selected_lq_idx - 3'd1;
        end
    end

    // Keep the functional/performance checkpoint on the original same-cycle
    // StoreQueue release.  The registered release boundary is a separate
    // timing experiment: it removes a slot from reserve_credit for one extra
    // cycle, which turns into IQ no-ready bubbles in the startup Store loop.
    StoreQueue #(.DEPTH(SQ_DEPTH)) u_store_queue (
        .clk(cpu_clk), .rstn(cpu_rstn),
        .flush(flush),
        .recover_valid(recover_valid), .system_flush(system_flush),
        .recover_id(recover_id),
        .accept_valid(store0_accept), .accept_entry(store_entry),
        .accept_ready(store_ready),
        .accept1_valid(store1_accept), .accept1_entry(store1_entry),
        .accept1_ready(store1_ready),
        .reserve0_valid(reserve0_valid), .reserve0_ready(reserve0_ready),
        .reserve0_uop_id(reserve0_uop_id), .reserve0_pc(reserve0_pc),
        .reserve0_store_mask(reserve0_store_mask), .reserve0_src1_ready(reserve0_src1_ready),
        .reserve0_src1_value(reserve0_src1_value), .reserve0_src1_id(reserve0_src1_id),
        .reserve1_valid(reserve1_valid), .reserve1_ready(reserve1_ready),
        .reserve1_uop_id(reserve1_uop_id), .reserve1_pc(reserve1_pc),
        .reserve1_store_mask(reserve1_store_mask), .reserve1_src1_ready(reserve1_src1_ready),
        .reserve1_src1_value(reserve1_src1_value), .reserve1_src1_id(reserve1_src1_id),
        .reserve_credit(store_reserve_credit),
        .addr_update0_valid(addr_update0_valid), .addr_update0_ack(addr_update0_ack),
        .addr_update0_uop_id(addr_update0_uop_id), .addr_update0_address(addr_update0_address),
        .addr_update0_store_wen(addr_update0_store_wen), .addr_update0_unalign(addr_update0_unalign),
        .addr_update0_data_ready(addr_update0_data_ready),
        .addr_update0_data_value(addr_update0_data_value),
        .addr_update0_data_src_id(addr_update0_data_src_id),
        .addr_update1_valid(addr_update1_valid), .addr_update1_ack(addr_update1_ack),
        .addr_update1_uop_id(addr_update1_uop_id), .addr_update1_address(addr_update1_address),
        .addr_update1_store_wen(addr_update1_store_wen), .addr_update1_unalign(addr_update1_unalign),
        .addr_update1_data_ready(addr_update1_data_ready),
        .addr_update1_data_value(addr_update1_data_value),
        .addr_update1_data_src_id(addr_update1_data_src_id),
        .complete0(store_data_complete0), .complete1(store_data_complete1),
        .commit0(commit0), .commit1(commit1),
        .release_valid(store_release_valid), .release_entry(store_release_entry),
        .release_fire(store_release_fire),
        .valid_vec(store_valid_vec), .addr_ready_vec(store_addr_ready_vec),
        .store_data_ready_vec(store_data_ready_vec),
        .addr_flat(store_addr_flat),
        .uop_id_flat(store_uop_id_flat),
        .store_wen_flat(store_wen_flat), .store_data_flat(store_data_flat),
        .store_byte_uop_id_flat(store_byte_uop_id_flat),
        .occupancy(sq_occupancy)
    );

    StoreBuffer #(.DEPTH(SB_DEPTH)) u_store_buffer (
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

    MemoryOrderChecker #(.STORE_SLOTS(STORE_SLOTS)) u_memory_order_checker (
        .load_valid(load_head_valid), .load_addr(load_head.address),
        .load_ren(load_ren), .store_valid(order_valid),
        .store_addr_ready(order_addr_ready),
        .store_addr_flat(order_addr_flat), .store_wen_flat(order_wen_flat),
        .blocked(load_blocked)
    );

    // Register the first half of the forwarding/order decision.  This is the
    // LSU-side timing boundary: the LoadQueue/SQ/SB age comparison no longer
    // drives the load_l1 enable in the same cycle.  The snapshot contains the
    // full Load identity and byte enables so the second half cannot mix a
    // forwarding result with a different queue entry.
    //
    // The snapshot is a pending transfer until the forwarding FIFO accepts it.
    // load_issue/load_pop describe the FIFO head and a physical response, not
    // this pending snapshot, so neither may invalidate it.  While it waits,
    // registered pop owners can compact older LQ entries; adjust the narrow
    // index so the later issue mark still selects the same Load.
    always_ff @(posedge cpu_clk or negedge cpu_rstn) begin
        if (!cpu_rstn) begin
            load_order_head_q       <= '0;
            load_order_head_valid_q <= 1'b0;
            load_order_idx_q        <= 3'd0;
            load_order_ren_q        <= 4'b0;
            order_unresolved_q      <= 1'b0;
            for (forward_q = 0; forward_q < 4; forward_q = forward_q + 1) begin
                tree_stg1_q[forward_q][0] <= '0;
                tree_stg1_q[forward_q][1] <= '0;
                tree_stg1_q[forward_q][2] <= '0;
                tree_stg1_q[forward_q][3] <= '0;
                tree_stg1_q[forward_q][4] <= '0;
                tree_stg1_q[forward_q][5] <= '0;
                tree_stg1_q[forward_q][6] <= '0;
                tree_stg1_q[forward_q][7] <= '0;
            end
        end else if (system_flush || flush) begin
            load_order_head_q       <= '0;
            load_order_head_valid_q <= 1'b0;
            load_order_idx_q        <= 3'd0;
            load_order_ren_q        <= 4'b0;
            order_unresolved_q      <= 1'b0;
            for (forward_q = 0; forward_q < 4; forward_q = forward_q + 1) begin
                tree_stg1_q[forward_q][0] <= '0;
                tree_stg1_q[forward_q][1] <= '0;
                tree_stg1_q[forward_q][2] <= '0;
                tree_stg1_q[forward_q][3] <= '0;
                tree_stg1_q[forward_q][4] <= '0;
                tree_stg1_q[forward_q][5] <= '0;
                tree_stg1_q[forward_q][6] <= '0;
                tree_stg1_q[forward_q][7] <= '0;
            end
        end else if (load_fwd_fifo_push) begin
            // FIFO push is the ownership transfer.  Clear the snapshot only
            // after its payload and issue mark have been accepted together.
            load_order_head_q       <= '0;
            load_order_head_valid_q <= 1'b0;
            load_order_idx_q        <= 3'd0;
            load_order_ren_q        <= 4'b0;
            order_unresolved_q      <= 1'b0;
            for (forward_q = 0; forward_q < 4; forward_q = forward_q + 1) begin
                tree_stg1_q[forward_q][0] <= '0;
                tree_stg1_q[forward_q][1] <= '0;
                tree_stg1_q[forward_q][2] <= '0;
                tree_stg1_q[forward_q][3] <= '0;
                tree_stg1_q[forward_q][4] <= '0;
                tree_stg1_q[forward_q][5] <= '0;
                tree_stg1_q[forward_q][6] <= '0;
                tree_stg1_q[forward_q][7] <= '0;
            end
        end else begin
            // Refresh the pending candidate until FIFO push transfers
            // ownership.  This resamples Store address/data readiness and the
            // forwarding tree, while the post-pop index still names the
            // pre-pop selected Load in the compacted LoadQueue view.
            load_order_head_q       <= load_head;
            load_order_head_valid_q <= load_head_valid;
            load_order_idx_q        <= selected_lq_idx_after_pop;
            load_order_ren_q        <= load_ren;
            // The exact address/byte overlap is represented by the registered
            // forwarding candidates below.  Keep only the separate unsafe
            // case here: an older Store whose address is not known yet.
            order_unresolved_q      <= |(order_valid & ~order_addr_ready);
            for (forward_q = 0; forward_q < 4; forward_q = forward_q + 1) begin
                tree_stg1_q[forward_q][0] <= tree_stg1[forward_q][0];
                tree_stg1_q[forward_q][1] <= tree_stg1[forward_q][1];
                tree_stg1_q[forward_q][2] <= tree_stg1[forward_q][2];
                tree_stg1_q[forward_q][3] <= tree_stg1[forward_q][3];
                tree_stg1_q[forward_q][4] <= tree_stg1[forward_q][4];
                tree_stg1_q[forward_q][5] <= tree_stg1[forward_q][5];
                tree_stg1_q[forward_q][6] <= tree_stg1[forward_q][6];
                tree_stg1_q[forward_q][7] <= tree_stg1[forward_q][7];
            end
        end
    end

    // Second half of the registered forwarding tree.  The result is aligned
    // with load_order_head_q/load_order_ren_q and is consumed by load_l1 on
    // the following clock edge.
    always_comb begin
        load_forward_mask_p = 4'b0;
        load_forward_data_p = 32'b0;
        load_forward_valid_p = 1'b0;
        load_blocked_candidate_p = 1'b0;
        for (forward_p = 0; forward_p < 4; forward_p = forward_p + 1) begin
            // Stage 2 (8 to 4) is now downstream of the LSU register.  This
            // leaves at most one reduction level on the LoadQueue-to-register
            // path while preserving the exact younger-uop winner rule.
            tree_stg2_p[forward_p][0] = select_younger(tree_stg1_q[forward_p][0],
                                                       tree_stg1_q[forward_p][1]);
            tree_stg2_p[forward_p][1] = select_younger(tree_stg1_q[forward_p][2],
                                                       tree_stg1_q[forward_p][3]);
            tree_stg2_p[forward_p][2] = select_younger(tree_stg1_q[forward_p][4],
                                                       tree_stg1_q[forward_p][5]);
            tree_stg2_p[forward_p][3] = select_younger(tree_stg1_q[forward_p][6],
                                                       tree_stg1_q[forward_p][7]);
            tree_stg3_p[forward_p][0] = select_younger(tree_stg2_p[forward_p][0],
                                                       tree_stg2_p[forward_p][1]);
            tree_stg3_p[forward_p][1] = select_younger(tree_stg2_p[forward_p][2],
                                                       tree_stg2_p[forward_p][3]);
            tree_winner_p[forward_p] = select_younger(tree_stg3_p[forward_p][0],
                                                       tree_stg3_p[forward_p][1]);
            load_forward_mask_p[forward_p] = tree_winner_p[forward_p].valid &&
                                             tree_winner_p[forward_p].data_ready;
            load_forward_data_p[forward_p*8 +: 8] = tree_winner_p[forward_p].data;

            // Any registered candidate on a byte selected by this Load means
            // that a same-word Store still has to be accounted for.  A full
            // byte cover is subsequently allowed by load_forward_valid_p;
            // partial cover remains blocked, matching the old checker.
            if (load_order_ren_q[forward_p]) begin
                for (integer blocked_i = 0; blocked_i < 8; blocked_i = blocked_i + 1)
                    if (tree_stg1_q[forward_p][blocked_i].valid)
                        load_blocked_candidate_p = 1'b1;
            end
        end
        load_order_blocked_p = load_order_head_valid_q &&
                               (order_unresolved_q || load_blocked_candidate_p);
        load_forward_valid_p = load_order_head_valid_q &&
                                ((load_forward_mask_p & load_order_ren_q) ==
                                 load_order_ren_q);
    end

    // Elastic forwarding owner FIFO.  The old single load_l1 register was
    // cleared on load_issue and could not accept another completed forwarding
    // decision in the same cycle.  This two-entry ready/valid boundary keeps
    // the selected Load and its byte data stable until the arbiter accepts it.
    always_comb begin
        load_l1_valid = (load_fwd_fifo_count_q != 2'd0) &&
                        !flush && !system_flush;
        load_l1_entry = '0;
        load_l1_blocked = 1'b0;
        load_l1_forward_valid = 1'b0;
        load_l1_forward_data = 32'h0;
        if (load_fwd_fifo_count_q != 2'd0) begin
            load_l1_entry = load_fwd_fifo_entry_q[load_fwd_fifo_head_q];
            load_l1_blocked = load_fwd_fifo_blocked_q[load_fwd_fifo_head_q];
            load_l1_forward_valid = load_fwd_fifo_forward_valid_q[load_fwd_fifo_head_q];
            load_l1_forward_data = load_fwd_fifo_data_q[load_fwd_fifo_head_q];
        end

        load_fwd_fifo_pop = load_l1_valid && load_issue &&
                            !flush && !system_flush;
        load_fwd_fifo_push = !flush && !system_flush &&
                             load_order_head_valid_q &&
                             (!load_order_blocked_p || load_forward_valid_p) &&
                             ((load_fwd_fifo_count_q < 2'd2) ||
                              load_fwd_fifo_pop);

        load_fwd_recover_count = 0;
        load_fwd_recover_entry0 = '0;
        load_fwd_recover_entry1 = '0;
        load_fwd_recover_blocked0 = 1'b0;
        load_fwd_recover_blocked1 = 1'b0;
        load_fwd_recover_valid0 = 1'b0;
        load_fwd_recover_valid1 = 1'b0;
        load_fwd_recover_forward0 = 1'b0;
        load_fwd_recover_forward1 = 1'b0;
        load_fwd_recover_data0 = 32'h0;
        load_fwd_recover_data1 = 32'h0;
        for (load_fwd_recover_i = 0; load_fwd_recover_i < 2;
             load_fwd_recover_i = load_fwd_recover_i + 1) begin
            if ((load_fwd_recover_i < load_fwd_fifo_count_q) &&
                !uop_is_younger(
                    load_fwd_fifo_entry_q[load_fwd_fifo_head_q ^
                                          load_fwd_recover_i[0]].uop_id,
                    recover_id)) begin
                if (load_fwd_recover_count == 0) begin
                    load_fwd_recover_entry0 =
                        load_fwd_fifo_entry_q[load_fwd_fifo_head_q ^
                                              load_fwd_recover_i[0]];
                    load_fwd_recover_blocked0 =
                        load_fwd_fifo_blocked_q[load_fwd_fifo_head_q ^
                                                load_fwd_recover_i[0]];
                    load_fwd_recover_valid0 = 1'b1;
                    load_fwd_recover_forward0 =
                        load_fwd_fifo_forward_valid_q[load_fwd_fifo_head_q ^
                                                      load_fwd_recover_i[0]];
                    load_fwd_recover_data0 =
                        load_fwd_fifo_data_q[load_fwd_fifo_head_q ^
                                             load_fwd_recover_i[0]];
                end else if (load_fwd_recover_count == 1) begin
                    load_fwd_recover_entry1 =
                        load_fwd_fifo_entry_q[load_fwd_fifo_head_q ^
                                              load_fwd_recover_i[0]];
                    load_fwd_recover_blocked1 =
                        load_fwd_fifo_blocked_q[load_fwd_fifo_head_q ^
                                                load_fwd_recover_i[0]];
                    load_fwd_recover_valid1 = 1'b1;
                    load_fwd_recover_forward1 =
                        load_fwd_fifo_forward_valid_q[load_fwd_fifo_head_q ^
                                                      load_fwd_recover_i[0]];
                    load_fwd_recover_data1 =
                        load_fwd_fifo_data_q[load_fwd_fifo_head_q ^
                                             load_fwd_recover_i[0]];
                end
                load_fwd_recover_count = load_fwd_recover_count + 1;
            end
        end
    end

    always_ff @(posedge cpu_clk or negedge cpu_rstn) begin
        if (!cpu_rstn) begin
            load_fwd_fifo_head_q <= 1'b0;
            load_fwd_fifo_tail_q <= 1'b0;
            load_fwd_fifo_count_q <= 2'd0;
            for (load_fwd_fifo_i = 0; load_fwd_fifo_i < 2;
                 load_fwd_fifo_i = load_fwd_fifo_i + 1) begin
                load_fwd_fifo_valid_q[load_fwd_fifo_i] <= 1'b0;
                load_fwd_fifo_entry_q[load_fwd_fifo_i] <= '0;
                load_fwd_fifo_blocked_q[load_fwd_fifo_i] <= 1'b0;
                load_fwd_fifo_forward_valid_q[load_fwd_fifo_i] <= 1'b0;
                load_fwd_fifo_data_q[load_fwd_fifo_i] <= 32'h0;
            end
        end else if (system_flush || (flush && !recover_valid)) begin
            load_fwd_fifo_head_q <= 1'b0;
            load_fwd_fifo_tail_q <= 1'b0;
            load_fwd_fifo_count_q <= 2'd0;
            for (load_fwd_fifo_i = 0; load_fwd_fifo_i < 2;
                 load_fwd_fifo_i = load_fwd_fifo_i + 1) begin
                load_fwd_fifo_valid_q[load_fwd_fifo_i] <= 1'b0;
                load_fwd_fifo_entry_q[load_fwd_fifo_i] <= '0;
                load_fwd_fifo_blocked_q[load_fwd_fifo_i] <= 1'b0;
                load_fwd_fifo_forward_valid_q[load_fwd_fifo_i] <= 1'b0;
                load_fwd_fifo_data_q[load_fwd_fifo_i] <= 32'h0;
            end
        end else if (flush) begin
            load_fwd_fifo_head_q <= 1'b0;
            load_fwd_fifo_tail_q <= (load_fwd_recover_count == 0) ? 1'b0 : 1'b1;
            load_fwd_fifo_count_q <= load_fwd_recover_count[1:0];
            load_fwd_fifo_valid_q[0] <= load_fwd_recover_valid0;
            load_fwd_fifo_valid_q[1] <= load_fwd_recover_valid1;
            load_fwd_fifo_entry_q[0] <= load_fwd_recover_entry0;
            load_fwd_fifo_entry_q[1] <= load_fwd_recover_entry1;
            load_fwd_fifo_blocked_q[0] <= load_fwd_recover_blocked0;
            load_fwd_fifo_blocked_q[1] <= load_fwd_recover_blocked1;
            load_fwd_fifo_forward_valid_q[0] <= load_fwd_recover_forward0;
            load_fwd_fifo_forward_valid_q[1] <= load_fwd_recover_forward1;
            load_fwd_fifo_data_q[0] <= load_fwd_recover_data0;
            load_fwd_fifo_data_q[1] <= load_fwd_recover_data1;
        end else begin
            case ({load_fwd_fifo_push, load_fwd_fifo_pop})
                2'b10: begin
                    load_fwd_fifo_valid_q[load_fwd_fifo_tail_q] <= 1'b1;
                    load_fwd_fifo_entry_q[load_fwd_fifo_tail_q] <= load_order_head_q;
                    load_fwd_fifo_blocked_q[load_fwd_fifo_tail_q] <= load_order_blocked_p;
                    load_fwd_fifo_forward_valid_q[load_fwd_fifo_tail_q] <= load_forward_valid_p;
                    load_fwd_fifo_data_q[load_fwd_fifo_tail_q] <= load_forward_data_p;
                    load_fwd_fifo_tail_q <= ~load_fwd_fifo_tail_q;
                    load_fwd_fifo_count_q <= load_fwd_fifo_count_q + 2'd1;
                end
                2'b01: begin
                    load_fwd_fifo_valid_q[load_fwd_fifo_head_q] <= 1'b0;
                    load_fwd_fifo_head_q <= ~load_fwd_fifo_head_q;
                    load_fwd_fifo_count_q <= load_fwd_fifo_count_q - 2'd1;
                end
                2'b11: begin
                    load_fwd_fifo_valid_q[load_fwd_fifo_tail_q] <= 1'b1;
                    load_fwd_fifo_entry_q[load_fwd_fifo_tail_q] <= load_order_head_q;
                    load_fwd_fifo_blocked_q[load_fwd_fifo_tail_q] <= load_order_blocked_p;
                    load_fwd_fifo_forward_valid_q[load_fwd_fifo_tail_q] <= load_forward_valid_p;
                    load_fwd_fifo_data_q[load_fwd_fifo_tail_q] <= load_forward_data_p;
                    load_fwd_fifo_tail_q <= ~load_fwd_fifo_tail_q;
                    load_fwd_fifo_head_q <= ~load_fwd_fifo_head_q;
                end
                default: begin end
            endcase
        end
    end

    wire load_is_mmio = load_l1_entry.address[31:16] == 16'h1f00;
    wire load_at_rob_head = rob_head_valid && uop_id_equal(load_l1_entry.uop_id, rob_head_id);
    wire load_memory_allowed = !load_is_mmio || load_at_rob_head;

    TaggedLsuArbiter u_lsu_arbiter (
        .clk(cpu_clk), .rstn(cpu_rstn),
        .flush(flush),
        .branch_flush(branch_flush),
        .recover_valid(recover_valid), .system_flush(system_flush),
        .recover_id(recover_id),
        .load_valid(load_l1_valid), .load_entry(load_l1_entry),
        .load_blocked(load_l1_blocked),
        .load_memory_allowed(load_memory_allowed),
        .load_forward_valid(load_l1_forward_valid),
        .load_forward_rdata(load_l1_forward_data), .load_issue(load_issue),
        .load_pop(load_pop), .load_pop_uop_id(load_pop_uop_id),
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

    // A physical response/forward completion transfers LoadQueue-pop
    // ownership into this narrow registered packet.  LoadQueue compaction is
    // deliberately one boundary later, so arbiter/MMIO/response selection and
    // the full owner identity cannot feed its issued/entry D inputs directly.
    // The register sustains one pop per cycle; branch recovery may capture a
    // surviving response, while a system flush discards all LQ ownership.
    always_ff @(posedge cpu_clk or negedge cpu_rstn) begin
        if (!cpu_rstn) begin
            load_pop_owner_valid_q <= 1'b0;
            load_pop_owner_id_q <= '0;
        end else if (system_flush || (flush && !recover_valid)) begin
            load_pop_owner_valid_q <= 1'b0;
            load_pop_owner_id_q <= '0;
        end else if (flush && recover_valid) begin
            // A branch flush may coincide with a physical response.  Keep
            // only the surviving owner; the arbiter already suppresses killed
            // owners, but the age check makes this boundary self-contained.
            load_pop_owner_valid_q <= load_pop &&
                                      !uop_is_younger(load_pop_uop_id,
                                                     recover_id);
            if (load_pop && !uop_is_younger(load_pop_uop_id, recover_id))
                load_pop_owner_id_q <= load_pop_uop_id;
        end else begin
            load_pop_owner_valid_q <= load_pop;
            if (load_pop)
                load_pop_owner_id_q <= load_pop_uop_id;
        end
    end

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
        if (dcache_req.wen != `RAM_WE_N) mem_pc = u_lsu_arbiter.request_entry_q.pc;
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


endmodule
