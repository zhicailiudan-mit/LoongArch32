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
    logic load_request_intent;
    logic mmio_request_intent;
    logic store_request_intent;
    logic foreground_store_candidate;
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

    // Registered DCache request ownership boundary.  Request selection is
    // performed without looking at DCache ready; only this registered packet
    // participates in the external handshake on the following cycle.  This
    // prevents ROB-head/MMIO permission and queue arbitration from reaching
    // the DCache array-read address/control cone in one combinational path.
    typedef enum logic [1:0] {
        REQ_NONE  = 2'd0,
        REQ_LOAD  = 2'd1,
        REQ_MMIO  = 2'd2,
        REQ_STORE = 2'd3
    } request_kind_t;

    logic            request_valid_q;
    request_kind_t   request_kind_q;
    memory_request_t request_payload_q;
    lsu_entry_t      request_entry_q;
    logic            request_background_store_q;

    memory_request_t load_intent_payload;
    memory_request_t store_intent_payload;

    logic request_dcache_fire;
    logic request_load_fire;
    logic request_mmio_fire;
    logic request_store_fire;

    always_comb begin
        // Ready-independent request payloads.  These signals terminate at the
        // request register below; they never drive DCache directly.
        load_intent_payload = '0;
        load_intent_payload.ren = make_load_ren(load_entry.load_ext_op,
                                                load_entry.address[1:0]);
        load_intent_payload.addr = load_entry.address;

        store_intent_payload = '0;
        store_intent_payload.addr = store_entry.address;
        store_intent_payload.wen = store_entry.store_wen;
        store_intent_payload.wdata = store_entry.store_data;

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

        // Store-to-Load forwarding fire (does not enter DCache owner FIFO)
        // Highest priority for CQ push port belongs to DCache response (!dcache_rsp.valid required)
        forward_slot_available = !dcache_rsp.valid &&
                                 ((!direct_completion.valid && (comp_count == 0 || comp_will_pop)) ||
                                  (direct_completion.valid && (comp_count < 3'd4) && (total_credits_used < 4'd4)));
        foreground_store_candidate = !flush && store_valid &&
                                     (store_state == S_IDLE) &&
                                     (owner_count == 3'd0) && !mmio_active;

        // A background Store may be selected only in a genuinely quiet load
        // window.  Selection itself is independent of wready.
        background_store_candidate = !flush && store_valid &&
                                     (store_state == S_IDLE) &&
                                     (owner_count > 3'd0) && !dcache_rsp.valid &&
                                     (comp_count == 3'd0) && !direct_completion.valid;

        // Intent arbitration is ready-independent.  A forced Store owns the
        // next request slot; otherwise a locally-forwarded Load wins without
        // consuming the DCache slot, followed by MMIO/cacheable Load and then
        // an ordinary/background Store.
        load_forward_fire = !request_valid_q && !flush && load_valid &&
                            load_forward_valid && load_memory_allowed &&
                            forward_slot_available &&
                            !(force_store && foreground_store_candidate);

        mmio_request_intent = !request_valid_q && !load_forward_fire &&
                              load_valid && mmio_allowed &&
                              !(force_store && foreground_store_candidate);

        load_request_intent = !request_valid_q && !load_forward_fire &&
                              !mmio_request_intent && load_valid &&
                              cacheable_load_allowed &&
                              !(force_store && foreground_store_candidate);

        store_request_intent = !request_valid_q &&
                               ((force_store && foreground_store_candidate) ||
                                (!load_forward_fire && !mmio_request_intent &&
                                 !load_request_intent &&
                                 (foreground_store_candidate ||
                                  background_store_candidate)));

        // Only the registered request packet observes DCache ready.
        request_load_fire  = !flush && request_valid_q &&
                             (request_kind_q == REQ_LOAD) && dcache_rsp.rready;
        request_mmio_fire  = !flush && request_valid_q &&
                             (request_kind_q == REQ_MMIO) && dcache_rsp.rready;
        request_store_fire = !flush && request_valid_q &&
                             (request_kind_q == REQ_STORE) && dcache_rsp.wready;
        request_dcache_fire = request_load_fire || request_mmio_fire ||
                              request_store_fire;

        load_fire = request_load_fire;
        mmio_fire = request_mmio_fire;
        store_fire = request_store_fire;
        background_store_fire = request_store_fire &&
                                request_background_store_q;

        load_turnaround_suppressed = load_turnaround_eligible &&
                                     (comp_count == 3'd0) &&
                                     !direct_completion.valid &&
                                     request_valid_q &&
                                     (request_kind_q == REQ_LOAD) &&
                                     !dcache_rsp.rready;

        turnaround_fire = load_turnaround_eligible &&
                          (comp_count == 3'd0) &&
                          !direct_completion.valid && load_fire;

        // Performance indicators
        perf_dcache_wait = (owner_count > 3'd0) || (store_state == S_WAIT_STORE) || mmio_active;
        perf_dcache_backpressure = !load_credit_available ||
            (load_valid && !load_forward_valid && !load_blocked && load_memory_allowed && !dcache_rsp.rready);

        // Control outputs
        load_issue = load_fire || mmio_fire || load_forward_fire;
        store_pop = (store_fire && dcache_rsp.wposted) ||
                    (store_state == S_WAIT_STORE && dcache_rsp.wresp);

        // The external DCache sees only registered payload.  A flush cancels
        // the packet before it can handshake: request_*_fire is also blocked
        // by flush, so exposing valid pins here would let DCache accept a
        // request which the LSU did not record.  Mask only the valid strobes;
        // keep flush out of the registered address/write-data datapaths.
        dcache_req = request_valid_q ? request_payload_q : '0;
        if (flush) begin
            dcache_req.ren = `RAM_WE_N;
            dcache_req.wen = `RAM_WE_N;
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

    integer     cidx;
    integer     oidx;
    logic [1:0] optr;
    logic [1:0] cptr;

    // One-entry non-fall-through request stage.  Its contents remain stable
    // until DCache accepts the request.  Flush cancels an unaccepted request;
    // the surviving queue entry can then be selected again after recovery.
    always_ff @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            request_valid_q            <= 1'b0;
            request_kind_q             <= REQ_NONE;
            request_payload_q          <= '0;
            request_entry_q            <= '0;
            request_background_store_q <= 1'b0;
        end else if (flush) begin
            request_valid_q            <= 1'b0;
            request_kind_q             <= REQ_NONE;
            request_payload_q          <= '0;
            request_entry_q            <= '0;
            request_background_store_q <= 1'b0;
        end else if (request_dcache_fire) begin
            request_valid_q            <= 1'b0;
            request_kind_q             <= REQ_NONE;
            request_payload_q          <= '0;
            request_entry_q            <= '0;
            request_background_store_q <= 1'b0;
        end else if (!request_valid_q) begin
            if (mmio_request_intent) begin
                request_valid_q            <= 1'b1;
                request_kind_q             <= REQ_MMIO;
                request_payload_q          <= load_intent_payload;
                request_entry_q            <= load_entry;
                request_background_store_q <= 1'b0;
            end else if (load_request_intent) begin
                request_valid_q            <= 1'b1;
                request_kind_q             <= REQ_LOAD;
                request_payload_q          <= load_intent_payload;
                request_entry_q            <= load_entry;
                request_background_store_q <= 1'b0;
            end else if (store_request_intent) begin
                request_valid_q            <= 1'b1;
                request_kind_q             <= REQ_STORE;
                request_payload_q          <= store_intent_payload;
                request_entry_q            <= store_entry;
                request_background_store_q <= background_store_candidate &&
                                              !foreground_store_candidate;
            end
        end
    end

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
                store_active_entry <= request_entry_q;
            end else if (store_state == S_WAIT_STORE && dcache_rsp.wresp) begin
                store_state <= S_IDLE;
            end

            // Owner FIFO Pushes & Pops
            if (owner_pop_do) begin
                owner_head <= owner_head + 2'd1;
            end
            if (load_fire) begin
                owner_fifo[owner_tail].entry  <= request_entry_q;
                owner_fifo[owner_tail].killed <= 1'b0;
                owner_fifo[owner_tail].is_mmio <= 1'b0;
                owner_tail <= owner_tail + 2'd1;
            end
            owner_count <= owner_count + (load_fire ? 3'd1 : 3'd0) -
                           (owner_pop_do ? 3'd1 : 3'd0);

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
                mmio_owner.entry  <= request_entry_q;
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

endmodule

// -----------------------------------------------------------------------------
// Tagged non-blocking LSU arbiter
// -----------------------------------------------------------------------------
// The legacy LsuArbiter above is kept for small standalone users of this file.
// The CPU top-level uses this implementation.  A Load owns a TID from the
// moment it is accepted by DCache until the matching physical response comes
// back; a flush only marks the entry killed and never frees the TID early.
module TaggedLsuArbiter (
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
    localparam integer TID_DEPTH = 8;
    localparam integer CQ_DEPTH  = 8;

    typedef struct packed {
        lsu_entry_t entry;
        logic       killed;
        logic       is_mmio;
    } tagged_owner_t;

    typedef struct packed {
        lsu_entry_t entry;
        logic [31:0] rdata;
        logic        killed;
    } tagged_completion_t;

    tagged_owner_t owner_table [0:TID_DEPTH-1];
    logic [TID_DEPTH-1:0] owner_valid;
    logic [3:0] owner_count;

    tagged_completion_t comp_fifo [0:CQ_DEPTH-1];
    logic [2:0] comp_head, comp_tail;
    logic [3:0] comp_count;

    logic mmio_active;
    logic [2:0] mmio_tid;

    typedef enum logic [1:0] {S_IDLE, S_WAIT_STORE} store_state_t;
    store_state_t store_state;
    lsu_entry_t store_active_entry;

    localparam integer MAX_LOAD_TURNAROUNDS_WITH_STORE = 2;
    logic [3:0] load_turnaround_streak;
    logic force_store;

    typedef enum logic [1:0] {
        REQ_NONE  = 2'd0,
        REQ_LOAD  = 2'd1,
        REQ_MMIO  = 2'd2,
        REQ_STORE = 2'd3
    } request_kind_t;

    logic            request_valid_q;
    request_kind_t   request_kind_q;
    memory_request_t request_payload_q;
    // Kept as a named register because the debug path in LoadStoreUnit uses it.
    lsu_entry_t     request_entry_q;
    logic            request_background_store_q;

    memory_request_t load_intent_payload;
    memory_request_t store_intent_payload;

    logic tid_alloc_valid;
    logic [2:0] tid_alloc;
    integer tid_idx;

    always_comb begin
        tid_alloc_valid = 1'b0;
        tid_alloc       = 3'd0;
        for (tid_idx = 0; tid_idx < TID_DEPTH; tid_idx = tid_idx + 1) begin
            if (!owner_valid[tid_idx] && !tid_alloc_valid) begin
                tid_alloc_valid = 1'b1;
                tid_alloc       = tid_idx[2:0];
            end
        end
    end

    logic rsp_owner_valid;
    logic rsp_owner_killed;
    logic rsp_owner_survives;
    logic rsp_is_mmio;
    tagged_owner_t rsp_owner;

    always_comb begin
        rsp_owner       = '0;
        rsp_owner_valid = 1'b0;
        if (dcache_rsp.valid) begin
            rsp_owner_valid = owner_valid[dcache_rsp.load_tid];
            if (rsp_owner_valid)
                rsp_owner = owner_table[dcache_rsp.load_tid];
        end
        rsp_is_mmio = rsp_owner_valid && rsp_owner.is_mmio;
        rsp_owner_killed = rsp_owner_valid &&
            (rsp_owner.killed || system_flush || (flush && !recover_valid) ||
             (branch_flush && recover_valid &&
              uop_is_younger(rsp_owner.entry.uop_id, recover_id)));
        rsp_owner_survives = rsp_owner_valid && !rsp_owner_killed;
    end

    logic load_fire, mmio_fire, load_forward_fire;
    logic store_fire, background_store_fire;
    logic load_request_intent, mmio_request_intent, store_request_intent;
    logic foreground_store_candidate, background_store_candidate;
    logic request_load_fire, request_mmio_fire, request_store_fire;
    logic request_dcache_fire;
    logic owner_resp_do;
    logic comp_pop_do, comp_push_do;
    logic [2:0] comp_push_tid;
    lsu_entry_t comp_push_entry;
    logic [31:0] comp_push_rdata;
    logic comp_push_killed;
    logic load_is_mmio, mmio_allowed, cacheable_load_allowed;
    logic owner_effective_killed;
    logic load_credit_available, forward_slot_available;
    logic comp_will_pop;
    logic turnaround_fire, load_turnaround_eligible;

    wire [4:0] total_credits_used = {1'b0, owner_count} +
                                    {1'b0, comp_count};
    wire comp_space = (comp_count < CQ_DEPTH);

    always_comb begin
        load_intent_payload = '0;
        load_intent_payload.ren      =
            (load_entry.load_ext_op == `RAM_EXT_B_Z ||
             load_entry.load_ext_op == `RAM_EXT_B_S) ?
                (4'b0001 << load_entry.address[1:0]) :
            ((load_entry.load_ext_op == `RAM_EXT_H_Z ||
              load_entry.load_ext_op == `RAM_EXT_H_S) ?
                (load_entry.address[1] ? 4'b1100 : 4'b0011) : 4'b1111);
        load_intent_payload.addr     = load_entry.address;
        load_intent_payload.load_tid = tid_alloc;

        store_intent_payload = '0;
        store_intent_payload.addr  = store_entry.address;
        store_intent_payload.wen   = store_entry.store_wen;
        store_intent_payload.wdata = store_entry.store_data;
        store_intent_payload.load_tid = 3'd0;

        load_is_mmio = load_valid && (load_entry.address[31:16] == 16'h1f00);
        owner_effective_killed = rsp_owner_killed;

        comp_will_pop = !flush && !direct_completion.valid &&
                        (comp_count != 4'd0);

        // TID reuse is deliberately conservative: the response cycle frees
        // the old slot, and a new request may reuse it on the next cycle.
        load_credit_available = tid_alloc_valid &&
                                (total_credits_used < 5'd8);

        mmio_allowed = load_is_mmio && load_memory_allowed &&
                       (owner_count == 4'd0) && (comp_count == 4'd0) &&
                       !mmio_active && (store_state == S_IDLE);

        cacheable_load_allowed = !load_is_mmio && load_memory_allowed &&
                                 !load_blocked && !load_forward_valid &&
                                 load_credit_available && !mmio_active;

        // A forwarded load never consumes a TID.  It must have a completion
        // queue slot when the normal completion port is occupied.
        forward_slot_available = !dcache_rsp.valid &&
            ((direct_completion.valid && comp_space) ||
             (!direct_completion.valid &&
              ((comp_count == 4'd0) || comp_will_pop)));

        foreground_store_candidate = !flush && store_valid &&
                                     (store_state == S_IDLE) &&
                                     (owner_count == 4'd0) && !mmio_active;
        background_store_candidate = !flush && store_valid &&
                                     (store_state == S_IDLE) &&
                                     (owner_count != 4'd0) &&
                                     !dcache_rsp.valid &&
                                     (comp_count == 4'd0) &&
                                     !direct_completion.valid;

        load_forward_fire = !request_valid_q && !flush && load_valid &&
                            load_forward_valid && load_memory_allowed &&
                            forward_slot_available &&
                            !(force_store && foreground_store_candidate);
        mmio_request_intent = !request_valid_q && !load_forward_fire &&
                              load_valid && mmio_allowed &&
                              !(force_store && foreground_store_candidate);
        load_request_intent = !request_valid_q && !load_forward_fire &&
                              !mmio_request_intent && load_valid &&
                              cacheable_load_allowed &&
                              !(force_store && foreground_store_candidate);
        store_request_intent = !request_valid_q &&
                               ((force_store && foreground_store_candidate) ||
                                (!load_forward_fire && !mmio_request_intent &&
                                 !load_request_intent &&
                                 (foreground_store_candidate ||
                                  background_store_candidate)));

        request_load_fire = !flush && request_valid_q &&
                            (request_kind_q == REQ_LOAD) &&
                            dcache_rsp.rready;
        request_mmio_fire = !flush && request_valid_q &&
                            (request_kind_q == REQ_MMIO) &&
                            dcache_rsp.rready;
        request_store_fire = !flush && request_valid_q &&
                             (request_kind_q == REQ_STORE) &&
                             dcache_rsp.wready;
        request_dcache_fire = request_load_fire || request_mmio_fire ||
                              request_store_fire;
        load_fire = request_load_fire;
        mmio_fire = request_mmio_fire;
        store_fire = request_store_fire;
        background_store_fire = request_store_fire &&
                                request_background_store_q;
        owner_resp_do = rsp_owner_valid;

        load_turnaround_eligible = rsp_owner_survives && !flush &&
                                   (owner_count != 4'd0);
        turnaround_fire = load_turnaround_eligible && load_fire &&
                          !direct_completion.valid && (comp_count == 4'd0);

        load_issue = load_fire || mmio_fire || load_forward_fire;
        store_pop = (store_fire && dcache_rsp.wposted) ||
                    (store_state == S_WAIT_STORE && dcache_rsp.wresp);

        perf_dcache_wait = (owner_count != 4'd0) ||
                           (store_state == S_WAIT_STORE) || mmio_active;
        perf_dcache_backpressure = !load_credit_available ||
            (load_valid && !load_forward_valid && !load_blocked &&
             load_memory_allowed && !dcache_rsp.rready);

        dcache_req = request_valid_q ? request_payload_q : '0;
        if (flush) begin
            dcache_req.ren = `RAM_WE_N;
            dcache_req.wen = `RAM_WE_N;
        end

        completion_valid = 1'b0;
        completion_entry = '0;
        completion_rdata = 32'h0;
        load_pop = 1'b0;
        load_pop_uop_id = '0;
        comp_pop_do = 1'b0;
        comp_push_do = 1'b0;
        comp_push_tid = 3'd0;
        comp_push_entry = '0;
        comp_push_rdata = 32'h0;
        comp_push_killed = 1'b0;

        if (direct_completion.valid) begin
            // Direct execution completion owns the main port.  A DCache
            // response or a forwarded load is queued behind it.
            if (rsp_owner_survives && comp_space) begin
                comp_push_do = 1'b1;
                comp_push_entry = rsp_owner.entry;
                comp_push_rdata = dcache_rsp.rdata;
                load_pop = 1'b1;
                load_pop_uop_id = rsp_owner.entry.uop_id;
            end
            if (load_forward_fire && comp_space) begin
                comp_push_do = 1'b1;
                comp_push_entry = load_entry;
                comp_push_rdata = load_forward_rdata;
                load_pop = 1'b1;
                load_pop_uop_id = load_entry.uop_id;
            end
        end else if (!flush && comp_count != 4'd0) begin
            comp_pop_do = 1'b1;
            if (!comp_fifo[comp_head].killed) begin
                completion_valid = 1'b1;
                completion_entry = comp_fifo[comp_head].entry;
                completion_rdata = comp_fifo[comp_head].rdata;
            end

            if (rsp_owner_survives && (comp_space || comp_pop_do)) begin
                comp_push_do = 1'b1;
                comp_push_entry = rsp_owner.entry;
                comp_push_rdata = dcache_rsp.rdata;
                load_pop = 1'b1;
                load_pop_uop_id = rsp_owner.entry.uop_id;
            end else if (load_forward_fire && (comp_space || comp_pop_do)) begin
                comp_push_do = 1'b1;
                comp_push_entry = load_entry;
                comp_push_rdata = load_forward_rdata;
                load_pop = 1'b1;
                load_pop_uop_id = load_entry.uop_id;
            end
        end else if (rsp_owner_survives) begin
            if (flush) begin
                if (comp_space) begin
                    comp_push_do = 1'b1;
                    comp_push_entry = rsp_owner.entry;
                    comp_push_rdata = dcache_rsp.rdata;
                end
            end else begin
                completion_valid = 1'b1;
                completion_entry = rsp_owner.entry;
                completion_rdata = dcache_rsp.rdata;
            end
            load_pop = 1'b1;
            load_pop_uop_id = rsp_owner.entry.uop_id;
        end else if (load_forward_fire) begin
            completion_valid = 1'b1;
            completion_entry = load_entry;
            completion_rdata = load_forward_rdata;
            load_pop = 1'b1;
            load_pop_uop_id = load_entry.uop_id;
        end
    end

    // Request packet register: the TID is part of the registered packet and
    // therefore cannot change while DCache backpressures the request.
    always_ff @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            request_valid_q            <= 1'b0;
            request_kind_q             <= REQ_NONE;
            request_payload_q          <= '0;
            request_entry_q            <= '0;
            request_background_store_q <= 1'b0;
        end else if (flush) begin
            request_valid_q            <= 1'b0;
            request_kind_q             <= REQ_NONE;
            request_payload_q          <= '0;
            request_entry_q            <= '0;
            request_background_store_q <= 1'b0;
        end else if (request_dcache_fire) begin
            request_valid_q            <= 1'b0;
            request_kind_q             <= REQ_NONE;
            request_payload_q          <= '0;
            request_entry_q            <= '0;
            request_background_store_q <= 1'b0;
        end else if (!request_valid_q) begin
            if (mmio_request_intent) begin
                request_valid_q            <= 1'b1;
                request_kind_q             <= REQ_MMIO;
                request_payload_q          <= load_intent_payload;
                request_entry_q            <= load_entry;
                request_background_store_q <= 1'b0;
            end else if (load_request_intent) begin
                request_valid_q            <= 1'b1;
                request_kind_q             <= REQ_LOAD;
                request_payload_q          <= load_intent_payload;
                request_entry_q            <= load_entry;
                request_background_store_q <= 1'b0;
            end else if (store_request_intent) begin
                request_valid_q            <= 1'b1;
                request_kind_q             <= REQ_STORE;
                request_payload_q          <= store_intent_payload;
                request_entry_q            <= store_entry;
                request_background_store_q <= background_store_candidate &&
                                              !foreground_store_candidate;
            end
        end
    end

    integer owner_i;
    integer cq_i;
    always_ff @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            owner_valid <= '0;
            owner_count <= 4'd0;
            comp_head   <= 3'd0;
            comp_tail   <= 3'd0;
            comp_count  <= 4'd0;
            mmio_active <= 1'b0;
            mmio_tid    <= 3'd0;
            store_state <= S_IDLE;
            store_active_entry <= '0;
            load_turnaround_streak <= 4'd0;
            force_store <= 1'b0;
            for (owner_i = 0; owner_i < TID_DEPTH; owner_i = owner_i + 1) begin
                owner_table[owner_i] <= '0;
            end
            for (cq_i = 0; cq_i < CQ_DEPTH; cq_i = cq_i + 1) begin
                comp_fifo[cq_i] <= '0;
            end
        end else begin
            if (branch_flush && recover_valid) begin
                for (owner_i = 0; owner_i < TID_DEPTH; owner_i = owner_i + 1)
                    if (owner_valid[owner_i] &&
                        uop_is_younger(owner_table[owner_i].entry.uop_id, recover_id))
                        owner_table[owner_i].killed <= 1'b1;
                for (cq_i = 0; cq_i < CQ_DEPTH; cq_i = cq_i + 1)
                    if ((cq_i < comp_count) &&
                        uop_is_younger(
                            comp_fifo[comp_head + cq_i[2:0]].entry.uop_id,
                            recover_id))
                        comp_fifo[comp_head + cq_i[2:0]].killed <= 1'b1;
            end

            if (system_flush || (flush && !recover_valid)) begin
                for (owner_i = 0; owner_i < TID_DEPTH; owner_i = owner_i + 1)
                    if (owner_valid[owner_i])
                        owner_table[owner_i].killed <= 1'b1;
                for (cq_i = 0; cq_i < CQ_DEPTH; cq_i = cq_i + 1)
                    comp_fifo[cq_i].killed <= 1'b1;
                comp_count <= 4'd0;
                comp_head  <= 3'd0;
                comp_tail  <= 3'd0;
            end else begin
                if (comp_pop_do)
                    comp_head <= comp_head + 3'd1;
                if (comp_push_do) begin
                    comp_fifo[comp_tail].entry  <= comp_push_entry;
                    comp_fifo[comp_tail].rdata  <= comp_push_rdata;
                    comp_fifo[comp_tail].killed <= comp_push_killed;
                    comp_tail <= comp_tail + 3'd1;
                end
                comp_count <= comp_count + (comp_push_do ? 4'd1 : 4'd0) -
                              (comp_pop_do ? 4'd1 : 4'd0);
            end

            if (owner_resp_do)
                owner_valid[dcache_rsp.load_tid] <= 1'b0;
            if (load_fire || mmio_fire) begin
                owner_table[request_payload_q.load_tid].entry  <= request_entry_q;
                owner_table[request_payload_q.load_tid].killed <= 1'b0;
                owner_table[request_payload_q.load_tid].is_mmio <= mmio_fire;
                owner_valid[request_payload_q.load_tid] <= 1'b1;
            end
            owner_count <= owner_count + (load_fire || mmio_fire ? 4'd1 : 4'd0) -
                           (owner_resp_do ? 4'd1 : 4'd0);

            if (mmio_fire) begin
                mmio_active <= 1'b1;
                mmio_tid    <= request_payload_q.load_tid;
            end else if (owner_resp_do && rsp_is_mmio) begin
                mmio_active <= 1'b0;
            end

            if (store_fire && !dcache_rsp.wposted) begin
                store_state <= S_WAIT_STORE;
                store_active_entry <= request_entry_q;
            end else if (store_state == S_WAIT_STORE && dcache_rsp.wresp) begin
                store_state <= S_IDLE;
            end

            if (flush || !store_valid) begin
                load_turnaround_streak <= 4'd0;
                force_store <= 1'b0;
            end else if (store_fire || background_store_fire) begin
                load_turnaround_streak <= 4'd0;
                force_store <= 1'b0;
            end else if (turnaround_fire) begin
                load_turnaround_streak <= load_turnaround_streak + 4'd1;
                if (load_turnaround_streak + 4'd1 >= MAX_LOAD_TURNAROUNDS_WITH_STORE)
                    force_store <= 1'b1;
            end else if (load_turnaround_streak >= MAX_LOAD_TURNAROUNDS_WITH_STORE) begin
                force_store <= 1'b1;
            end
        end
    end

endmodule
