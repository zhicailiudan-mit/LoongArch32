`timescale 1ns/1ps

`include "defines.vh"
import cpu_types_pkg::*;

module tb_rob16;
    logic clk;
    logic rstn;
    logic [1:0] alloc_valid;
    logic [1:0] alloc_ready;
    logic [`ROB_TAG_W-1:0] alloc_tag [0:1];
    issue_uop_t alloc_uop [0:1];
    completion_t complete [0:1];
    logic recover_valid;
    logic [`ROB_TAG_W-1:0] recover_tag;
    commit_t commit [0:1];
    logic [`ROB_TAG_W-1:0] query_tag [0:3];
    logic query_done [0:3];
    logic [31:0] query_value [0:3];
    logic [`ROB_DEPTH-1:0] live_mask;
    logic [`ROB_TAG_W:0] occupancy;
    integer i;
    bit saw_wrap;

    `include "tb_common.svh"

    function automatic issue_uop_t make_uop(
        input logic [31:0] fpc,
        input logic [4:0]  frd
    );
        issue_uop_t u;
        begin
            u = '0;
            u.pc = fpc;
            u.reg_write = (frd != 5'd0);
            u.arch_rd = frd;
            make_uop = u;
        end
    endfunction

    task automatic clear_inputs;
        begin
            alloc_valid = 2'b00;
            alloc_uop[0] = '0;
            alloc_uop[1] = '0;
            complete[0] = '0;
            complete[1] = '0;
            recover_valid = 1'b0;
            recover_tag = '0;
            for (i = 0; i < 4; i = i + 1)
                query_tag[i] = '0;
        end
    endtask

    ROB16 dut (
        .clk         (clk),
        .rstn        (rstn),
        .alloc_valid (alloc_valid),
        .alloc_ready (alloc_ready),
        .alloc_tag   (alloc_tag),
        .alloc_uop   (alloc_uop),
        .complete    (complete),
        .recover_valid(recover_valid),
        .recover_tag (recover_tag),
        .commit      (commit),
        .query_tag   (query_tag),
        .query_done  (query_done),
        .query_value (query_value),
        .live_mask   (live_mask),
        .occupancy   (occupancy)
    );

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    initial begin
        rstn = 1'b0;
        clear_inputs();
        repeat (3) @(posedge clk);
        rstn = 1'b1;
        @(negedge clk);

        tb_expect(occupancy == 0, "ROB reset occupancy");
        tb_expect(alloc_ready[0] && alloc_ready[1], "ROB reset allocation ready");

        alloc_valid = 2'b11;
        alloc_uop[0] = make_uop(32'h1000, 5'd1);
        alloc_uop[1] = make_uop(32'h1004, 5'd2);
        #1;
        tb_expect(alloc_tag[0] == 4'd0 && alloc_tag[1] == 4'd1,
                  "ROB initial dual allocation tags");
        @(posedge clk);
        #1;
        alloc_valid = 2'b00;
        tb_expect(occupancy == 2, "ROB dual allocation occupancy");
        tb_expect(live_mask[0] && live_mask[1], "ROB dual allocation live mask");
        query_tag[1] = 4'd1;

        // Younger completion alone must not retire the older entry.
        @(negedge clk);
        complete[1].valid = 1'b1;
        complete[1].rob_tag = 4'd1;
        complete[1].value = 32'h2222;
        complete[1].reg_write = 1'b1;
        #1;
        tb_expect(!commit[0].valid, "ROB blocks younger completion at head");
        @(posedge clk);
        #1;
        complete[1] = '0;
        tb_expect(query_done[1] && query_value[1] == 32'h2222,
                  "ROB completed younger query");

        // Completing the head and the already-completed next entry must allow
        // dual commit in the same cycle.
        @(negedge clk);
        complete[0].valid = 1'b1;
        complete[0].rob_tag = 4'd0;
        complete[0].value = 32'h1111;
        complete[0].reg_write = 1'b1;
        #1;
        tb_expect(commit[0].valid && commit[1].valid,
                  "ROB completion and dual commit in one cycle");
        tb_expect(commit[0].rob_tag == 4'd0 && commit[1].rob_tag == 4'd1,
                  "ROB commit order");
        tb_expect(commit[0].value == 32'h1111 && commit[1].value == 32'h2222,
                  "ROB commit values");
        @(posedge clk);
        #1;
        clear_inputs();
        tb_expect(occupancy == 0, "ROB dual commit drains entries");

        // Recovery keeps the recovery entry and older entries, and removes
        // younger live entries.
        alloc_valid = 2'b11;
        alloc_uop[0] = make_uop(32'h2000, 5'd3);
        alloc_uop[1] = make_uop(32'h2004, 5'd4);
        @(posedge clk);
        #1;
        alloc_valid = 2'b11;
        alloc_uop[0] = make_uop(32'h2008, 5'd5);
        alloc_uop[1] = make_uop(32'h200c, 5'd6);
        @(posedge clk);
        #1;
        alloc_valid = 2'b00;
        tb_expect(occupancy == 4, "ROB recovery setup occupancy");

        @(negedge clk);
        recover_valid = 1'b1;
        // The current ROB head is tag 2 after the previous dual commit;
        // recover at tag 3 so tags 2 and 3 remain live.
        recover_tag = 4'd3;
        #1;
        @(posedge clk);
        #1;
        recover_valid = 1'b0;
        $display("[UNIT] ROB recovery observed occupancy=%0d live_mask=%h",
                 occupancy, live_mask);
        tb_expect(occupancy == 2, "ROB recovery occupancy");
        tb_expect(!live_mask[0] && !live_mask[1] && live_mask[2] && live_mask[3] &&
                  !live_mask[4] && !live_mask[5],
                  "ROB recovery live mask");

        // Exercise head/tail wrap while allocating and completing one entry
        // per cycle.  This also covers completion and commit on the same edge.
        rstn = 1'b0;
        repeat (2) @(posedge clk);
        rstn = 1'b1;
        clear_inputs();
        saw_wrap = 1'b0;
        for (i = 0; i < 20; i = i + 1) begin
            @(negedge clk);
            alloc_valid[0] = alloc_ready[0];
            alloc_valid[1] = 1'b0;
            alloc_uop[0] = make_uop(32'h3000 + i * 4, 5'd7);
            if (occupancy != 0) begin
                complete[0].valid = 1'b1;
                complete[0].rob_tag = commit[0].rob_tag;
                complete[0].value = 32'h5000 + i;
                complete[0].reg_write = 1'b1;
            end else begin
                complete[0] = '0;
            end
            #1;
            if ((i > 0) && (alloc_tag[0] == 4'd0))
                saw_wrap = 1'b1;
            @(posedge clk);
            #1;
            alloc_valid = 2'b00;
            complete[0] = '0;
            tb_expect(occupancy <= `ROB_DEPTH, "ROB occupancy never exceeds depth");
        end
        tb_expect(saw_wrap, "ROB tag wrap exercised");

        tb_note("ROB16 baseline PASS");
        $finish;
    end
endmodule
