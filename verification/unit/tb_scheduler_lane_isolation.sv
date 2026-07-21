`timescale 1ns/1ps
`include "defines.vh"

import cpu_types_pkg::*;

module tb_scheduler_lane_isolation;
    logic clk = 0;
    logic rstn = 0;
    logic flush = 0;
    logic barrier_release = 0;
    logic dispatch0_valid, dispatch1_valid;
    logic dispatch0_ready, dispatch1_ready;
    issue_uop_t dispatch0_uop, dispatch1_uop;
    logic d0s0r, d0s1r, d1s0r, d1s1r;
    logic [`ROB_TAG_W-1:0] d0s0t, d0s1t, d1s0t, d1s1t;
    completion_t complete0, complete1;
    commit_t commit0, commit1;
    logic rob_head_valid;
    logic [`ROB_TAG_W-1:0] rob_head_tag;
    logic system_inflight;
    logic main_issue_valid, main_issue_ready, main_issue_fire;
    issue_uop_t main_issue;
    logic system_issue_valid, system_issue_ready, system_issue_fire;
    issue_uop_t system_issue;
    logic issue1_valid, issue1_ready, issue1_fire;
    issue_uop_t issue1;
    logic [2:0] occupancy;

    always #5 clk = ~clk;

    Scheduler dut (
        .clk, .rstn, .flush, .barrier_release,
        .dispatch0_valid, .dispatch0_ready, .dispatch0_uop,
        .dispatch0_src0_ready(d0s0r), .dispatch0_src0_tag(d0s0t),
        .dispatch0_src1_ready(d0s1r), .dispatch0_src1_tag(d0s1t),
        .dispatch1_valid, .dispatch1_ready, .dispatch1_uop,
        .dispatch1_src0_ready(d1s0r), .dispatch1_src0_tag(d1s0t),
        .dispatch1_src1_ready(d1s1r), .dispatch1_src1_tag(d1s1t),
        .complete0, .complete1, .commit0, .commit1,
        .rob_head_valid, .rob_head_tag, .system_inflight,
        .main_issue_valid, .main_issue_ready, .main_issue_fire, .main_issue,
        .system_issue_valid, .system_issue_ready, .system_issue_fire,
        .system_issue,
        .issue1_valid, .issue1_ready, .issue1_fire, .issue1, .occupancy
    );

    task automatic fail(input string message);
        $display("[LANE-ISOLATION-FAIL] %s", message);
        $fatal(1, "scheduler lane isolation failure");
    endtask

    task automatic drive_uop(
        output issue_uop_t uop,
        input logic [`ROB_TAG_W-1:0] tag,
        input logic [4:0] alu_op
    );
        uop = '0;
        uop.rob_tag = tag;
        uop.pc = 32'h1c00_0000 + {26'd0, tag, 2'b00};
        uop.alu_op = alu_op;
        uop.result_sel = `WD_ALU;
        uop.reg_write = 1'b1;
        uop.src0_used = 1'b0;
        uop.src1_used = 1'b0;
    endtask

    initial begin
        dispatch0_valid = 0;
        dispatch1_valid = 0;
        dispatch0_uop = '0;
        dispatch1_uop = '0;
        d0s0r = 1; d0s1r = 1; d1s0r = 1; d1s1r = 1;
        d0s0t = 0; d0s1t = 0; d1s0t = 0; d1s1t = 0;
        complete0 = '0; complete1 = '0; commit0 = '0; commit1 = '0;
        rob_head_valid = 0; rob_head_tag = 0; system_inflight = 0;
        main_issue_ready = 0;
        issue1_ready = 1;
        system_issue_ready = 1;

        repeat (3) @(posedge clk);
        rstn = 1;
        @(posedge clk);

        // A fast integer selected on the main queue output must be consumed
        // by lane1 while lane0 is locally blocked.
        drive_uop(dispatch0_uop, 4'd1, `ALU_ADD);
        dispatch0_valid = 1;
        @(posedge clk);
        dispatch0_valid = 0;
        #1;
        if (!issue1_valid || issue1.rob_tag != 4'd1 || main_issue_valid)
            fail("fast integer did not bypass blocked lane0 to lane1");
        @(posedge clk);

        // An older MUL remains lane0-only, while the younger ADD continues on
        // lane1 in the same blocked-lane0 interval.
        drive_uop(dispatch0_uop, 4'd2, `ALU_MULL);
        drive_uop(dispatch1_uop, 4'd3, `ALU_ADD);
        dispatch0_valid = 1;
        dispatch1_valid = 1;
        @(posedge clk);
        dispatch0_valid = 0;
        dispatch1_valid = 0;
        #1;
        if (!main_issue_valid || main_issue.rob_tag != 4'd2)
            fail("MUL was not retained on lane0");
        if (!issue1_valid || issue1.rob_tag != 4'd3)
            fail("younger integer did not continue on lane1 beside MUL");
        @(posedge clk);

        main_issue_ready = 1;
        #1;
        if (!main_issue_valid || main_issue.rob_tag != 4'd2)
            fail("held MUL payload changed before lane0 handshake");
        @(posedge clk);
        #1;
        if (occupancy != 0)
            fail("queue did not drain after independent lane handshakes");

        // The oldest ready uop is an ALU operation and the younger uop needs
        // lane0's LSU.  Resource-aware pairing must swap the physical lanes:
        // ALU -> lane1, LSU -> lane0, with both handshakes on this cycle.
        drive_uop(dispatch0_uop, 4'd4, `ALU_ADD);
        drive_uop(dispatch1_uop, 4'd5, `ALU_ADD);
        dispatch1_uop.is_ld_st = 1'b1;
        dispatch1_uop.result_sel = `WD_RAM;
        dispatch0_valid = 1;
        dispatch1_valid = 1;
        @(posedge clk);
        dispatch0_valid = 0;
        dispatch1_valid = 0;
        #1;
        if (!main_issue_valid || main_issue.rob_tag != 4'd5 ||
            !main_issue.is_ld_st)
            fail("younger LSU was not routed to its only capable lane");
        if (!issue1_valid || issue1.rob_tag != 4'd4 || issue1.is_ld_st)
            fail("oldest ALU was not paired onto lane1 beside LSU");
        if (!main_issue_fire || !issue1_fire)
            fail("resource-aware ALU+LSU pair did not fire simultaneously");
        @(posedge clk);
        #1;
        if (occupancy != 0)
            fail("resource-aware issue pair did not drain exactly two entries");

        // MDU is now legal on lane1. With lane0 backpressured, the older ALU
        // remains stable there while the younger multiply progresses on its
        // independent lane-local multiplier.
        main_issue_ready = 0;
        drive_uop(dispatch0_uop, 4'd6, `ALU_ADD);
        drive_uop(dispatch1_uop, 4'd7, `ALU_MULL);
        dispatch0_valid = 1;
        dispatch1_valid = 1;
        @(posedge clk);
        dispatch0_valid = 0;
        dispatch1_valid = 0;
        #1;
        if (!main_issue_valid || main_issue.rob_tag != 4'd6 || main_issue_fire)
            fail("backpressured lane0 did not hold the older ALU");
        if (!issue1_fire || issue1.rob_tag != 4'd7 ||
            issue1.alu_op != `ALU_MULL)
            fail("younger multiply did not progress on lane1");
        @(posedge clk);
        main_issue_ready = 1;
        #1;
        if (!main_issue_valid || main_issue.rob_tag != 4'd6)
            fail("paired ALU payload changed under lane0 backpressure");
        @(posedge clk);
        #1;
        if (occupancy != 0)
            fail("held resource-aware pair leaked a queue entry");

        // Two independent multiplications may issue together when both MDU
        // lanes are ready.
        drive_uop(dispatch0_uop, 4'd13, `ALU_MULL);
        drive_uop(dispatch1_uop, 4'd14, `ALU_MULH);
        dispatch0_valid = 1;
        dispatch1_valid = 1;
        @(posedge clk);
        dispatch0_valid = 0;
        dispatch1_valid = 0;
        #1;
        if (!main_issue_fire || main_issue.rob_tag != 4'd13)
            fail("older multiply did not issue on main MDU lane");
        if (!issue1_fire || issue1.rob_tag != 4'd14)
            fail("younger multiply did not issue on second MDU lane");
        @(posedge clk);
        #1;
        if (occupancy != 0)
            fail("dual-MDU issue did not drain exactly two entries");

        // A younger branch must not resolve while an older uop is still ahead
        // of it in the ROB.  Whole-queue recovery would otherwise delete an
        // older unresolved LSU entry and leave its ROB slot permanently live.
        drive_uop(dispatch0_uop, 4'd8, `ALU_ADD);
        drive_uop(dispatch1_uop, 4'd9, `ALU_PC4);
        dispatch1_uop.is_br_jmp = 1'b1;
        dispatch1_uop.npc_op = `NPC_CALL;
        rob_head_valid = 1;
        rob_head_tag = 4'd8;
        dispatch0_valid = 1;
        dispatch1_valid = 1;
        @(posedge clk);
        dispatch0_valid = 0;
        dispatch1_valid = 0;
        #1;
        if (!main_issue_fire || main_issue.rob_tag != 4'd8)
            fail("older ALU did not issue ahead of younger branch");
        if ((main_issue_valid && main_issue.rob_tag == 4'd9) ||
            (issue1_valid && issue1.rob_tag == 4'd9))
            fail("younger branch issued before reaching ROB head");
        @(posedge clk);
        rob_head_tag = 4'd9;
        #1;
        if (!main_issue_valid || main_issue.rob_tag != 4'd9 ||
            !main_issue.is_br_jmp)
            fail("branch did not become eligible at ROB head");
        @(posedge clk);
        #1;
        if (occupancy != 0)
            fail("ROB-head branch did not drain from issue queue");

        // Dispatch lane ownership must not constrain execution ownership.  A
        // lone LSU uop arriving through dispatch1 is dynamically steered onto
        // the shared main/LSU path.
        rob_head_valid = 0;
        drive_uop(dispatch1_uop, 4'd10, `ALU_ADD);
        dispatch1_uop.is_ld_st = 1'b1;
        dispatch1_uop.result_sel = `WD_RAM;
        dispatch1_valid = 1;
        @(posedge clk);
        dispatch1_valid = 0;
        #1;
        if (!main_issue_valid || !main_issue_fire ||
            main_issue.rob_tag != 4'd10 || !main_issue.is_ld_st)
            fail("dispatch1 LSU was not steered to the shared LSU path");
        if (issue1_valid && issue1.is_ld_st)
            fail("dispatch1 LSU leaked into the integer-only execution path");
        @(posedge clk);
        #1;
        if (occupancy != 0)
            fail("dispatch1 LSU did not drain after the shared-path handshake");

        // With a single LSU entrance, two ready memory uops must not both
        // handshake.  The older one issues first and the younger one remains
        // resident for the following cycle.
        drive_uop(dispatch0_uop, 4'd11, `ALU_ADD);
        drive_uop(dispatch1_uop, 4'd12, `ALU_ADD);
        dispatch0_uop.is_ld_st = 1'b1;
        dispatch0_uop.result_sel = `WD_RAM;
        dispatch1_uop.is_ld_st = 1'b1;
        dispatch1_uop.result_sel = `WD_RAM;
        dispatch0_valid = 1;
        dispatch1_valid = 1;
        @(posedge clk);
        dispatch0_valid = 0;
        dispatch1_valid = 0;
        #1;
        if (!main_issue_fire || main_issue.rob_tag != 4'd11 ||
            !main_issue.is_ld_st)
            fail("older member of dual-LSU pair did not issue first");
        if (issue1_fire)
            fail("single-entry LSU accepted a second memory uop in one cycle");
        @(posedge clk);
        #1;
        if (!main_issue_fire || main_issue.rob_tag != 4'd12 ||
            !main_issue.is_ld_st)
            fail("younger dual-LSU member was lost or did not issue second");
        @(posedge clk);
        #1;
        if (occupancy != 0)
            fail("dual-LSU serialization did not drain both queue entries");

        $display("[LANE-ISOLATION-PASS]");
        $finish;
    end
endmodule
