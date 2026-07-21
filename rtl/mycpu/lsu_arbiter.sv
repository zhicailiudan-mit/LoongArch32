`timescale 1ns / 1ps
`include "defines.vh"
import cpu_types_pkg::*;

// One DCache request remains in flight, while the queues around this unit
// allow independent memory operations to wait without freezing the frontend.
module LsuArbiter (
    input logic clk, input logic rstn,
    input logic flush,
    input logic branch_flush,
    input logic recover_valid, input logic system_flush,
    input uop_id_t recover_id,
    input logic load_valid, input lsu_entry_t load_entry,
    input logic load_blocked,
    input logic load_forward_valid,
    input logic [31:0] load_forward_rdata,
    output logic load_issue, output logic load_pop,
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
    typedef enum logic [1:0] {IDLE, WAIT_LOAD, WAIT_STORE} state_t;
    state_t state;
    lsu_entry_t active_entry;
    lsu_entry_t pending_entry;
    logic [31:0] pending_rdata;
    logic pending_valid;
    logic load_fire, load_forward_fire, store_fire;
    logic load_response_seen, load_event, load_forward_event;
    logic store_response_seen, store_event, response_event;
    logic active_killed;
    lsu_entry_t response_entry;
    logic [31:0] response_rdata;
    logic squash_active;
    logic squash_pending;

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
        load_forward_fire = !flush && (state == IDLE) && !pending_valid &&
                            load_valid && load_forward_valid;
        load_fire = !flush && (state == IDLE) && !pending_valid && load_valid &&
                    !load_forward_valid &&
                    !load_blocked && dcache_rsp.rready;
        store_fire = !flush && (state == IDLE) && !pending_valid &&
                     !load_fire && !load_forward_fire &&
                     store_valid && dcache_rsp.wready;
        squash_active = flush && (system_flush || !recover_valid ||
                         uop_is_younger(active_entry.uop_id, recover_id));
        squash_pending = flush && (system_flush || !recover_valid ||
                          uop_is_younger(pending_entry.uop_id, recover_id));
        load_response_seen = (state == WAIT_LOAD) && dcache_rsp.valid;
        load_event = load_response_seen && !active_killed && !squash_active;
        load_forward_event = load_forward_fire;
        store_response_seen = (state == WAIT_STORE) && dcache_rsp.wresp;
        store_event = store_response_seen ||
                      ((state == IDLE) && store_fire && dcache_rsp.wposted);
        response_event = load_event || load_forward_event || store_event;
        response_entry = active_entry;
        response_rdata = dcache_rsp.rdata;
        if (load_forward_fire) begin
            response_entry = load_entry;
            response_rdata = load_forward_rdata;
        end else if ((state == IDLE) && store_fire) begin
            response_entry = store_entry;
        end

        perf_dcache_wait = (state == WAIT_LOAD) || (state == WAIT_STORE);
        perf_dcache_backpressure = (state == IDLE) && !pending_valid &&
            ((!load_forward_valid && !load_blocked && load_valid && !dcache_rsp.rready) ||
             ((!load_valid || (load_blocked && !load_forward_valid)) &&
              store_valid && !dcache_rsp.wready));

        load_issue = load_fire || load_forward_fire;
        load_pop = load_event || load_forward_event;
        store_pop = store_event;
        dcache_req = '0;
        if (store_line_alloc_valid)
            dcache_req.addr = store_line_alloc_addr;
        if (load_fire) begin
            dcache_req.ren  = make_load_ren(load_entry.load_ext_op,
                                            load_entry.address[1:0]);
            dcache_req.addr = load_entry.address;
        end else if (store_fire) begin
            dcache_req.addr  = store_entry.address;
            dcache_req.wen   = store_entry.store_wen;
            dcache_req.wdata = store_entry.store_data;
        end

        completion_valid = 1'b0;
        completion_entry = '0;
        completion_rdata = '0;
        if (flush) begin
            completion_valid = 1'b0;
        end else if (pending_valid && !squash_pending && !direct_completion.valid) begin
            completion_valid = 1'b1;
            completion_entry = pending_entry;
            completion_rdata = pending_rdata;
        end else if (response_event && !direct_completion.valid) begin
            completion_valid = 1'b1;
            completion_entry = response_entry;
            completion_rdata = response_rdata;
        end
    end

    wire surviving_load_response = branch_flush && load_response_seen && !active_killed && !uop_is_younger(active_entry.uop_id, recover_id);

    always_ff @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            state <= IDLE;
            active_entry <= '0;
            pending_entry <= '0;
            pending_rdata <= '0;
            pending_valid <= 1'b0;
            active_killed <= 1'b0;
        end else begin
            if (squash_pending)
                pending_valid <= 1'b0;

            if (load_fire) begin
                active_entry <= load_entry;
                state <= WAIT_LOAD;
                active_killed <= 1'b0;
            end else if (store_fire) begin
                active_entry <= store_entry;
                if (!dcache_rsp.wposted) state <= WAIT_STORE;
            end else if (load_response_seen) begin
                // A flushed load still owns the single DCache response slot;
                // consume it, but never expose it as a ROB completion.
                state <= IDLE;
                active_killed <= 1'b0;
            end

            if (state == WAIT_LOAD && squash_active && !load_response_seen)
                active_killed <= 1'b1;

            if (pending_valid && !direct_completion.valid && !flush)
                pending_valid <= 1'b0;

            if (response_event) begin
                state <= IDLE;
                if ((direct_completion.valid && !flush) || surviving_load_response) begin
                    pending_valid <= 1'b1;
                    pending_entry <= response_entry;
                    pending_rdata <= response_rdata;
                end
            end
        end
    end

`ifndef SYNTHESIS
    always @(posedge clk) begin
        if (rstn) begin
            // 1. branch flush survivor response 必须保存
            if ($past(surviving_load_response) && !$past(squash_active) && !pending_valid)
                $fatal(1, "surviving load response not saved to pending");

            // 2. survivor identity 稳定
            if ($past(surviving_load_response) && !$past(squash_active)) begin
                if (pending_entry.uop_id != $past(active_entry.uop_id) ||
                    pending_entry.pc != $past(active_entry.pc) ||
                    pending_entry.address != $past(active_entry.address) ||
                    pending_entry.load_ext_op != $past(active_entry.load_ext_op))
                    $fatal(1, "surviving load identity corrupted");
            end

            // 3. 被 squash 的年轻 Load不能完成
            if (branch_flush && load_response_seen && uop_is_younger(active_entry.uop_id, recover_id)) begin
                if (completion_valid && completion_entry.uop_id == active_entry.uop_id)
                    $fatal(1, "squashed young load completed");
            end

            // 4. system_flush 后不能保留 pending
            if ($past(system_flush) && pending_valid)
                $fatal(1, "system_flush failed to clear pending");

            // 5. pending 不得被覆盖
            if ($past(pending_valid) && !$past(completion_valid) && !$past(squash_pending)) begin
                if (!pending_valid || pending_entry != $past(pending_entry) || pending_rdata != $past(pending_rdata))
                    $fatal(1, "pending overwritten or lost");
            end

            // 6. Load completion唯一性
            if ($past(completion_valid) && completion_valid && completion_entry.uop_id == $past(completion_entry.uop_id))
                $fatal(1, "Load completion duplicated");

            // 7. load_pop 守恒
            if (load_pop && !load_forward_event && !squash_active) begin
                if (!completion_valid && !surviving_load_response && !(direct_completion.valid && !flush))
                    $fatal(1, "load_pop without completion or pending write. uop_id=%p, recover_id=%p, state=%d, flush=%b, branch_flush=%b, system_flush=%b, dcache_rsp.valid=%b, pending_valid=%b", active_entry.uop_id, recover_id, state, flush, branch_flush, system_flush, dcache_rsp.valid, pending_valid);
            end

            if (surviving_load_response) begin
                $display("[LSU-COVER] preserved older load response across branch flush\n  active uop_id=%p, recover_id=%p, PC=%h, address=%h, data=%h",
                         active_entry.uop_id, recover_id, active_entry.pc, active_entry.address, dcache_rsp.rdata);
            end
        end
    end
`endif

endmodule
