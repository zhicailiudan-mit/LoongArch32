`timescale 1ns / 1ps
`include "defines.vh"
import cpu_types_pkg::*;

// One DCache request remains in flight, while the queues around this unit
// allow independent memory operations to wait without freezing the frontend.
module LSUArbiter (
    input logic clk, input logic rstn,
    input logic flush,
    input logic load_valid, input lsu_entry_t load_entry,
    input logic load_blocked,
    output logic load_issue, output logic load_pop,
    input logic store_valid, input lsu_entry_t store_entry,
    output logic store_pop,
    input completion_t direct_completion,
    output logic completion_valid, output lsu_entry_t completion_entry,
    output logic [31:0] completion_rdata,
    output memory_request_t dcache_req,
    input memory_response_t dcache_rsp
);
    typedef enum logic [1:0] {IDLE, WAIT_LOAD, WAIT_STORE} state_t;
    state_t state;
    lsu_entry_t active_entry;
    lsu_entry_t pending_entry;
    logic [31:0] pending_rdata;
    logic pending_valid;
    logic load_fire, store_fire;
    logic load_response_seen, load_event;
    logic store_response_seen, store_event, response_event;
    logic active_killed;
    lsu_entry_t response_entry;
    logic [31:0] response_rdata;

    always_comb begin
        load_fire = !flush && (state == IDLE) && !pending_valid && load_valid &&
                    !load_blocked && dcache_rsp.rready;
        store_fire = !flush && (state == IDLE) && !pending_valid && !load_fire &&
                     store_valid && dcache_rsp.wready;
        load_response_seen = (state == WAIT_LOAD) && dcache_rsp.valid;
        load_event = load_response_seen && !flush && !active_killed;
        store_response_seen = (state == WAIT_STORE) && dcache_rsp.wresp;
        store_event = store_response_seen ||
                      ((state == IDLE) && store_fire && dcache_rsp.wposted);
        response_event = load_event || store_event;
        response_entry = active_entry;
        response_rdata = dcache_rsp.rdata;
        if ((state == IDLE) && store_fire) response_entry = store_entry;

        load_issue = load_fire;
        load_pop = load_event;
        store_pop = store_event;
        dcache_req = '0;
        if (load_fire) begin
            dcache_req.ren  = 4'hf;
            dcache_req.addr = load_entry.address;
        end else if (store_fire) begin
            dcache_req.addr  = store_entry.address;
            dcache_req.wen   = store_entry.store_wen;
            dcache_req.wdata = store_entry.store_data;
        end

        completion_valid = 1'b0;
        completion_entry = '0;
        completion_rdata = '0;
        if (!flush && pending_valid && !direct_completion.valid) begin
            completion_valid = 1'b1;
            completion_entry = pending_entry;
            completion_rdata = pending_rdata;
        end else if (!flush && response_event && !direct_completion.valid) begin
            completion_valid = 1'b1;
            completion_entry = response_entry;
            completion_rdata = response_rdata;
        end
    end

    always_ff @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            state <= IDLE;
            active_entry <= '0;
            pending_entry <= '0;
            pending_rdata <= '0;
            pending_valid <= 1'b0;
            active_killed <= 1'b0;
        end else begin
            if (flush)
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

            if (state == WAIT_LOAD && flush && !load_response_seen)
                active_killed <= 1'b1;

            if (pending_valid && !direct_completion.valid && !flush)
                pending_valid <= 1'b0;

            if (response_event) begin
                state <= IDLE;
                if (direct_completion.valid && !flush) begin
                    pending_valid <= 1'b1;
                    pending_entry <= response_entry;
                    pending_rdata <= response_rdata;
                end
            end
        end
    end
endmodule
