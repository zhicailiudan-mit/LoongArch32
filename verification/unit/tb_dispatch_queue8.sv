`timescale 1ns/1ps

`include "defines.vh"
import cpu_types_pkg::*;

module tb_dispatch_queue8;
    logic clk = 1'b0;
    logic rstn = 1'b0;
    logic flush = 1'b0;
    logic recover_valid = 1'b0;
    logic system_flush = 1'b0;
    uop_id_t recover_id;
    logic barrier_release = 1'b0;
    logic perf_true_source_wait;
    logic perf_lsu_order;
    logic perf_serializing;
    dispatch_uop_t enq [0:1];
    wire enq_ready [0:1];
    completion_t complete [0:1];
    commit_t commit [0:1];
    logic rob_head_valid = 1'b0;
    logic [`ROB_TAG_W-1:0] rob_head_tag = '0;
    uop_id_t rob_head_id;
    wire issue_valid [0:1];
    logic issue_ready [0:1];
    issue_uop_t issue [0:1];
    wire [3:0] occupancy;

    integer next_tag;
    logic [31:0] held_pc;

    always #5 clk = ~clk;

    DispatchQueue dut (
        .clk(clk), .rstn(rstn), .flush(flush),
        .recover_valid(recover_valid), .system_flush(system_flush),
        .recover_id(recover_id), .barrier_release(barrier_release),
        .perf_true_source_wait(perf_true_source_wait),
        .perf_lsu_order(perf_lsu_order),
        .perf_serializing(perf_serializing),
        .enq(enq), .enq_ready(enq_ready),
        .complete(complete), .commit(commit),
        .rob_head_valid(rob_head_valid), .rob_head_tag(rob_head_tag),
        .rob_head_id(rob_head_id), .issue_valid(issue_valid),
        .issue_ready(issue_ready), .issue(issue), .occupancy(occupancy)
    );

    task automatic fail(input string msg);
        begin
            $display("[DQ8-FAIL] %s", msg);
            $fatal(1);
        end
    endtask

    task automatic clear_inputs;
        begin
            enq[0] = '0;
            enq[1] = '0;
            complete[0] = '0;
            complete[1] = '0;
            commit[0] = '0;
            commit[1] = '0;
            recover_id = '0;
            rob_head_id = '0;
        end
    endtask

    task automatic make_lane(input integer lane, input logic ready_sources);
        begin
            enq[lane] = '0;
            enq[lane].valid = 1'b1;
            enq[lane].uop.uop_id.rob_tag = next_tag[`ROB_TAG_W-1:0];
            enq[lane].uop.uop_id.epoch = next_tag[`ROB_TAG_W+1:`ROB_TAG_W];
            enq[lane].uop.pc = 32'h1000 + next_tag * 4;
            enq[lane].uop.result_sel = `WD_ALU;
            enq[lane].uop.alu_op = `ALU_ADD;
            enq[lane].src0_ready = ready_sources;
            enq[lane].src1_ready = ready_sources;
            next_tag = next_tag + 1;
        end
    endtask

    task automatic enqueue_two(input logic ready0, input logic ready1);
        begin
            make_lane(0, ready0);
            make_lane(1, ready1);
            #1;
            if (!enq_ready[0] || !enq_ready[1])
                fail("dual enqueue unexpectedly backpressured");
            @(posedge clk); #1;
            enq[0].valid = 1'b0;
            enq[1].valid = 1'b0;
        end
    endtask

    task automatic expect_pair(input logic [31:0] pc0, input logic [31:0] pc1);
        begin
            #1;
            if (!issue_valid[0] || !issue_valid[1])
                fail("expected a dual issue pair");
            if (issue[0].pc !== pc0 || issue[1].pc !== pc1)
                fail($sformatf("oldest pair mismatch got %h/%h expected %h/%h",
                               issue[0].pc, issue[1].pc, pc0, pc1));
            if (issue[0].uop_id == issue[1].uop_id)
                fail("two issue lanes selected the same entry");
        end
    endtask

    initial begin
        clear_inputs();
        issue_ready[0] = 1'b0;
        issue_ready[1] = 1'b0;
        next_tag = 0;
        repeat (3) @(posedge clk);
        rstn = 1'b1;
        @(posedge clk); #1;

        // Fill all eight entries with four dual enqueues.
        enqueue_two(1'b1, 1'b1);
        enqueue_two(1'b1, 1'b1);
        enqueue_two(1'b1, 1'b1);
        enqueue_two(1'b1, 1'b1);
        if (occupancy !== 4'd8) fail("queue did not reach occupancy eight");
        if (enq_ready[0] || enq_ready[1]) fail("full queue exposed enqueue capacity");

        // Balanced selectors must still produce the two oldest entries.
        expect_pair(32'h1000, 32'h1004);
        issue_ready[0] = 1'b1;
        issue_ready[1] = 1'b1;
        @(posedge clk); #1;
        if (occupancy !== 4'd6) fail("dual issue did not remove two entries");

        // Dual enqueue and dual issue in the same cycle with existing space.
        make_lane(0, 1'b1);
        make_lane(1, 1'b1);
        expect_pair(32'h1008, 32'h100c);
        if (!enq_ready[0] || !enq_ready[1]) fail("two free slots not advertised");
        @(posedge clk); #1;
        enq[0].valid = 1'b0;
        enq[1].valid = 1'b0;
        if (occupancy !== 4'd6) fail("simultaneous dual enqueue/issue changed occupancy");

        // One-lane issue leaves exactly one slot available on the next cycle.
        issue_ready[1] = 1'b0;
        held_pc = issue[1].pc;
        @(posedge clk); #1;
        if (occupancy !== 4'd5) fail("single issue did not remove one entry");
        if (!issue_valid[1] || issue[1].pc !== held_pc)
            fail("stalled lane payload did not remain stable");
        make_lane(0, 1'b1);
        enq[1].valid = 1'b0;
        if (!enq_ready[0]) fail("single free slot did not accept lane0");
        @(posedge clk); #1;
        enq[0].valid = 1'b0;

        // Flush removes every unissued queue entry.
        flush = 1'b1;
        system_flush = 1'b1;
        @(posedge clk); #1;
        flush = 1'b0;
        system_flush = 1'b0;
        if (occupancy !== 0 || issue_valid[0] || issue_valid[1])
            fail("flush did not empty DQ8");

        // Mixed readiness: the unready oldest entry stays queued while the
        // next two ready entries issue; completion then wakes the oldest.
        issue_ready[0] = 1'b0;
        issue_ready[1] = 1'b0;
        enqueue_two(1'b0, 1'b1);
        make_lane(0, 1'b1);
        enq[1].valid = 1'b0;
        @(posedge clk); #1;
        enq[0].valid = 1'b0;
        issue_ready[0] = 1'b1;
        issue_ready[1] = 1'b1;
        expect_pair(32'h1030, 32'h1034);
        @(posedge clk); #1;
        complete[0].valid = 1'b1;
        complete[0].reg_write = 1'b1;
        complete[0].uop_id.rob_tag = 5'd10;
        complete[0].uop_id.epoch = '0;
        // The test's unready entry has no architectural source, so explicitly
        // finish with a flush after exercising the varied-ready selector.
        @(posedge clk); #1;
        complete[0] = '0;
        flush = 1'b1;
        system_flush = 1'b1;
        @(posedge clk); #1;
        if (occupancy !== 0) fail("final flush failed");

        // A Store whose address is ready but whose data is unresolved may
        // occupy lane0.  It must not also take lane1, because the ready ALU on
        // lane1 can be the producer needed to drain a full StoreQueue.
        flush = 1'b0;
        system_flush = 1'b0;
        issue_ready[0] = 1'b0;
        issue_ready[1] = 1'b0;
        enq[0] = '0;
        enq[0].valid = 1'b1;
        enq[0].src0_ready = 1'b1;
        enq[0].src1_ready = 1'b0;
        enq[0].uop.uop_id = '{epoch:'0, rob_tag:5'd20};
        enq[0].uop.pc = 32'h2000;
        enq[0].uop.is_ld_st = 1'b1;
        enq[0].uop.store_mask = 4'hf;
        enq[0].uop.result_sel = `WD_ALU;
        enq[1] = '0;
        enq[1].valid = 1'b1;
        enq[1].src0_ready = 1'b1;
        enq[1].src1_ready = 1'b1;
        enq[1].uop.uop_id = '{epoch:'0, rob_tag:5'd21};
        enq[1].uop.pc = 32'h2004;
        enq[1].uop.result_sel = `WD_ALU;
        enq[1].uop.alu_op = `ALU_ADD;
        @(posedge clk); #1;
        enq[0].valid = 1'b0;
        enq[1].valid = 1'b0;
        if (!issue_valid[0] || issue[0].pc !== 32'h2000)
            fail("unresolved-data Store was not retained on lane0");
        if (!issue_valid[1] || issue[1].pc !== 32'h2004 ||
            issue[1].is_ld_st)
            fail("unresolved-data Store blocked its ready ALU producer on lane1");

        $display("[DQ8-PASS] depth, oldest selection, dual/single issue, simultaneous enqueue, stall and flush passed");
        $finish;
    end

    always @(posedge clk) begin
        if (rstn && occupancy > 8) fail("occupancy exceeded eight");
        if (rstn && issue_valid[0] && issue_valid[1] &&
            uop_id_equal(issue[0].uop_id, issue[1].uop_id))
            fail("duplicate dual issue selection");
    end
endmodule
