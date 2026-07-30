`timescale 1ns/1ps
`include "defines.vh"
import cpu_types_pkg::*;

module tb_lsu_request_boundary;
    logic clk = 1'b0;
    logic rstn = 1'b0;
    always #5 clk = ~clk;

    logic flush, branch_flush, recover_valid, system_flush;
    uop_id_t recover_id;
    logic load_valid, load_blocked, load_memory_allowed;
    logic load_forward_valid;
    logic [31:0] load_forward_rdata;
    lsu_entry_t load_entry;
    logic load_issue, load_pop;
    uop_id_t load_pop_uop_id;
    logic store_valid, store_pop;
    lsu_entry_t store_entry;
    completion_t direct_completion;
    logic completion_valid;
    lsu_entry_t completion_entry;
    logic [31:0] completion_rdata;
    memory_request_t dcache_req;
    memory_response_t dcache_rsp;
    logic perf_dcache_wait, perf_dcache_backpressure;

    LsuArbiter dut (
        .clk, .rstn, .flush, .branch_flush, .recover_valid,
        .system_flush, .recover_id,
        .load_valid, .load_entry, .load_blocked, .load_memory_allowed,
        .load_forward_valid, .load_forward_rdata,
        .load_issue, .load_pop, .load_pop_uop_id,
        .store_valid, .store_entry, .store_pop,
        .store_line_alloc_valid(1'b0), .store_line_alloc_addr(32'b0),
        .direct_completion, .completion_valid, .completion_entry,
        .completion_rdata, .dcache_req, .dcache_rsp,
        .perf_dcache_wait, .perf_dcache_backpressure
    );

    task automatic fail(input string message);
        begin
            $display("[UNIT-FAIL] %s", message);
            $finish;
        end
    endtask

    initial begin
        flush = 0;
        branch_flush = 0;
        recover_valid = 0;
        system_flush = 0;
        recover_id = '0;
        load_valid = 0;
        load_blocked = 0;
        load_memory_allowed = 1;
        load_forward_valid = 0;
        load_forward_rdata = '0;
        load_entry = '0;
        store_valid = 0;
        store_entry = '0;
        direct_completion = '0;
        dcache_rsp = '0;

        repeat (2) @(posedge clk);
        rstn = 1;

        // Capture a Load while DCache is not ready.
        @(negedge clk);
        load_entry.valid = 1;
        load_entry.address = 32'h1234_5679;
        load_entry.load_ext_op = `RAM_EXT_B_Z;
        load_entry.uop_id = 'd3;
        load_valid = 1;
        @(posedge clk); #1;
        if (dcache_req.addr !== 32'h1234_5679 || dcache_req.ren !== 4'b0010)
            fail("Load intent was not registered correctly");
        if (load_issue) fail("Load fired while rready was low");

        // Changing the source queue view must not alter a stalled request.
        load_entry.address = 32'hdead_beef;
        load_entry.uop_id = 'd7;
        repeat (2) begin
            @(posedge clk); #1;
            if (dcache_req.addr !== 32'h1234_5679 || dcache_req.ren !== 4'b0010)
                fail("Stalled Load request payload changed");
        end

        dcache_rsp.rready = 1;
        #1;
        if (!load_issue) fail("Registered Load did not handshake");
        @(posedge clk); #1;
        dcache_rsp.rready = 0;
        load_valid = 0;
        if ((|dcache_req.ren) || (|dcache_req.wen))
            fail("Accepted Load request did not leave request stage");

        // Return the Load and verify that the captured (not mutated) owner is used.
        @(negedge clk);
        dcache_rsp.valid = 1;
        dcache_rsp.rdata = 32'ha5a5_5a5a;
        #1;
        if (!completion_valid || completion_entry.address !== 32'h1234_5679)
            fail("Load owner metadata was not captured with request");
        @(posedge clk); #1;
        dcache_rsp.valid = 0;

        // Capture and stall a posted Store in the same way.
        @(negedge clk);
        store_entry.valid = 1;
        store_entry.address = 32'h8000_0044;
        store_entry.store_wen = 4'b0101;
        store_entry.store_data = 32'h1122_3344;
        store_valid = 1;
        @(posedge clk); #1;
        if (dcache_req.addr !== 32'h8000_0044 ||
            dcache_req.wen !== 4'b0101 ||
            dcache_req.wdata !== 32'h1122_3344)
            fail("Store intent was not registered correctly");
        store_entry.address = 32'hffff_0000;
        store_entry.store_wen = 4'b1111;
        store_entry.store_data = 32'hdead_beef;
        @(posedge clk); #1;
        if (dcache_req.addr !== 32'h8000_0044 ||
            dcache_req.wen !== 4'b0101 ||
            dcache_req.wdata !== 32'h1122_3344)
            fail("Stalled Store request payload changed");

        dcache_rsp.wready = 1;
        dcache_rsp.wposted = 1;
        #1;
        if (!store_pop) fail("Posted Store did not pop on handshake");
        @(posedge clk); #1;
        dcache_rsp.wready = 0;
        dcache_rsp.wposted = 0;
        store_valid = 0;
        if ((|dcache_req.ren) || (|dcache_req.wen))
            fail("Accepted Store request did not leave request stage");

        // Flush must cancel an unaccepted request without issuing it.
        @(negedge clk);
        load_entry.address = 32'h4000_0000;
        load_entry.load_ext_op = `RAM_EXT_N;
        load_valid = 1;
        @(posedge clk); #1;
        flush = 1;
        dcache_rsp.rready = 1;
        #1;
        if (load_issue) fail("Request fired during flush");
        @(posedge clk); #1;
        flush = 0;
        dcache_rsp.rready = 0;
        load_valid = 0;
        if ((|dcache_req.ren) || (|dcache_req.wen))
            fail("Flush did not cancel pending request");

        $display("[UNIT-PASS] LSU registered request boundary");
        $finish;
    end
endmodule
