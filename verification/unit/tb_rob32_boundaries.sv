`timescale 1ns/1ps

`include "defines.vh"
import cpu_types_pkg::*;

module tb_rob32_boundaries;
    logic clk = 1'b0;
    logic rstn = 1'b0;
    logic [1:0] alloc_valid;
    wire [1:0] alloc_ready;
    uop_id_t alloc_id [0:1];
    issue_uop_t alloc_uop [0:1];
    completion_t complete [0:1];
    logic recover_valid;
    uop_id_t recover_id;
    commit_t commit [0:1];
    uop_id_t query_id [0:3];
    wire query_done [0:3];
    wire [31:0] query_value [0:3];
    wire [`ROB_DEPTH-1:0] live_mask;
    uop_id_t head_id;
    wire [`ROB_TAG_W:0] occupancy;

    uop_id_t id31;
    uop_id_t old_id0;
    uop_id_t new_id0;
    uop_id_t old_epoch_id0;
    integer i;

    always #5 clk = ~clk;

    ReorderBuffer dut (
        .clk(clk), .rstn(rstn), .alloc_valid(alloc_valid),
        .alloc_ready(alloc_ready), .alloc_id(alloc_id),
        .alloc_uop(alloc_uop), .complete(complete),
        .recover_valid(recover_valid), .recover_id(recover_id),
        .commit(commit), .query_id(query_id), .query_done(query_done),
        .query_value(query_value), .live_mask(live_mask),
        .head_id(head_id), .occupancy(occupancy)
    );

    task automatic fail(input string msg);
        begin
            $display("[ROB32-FAIL] %s", msg);
            $fatal(1);
        end
    endtask

    task automatic clear_drives;
        integer q;
        begin
            alloc_valid = 2'b00;
            alloc_uop[0] = '0;
            alloc_uop[1] = '0;
            complete[0] = '0;
            complete[1] = '0;
            recover_valid = 1'b0;
            recover_id = '0;
            for (q = 0; q < 4; q = q + 1)
                query_id[q] = '0;
        end
    endtask

    task automatic alloc_one(input logic [31:0] pc_value, output uop_id_t id);
        begin
            @(negedge clk);
            alloc_valid = 2'b01;
            alloc_uop[0] = '0;
            alloc_uop[0].pc = pc_value;
            alloc_uop[0].reg_write = 1'b1;
            alloc_uop[0].arch_rd = 5'd1;
            #1;
            if (!alloc_ready[0]) fail("single allocation unexpectedly blocked");
            id = alloc_id[0];
            @(posedge clk); #1;
            alloc_valid = 2'b00;
        end
    endtask

    task automatic alloc_two(input logic [31:0] pc_value,
                             output uop_id_t id0, output uop_id_t id1);
        begin
            @(negedge clk);
            alloc_valid = 2'b11;
            alloc_uop[0] = '0;
            alloc_uop[1] = '0;
            alloc_uop[0].pc = pc_value;
            alloc_uop[1].pc = pc_value + 4;
            #1;
            if (!alloc_ready[0] || !alloc_ready[1])
                fail("dual allocation unexpectedly blocked");
            id0 = alloc_id[0];
            id1 = alloc_id[1];
            @(posedge clk); #1;
            alloc_valid = 2'b00;
        end
    endtask

    task automatic complete_two(input uop_id_t id0, input uop_id_t id1);
        begin
            @(negedge clk);
            complete[0] = '0;
            complete[1] = '0;
            complete[0].valid = 1'b1;
            complete[0].uop_id = id0;
            complete[0].reg_write = 1'b1;
            complete[0].value = 32'hc000_0000 | id0.rob_tag;
            complete[1].valid = 1'b1;
            complete[1].uop_id = id1;
            complete[1].reg_write = 1'b1;
            complete[1].value = 32'hc100_0000 | id1.rob_tag;
            @(posedge clk); #1;
            complete[0] = '0;
            complete[1] = '0;
        end
    endtask

    task automatic complete_one_and_commit(input uop_id_t id);
        begin
            @(negedge clk);
            complete[0] = '0;
            complete[0].valid = 1'b1;
            complete[0].uop_id = id;
            complete[0].reg_write = 1'b1;
            complete[0].value = 32'ha000_0000 | id.rob_tag;
            @(posedge clk); #1;
            complete[0] = '0;
            @(negedge clk); #1;
            if (!commit[0].valid || !uop_id_equal(commit[0].uop_id, id))
                fail("single completion/commit identity mismatch");
            @(posedge clk); #1;
        end
    endtask

    task automatic wait_commit_pair(input uop_id_t id0, input uop_id_t id1);
        begin
            @(negedge clk); #1;
            if (!commit[0].valid || !commit[1].valid ||
                !uop_id_equal(commit[0].uop_id, id0) ||
                !uop_id_equal(commit[1].uop_id, id1))
                fail("dual commit identity/order mismatch");
            @(posedge clk); #1;
        end
    endtask

    initial begin
        uop_id_t tmp;
        uop_id_t ids [0:31];
        uop_id_t wrap0;
        uop_id_t wrap1;

        clear_drives();
        repeat (3) @(posedge clk);
        rstn = 1'b1;

        // Create tail=31, then retire two entries so a dual allocation can
        // cross 31 -> 0 without the ROB being capacity blocked.
        for (i = 0; i < 31; i = i + 1)
            alloc_one(32'h2000 + i * 4, ids[i]);
        if (occupancy !== 31 || alloc_id[0].rob_tag !== 5'd31)
            fail("setup did not place tail at tag 31");
        if (alloc_ready[1]) fail("31-entry ROB incorrectly allowed dual allocation");

        complete_two(ids[0], ids[1]);
        wait_commit_pair(ids[0], ids[1]);
        if (occupancy !== 29 || head_id.rob_tag !== 5'd2)
            fail("initial dual commit state mismatch");
        alloc_two(32'h3000, wrap0, wrap1);
        id31 = wrap0;
        old_id0 = wrap1;
        if (wrap0.rob_tag !== 5'd31 || wrap1.rob_tag !== 5'd0 ||
            wrap1.epoch !== (wrap0.epoch + 1'b1))
            fail("dual allocation did not wrap tag/epoch at 31 -> 0");

        // Recovery at tag31 must keep the older wrapped window and squash
        // younger tag0 even though its numeric tag is smaller.
        @(negedge clk);
        recover_valid = 1'b1;
        recover_id = id31;
        @(posedge clk); #1;
        recover_valid = 1'b0;
        if (occupancy !== 30 || !live_mask[31] || live_mask[0])
            fail("recovery across wrap produced the wrong live window");

        // Reallocate tag0 with the continuous wrapped epoch, then prove a
        // genuinely old-epoch completion cannot mark the replacement done.
        // A killed same-ID completion is canceled by the producing execution
        // or LSU pipeline during recovery before reaching the ROB interface.
        alloc_one(32'h3010, new_id0);
        if (new_id0.rob_tag !== 5'd0 || new_id0.epoch !== old_id0.epoch)
            fail("recovery broke the continuous wrapped uop-ID sequence");
        query_id[0] = new_id0;
        old_epoch_id0 = new_id0;
        old_epoch_id0.epoch = new_id0.epoch - 1'b1;
        @(negedge clk);
        complete[0] = '0;
        complete[0].valid = 1'b1;
        complete[0].uop_id = old_epoch_id0;
        complete[0].reg_write = 1'b1;
        complete[0].value = 32'hdead_beef;
        @(posedge clk); #1;
        complete[0] = '0;
        if (query_done[0]) fail("late old-epoch completion updated reused entry");

        // Drain tags 2..29 in pairs, then tag30 alone so head becomes 31.
        for (i = 2; i < 30; i = i + 2) begin
            complete_two(ids[i], ids[i+1]);
            wait_commit_pair(ids[i], ids[i+1]);
        end
        @(negedge clk);
        complete[0] = '0;
        complete[0].valid = 1'b1;
        complete[0].uop_id = ids[30];
        @(posedge clk); #1;
        complete[0] = '0;
        @(negedge clk); #1;
        if (!commit[0].valid || commit[1].valid || commit[0].uop_id.rob_tag != 5'd30)
            fail("single commit at tag30 mismatch");
        @(posedge clk); #1;
        if (head_id.rob_tag !== 5'd31) fail("head did not advance to tag31");

        // Complete tags31 and0 and verify dual commit crosses 31 -> 0.
        complete_two(id31, new_id0);
        wait_commit_pair(id31, new_id0);
        if (occupancy !== 0 || head_id.rob_tag !== 5'd1)
            fail("dual commit did not cross head 31 -> 0 correctly");

        // Fill all 32 entries, then complete the head.  On the following
        // commit edge alloc_ready must expose the retiring slot immediately.
        for (i = 0; i < 16; i = i + 1)
            alloc_two(32'h4000 + i * 8, ids[2*i], ids[2*i+1]);
        if (occupancy !== 32 || alloc_ready[0] || alloc_ready[1])
            fail("full ROB capacity state mismatch");
        @(negedge clk);
        complete[0] = '0;
        complete[0].valid = 1'b1;
        complete[0].uop_id = ids[0];
        @(posedge clk); #1;
        complete[0] = '0;
        @(negedge clk);
        alloc_valid = 2'b01;
        alloc_uop[0] = '0;
        alloc_uop[0].pc = 32'h5000;
        #1;
        if (!commit[0].valid || !alloc_ready[0] || alloc_ready[1])
            fail("full ROB did not allow one allocation with one commit");
        tmp = alloc_id[0];
        @(posedge clk); #1;
        alloc_valid = 2'b00;
        if (occupancy !== 32 || !live_mask[tmp.rob_tag])
            fail("full commit/allocation did not preserve full occupancy");

        // Reset only the unit-test DUT, then allocate and retire beyond the
        // complete 2-bit-epoch x 5-bit-tag identifier space.  This exercises
        // repeated ROB and complete uop-ID wrap without carrying full-test
        // state into the stream.
        @(negedge clk);
        rstn = 1'b0;
        clear_drives();
        repeat (2) @(posedge clk);
        @(negedge clk);
        rstn = 1'b1;
        for (i = 0; i < 160; i = i + 1) begin
            alloc_one(32'h6000 + i * 4, tmp);
            if (tmp.rob_tag !== i[`ROB_TAG_W-1:0])
                fail("streaming allocation tag sequence mismatch");
            complete_one_and_commit(tmp);
        end
        if (occupancy !== 0 || head_id.rob_tag !== 5'd0)
            fail("multi-wrap stream did not finish empty at tag zero");

        $display("[ROB32-PASS] allocation/commit wrap, capacity, recovery, epoch, full+commit and multi-ID-wrap passed");
        $finish;
    end

    always @(posedge clk) begin
        if (rstn && occupancy > `ROB_DEPTH)
            fail("occupancy exceeded ROB_DEPTH");
        if (rstn && occupancy !== $countones(live_mask))
            fail("occupancy/live-mask conservation failed");
    end
endmodule
