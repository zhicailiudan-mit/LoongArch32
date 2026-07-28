`timescale 1ns / 1ps
`include "defines.vh"
import cpu_types_pkg::*;

// Phase 2A High-Performance LSU Arbiter:
// - Up to 4 in-flight cacheable DCache Loads with 4-entry ordered Load Owner FIFO.
// - 4-entry Load Completion Queue to eliminate completion port conflicts.
// - Strict credit conservation: (load_owner_count + load_completion_queue_count <= 4).
// - Independent Store processing with 2-entry DCache Store FIFO support & fairness.
module LsuArbiter (
    input logic clk, input logic rstn,
    input logic flush,
    input logic branch_flush,
    input logic recover_valid, input logic system_flush,
    input uop_id_t recover_id,
    input logic load_valid, input lsu_entry_t load_entry,
    input logic load_blocked,
    input logic load_memory_allowed,
    input logic load_forward_valid,
    input logic [31:0] load_forward_rdata,
    output logic load_issue, output logic load_pop,
    output uop_id_t load_pop_uop_id,
    input logic store_valid, input lsu_entry_t store_entry,
    output logic store_pop,
    input logic store_line_alloc_valid,
    input logic [31:0] store_line_alloc_addr,
    input completion_t direct_completion,
    output logic completion_valid, output lsu_entry_t completion_entry,
    output logic [31:0] completion_rdata,
    output memory_request_t dcache_req,
    input memory_response_t dcache_rsp,
    output logic perf_dcache_wait,
    output logic perf_dcache_backpressure
);
    // -------------------------------------------------------------------------
    // 1. Owner FIFO & Completion Queue Data Types
    // -------------------------------------------------------------------------
    typedef struct packed {
        lsu_entry_t entry;
        logic       killed;
        logic       is_mmio;
`ifndef SYNTHESIS
        logic [63:0] req_seq;
`endif
    } load_owner_t;

    load_owner_t owner_fifo [0:3];
    logic [1:0]  owner_head;
    logic [1:0]  owner_tail;
    logic [2:0]  owner_count;

    typedef struct packed {
        lsu_entry_t entry;
        logic [31:0] rdata;
        logic       killed;
    } load_completion_t;

    load_completion_t comp_fifo [0:3];
    logic [1:0]       comp_head;
    logic [1:0]       comp_tail;
    logic [2:0]       comp_count;

    // MMIO owner slot (strictly serialized)
    logic        mmio_active;
    load_owner_t mmio_owner;

    // Store state machine (for uncached Store wait & active Store tracking)
    typedef enum logic [1:0] {S_IDLE, S_WAIT_STORE} store_state_t;
    store_state_t store_state;
    lsu_entry_t   store_active_entry;

    // Turnaround fairness streak
    localparam integer MAX_LOAD_TURNAROUNDS_WITH_STORE = 2;
    logic [3:0] load_turnaround_streak;
    logic force_store;

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

    // -------------------------------------------------------------------------
    // 2. Control & Handshake Logic Signals
    // -------------------------------------------------------------------------
    logic load_fire;
    logic mmio_fire;
    logic load_forward_fire;
    logic store_fire;
    logic background_store_candidate;
    logic background_store_fire;
    logic turnaround_fire;
    logic load_turnaround_eligible;
    logic load_turnaround_suppressed;

    logic owner_pop_do;
    logic owner_push_comp_do;
    logic comp_pop_do;
    logic comp_push_do;
    lsu_entry_t comp_push_entry;
    logic [31:0] comp_push_rdata;
    logic        comp_push_killed;

    logic [3:0] total_credits_used;
    logic       credit_releasing;
    logic       owner_will_resp;
    logic       owner_slot_available;
    logic       reserved_credit_available;
    logic       load_credit_available;
    logic       comp_will_pop;
    logic       forward_slot_available;

    logic owner_effective_killed;
    logic mmio_effective_killed;

    logic load_is_mmio;
    logic mmio_allowed;
    logic cacheable_load_allowed;

    always_comb begin
        // Effective killed flags during flush or marked killed bit
        owner_effective_killed = 1'b0;
        if (owner_count > 3'd0) begin
            owner_effective_killed = owner_fifo[owner_head].killed ||
                (system_flush || (flush && !recover_valid)) ||
                (branch_flush && recover_valid && uop_is_younger(owner_fifo[owner_head].entry.uop_id, recover_id));
        end

        mmio_effective_killed = 1'b0;
        if (mmio_active) begin
            mmio_effective_killed = mmio_owner.killed ||
                (system_flush || (flush && !recover_valid)) ||
                (branch_flush && recover_valid && uop_is_younger(mmio_owner.entry.uop_id, recover_id));
        end

        // MMIO address detection (valid only when load_valid is active)
        load_is_mmio = load_valid && (load_entry.address[31:16] == 16'h1f00);

        total_credits_used = {1'b0, owner_count} + {1'b0, comp_count} + {3'b0, mmio_active};

        // Early predicates for credit and slot availability
        comp_will_pop = !flush && !direct_completion.valid && (comp_count > 3'd0);
        owner_will_resp = dcache_rsp.valid && (owner_count > 3'd0);
        credit_releasing = comp_will_pop ||
                           (!direct_completion.valid && dcache_rsp.valid && comp_count == 3'd0) ||
                           (dcache_rsp.valid && ((owner_count > 3'd0 && owner_effective_killed) || (mmio_active && mmio_effective_killed)));

        // Independent Owner FIFO & Completion Reservation gating
        owner_slot_available = (owner_count < 3'd4) || owner_will_resp;
        reserved_credit_available = (total_credits_used < 4'd4) || credit_releasing;

        load_credit_available = owner_slot_available && reserved_credit_available;

        // MMIO Load must strictly serialize
        mmio_allowed = load_is_mmio && load_memory_allowed &&
                       (owner_count == 3'd0) && (comp_count == 3'd0) &&
                       !mmio_active && (store_state == S_IDLE);

        // Cacheable Load allowed to fire
        cacheable_load_allowed = !load_is_mmio && load_memory_allowed &&
                                 !load_blocked && !load_forward_valid &&
                                 load_credit_available && !mmio_active;

        // Turnaround eligibility (when DCache response returns while another Load can issue)
        load_turnaround_eligible = (owner_count > 3'd0) && dcache_rsp.valid && !flush &&
                                   !owner_effective_killed;

        load_turnaround_suppressed = load_turnaround_eligible && (comp_count == 3'd0) &&
                                     !direct_completion.valid && load_valid &&
                                     !load_forward_valid && cacheable_load_allowed &&
                                     dcache_rsp.rready && (force_store && store_valid);

        turnaround_fire = load_turnaround_eligible && (comp_count == 3'd0) &&
                          !direct_completion.valid && load_valid &&
                          !load_forward_valid && cacheable_load_allowed &&
                          dcache_rsp.rready && !(force_store && store_valid);

        load_fire = !flush && load_valid && cacheable_load_allowed && dcache_rsp.rready &&
                    !((owner_count == 3'd0) && force_store && store_valid && dcache_rsp.wready);

        mmio_fire = !flush && load_valid && mmio_allowed && dcache_rsp.rready;

        // Store-to-Load forwarding fire (does not enter DCache owner FIFO)
        // Highest priority for CQ push port belongs to DCache response (!dcache_rsp.valid required)
        forward_slot_available = !dcache_rsp.valid &&
                                 ((!direct_completion.valid && (comp_count == 0 || comp_will_pop)) ||
                                  (direct_completion.valid && (comp_count < 3'd4) && (total_credits_used < 4'd4)));
        load_forward_fire = !flush && load_valid && load_forward_valid && load_memory_allowed &&
                            forward_slot_available &&
                            !((owner_count == 3'd0) && force_store && store_valid && dcache_rsp.wready);

        // Ordinary Store fire
        store_fire = !flush && (store_state == S_IDLE) && (owner_count == 3'd0) && !mmio_active &&
                     !load_fire && !mmio_fire && !load_forward_fire &&
                     store_valid && dcache_rsp.wready;

        // Background Store candidate (when cacheable Loads are in-flight during quiet cycles)
        background_store_candidate = !flush && (owner_count > 3'd0) && !dcache_rsp.valid &&
                                     (comp_count == 3'd0) && !direct_completion.valid &&
                                     !load_fire && !mmio_fire && !load_forward_fire &&
                                     store_valid && (store_state == S_IDLE);
        background_store_fire = background_store_candidate && dcache_rsp.wready;

        // Performance indicators
        perf_dcache_wait = (owner_count > 3'd0) || (store_state == S_WAIT_STORE) || mmio_active;
        perf_dcache_backpressure = !load_credit_available ||
            (load_valid && !load_forward_valid && !load_blocked && load_memory_allowed && !dcache_rsp.rready);

        // Control outputs
        load_issue = load_fire || mmio_fire || load_forward_fire;
        store_pop = (store_fire && dcache_rsp.wposted) || (store_state == S_WAIT_STORE && dcache_rsp.wresp) || background_store_fire;

        // DCache Request multiplexing
        dcache_req = '0;
        if (store_valid && (store_state == S_IDLE)) begin
            dcache_req.addr = store_entry.address;
        end

        if (store_line_alloc_valid)
            dcache_req.addr = store_line_alloc_addr;

        if (load_fire || mmio_fire) begin
            dcache_req.ren  = make_load_ren(load_entry.load_ext_op, load_entry.address[1:0]);
            dcache_req.addr = load_entry.address;
        end else if (store_fire || background_store_fire) begin
            dcache_req.addr  = store_entry.address;
            dcache_req.wen   = store_entry.store_wen;
            dcache_req.wdata = store_entry.store_data;
        end else if (background_store_candidate) begin
            dcache_req.addr  = store_entry.address;
        end

        // ---------------------------------------------------------------------
        // 3. Completion Port & Queue Arbitration Matrix
        // ---------------------------------------------------------------------
        completion_valid = 1'b0;
        completion_entry = '0;
        completion_rdata = '0;
        owner_pop_do = 1'b0;
        owner_push_comp_do = 1'b0;
        comp_pop_do = 1'b0;
        comp_push_do = 1'b0;
        comp_push_entry = '0;
        comp_push_rdata = 32'h0;
        comp_push_killed = 1'b0;
        load_pop = 1'b0;
        load_pop_uop_id = '0;

        if (direct_completion.valid) begin
            // Main completion port is occupied by direct_completion in load_store_unit.
            completion_valid = 1'b0;
            completion_entry = '0;
            completion_rdata = 32'h0;

            // Handle simultaneous DCache response -> Must push to Completion Queue or absorb if killed
            if (dcache_rsp.valid) begin
                if (mmio_active) begin
                    if (!mmio_effective_killed) begin
                        comp_push_do = 1'b1;
                        comp_push_entry = mmio_owner.entry;
                        comp_push_rdata = dcache_rsp.rdata;
                        comp_push_killed = 1'b0;
                        load_pop = 1'b1;
                        load_pop_uop_id = mmio_owner.entry.uop_id;
                    end
                end else if (owner_count > 3'd0) begin
                    owner_pop_do = 1'b1;
                    if (!owner_effective_killed) begin
                        owner_push_comp_do = 1'b1;
                        comp_push_do = 1'b1;
                        comp_push_entry = owner_fifo[owner_head].entry;
                        comp_push_rdata = dcache_rsp.rdata;
                        comp_push_killed = 1'b0;
                        load_pop = 1'b1;
                        load_pop_uop_id = owner_fifo[owner_head].entry.uop_id;
                    end
                end
            end

            // Handle simultaneous Forwarded Load -> Push to Completion Queue
            if (load_forward_fire) begin
                comp_push_do = 1'b1;
                comp_push_entry = load_entry;
                comp_push_rdata = load_forward_rdata;
                comp_push_killed = 1'b0;
                load_pop = 1'b1;
                load_pop_uop_id = load_entry.uop_id;
            end
        end else begin
            // Direct Completion is NOT active -> Main completion port is available
            if (!flush && comp_count > 0) begin
                // Pop head of Completion Queue onto main port
                comp_pop_do = 1'b1;
                if (!comp_fifo[comp_head].killed) begin
                    completion_valid = 1'b1;
                    completion_entry = comp_fifo[comp_head].entry;
                    completion_rdata = comp_fifo[comp_head].rdata;
                end

                // If DCache response arrives in same cycle, push to Completion Queue (slot freed by comp_pop_do!)
                if (dcache_rsp.valid) begin
                    if (mmio_active) begin
                        if (!mmio_effective_killed) begin
                            comp_push_do = 1'b1;
                            comp_push_entry = mmio_owner.entry;
                            comp_push_rdata = dcache_rsp.rdata;
                            comp_push_killed = 1'b0;
                            load_pop = 1'b1;
                            load_pop_uop_id = mmio_owner.entry.uop_id;
                        end
                    end else if (owner_count > 3'd0) begin
                        owner_pop_do = 1'b1;
                        if (!owner_effective_killed) begin
                            owner_push_comp_do = 1'b1;
                            comp_push_do = 1'b1;
                            comp_push_entry = owner_fifo[owner_head].entry;
                            comp_push_rdata = dcache_rsp.rdata;
                            comp_push_killed = 1'b0;
                            load_pop = 1'b1;
                            load_pop_uop_id = owner_fifo[owner_head].entry.uop_id;
                        end
                    end
                end else if (load_forward_fire) begin
                    // The old queue head uses the completion port while the
                    // forwarded load occupies the slot freed this cycle.
                    comp_push_do = 1'b1;
                    comp_push_entry = load_entry;
                    comp_push_rdata = load_forward_rdata;
                    comp_push_killed = 1'b0;
                    load_pop = 1'b1;
                    load_pop_uop_id = load_entry.uop_id;
                end
            end else if (dcache_rsp.valid) begin
                // The DCache response is untagged and belongs to either the
                // active MMIO owner or the ordinary owner FIFO head.
                //
                // During branch recovery, a response belonging to an older,
                // surviving Load must not be discarded.  The ROB completion
                // output is suppressed while flush is active, so save that
                // response into the Completion Queue and remove the matching
                // issued entry from the LoadQueue.
                if (mmio_active) begin
                    if (!mmio_effective_killed) begin
                        if (flush) begin
                            // Surviving MMIO Load response during branch flush.
                            comp_push_do     = 1'b1;
                            comp_push_entry  = mmio_owner.entry;
                            comp_push_rdata  = dcache_rsp.rdata;
                            comp_push_killed = 1'b0;
                        end else begin
                            // Normal response: use the completion port directly.
                            completion_valid = 1'b1;
                            completion_entry = mmio_owner.entry;
                            completion_rdata = dcache_rsp.rdata;
                        end

                        // The physical response has been consumed.  Remove the
                        // matching issued LoadQueue entry in both cases.
                        load_pop        = 1'b1;
                        load_pop_uop_id = mmio_owner.entry.uop_id;
                    end
                end else if (owner_count > 3'd0) begin
                    // A physical DCache response always consumes the owner FIFO
                    // head, including responses for killed operations.
                    owner_pop_do = 1'b1;

                    if (!owner_effective_killed) begin
                        if (flush) begin
                            // This Load is older than the recovering branch.
                            // Preserve its response until completion delivery
                            // resumes after the flush cycle.
                            owner_push_comp_do = 1'b1;
                            comp_push_do       = 1'b1;
                            comp_push_entry    = owner_fifo[owner_head].entry;
                            comp_push_rdata    = dcache_rsp.rdata;
                            comp_push_killed   = 1'b0;
                        end else begin
                            // Normal response: use the completion port directly.
                            completion_valid = 1'b1;
                            completion_entry = owner_fifo[owner_head].entry;
                            completion_rdata = dcache_rsp.rdata;
                        end

                        // Remove the matching issued LoadQueue entry.  During a
                        // branch flush the LoadQueue compaction logic preserves
                        // older entries while applying this full-uop-ID pop.
                        load_pop        = 1'b1;
                        load_pop_uop_id = owner_fifo[owner_head].entry.uop_id;
                    end
                end
            end else if (load_forward_fire && !flush) begin
                // Forwarded Load outputs directly when no queued/DCache responses
                completion_valid = 1'b1;
                completion_entry = load_entry;
                completion_rdata = load_forward_rdata;
                load_pop = 1'b1;
                load_pop_uop_id = load_entry.uop_id;
            end
        end
    end

    // -------------------------------------------------------------------------
    // 4. Sequential State & Queue Updates
    // -------------------------------------------------------------------------
`ifndef SYNTHESIS
    logic [63:0] req_seq_counter;
`endif

    integer     cidx;
    integer     oidx;
    logic [1:0] optr;
    logic [1:0] cptr;

    always_ff @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            owner_head  <= 2'b0;
            owner_tail  <= 2'b0;
            owner_count <= 3'd0;
            comp_head   <= 2'd0;
            comp_tail   <= 2'd0;
            comp_count  <= 3'd0;
            mmio_active <= 1'b0;
            store_state <= S_IDLE;
            load_turnaround_streak <= 4'd0;
            force_store <= 1'b0;
`ifndef SYNTHESIS
            req_seq_counter <= 64'd0;
`endif
        end else begin
            // Branch Flush / Recovery: mark younger in-flight owners and completion entries killed
            if (branch_flush && recover_valid) begin
                if (owner_count > 3'd0) begin
                    for (oidx = 0; oidx < 4; oidx = oidx + 1) begin
                        if (oidx < owner_count) begin
                            optr = owner_head + oidx[1:0];
                            if (uop_is_younger(owner_fifo[optr].entry.uop_id, recover_id))
                                owner_fifo[optr].killed <= 1'b1;
                        end
                    end
                end
                if (comp_count > 3'd0) begin
                    for (cidx = 0; cidx < 4; cidx = cidx + 1) begin
                        if (cidx < comp_count) begin
                            cptr = comp_head + cidx[1:0];
                            if (uop_is_younger(comp_fifo[cptr].entry.uop_id, recover_id))
                                comp_fifo[cptr].killed <= 1'b1;
                        end
                    end
                end
                if (mmio_active && uop_is_younger(mmio_owner.entry.uop_id, recover_id)) begin
                    mmio_owner.killed <= 1'b1;
                end
            end

            // System Flush: mark all active owners killed, clear completion queue
            if (system_flush || (flush && !recover_valid)) begin
                for (oidx = 0; oidx < 4; oidx = oidx + 1) begin
                    owner_fifo[oidx].killed <= 1'b1;
                end
                for (cidx = 0; cidx < 4; cidx = cidx + 1) begin
                    comp_fifo[cidx].killed <= 1'b1;
                end
                comp_count <= 3'd0;
                comp_head  <= 2'd0;
                comp_tail  <= 2'd0;
                if (mmio_active) mmio_owner.killed <= 1'b1;
            end

            // Store Fairness & Streak management
            if (flush || !store_valid) begin
                load_turnaround_streak <= 4'd0;
                force_store <= 1'b0;
            end else if (store_fire || background_store_fire) begin
                load_turnaround_streak <= 4'd0;
                force_store <= 1'b0;
            end else if (turnaround_fire) begin
                load_turnaround_streak <= load_turnaround_streak + 4'd1;
                if (load_turnaround_streak + 4'd1 >= MAX_LOAD_TURNAROUNDS_WITH_STORE) begin
                    force_store <= 1'b1;
                end
            end else if (load_turnaround_streak >= MAX_LOAD_TURNAROUNDS_WITH_STORE) begin
                force_store <= 1'b1;
            end

            // Store State Machine
            if (store_fire && !dcache_rsp.wposted) begin
                store_state <= S_WAIT_STORE;
                store_active_entry <= store_entry;
            end else if (store_state == S_WAIT_STORE && dcache_rsp.wresp) begin
                store_state <= S_IDLE;
            end

            // Owner FIFO Pushes & Pops
            if (owner_pop_do) begin
                owner_head <= owner_head + 2'd1;
            end
            if (load_fire && !load_is_mmio) begin
                owner_fifo[owner_tail].entry  <= load_entry;
                owner_fifo[owner_tail].killed <= 1'b0;
                owner_fifo[owner_tail].is_mmio <= 1'b0;
`ifndef SYNTHESIS
                owner_fifo[owner_tail].req_seq <= req_seq_counter;
                req_seq_counter <= req_seq_counter + 64'd1;
`endif
                owner_tail <= owner_tail + 2'd1;
            end
            owner_count <= owner_count + ((load_fire && !load_is_mmio) ? 3'd1 : 3'd0) - (owner_pop_do ? 3'd1 : 3'd0);

            // Completion Queue Pushes & Pops
            if (comp_pop_do) begin
                comp_head <= comp_head + 2'd1;
            end
            if (comp_push_do) begin
                comp_fifo[comp_tail].entry  <= comp_push_entry;
                comp_fifo[comp_tail].rdata  <= comp_push_rdata;
                comp_fifo[comp_tail].killed <= comp_push_killed;
                comp_tail <= comp_tail + 2'd1;
            end
            if (!(system_flush || (flush && !recover_valid))) begin
                comp_count <= comp_count + (comp_push_do ? 3'd1 : 3'd0) - (comp_pop_do ? 3'd1 : 3'd0);
            end

            // MMIO Owner Tracking
            if (mmio_fire) begin
                mmio_active <= 1'b1;
                mmio_owner.entry  <= load_entry;
                mmio_owner.killed <= 1'b0;
                mmio_owner.is_mmio <= 1'b1;
            end else if (dcache_rsp.valid && mmio_active) begin
                mmio_active <= 1'b0;
            end
        end
    end

    // -------------------------------------------------------------------------
    // 5. Simulation-Only Assertions & Light Metrics
    // -------------------------------------------------------------------------
`ifndef SYNTHESIS
    longint unsigned cycle_cnt;
    longint unsigned load_owner_max_occupancy;
    longint unsigned load_two_inflight_cycles;
    longint unsigned load_three_inflight_cycles;
    longint unsigned load_four_inflight_cycles;
    longint unsigned load_request_response_turnaround_count;
    longint unsigned load_completion_queue_max_occupancy;
    longint unsigned load_request_block_owner_full_count;
    longint unsigned load_request_block_credit_full_count;
    longint unsigned load_request_block_no_credit_count;

    wire store_wait_cycle = store_valid && !store_fire && !background_store_fire && !flush;

    wire load_eligible_for_issue = !flush && load_valid && !load_is_mmio &&
                                   load_memory_allowed && !load_blocked && !load_forward_valid &&
                                   !mmio_active;
    wire load_blocked_by_owner_full  = load_eligible_for_issue && !owner_slot_available;
    wire load_blocked_by_credit_full = load_eligible_for_issue && owner_slot_available && !reserved_credit_available;
    wire load_blocked_by_credit      = load_eligible_for_issue && (!owner_slot_available || !reserved_credit_available);

    always_ff @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            cycle_cnt <= 0;
            load_owner_max_occupancy <= 0;
            load_two_inflight_cycles <= 0;
            load_three_inflight_cycles <= 0;
            load_four_inflight_cycles <= 0;
            load_request_response_turnaround_count <= 0;
            load_completion_queue_max_occupancy <= 0;
            load_request_block_owner_full_count <= 0;
            load_request_block_credit_full_count <= 0;
            load_request_block_no_credit_count <= 0;
        end else begin
            cycle_cnt <= cycle_cnt + 1;

            if (owner_count > load_owner_max_occupancy)
                load_owner_max_occupancy <= owner_count;
            if (owner_count == 3'd2)
                load_two_inflight_cycles <= load_two_inflight_cycles + 1;
            if (owner_count == 3'd3)
                load_three_inflight_cycles <= load_three_inflight_cycles + 1;
            if (owner_count == 3'd4)
                load_four_inflight_cycles <= load_four_inflight_cycles + 1;

            if (turnaround_fire)
                load_request_response_turnaround_count <= load_request_response_turnaround_count + 1;
            if (comp_count > load_completion_queue_max_occupancy)
                load_completion_queue_max_occupancy <= comp_count;

            if (load_blocked_by_owner_full)
                load_request_block_owner_full_count <= load_request_block_owner_full_count + 1;
            if (load_blocked_by_credit_full)
                load_request_block_credit_full_count <= load_request_block_credit_full_count + 1;
            if (load_blocked_by_credit)
                load_request_block_no_credit_count <= load_request_block_no_credit_count + 1;

            if (cycle_cnt > 0 && (cycle_cnt % 100000 == 0)) begin
                $display("[LSU-PHASE2A-STATS] cycles=%0d max_owner_occ=%0d two_inflight=%0d three_inflight=%0d four_inflight=%0d turnaround_count=%0d max_comp_occ=%0d block_no_credit=%0d (owner_full=%0d credit_full=%0d)",
                         cycle_cnt, load_owner_max_occupancy, load_two_inflight_cycles, load_three_inflight_cycles, load_four_inflight_cycles,
                         load_request_response_turnaround_count, load_completion_queue_max_occupancy,
                         load_request_block_no_credit_count, load_request_block_owner_full_count, load_request_block_credit_full_count);
            end
        end
    end

    // Next-state calculations for exact conservation assertions
    logic [2:0] owner_alloc;
    logic [2:0] owner_resp;
    logic [2:0] cq_push;
    logic [2:0] cq_pop;

    assign owner_alloc = (load_fire && !load_is_mmio) ? 3'd1 : 3'd0;
    assign owner_resp  = owner_pop_do ? 3'd1 : 3'd0;
    assign cq_push     = comp_push_do ? 3'd1 : 3'd0;
    assign cq_pop      = comp_pop_do ? 3'd1 : 3'd0;

    logic [3:0] owner_next;
    logic [3:0] comp_next;
    logic [3:0] reserved_next;

    assign owner_next    = {1'b0, owner_count} + owner_alloc - owner_resp;
    assign comp_next     = {1'b0, comp_count} + cq_push - cq_pop;
    assign reserved_next = owner_next + comp_next + {3'b0, mmio_active && !mmio_fire && !(dcache_rsp.valid && mmio_active)};

    always @(posedge clk) begin
        if (rstn) begin
            // 1. Unconditional Registered state bounds
            if (owner_count > 3'd4)
                $fatal(1, "[ASSERT-LSU-2A] owner occupancy exceeded 4!");
            if (comp_count > 3'd4)
                $fatal(1, "[ASSERT-LSU-2A] completion queue occupancy exceeded 4!");
            if ({1'b0, owner_count} + {1'b0, comp_count} > 4'd4)
                $fatal(1, "[ASSERT-LSU-2A] owner_count + comp_count credit bound violated!");

            // 2. Exact Next-state bounds
            if (owner_next > 4'd4)
                $fatal(1, "[ASSERT-LSU-2A] owner_next exceeded 4!");
            if (comp_next > 4'd4)
                $fatal(1, "[ASSERT-LSU-2A] comp_next exceeded 4!");
            if (reserved_next > 4'd4)
                $fatal(1, "[ASSERT-LSU-2A] reserved_next exceeded 4!");

            // 3. Mutual exclusion between load_forward_fire and cacheable load_fire
            if (load_forward_fire && load_fire && !load_is_mmio)
                $fatal(1, "[ASSERT-LSU-2A] load_forward_fire and load_fire active simultaneously!");

            // 4. DCache response requires active owner
            if (dcache_rsp.valid && !mmio_active && owner_count == 3'd0)
                $fatal(1, "[ASSERT-LSU-2A] DCache response arrived while owner FIFO is empty!");

            // 5. One load fire pushes exactly 1 owner
            if (load_fire && !load_is_mmio) begin
                if (owner_count == 3'd4 && !owner_pop_do)
                    $fatal(1, "[ASSERT-LSU-2A] Load fired while owner FIFO full without pop!");
            end

            // 6. Forwarded load popped only when completed or enqueued
            if (load_forward_fire) begin
                if (!load_pop)
                    $fatal(1, "[ASSERT-LSU-2A] Forwarded load fired without load_pop!");
            end

            // 7. Load and Store cannot simultaneously drive DCache request
            if ((|dcache_req.ren) && (|dcache_req.wen))
                $fatal(1, "[ASSERT-LSU-2A] DCache request collision: ren and wen active simultaneously!");

            // 8. MMIO and ordinary owner FIFO cannot be in-flight together
            if (mmio_active && owner_count > 3'd0)
                $fatal(1, "[ASSERT-LSU-2A] MMIO load and ordinary owner FIFO active simultaneously!");

            // 9. A response belonging to a Load older than the recovering
            // branch must be saved and must remove its issued LQ entry.
            if (flush && branch_flush && recover_valid &&
                dcache_rsp.valid) begin

                if (mmio_active && !mmio_effective_killed) begin
                    if (!comp_push_do)
                        $fatal(1,
                            "[ASSERT-LSU-2A] Surviving MMIO Load response was not saved across branch flush!");

                    if (!load_pop)
                        $fatal(1,
                            "[ASSERT-LSU-2A] Surviving MMIO Load response did not pop LoadQueue entry!");

                    if (!uop_id_equal(load_pop_uop_id,
                                     mmio_owner.entry.uop_id))
                        $fatal(1,
                            "[ASSERT-LSU-2A] Surviving MMIO Load pop uop_id mismatch!");

                    if (!uop_id_equal(comp_push_entry.uop_id,
                                     mmio_owner.entry.uop_id))
                        $fatal(1,
                            "[ASSERT-LSU-2A] Surviving MMIO completion uop_id mismatch!");
                end

                if (!mmio_active && owner_count > 3'd0 &&
                    !owner_effective_killed) begin
                    if (!owner_pop_do)
                        $fatal(1,
                            "[ASSERT-LSU-2A] Surviving Load response did not consume owner FIFO head!");

                    if (!comp_push_do)
                        $fatal(1,
                            "[ASSERT-LSU-2A] Surviving Load response was not saved across branch flush!");

                    if (!load_pop)
                        $fatal(1,
                            "[ASSERT-LSU-2A] Surviving Load response did not pop LoadQueue entry!");

                    if (!uop_id_equal(load_pop_uop_id,
                                     owner_fifo[owner_head].entry.uop_id))
                        $fatal(1,
                            "[ASSERT-LSU-2A] Surviving Load pop uop_id mismatch!");

                    if (!uop_id_equal(comp_push_entry.uop_id,
                                     owner_fifo[owner_head].entry.uop_id))
                        $fatal(1,
                            "[ASSERT-LSU-2A] Surviving Load completion uop_id mismatch!");
                end
            end
        end
    end
`endif

endmodule
