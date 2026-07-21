`timescale 1ns/1ps

`include "defines.vh"
import cpu_types_pkg::*;

// Extended ROB verification.  The model uses an ordered list of live tags and
// independent sequence numbers; it does not reproduce the DUT head/tail/count
// equations.  The current ROB interface is a two-entry consecutive dispatch
// packet: lane 1 is valid only together with lane 0.  This is required because
// alloc_tag[1] is defined as tail+1 and the interface has no hole/head advance
// protocol for a lane-1-only allocation.
module tb_rob16_extended;
    localparam integer DEPTH = `ROB_DEPTH;
    localparam integer TAG_W = `ROB_TAG_W;
    localparam integer DISPATCH_W = 2;
    localparam integer COMMIT_W = 2;
    localparam integer QUERY_W = 4;
    localparam integer LANES = DISPATCH_W;
    localparam integer RESET_CYCLES = 2;
    localparam integer BACKPRESSURE_CYCLES = DEPTH * 2;
    localparam integer HISTORY_DEPTH = 32;
    localparam integer WATCHDOG_GAP_NS = 1_000_000;
    localparam integer PER_TEST_TIMEOUT_NS = 5_000_000;
    localparam integer GLOBAL_TIMEOUT_NS = 100_000_000;
    localparam integer RESPONSE_SLOTS = DEPTH * 4;
    localparam bit LANE1_REQUIRES_LANE0 = 1'b1;
    localparam bit RECOVERY_SQUASHES_ALLOCATION = 1'b1;
    // The DUT's head/tail are implementation details, not ROB outputs.  The
    // default scoreboard is black-box; enabling this bit adds optional
    // white-box diagnostics without making correctness depend on hierarchy.
    localparam bit ENABLE_WHITEBOX_CHECKS = 1'b0;

    logic clk;
    logic rstn;
    logic [DISPATCH_W-1:0] alloc_valid;
    logic [DISPATCH_W-1:0] alloc_ready;
    logic [TAG_W-1:0] alloc_tag [0:1];
    issue_uop_t alloc_uop [0:1];
    completion_t complete [0:1];
    logic recover_valid;
    logic [TAG_W-1:0] recover_tag;
    commit_t commit [0:1];
    logic [TAG_W-1:0] query_tag [0:QUERY_W-1];
    logic query_done [0:QUERY_W-1];
    logic [31:0] query_value [0:QUERY_W-1];
    logic [QUERY_W-1:0] query_live_cov;
    logic [QUERY_W-1:0] query_completed_cov;
    logic [DEPTH-1:0] live_mask;
    logic [TAG_W:0] occupancy;

    typedef struct {
        bit valid;
        logic [TAG_W-1:0] tag;
        logic [31:0] pc;
        bit has_dest;
        bit reg_write;
        logic [4:0] arch_rd;
        logic [31:0] value;
        bit completed;
        longint unsigned seq_id;
    } ref_entry_t;

    ref_entry_t ref_entries [0:DEPTH-1];
    logic [TAG_W-1:0] ref_order [0:DEPTH-1];
    integer ref_count;
    longint unsigned next_sequence;
    logic [TAG_W-1:0] ref_head_tag;
    logic [TAG_W-1:0] ref_next_tag;

    logic exp_alloc_ready [0:DISPATCH_W-1];
    logic [TAG_W-1:0] exp_alloc_tag [0:DISPATCH_W-1];
    commit_t exp_commit [0:COMMIT_W-1];
    bit cycle_alloc_fire [0:DISPATCH_W-1];
    logic [TAG_W-1:0] cycle_alloc_tag [0:DISPATCH_W-1];
    bit recovery_live_before;
    bit recovery_committed_before;
    logic [TAG_W-1:0] recovery_tag_before;

    integer scoreboard_error_count;
    integer assertion_error_count;
    integer timeout_error_count;
    integer protocol_error_count;
    integer total_error_count;
    integer cycle_no;
    integer random_cycles;
    integer random_seed;
    integer min_coverage;
    integer stop_on_error_arg;
    integer rng;
    string test_name;
    string history [0:HISTORY_DEPTH-1];
    bit history_valid [0:HISTORY_DEPTH-1];
    integer history_ptr;
    bit plusarg_present;
    time last_cycle_time;
    bit test_finished;
    bit random_scheduler_active;
    bit directed_tests_finished;
    bit random_tests_finished;
    time test_start_time;
    real tool_coverage;
    real manual_coverage;
    integer manual_cov_hit_count;
    integer alloc_count_cov;
    integer completion_count_cov;
    integer commit_count_cov;
    bit coverage_ok;
    bit scope_complete;

    localparam integer COV_MANDATORY_POINTS = 32;
    localparam integer COV_OCC_EMPTY = 0;
    localparam integer COV_OCC_ONE = 1;
    localparam integer COV_OCC_MIDDLE = 2;
    localparam integer COV_OCC_NEAR_FULL = 3;
    localparam integer COV_OCC_FULL = 4;
    localparam integer COV_ALLOC_ZERO = 5;
    localparam integer COV_ALLOC_ONE = 6;
    localparam integer COV_ALLOC_TWO = 7;
    localparam integer COV_COMPLETE_ZERO = 8;
    localparam integer COV_COMPLETE_ONE = 9;
    localparam integer COV_COMPLETE_TWO = 10;
    localparam integer COV_COMMIT_ZERO = 11;
    localparam integer COV_COMMIT_ONE = 12;
    localparam integer COV_COMMIT_TWO = 13;
    localparam integer COV_QUERY_LIVE = 14;
    localparam integer COV_QUERY_DEAD = 15;
    localparam integer COV_QUERY_COMPLETED = 16;
    localparam integer COV_QUERY_UNCOMPLETED = 17;
    localparam integer COV_WRAP = 18;
    localparam integer COV_RECOVER_HEAD = 19;
    localparam integer COV_RECOVER_MIDDLE = 20;
    localparam integer COV_RECOVER_TAIL = 21;
    localparam integer COV_RECOVER_COMBO = 22;
    localparam integer COV_X0 = 23;
    localparam integer COV_WRAP_RECOVERY = 24;
    localparam integer COV_RECOVER_ALLOC = 25;
    localparam integer COV_RECOVER_COMPLETION = 26;
    localparam integer COV_RECOVER_COMMIT = 27;
    localparam integer COV_SQUASH_COMPLETION = 28;
    localparam integer COV_DUAL_SAME_TAG = 29;
    localparam integer COV_FULL_SAME_COMMIT = 30;
    localparam integer COV_EMPTY_SAME_ALLOC = 31;
    bit mandatory_cov_hit [0:COV_MANDATORY_POINTS-1];

    typedef struct {
        bit valid;
        logic [TAG_W-1:0] tag;
        logic [31:0] value;
        bit reg_write;
        integer due_cycle;
    } response_slot_t;
    response_slot_t response_slots [0:RESPONSE_SLOTS-1];

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

    logic [DISPATCH_W-1:0] completion_valid;
    assign completion_valid = {complete[1].valid, complete[0].valid};

    task automatic mark_cov(input integer point);
        begin
            if ((point >= 0) && (point < COV_MANDATORY_POINTS))
                mandatory_cov_hit[point] = 1'b1;
        end
    endtask

    function automatic integer mandatory_cov_count;
        integer i;
        begin
            mandatory_cov_count = 0;
            for (i = 0; i < COV_MANDATORY_POINTS; i = i + 1)
                mandatory_cov_count = mandatory_cov_count + mandatory_cov_hit[i];
        end
    endfunction

    task automatic dump_failure_context(
        input string kind,
        input string message
    );
        integer k;
        begin
            $display("[ROB-EXT-%s] test=%s seed=%0d cycle=%0d %s",
                     kind, test_name, random_seed, cycle_no, message);
            $display("[ROB-EXT-STATE] ref_head=%h ref_tail=%h ref_count=%0d dut_count=%0d dut_live=%h",
                     ref_head_tag, ref_next_tag, ref_count, occupancy, live_mask);
            if (ENABLE_WHITEBOX_CHECKS)
                $display("[ROB-EXT-WHITEBOX] dut_head=%h dut_tail=%h",
                         dut.head, dut.tail);
            $display("[ROB-EXT-INPUT] alloc=%b/%b tags=%h/%h c0=%b:%h/%h c1=%b:%h/%h recover=%b:%h",
                     alloc_valid[0], alloc_valid[1], alloc_tag[0], alloc_tag[1],
                     complete[0].valid, complete[0].rob_tag,
                     complete[0].value, complete[1].valid,
                     complete[1].rob_tag, complete[1].value,
                     recover_valid, recover_tag);
            $display("[ROB-EXT-DUT] ready=%b commit0=%b:%h/%h commit1=%b:%h/%h qdone=%b%b%b%b qvalue=%h/%h/%h/%h",
                     alloc_ready,
                     commit[0].valid, commit[0].rob_tag, commit[0].value,
                     commit[1].valid, commit[1].rob_tag, commit[1].value,
                     query_done[0], query_done[1], query_done[2], query_done[3],
                     query_value[0], query_value[1], query_value[2], query_value[3]);
            if (total_error_count <= 20) begin
                for (k = 0; k < ref_count; k = k + 1)
                    $display("[ROB-EXT-REF] order[%0d]=tag%h seq=%0d pc=%h done=%b has_dest=%b rd=%0d value=%h reg_write=%b",
                             k, ref_order[k], ref_entries[ref_order[k]].seq_id,
                             ref_entries[ref_order[k]].pc,
                             ref_entries[ref_order[k]].completed,
                             ref_entries[ref_order[k]].has_dest,
                             ref_entries[ref_order[k]].arch_rd,
                             ref_entries[ref_order[k]].value,
                             ref_entries[ref_order[k]].reg_write);
                for (k = 0; k < HISTORY_DEPTH; k = k + 1)
                    if (history_valid[k])
                        $display("[ROB-EXT-HISTORY] %s", history[k]);
            end
        end
    endtask

    task automatic assertion_fail(input string message);
        begin
            assertion_error_count = assertion_error_count + 1;
            total_error_count = total_error_count + 1;
            dump_failure_context("ASSERT-FAIL", message);
            if (stop_on_error_arg != 0)
                $fatal(2, "ROB-EXT assertion failure");
        end
    endtask

    task automatic timeout_fail(input string message);
        begin
            timeout_error_count = timeout_error_count + 1;
            total_error_count = total_error_count + 1;
            dump_failure_context("WATCHDOG", message);
            $fatal(2, "ROB-EXT timeout");
        end
    endtask

    task automatic protocol_fail(input string message);
        begin
            protocol_error_count = protocol_error_count + 1;
            total_error_count = total_error_count + 1;
            dump_failure_context("PROTOCOL-FAIL", message);
            if (stop_on_error_arg != 0)
                $fatal(2, "ROB-EXT protocol failure");
        end
    endtask

    // Interface and architectural invariants for the currently exposed ROB
    // contract.  Exception, physical-register and generation properties are
    // intentionally absent because those fields are not in the DUT ports.
    ap_lane1_contract: assert property (@(posedge clk) disable iff (!rstn)
        !LANE1_REQUIRES_LANE0 || !(alloc_valid[1] && !alloc_valid[0]))
        else assertion_fail("ROB-EXT-PROTOCOL lane1 valid without lane0");

    ap_alloc0_hold: assert property (@(posedge clk) disable iff (!rstn)
        (alloc_valid[0] && !alloc_ready[0] && !recover_valid) |=>
        (recover_valid ||
         (alloc_valid[0] &&
          $stable(alloc_uop[0].pc) &&
          $stable(alloc_uop[0].arch_rd) &&
          $stable(alloc_uop[0].reg_write) &&
          $stable(alloc_uop[0].is_ld_st) &&
          $stable(alloc_uop[0].is_br_jmp) &&
          $stable(alloc_uop[0].system_op) &&
          $stable(alloc_uop[0].serializing) &&
          $stable(alloc_uop[0]))))
        else assertion_fail("ROB-EXT-PROTOCOL alloc lane0 changed while stalled");

    ap_alloc1_hold: assert property (@(posedge clk) disable iff (!rstn)
        (alloc_valid[1] && !alloc_ready[1] && !recover_valid) |=>
        (recover_valid ||
         (alloc_valid[1] &&
          $stable(alloc_uop[1].pc) &&
          $stable(alloc_uop[1].arch_rd) &&
          $stable(alloc_uop[1].reg_write) &&
          $stable(alloc_uop[1].is_ld_st) &&
          $stable(alloc_uop[1].is_br_jmp) &&
          $stable(alloc_uop[1].system_op) &&
          $stable(alloc_uop[1].serializing) &&
          $stable(alloc_uop[1]))))
        else assertion_fail("ROB-EXT-PROTOCOL alloc lane1 changed while stalled");

    ap_occupancy_bound: assert property (@(posedge clk) disable iff (!rstn)
        occupancy <= DEPTH)
        else assertion_fail("ROB-EXT-INVARIANT occupancy exceeds DEPTH");

    ap_reset_state: assert property (@(posedge clk)
        !rstn |-> (occupancy == 0 && live_mask == '0 &&
                  !commit[0].valid && !commit[1].valid))
        else assertion_fail("ROB-EXT-INVARIANT reset did not clear ROB state");

    ap_live_count: assert property (@(posedge clk) disable iff (!rstn)
        occupancy == $countones(live_mask))
        else assertion_fail("ROB-EXT-INVARIANT occupancy/live_mask mismatch");

    ap_commit1_in_order: assert property (@(posedge clk) disable iff (!rstn)
        commit[1].valid |->
        (commit[0].valid &&
         (commit[1].rob_tag == (commit[0].rob_tag + 1'b1))))
        else assertion_fail("ROB-EXT-INVARIANT commit lane1 bypassed lane0/order");

    ap_commit_requires_entry: assert property (@(posedge clk) disable iff (!rstn)
        commit[0].valid |-> (occupancy != 0))
        else assertion_fail("ROB-EXT-INVARIANT commit without occupancy");

    genvar query_index;
    generate
        for (query_index = 0; query_index < QUERY_W; query_index = query_index + 1) begin : GEN_QUERY_ASSERT
            ap_query_done_live: assert property (@(posedge clk) disable iff (!rstn)
                query_done[query_index] |-> live_mask[query_tag[query_index]])
                else assertion_fail("ROB-EXT-INVARIANT query_done for dead tag");
        end
    endgenerate

    covergroup rob_functional_cg @(posedge clk);
        cp_occupancy: coverpoint occupancy {
            bins empty = {0};
            bins partial = {[1:DEPTH-1]};
            bins full = {DEPTH};
        }
        cp_alloc_valid: coverpoint alloc_valid;
        cp_alloc_ready: coverpoint alloc_ready;
        cp_completion_valid: coverpoint completion_valid;
        cp_alloc_count: coverpoint alloc_count_cov {
            bins zero = {0};
            bins one = {1};
            bins two = {2};
        }
        cp_completion_count: coverpoint completion_count_cov {
            bins zero = {0};
            bins one = {1};
            bins two = {2};
        }
        cp_commit_count: coverpoint commit_count_cov {
            bins zero = {0};
            bins one = {1};
            bins two = {2};
        }
        cp_query_live: coverpoint query_live_cov;
        cp_query_completed: coverpoint query_completed_cov;
        cp_recover: coverpoint recover_valid;
        cp_dual_dispatch: coverpoint (alloc_valid == {DISPATCH_W{1'b1}} &&
                                      alloc_ready == {DISPATCH_W{1'b1}});
        cp_dual_commit: coverpoint (commit[0].valid && commit[1].valid);
        cp_completion_lane0_only: coverpoint (complete[0].valid && !complete[1].valid);
        cp_completion_lane1_only: coverpoint (!complete[0].valid && complete[1].valid);
        cp_same_tag_completion: coverpoint
            (complete[0].valid && complete[1].valid &&
             (complete[0].rob_tag == complete[1].rob_tag));
        cross cp_occupancy, cp_recover;
        cross cp_dual_dispatch, cp_dual_commit;
        cross cp_recover, cp_completion_count, cp_commit_count;
    endgroup
    rob_functional_cg rob_cov = new();

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    initial begin
        last_cycle_time = 0;
        test_finished = 1'b0;
        forever begin
            #(WATCHDOG_GAP_NS / 10);
            if (!test_finished && (($time - last_cycle_time) > WATCHDOG_GAP_NS)) begin
                timeout_fail($sformatf("no completed test cycle for %0d ns at sim_time=%0t",
                                       WATCHDOG_GAP_NS, $time));
            end
            if (!test_finished && (($time - test_start_time) > PER_TEST_TIMEOUT_NS)) begin
                timeout_fail($sformatf("test %s exceeded per-test timeout %0d ns",
                                       test_name, PER_TEST_TIMEOUT_NS));
            end
        end
    end

    initial begin
        #(GLOBAL_TIMEOUT_NS);
        if (!test_finished)
            timeout_fail($sformatf("global simulation timeout at %0t", $time));
    end

    function automatic issue_uop_t make_uop(
        input logic [31:0] pc_value,
        input logic [4:0] rd_value,
        input bit writes_rd,
        input integer kind
    );
        issue_uop_t u;
        begin
            u = '0;
            u.pc = pc_value;
            u.reg_write = writes_rd;
            u.arch_rd = rd_value;
            u.is_ld_st = (kind == 1);
            u.is_br_jmp = (kind == 2);
            u.system_op = (kind == 3) ? SYS_CSRRD : SYS_NONE;
            u.serializing = (kind == 3);
            make_uop = u;
        end
    endfunction

    function automatic integer find_ref_tag(input logic [TAG_W-1:0] tag);
        integer i;
        begin
            find_ref_tag = -1;
            for (i = 0; i < DEPTH; i = i + 1)
                if ((i < ref_count) && (ref_order[i] == tag))
                    find_ref_tag = i;
        end
    endfunction

    function automatic [DEPTH-1:0] model_live_mask;
        integer i;
        begin
            model_live_mask = '0;
            for (i = 0; i < ref_count; i = i + 1)
                model_live_mask[ref_order[i]] = 1'b1;
        end
    endfunction

    task automatic ext_fail(input string message);
        begin
            scoreboard_error_count = scoreboard_error_count + 1;
            total_error_count = total_error_count + 1;
            dump_failure_context("FAIL", message);
            if (stop_on_error_arg != 0)
                $fatal(2, "ROB-EXT scoreboard failure");
        end
    endtask

    task automatic ext_expect(input bit condition, input string message);
        begin
            if (!condition)
                ext_fail(message);
        end
    endtask

    task automatic clear_inputs;
        integer i;
        bit hold0;
        bit hold1;
        begin
            // A stalled allocation is a live ready/valid transaction.  The
            // driver is not allowed to withdraw or rewrite it before fire.
            hold0 = rstn && alloc_valid[0] && !alloc_ready[0];
            hold1 = rstn && alloc_valid[1] && !alloc_ready[1];
            if (!hold0) begin
                alloc_valid[0] = 1'b0;
                alloc_uop[0] = '0;
            end
            if (!hold1) begin
                alloc_valid[1] = 1'b0;
                alloc_uop[1] = '0;
            end
            complete[0] = '0;
            complete[1] = '0;
            recover_valid = 1'b0;
            recover_tag = '0;
            for (i = 0; i < QUERY_W; i = i + 1) begin
                query_tag[i] = '0;
                query_live_cov[i] = 1'b0;
                query_completed_cov[i] = 1'b0;
            end
        end
    endtask

    task automatic clear_history;
        integer i;
        begin
            history_ptr = 0;
            for (i = 0; i < HISTORY_DEPTH; i = i + 1) begin
                history_valid[i] = 1'b0;
                history[i] = "";
            end
        end
    endtask

    task automatic clear_ref_entry(output ref_entry_t entry);
        begin
            entry.valid = 1'b0;
            entry.tag = '0;
            entry.pc = '0;
            entry.has_dest = 1'b0;
            entry.reg_write = 1'b0;
            entry.arch_rd = '0;
            entry.value = '0;
            entry.completed = 1'b0;
            entry.seq_id = 0;
        end
    endtask

    task automatic clear_response_scheduler;
        integer i;
        begin
            for (i = 0; i < RESPONSE_SLOTS; i = i + 1) begin
                response_slots[i].valid = 1'b0;
                response_slots[i].tag = '0;
                response_slots[i].value = '0;
                response_slots[i].reg_write = 1'b0;
                response_slots[i].due_cycle = 0;
            end
        end
    endtask

    task automatic schedule_response(
        input logic [TAG_W-1:0] tag,
        input logic [31:0] value,
        input bit reg_write
    );
        integer i;
        bit inserted;
        begin
            inserted = 1'b0;
            for (i = 0; i < RESPONSE_SLOTS; i = i + 1) begin
                if (!inserted && !response_slots[i].valid) begin
                    response_slots[i].valid = 1'b1;
                    response_slots[i].tag = tag;
                    response_slots[i].value = value;
                    response_slots[i].reg_write = reg_write;
                    response_slots[i].due_cycle = cycle_no + 1 + ($urandom(rng) % 20);
                    inserted = 1'b1;
                end
            end
            if (!inserted)
                ext_fail("completion scheduler overflow");
        end
    endtask

    task automatic cancel_responses_for_dead_entries;
        integer i;
        begin
            for (i = 0; i < RESPONSE_SLOTS; i = i + 1)
                if (response_slots[i].valid &&
                    (find_ref_tag(response_slots[i].tag) < 0))
                    response_slots[i].valid = 1'b0;
        end
    endtask

    task automatic drive_due_responses;
        integer i;
        integer lane;
        begin
            complete[0] = '0;
            complete[1] = '0;
            lane = 0;
            for (i = 0; i < RESPONSE_SLOTS; i = i + 1) begin
                if ((lane < DISPATCH_W) && response_slots[i].valid &&
                    (response_slots[i].due_cycle <= cycle_no)) begin
                    set_completion(lane, response_slots[i].tag,
                                   response_slots[i].value,
                                   response_slots[i].reg_write);
                    response_slots[i].valid = 1'b0;
                    lane = lane + 1;
                end
            end
        end
    endtask

    function automatic bit responses_pending;
        integer i;
        begin
            responses_pending = 1'b0;
            for (i = 0; i < RESPONSE_SLOTS; i = i + 1)
                responses_pending = responses_pending || response_slots[i].valid;
        end
    endfunction

    task automatic drain_random_scheduler;
        integer i;
        bit drained;
        begin
            drained = 1'b0;
            for (i = 0; i < (DEPTH * 64); i = i + 1) begin
                if (!drained) begin
                    @(negedge clk);
                    clear_inputs();
                    drive_due_responses();
                    step_cycle("random scheduler drain");
                    drained = (ref_count == 0) && !responses_pending();
                end
            end
            ext_expect(drained, "random scheduler drains to empty");
        end
    endtask

    task automatic reset_model;
        integer i;
        begin
            ref_count = 0;
            next_sequence = 0;
            ref_head_tag = '0;
            ref_next_tag = '0;
            clear_response_scheduler();
            for (i = 0; i < DEPTH; i = i + 1) begin
                clear_ref_entry(ref_entries[i]);
                ref_order[i] = '0;
            end
        end
    endtask

    task automatic reset_case(input string name);
        begin
            rstn = 1'b0;
            clear_inputs();
            repeat (RESET_CYCLES) @(posedge clk);
            reset_model();
            clear_history();
            cycle_no = 0;
            rstn = 1'b1;
            @(negedge clk);
            #1;
            ext_expect(occupancy == 0, {name, ": reset occupancy"});
            ext_expect(live_mask == '0, {name, ": reset live mask"});
            ext_expect(!commit[0].valid && !commit[1].valid,
                        {name, ": reset commit outputs"});
            test_start_time = $time;
        end
    endtask

    task automatic present_alloc(
        input bit lane0_valid,
        input bit lane1_valid,
        input issue_uop_t uop0,
        input issue_uop_t uop1
    );
        begin
            if (LANE1_REQUIRES_LANE0 && lane1_valid && !lane0_valid) begin
                protocol_fail("lane1 valid without lane0");
                lane1_valid = 1'b0;
            end

            if (!(alloc_valid[0] && !alloc_ready[0])) begin
                alloc_valid[0] = lane0_valid;
                alloc_uop[0] = lane0_valid ? uop0 : '0;
            end
            if (!(alloc_valid[1] && !alloc_ready[1])) begin
                alloc_valid[1] = lane1_valid;
                alloc_uop[1] = lane1_valid ? uop1 : '0;
            end
        end
    endtask

    task automatic set_alloc(
        input bit lane0_valid,
        input bit lane1_valid,
        input integer index,
        input integer kind0,
        input integer kind1
    );
        begin
            present_alloc(
                lane0_valid,
                lane1_valid,
                make_uop(32'h1000 + index * 8, 5'd1 + (index % 20),
                         kind0 != 1, kind0),
                make_uop(32'h1004 + index * 8, 5'd2 + (index % 20),
                         kind1 != 1, kind1));
        end
    endtask

    task automatic set_completion(
        input integer lane,
        input logic [TAG_W-1:0] tag,
        input logic [31:0] value,
        input bit reg_write
    );
        begin
            complete[lane] = '0;
            complete[lane].valid = 1'b1;
            complete[lane].rob_tag = tag;
            complete[lane].value = value;
            complete[lane].reg_write = reg_write;
        end
    endtask

    task automatic record_history(input string name);
        begin
            history[history_ptr] = $sformatf(
                "cyc=%0d %s alloc=%b c0=%b/%h c1=%b/%h recover=%b/%h occ=%0d",
                cycle_no, name, alloc_valid, complete[0].valid,
                complete[0].rob_tag, complete[1].valid,
                complete[1].rob_tag, recover_valid, recover_tag, occupancy);
            history_valid[history_ptr] = 1'b1;
            history_ptr = (history_ptr + 1) % HISTORY_DEPTH;
        end
    endtask

    task automatic get_completion(
        input logic [TAG_W-1:0] tag,
        output bit hit,
        output logic [31:0] value,
        output bit reg_write
    );
        integer lane;
        begin
            hit = 1'b0;
            value = '0;
            reg_write = 1'b0;
            if (find_ref_tag(tag) >= 0) begin
                for (lane = 0; lane < DISPATCH_W; lane = lane + 1) begin
                    if (!hit && complete[lane].valid &&
                        (complete[lane].rob_tag == tag)) begin
                        hit = 1'b1;
                        value = complete[lane].value;
                        reg_write = complete[lane].reg_write;
                    end
                end
            end
        end
    endtask

    task automatic compute_expected;
        ref_entry_t e0;
        ref_entry_t e1;
        bit hit0;
        bit hit1;
        bit rw0;
        bit rw1;
        logic [31:0] val0;
        logic [31:0] val1;
        integer recover_index;
        begin
            exp_alloc_ready[0] = !recover_valid && (ref_count < DEPTH);
            exp_alloc_ready[1] = !recover_valid &&
                                  (ref_count <= (DEPTH - 2));
            exp_alloc_tag[0] = ref_next_tag;
            exp_alloc_tag[1] = ref_next_tag + 1'b1;
            exp_commit[0] = '0;
            exp_commit[1] = '0;

            if (ref_count > 0) begin
                e0 = ref_entries[ref_order[0]];
                get_completion(e0.tag, hit0, val0, rw0);
                exp_commit[0].valid = e0.completed || hit0;
                exp_commit[0].rob_tag = e0.tag;
                exp_commit[0].pc = e0.pc;
                exp_commit[0].has_dest = e0.has_dest;
                exp_commit[0].arch_rd = e0.arch_rd;
                exp_commit[0].reg_write = hit0 ? rw0 : e0.reg_write;
                exp_commit[0].value = hit0 ? val0 : e0.value;
            end

            recover_index = find_ref_tag(recover_tag);
            if ((ref_count > 1) && exp_commit[0].valid &&
                (!recover_valid || (recover_index >= 1))) begin
                e1 = ref_entries[ref_order[1]];
                get_completion(e1.tag, hit1, val1, rw1);
                if (e1.completed || hit1) begin
                    exp_commit[1].valid = 1'b1;
                    exp_commit[1].rob_tag = e1.tag;
                    exp_commit[1].pc = e1.pc;
                    exp_commit[1].has_dest = e1.has_dest;
                    exp_commit[1].arch_rd = e1.arch_rd;
                    exp_commit[1].reg_write = hit1 ? rw1 : e1.reg_write;
                    exp_commit[1].value = hit1 ? val1 : e1.value;
                end
            end
        end
    endtask

    task automatic expected_query(
        input logic [TAG_W-1:0] tag,
        output bit done_value,
        output logic [31:0] result_value
    );
        bit hit;
        bit rw;
        logic [31:0] value;
        begin
            done_value = 1'b0;
            result_value = '0;
            if (find_ref_tag(tag) >= 0) begin
                get_completion(tag, hit, value, rw);
                if (hit) begin
                    done_value = rw;
                    result_value = value;
                end else if (ref_entries[tag].completed) begin
                    done_value = ref_entries[tag].reg_write;
                    result_value = ref_entries[tag].value;
                end else begin
                    result_value = ref_entries[tag].value;
                end
            end
        end
    endtask

    task automatic compare_commit(input integer lane);
        begin
            ext_expect(commit[lane].valid === exp_commit[lane].valid,
                       $sformatf("commit lane%0d valid", lane));
            if (exp_commit[lane].valid) begin
                ext_expect(commit[lane].rob_tag === exp_commit[lane].rob_tag,
                           $sformatf("commit lane%0d tag", lane));
                ext_expect(commit[lane].pc === exp_commit[lane].pc,
                           $sformatf("commit lane%0d pc", lane));
                ext_expect(commit[lane].has_dest === exp_commit[lane].has_dest,
                           $sformatf("commit lane%0d has_dest", lane));
                ext_expect(commit[lane].reg_write === exp_commit[lane].reg_write,
                           $sformatf("commit lane%0d reg_write", lane));
                ext_expect(commit[lane].arch_rd === exp_commit[lane].arch_rd,
                           $sformatf("commit lane%0d rd", lane));
                ext_expect(commit[lane].value === exp_commit[lane].value,
                           $sformatf("commit lane%0d value", lane));
            end
        end
    endtask

    task automatic check_pre(input string name);
        bit exp_done;
        bit query_hit;
        bit query_rw;
        logic [31:0] exp_value;
        logic [31:0] query_value_model;
        integer i;
        integer alloc_count;
        integer completion_count;
        integer commit_count;
        integer alloc_attempt_count;
        integer recovery_index;
        begin
            record_history(name);
            compute_expected();
            recovery_live_before = recover_valid &&
                                   (find_ref_tag(recover_tag) >= 0);
            recovery_committed_before = recovery_live_before &&
                ((exp_commit[0].valid &&
                  (exp_commit[0].rob_tag == recover_tag)) ||
                 (exp_commit[1].valid &&
                  (exp_commit[1].rob_tag == recover_tag)));
            recovery_tag_before = recover_tag;

            alloc_count = (alloc_valid[0] && alloc_ready[0]) +
                          (alloc_valid[1] && alloc_ready[1]);
            alloc_attempt_count = alloc_valid[0] + alloc_valid[1];
            completion_count = complete[0].valid + complete[1].valid;
            commit_count = commit[0].valid + commit[1].valid;
            alloc_count_cov = alloc_count;
            completion_count_cov = completion_count;
            commit_count_cov = commit_count;

            case (ref_count)
                0: mark_cov(COV_OCC_EMPTY);
                1: mark_cov(COV_OCC_ONE);
                DEPTH-1: mark_cov(COV_OCC_NEAR_FULL);
                DEPTH: mark_cov(COV_OCC_FULL);
                default: mark_cov(COV_OCC_MIDDLE);
            endcase
            case (alloc_count)
                0: mark_cov(COV_ALLOC_ZERO);
                1: mark_cov(COV_ALLOC_ONE);
                2: mark_cov(COV_ALLOC_TWO);
            endcase
            case (completion_count)
                0: mark_cov(COV_COMPLETE_ZERO);
                1: mark_cov(COV_COMPLETE_ONE);
                2: mark_cov(COV_COMPLETE_TWO);
            endcase
            case (commit_count)
                0: mark_cov(COV_COMMIT_ZERO);
                1: mark_cov(COV_COMMIT_ONE);
                2: mark_cov(COV_COMMIT_TWO);
            endcase
            if ((ref_next_tag == '0) && (cycle_no > 0))
                mark_cov(COV_WRAP);
            if ((ref_count == DEPTH) && (commit_count > 0))
                mark_cov(COV_FULL_SAME_COMMIT);
            if ((ref_count == 0) && (alloc_count > 0))
                mark_cov(COV_EMPTY_SAME_ALLOC);
            if (complete[0].valid && complete[1].valid &&
                (complete[0].rob_tag == complete[1].rob_tag))
                mark_cov(COV_DUAL_SAME_TAG);
            if ((alloc_valid[0] && alloc_ready[0] &&
                 alloc_uop[0].reg_write && (alloc_uop[0].arch_rd == 5'd0)) ||
                (alloc_valid[1] && alloc_ready[1] &&
                 alloc_uop[1].reg_write && (alloc_uop[1].arch_rd == 5'd0)))
                mark_cov(COV_X0);
            if (recover_valid) begin
                if (alloc_attempt_count > 0)
                    mark_cov(COV_RECOVER_ALLOC);
                if (completion_count > 0)
                    mark_cov(COV_RECOVER_COMPLETION);
                if (commit_count > 0)
                    mark_cov(COV_RECOVER_COMMIT);
                if ((alloc_attempt_count > 0) || (completion_count > 0) ||
                    (commit_count > 0))
                    mark_cov(COV_RECOVER_COMBO);
                if (recovery_live_before) begin
                    recovery_index = find_ref_tag(recover_tag);
                    if (recovery_index == 0)
                        mark_cov(COV_RECOVER_HEAD);
                    else if (recovery_index == (ref_count - 1))
                        mark_cov(COV_RECOVER_TAIL);
                    else
                        mark_cov(COV_RECOVER_MIDDLE);
                    if ((recover_tag == '0) || (ref_next_tag == '0))
                        mark_cov(COV_WRAP_RECOVERY);
                end
            end
            ext_expect(alloc_ready[0] === exp_alloc_ready[0],
                       {name, ": alloc_ready0"});
            ext_expect(alloc_ready[1] === exp_alloc_ready[1],
                       {name, ": alloc_ready1"});
            ext_expect(alloc_tag[0] === exp_alloc_tag[0],
                       {name, ": alloc_tag0"});
            ext_expect(alloc_tag[1] === exp_alloc_tag[1],
                       {name, ": alloc_tag1"});
            ext_expect(!LANE1_REQUIRES_LANE0 ||
                       !(alloc_valid[1] && !alloc_valid[0]),
                       {name, ": lane1 requires lane0"});
            ext_expect(occupancy === ref_count,
                       {name, ": pre occupancy"});
            if (ENABLE_WHITEBOX_CHECKS) begin
                ext_expect(dut.head === ref_head_tag,
                           {name, ": pre head"});
                ext_expect(dut.tail === ref_next_tag,
                           {name, ": pre tail"});
            end
            ext_expect(live_mask === model_live_mask(),
                       {name, ": pre live mask"});
            compare_commit(0);
            compare_commit(1);
            for (i = 0; i < QUERY_W; i = i + 1) begin
                query_live_cov[i] = 1'b0;
                query_completed_cov[i] = 1'b0;
                if (find_ref_tag(query_tag[i]) >= 0) begin
                    query_live_cov[i] = 1'b1;
                    get_completion(query_tag[i], query_hit,
                                   query_value_model, query_rw);
                    query_completed_cov[i] = query_hit ||
                                              ref_entries[query_tag[i]].completed;
                    mark_cov(COV_QUERY_LIVE);
                    if (query_completed_cov[i])
                        mark_cov(COV_QUERY_COMPLETED);
                    else
                        mark_cov(COV_QUERY_UNCOMPLETED);
                end else begin
                    mark_cov(COV_QUERY_DEAD);
                end
                expected_query(query_tag[i], exp_done, exp_value);
                ext_expect(query_done[i] === exp_done,
                           $sformatf("%s: query%0d done", name, i));
                // query_value is not specified for an invalid tag.  Compare
                // it only while the entry is live or when query_done is true.
                if ((find_ref_tag(query_tag[i]) >= 0) || exp_done)
                    ext_expect(query_value[i] === exp_value,
                               $sformatf("%s: query%0d value", name, i));
            end
        end
    endtask

    task automatic ref_apply;
        integer i;
        integer j;
        integer old_count;
        integer commit_count;
        integer recovery_index;
        integer new_count;
        logic [TAG_W-1:0] new_order [0:DEPTH-1];
        ref_entry_t new_entry;
        logic [TAG_W-1:0] tag_value;
        begin
            // Completion writes are applied before commit/recovery, matching
            // the current DUT's combinational completion-to-commit path.
            for (i = 0; i < DISPATCH_W; i = i + 1) begin
                if (complete[i].valid &&
                    (find_ref_tag(complete[i].rob_tag) >= 0)) begin
                    ref_entries[complete[i].rob_tag].completed = 1'b1;
                    ref_entries[complete[i].rob_tag].value = complete[i].value;
                    ref_entries[complete[i].rob_tag].reg_write = complete[i].reg_write;
                end
            end

            commit_count = exp_commit[0].valid + exp_commit[1].valid;
            old_count = ref_count;
            if (commit_count > 0)
                ref_head_tag = ref_head_tag + commit_count;

            // The RTL gives recover_valid priority over allocation and gates
            // alloc_ready in that cycle.  A same-cycle allocation packet is
            // therefore a flushed packet, not a fire.
            if (recover_valid && (ref_count > 0) &&
                (find_ref_tag(recover_tag) >= 0)) begin
                recovery_index = find_ref_tag(recover_tag);
                new_count = recovery_index + 1 - commit_count;
                if (new_count < 0)
                    new_count = 0;
                for (i = 0; i < new_count; i = i + 1)
                    new_order[i] = ref_order[commit_count + i];
                for (i = 0; i < old_count; i = i + 1)
                    ref_entries[ref_order[i]].valid = 1'b0;
                for (i = 0; i < new_count; i = i + 1) begin
                    ref_order[i] = new_order[i];
                    ref_entries[new_order[i]].valid = 1'b1;
                end
                for (i = new_count; i < DEPTH; i = i + 1)
                    ref_order[i] = '0;
                ref_count = new_count;
                ref_next_tag = recover_tag + 1'b1;
                if (random_scheduler_active)
                    cancel_responses_for_dead_entries();
            end else if (recover_valid) begin
                // A recovery on an empty/invalid ROB is a safe no-op.
                for (i = 0; i < commit_count; i = i + 1)
                    if (ref_count > 0) begin
                        ref_entries[ref_order[0]].valid = 1'b0;
                        for (j = 0; j < ref_count - 1; j = j + 1)
                            ref_order[j] = ref_order[j+1];
                        ref_count = ref_count - 1;
                    end
                if (random_scheduler_active)
                    cancel_responses_for_dead_entries();
            end else begin
                for (i = 0; i < commit_count; i = i + 1) begin
                    if ((ref_count == 0) ||
                        (exp_commit[i].rob_tag != ref_order[0])) begin
                        ext_fail("reference commit order invariant");
                    end else begin
                        ref_entries[ref_order[0]].valid = 1'b0;
                        for (j = 0; j < ref_count - 1; j = j + 1)
                            ref_order[j] = ref_order[j+1];
                        ref_count = ref_count - 1;
                    end
                end

                if (random_scheduler_active)
                    cancel_responses_for_dead_entries();

                if (cycle_alloc_fire[0]) begin
                    tag_value = ref_next_tag;
                    if (ref_entries[tag_value].valid)
                        ext_fail("reference allocation tag already live");
                    clear_ref_entry(new_entry);
                    new_entry.valid = 1'b1;
                    new_entry.tag = tag_value;
                    new_entry.pc = alloc_uop[0].pc;
                    new_entry.has_dest = alloc_uop[0].reg_write &&
                                          (alloc_uop[0].arch_rd != 5'd0);
                    new_entry.reg_write = new_entry.has_dest;
                    new_entry.arch_rd = alloc_uop[0].arch_rd;
                    new_entry.seq_id = next_sequence;
                    next_sequence = next_sequence + 1;
                    ref_entries[tag_value] = new_entry;
                    ref_order[ref_count] = tag_value;
                    ref_count = ref_count + 1;
                    ref_next_tag = ref_next_tag + 1'b1;
                end
                if (cycle_alloc_fire[1]) begin
                    tag_value = ref_next_tag;
                    clear_ref_entry(new_entry);
                    new_entry.valid = 1'b1;
                    new_entry.tag = tag_value;
                    new_entry.pc = alloc_uop[1].pc;
                    new_entry.has_dest = alloc_uop[1].reg_write &&
                                          (alloc_uop[1].arch_rd != 5'd0);
                    new_entry.reg_write = new_entry.has_dest;
                    new_entry.arch_rd = alloc_uop[1].arch_rd;
                    new_entry.seq_id = next_sequence;
                    next_sequence = next_sequence + 1;
                    ref_entries[tag_value] = new_entry;
                    ref_order[ref_count] = tag_value;
                    ref_count = ref_count + 1;
                    ref_next_tag = ref_next_tag + 1'b1;
                end
            end

            if (random_scheduler_active && !recover_valid) begin
                if (cycle_alloc_fire[0])
                    schedule_response(cycle_alloc_tag[0],
                                      alloc_uop[0].pc + 32'h0000_0100,
                                      alloc_uop[0].reg_write &&
                                      (alloc_uop[0].arch_rd != 5'd0));
                if (cycle_alloc_fire[1])
                    schedule_response(cycle_alloc_tag[1],
                                      alloc_uop[1].pc + 32'h0000_0100,
                                      alloc_uop[1].reg_write &&
                                      (alloc_uop[1].arch_rd != 5'd0));
            end
        end
    endtask

    task automatic check_post(input string name);
        integer i;
        integer live_count;
        bit exp_done;
        logic [31:0] exp_value;
        begin
            live_count = 0;
            for (i = 0; i < DEPTH; i = i + 1)
                live_count = live_count + live_mask[i];
            ext_expect(occupancy === ref_count,
                       {name, ": post occupancy"});
            if (ENABLE_WHITEBOX_CHECKS) begin
                ext_expect(dut.head === ref_head_tag,
                           {name, ": post head"});
                ext_expect(dut.tail === ref_next_tag,
                           {name, ": post tail"});
            end
            ext_expect(live_mask === model_live_mask(),
                       {name, ": post live mask"});
            if (recovery_live_before && !recovery_committed_before)
                ext_expect(live_mask[recovery_tag_before],
                           {name, ": recovery point preserved"});
            ext_expect(live_count == ref_count,
                       {name, ": live mask/count consistency"});
            ext_expect(ref_count <= DEPTH,
                       {name, ": reference count bound"});
            if (ref_count == 0)
                ext_expect(live_mask == '0, {name, ": empty live mask"});
            if (ref_count == DEPTH)
                ext_expect(live_mask == {DEPTH{1'b1}},
                            {name, ": full live mask"});
            // Query is combinational and remains observable after the state
            // transition.  Compare it again here so recovery/commit can be
            // checked against the post-transition live set, not only the
            // pre-edge set.
            for (i = 0; i < QUERY_W; i = i + 1) begin
                expected_query(query_tag[i], exp_done, exp_value);
                ext_expect(query_done[i] === exp_done,
                           $sformatf("%s: post query%0d done", name, i));
                if ((find_ref_tag(query_tag[i]) >= 0) || exp_done)
                    ext_expect(query_value[i] === exp_value,
                               $sformatf("%s: post query%0d value", name, i));
            end
        end
    endtask

    task automatic step_cycle(input string name);
        integer i;
        begin
            #1;
            check_pre(name);
            for (i = 0; i < DISPATCH_W; i = i + 1) begin
                cycle_alloc_fire[i] = alloc_valid[i] && alloc_ready[i] &&
                                      !(recover_valid &&
                                        RECOVERY_SQUASHES_ALLOCATION);
                cycle_alloc_tag[i] = alloc_tag[i];
            end
            @(posedge clk);
            #1;
            ref_apply();
            check_post(name);
            // A fired request is consumed by the source.  A stalled request
            // remains asserted and its payload remains untouched.  Recovery
            // has RTL priority and squashes any same-cycle allocation packet.
            for (i = 0; i < DISPATCH_W; i = i + 1) begin
                if (cycle_alloc_fire[i] ||
                    (recover_valid && RECOVERY_SQUASHES_ALLOCATION &&
                     alloc_valid[i])) begin
                    alloc_valid[i] = 1'b0;
                    alloc_uop[i] = '0;
                end
            end
            last_cycle_time = $time;
            cycle_no = cycle_no + 1;
        end
    endtask

    task automatic idle_step(input string name);
        begin
            clear_inputs();
            step_cycle(name);
        end
    endtask

    task automatic query_window(
        input integer start_index,
        input integer live_count,
        input string name
    );
        integer i;
        begin
            clear_inputs();
            for (i = 0; i < QUERY_W; i = i + 1) begin
                if (i < live_count)
                    query_tag[i] = ref_order[start_index + i];
                else
                    query_tag[i] = ref_next_tag;
            end
            step_cycle(name);
        end
    endtask

    task automatic query_all_live_entries_test;
        integer i;
        begin
            reset_case("query_all_live_entries");
            for (i = 0; i < (DEPTH / DISPATCH_W); i = i + 1) begin
                @(negedge clk); set_alloc(1'b1, 1'b1, 300+i, 0, 0);
                step_cycle("query fill live entries");
            end
            for (i = 0; i < DEPTH; i = i + QUERY_W)
                @(negedge clk) query_window(i, QUERY_W,
                                             "query every live entry");
        end
    endtask

    task automatic query_uncompleted_completed_test;
        logic [TAG_W-1:0] t0;
        logic [TAG_W-1:0] t1;
        logic [TAG_W-1:0] t2;
        logic [TAG_W-1:0] t3;
        begin
            reset_case("query_uncompleted_completed");
            @(negedge clk); set_alloc(1'b1, 1'b1, 340, 0, 0); step_cycle("query state setup");
            t0 = ref_order[0]; t1 = ref_order[1];
            t2 = ref_order[2]; t3 = ref_order[3];
            @(negedge clk); clear_inputs();
            query_tag[0] = t0; query_tag[1] = t1;
            query_tag[2] = t2; query_tag[3] = t3;
            set_completion(1, t3, 32'hC300, 1'b1);
            step_cycle("query completion lane1 only");
            @(negedge clk);
            query_window(0, QUERY_W, "query completed versus uncompleted");
        end
    endtask

    task automatic query_dead_and_released_test;
        logic [TAG_W-1:0] released_tag;
        begin
            reset_case("query_dead_and_released");
            released_tag = ref_next_tag;
            @(negedge clk); clear_inputs();
            query_tag[0] = ref_next_tag;
            query_tag[1] = '0;
            query_tag[2] = ref_next_tag;
            query_tag[3] = '0;
            step_cycle("query unallocated tags");
            ext_expect(!query_done[0] && !query_done[1] &&
                       !query_done[2] && !query_done[3],
                       "unallocated query tags are not done");

            @(negedge clk); set_alloc(1'b1, 1'b0, 360, 0, 0); step_cycle("query release setup");
            released_tag = ref_order[0];
            @(negedge clk); clear_inputs();
            set_completion(0, released_tag, 32'hC360, 1'b1);
            query_tag[0] = released_tag;
            step_cycle("query commit and release");
            @(negedge clk); clear_inputs();
            query_tag[0] = released_tag;
            query_tag[1] = ref_next_tag;
            step_cycle("query released tag");
            ext_expect(!query_done[0] && !query_done[1],
                       "released tags are not done");
        end
    endtask

    task automatic query_same_entry_four_ports_test;
        logic [TAG_W-1:0] target;
        begin
            reset_case("query_same_entry_four_ports");
            @(negedge clk); set_alloc(1'b1, 1'b0, 380, 0, 0); step_cycle("query same setup");
            target = ref_order[0];
            @(negedge clk); clear_inputs();
            query_tag[0] = target; query_tag[1] = target;
            query_tag[2] = target; query_tag[3] = target;
            step_cycle("four query ports same entry");
        end
    endtask

    task automatic query_wraparound_test;
        integer i;
        logic [TAG_W-1:0] released_tag;
        logic [TAG_W-1:0] live_tag;
        begin
            reset_case("query_wraparound");
            released_tag = '0;
            for (i = 0; i < DEPTH + 2; i = i + 1) begin
                @(negedge clk); set_alloc(1'b1, 1'b0, 400+i, 0, 0);
                if (ref_count > 0) begin
                    released_tag = ref_order[0];
                    set_completion(0, released_tag, 32'hC400+i, 1'b1);
                end
                step_cycle("query wrap rotate");
            end
            live_tag = ref_order[0];
            @(negedge clk); clear_inputs();
            query_tag[0] = released_tag;
            query_tag[1] = live_tag;
            query_tag[2] = ref_next_tag;
            query_tag[3] = live_tag;
            step_cycle("query tags across wraparound");
        end
    endtask

    task automatic query_recovery_before_after_test;
        logic [TAG_W-1:0] recovery_point;
        logic [TAG_W-1:0] killed_tag;
        logic [TAG_W-1:0] older_tag;
        begin
            reset_case("query_recovery_before_after");
            @(negedge clk); set_alloc(1'b1, 1'b1, 430, 0, 0); step_cycle("query recovery setup0");
            @(negedge clk); set_alloc(1'b1, 1'b1, 431, 0, 0); step_cycle("query recovery setup1");
            older_tag = ref_order[0];
            recovery_point = ref_order[1];
            killed_tag = ref_order[3];
            @(negedge clk); clear_inputs();
            query_tag[0] = older_tag;
            query_tag[1] = recovery_point;
            query_tag[2] = killed_tag;
            query_tag[3] = ref_next_tag;
            recover_valid = 1'b1;
            recover_tag = recovery_point;
            step_cycle("query recovery same cycle");
            @(negedge clk); clear_inputs();
            query_tag[0] = older_tag;
            query_tag[1] = recovery_point;
            query_tag[2] = killed_tag;
            query_tag[3] = ref_next_tag;
            step_cycle("query recovery after kill");
            ext_expect(!query_done[2], "query killed entry is not done");
        end
    endtask

    task automatic single_dispatch_single_commit_test;
        begin
            reset_case("single_dispatch_single_commit");
            @(negedge clk); set_alloc(1'b1, 1'b0, 1, 0, 0); step_cycle("single dispatch");
            @(negedge clk); clear_inputs(); set_completion(0, ref_order[0], 32'h1111, 1'b1);
            query_tag[0] = ref_order[0]; step_cycle("single commit");
            @(negedge clk); idle_step("single post reset");
        end
    endtask

    task automatic dual_dispatch_test;
        begin
            reset_case("dual_dispatch");
            @(negedge clk); set_alloc(1'b1, 1'b1, 2, 0, 0); step_cycle("dual dispatch");
            @(negedge clk); set_completion(0, ref_order[0], 32'h2200, 1'b1);
            set_completion(1, ref_order[1], 32'h2201, 1'b1); step_cycle("dual completion commit");
        end
    endtask

    task automatic single_lane_valid_test;
        begin
            reset_case("single_lane_valid");
            @(negedge clk); set_alloc(1'b1, 1'b0, 3, 0, 0); step_cycle("lane0 only");
            @(negedge clk); clear_inputs(); set_completion(0, ref_order[0], 32'h3300, 1'b1); step_cycle("lane0 only commit");
        end
    endtask

    task automatic partial_dispatch_accept_test;
        integer i;
        begin
            reset_case("partial_dispatch_accept");
            // Fill to DEPTH-2 with complete packets, then exercise the
            // lane0-only acceptance at both the near-full and full boundary.
            for (i = 0; i < ((DEPTH / DISPATCH_W) - 1); i = i + 1) begin
                @(negedge clk); set_alloc(1'b1, 1'b1, 4+i, 0, 0);
                step_cycle("partial setup dual");
            end
            @(negedge clk); set_alloc(1'b1, 1'b0, 20, 0, 0);
            step_cycle("lane0 partial dispatch");
            ext_expect(ref_count == (DEPTH - 1),
                       "lane0-only partial dispatch accepted");
            @(negedge clk); set_alloc(1'b1, 1'b0, 21, 0, 0);
            step_cycle("lane0 accepts while lane1 not ready");
            ext_expect(ref_count == DEPTH,
                       "lane0 can fire independently at full boundary");
        end
    endtask

    task automatic fill_to_full_test;
        integer i;
        begin
            reset_case("fill_to_full");
            for (i = 0; i < (DEPTH / DISPATCH_W); i = i + 1) begin
                @(negedge clk); set_alloc(1'b1, 1'b1, 10+i, i%4, (i+1)%4); step_cycle("fill dual dispatch");
            end
            ext_expect(ref_count == DEPTH, "fill reaches full occupancy");
            @(negedge clk); idle_step("full backpressure");
            ext_expect(!alloc_ready[0] && !alloc_ready[1], "full backpressure ready");
        end
    endtask

    task automatic drain_to_empty_test;
        integer i;
        logic [TAG_W-1:0] t0;
        logic [TAG_W-1:0] t1;
        begin
            reset_case("drain_to_empty");
            for (i = 0; i < (DEPTH / DISPATCH_W); i = i + 1) begin
                @(negedge clk); set_alloc(1'b1, 1'b1, 20+i, 0, 0); step_cycle("drain fill");
            end
            for (i = 0; i < (DEPTH / DISPATCH_W); i = i + 1) begin
                t0 = ref_order[0]; t1 = ref_order[1];
                @(negedge clk); clear_inputs();
                set_completion(0, t0, 32'h4000+i, 1'b1);
                set_completion(1, t1, 32'h4100+i, 1'b1);
                step_cycle("drain dual commit");
            end
            ext_expect(ref_count == 0, "drain reaches empty occupancy");
        end
    endtask

    task automatic simultaneous_dispatch_commit_test;
        logic [TAG_W-1:0] head_tag;
        begin
            reset_case("simultaneous_dispatch_commit");
            @(negedge clk); set_alloc(1'b1, 1'b0, 40, 0, 0); step_cycle("setup dispatch");
            head_tag = ref_order[0];
            @(negedge clk); set_alloc(1'b1, 1'b0, 41, 0, 0);
            set_completion(0, head_tag, 32'h4200, 1'b1);
            step_cycle("dispatch completion commit same cycle");
            ext_expect(ref_count == 1, "same-cycle dispatch and commit count");
        end
    endtask

    task automatic simultaneous_dual_dispatch_dual_commit_test;
        logic [TAG_W-1:0] t0;
        logic [TAG_W-1:0] t1;
        begin
            reset_case("simultaneous_dual_dispatch_dual_commit");
            @(negedge clk); set_alloc(1'b1, 1'b1, 50, 0, 0); step_cycle("setup dual");
            t0 = ref_order[0]; t1 = ref_order[1];
            @(negedge clk); set_alloc(1'b1, 1'b1, 51, 0, 0);
            set_completion(0, t0, 32'h5100, 1'b1);
            set_completion(1, t1, 32'h5101, 1'b1);
            step_cycle("dual dispatch dual commit");
        end
    endtask

    task automatic completion_order_tests;
        logic [TAG_W-1:0] t0;
        logic [TAG_W-1:0] t1;
        begin
            reset_case("completion_order");
            @(negedge clk); set_alloc(1'b1, 1'b1, 60, 0, 0); step_cycle("completion order setup");
            t0 = ref_order[0]; t1 = ref_order[1];
            @(negedge clk); clear_inputs(); set_completion(0, t1, 32'h6201, 1'b1); step_cycle("tail completes first");
            ext_expect(!commit[0].valid, "tail completion cannot bypass head");
            @(negedge clk); clear_inputs(); set_completion(0, t0, 32'h6200, 1'b1); step_cycle("head completes later");
            ext_expect(ref_count == 0, "ordered dual commit after both complete");
        end
    endtask

    task automatic completion_edge_tests;
        logic [TAG_W-1:0] t0;
        logic [TAG_W-1:0] t1;
        begin
            reset_case("completion_edge");
            @(negedge clk); set_alloc(1'b1, 1'b1, 70, 0, 0); step_cycle("completion edge setup");
            t0 = ref_order[0]; t1 = ref_order[1];
            @(negedge clk); clear_inputs(); set_completion(0, t1, 32'h7101, 1'b1); step_cycle("tail only");
            ext_expect(!commit[0].valid, "tail only no head commit");
            @(negedge clk); clear_inputs();
            set_completion(0, t0, 32'h7100, 1'b1);
            step_cycle("head completion same cycle commit");
        end
    endtask

    task automatic completion_extended_tests;
        integer i;
        logic [TAG_W-1:0] t0;
        logic [TAG_W-1:0] t1;
        logic [TAG_W-1:0] t2;
        logic [TAG_W-1:0] t3;
        logic [TAG_W-1:0] killed_tag;
        logic [TAG_W-1:0] old_tag;
        logic [TAG_W-1:0] head_tag;
        begin
            // complete[1] is independently tested as the head completion.
            reset_case("completion_lane1_head");
            @(negedge clk); set_alloc(1'b1, 1'b0, 90, 0, 0); step_cycle("lane1 head setup");
            t0 = ref_order[0];
            @(negedge clk); clear_inputs(); set_completion(1, t0, 32'h9100, 1'b1);
            step_cycle("lane1 completes head");

            // Lane 1 may complete a non-head entry without allowing it to
            // bypass the older head.
            reset_case("completion_lane1_nonhead");
            @(negedge clk); set_alloc(1'b1, 1'b1, 91, 0, 0); step_cycle("lane1 nonhead setup");
            t0 = ref_order[0]; t1 = ref_order[1];
            @(negedge clk); clear_inputs(); set_completion(1, t1, 32'h9201, 1'b1);
            query_tag[0] = t1;
            step_cycle("lane1 completes nonhead");
            ext_expect(!commit[0].valid, "nonhead lane1 completion cannot commit head");

            // Two adjacent entries, lane order reversed, and two nonadjacent
            // entries are all legal completion patterns.
            reset_case("completion_adjacent_and_nonadjacent");
            @(negedge clk); set_alloc(1'b1, 1'b1, 92, 0, 0); step_cycle("completion four setup0");
            @(negedge clk); set_alloc(1'b1, 1'b1, 93, 0, 0); step_cycle("completion four setup1");
            t0 = ref_order[0]; t1 = ref_order[1];
            t2 = ref_order[2]; t3 = ref_order[3];
            @(negedge clk); clear_inputs();
            set_completion(0, t1, 32'h9301, 1'b1);
            set_completion(1, t0, 32'h9300, 1'b1);
            step_cycle("two ports reverse adjacent completion");
            @(negedge clk); clear_inputs();
            set_completion(0, t2, 32'h9302, 1'b1);
            set_completion(1, t3, 32'h9303, 1'b1);
            step_cycle("two ports adjacent completion");

            reset_case("completion_nonadjacent");
            @(negedge clk); set_alloc(1'b1, 1'b1, 94, 0, 0); step_cycle("nonadjacent setup0");
            @(negedge clk); set_alloc(1'b1, 1'b1, 95, 0, 0); step_cycle("nonadjacent setup1");
            t0 = ref_order[0]; t1 = ref_order[1];
            t2 = ref_order[2]; t3 = ref_order[3];
            @(negedge clk); clear_inputs();
            set_completion(0, t0, 32'h9400, 1'b1);
            set_completion(1, t3, 32'h9403, 1'b1);
            #1;
            ext_expect(commit[0].valid && !commit[1].valid,
                       "nonadjacent completion commits only head");
            step_cycle("two ports nonadjacent completion");

            // Same-tag dual completion follows the DUT's actual priority:
            // combinational query/commit uses lane 0, while the sequential
            // completion writes are applied lane 0 then lane 1.
            reset_case("completion_same_tag");
            @(negedge clk); set_alloc(1'b1, 1'b1, 96, 0, 0); step_cycle("same tag setup");
            t1 = ref_order[1];
            @(negedge clk); clear_inputs();
            set_completion(0, t1, 32'h9500, 1'b1);
            set_completion(1, t1, 32'h95ff, 1'b1);
            query_tag[0] = t1;
            step_cycle("same tag dual completion");
            @(negedge clk); clear_inputs();
            query_tag[0] = t1;
            step_cycle("same tag stored lane1 priority");
            ext_expect(query_value[0] == 32'h95ff,
                       "same tag sequential completion priority");

            // A completion for an entry removed by recovery is ignored; the
            // query also proves that the killed tag is not resurrected.
            reset_case("completion_recovery_cancel");
            @(negedge clk); set_alloc(1'b1, 1'b1, 97, 0, 0); step_cycle("cancel setup0");
            @(negedge clk); set_alloc(1'b1, 1'b0, 98, 0, 0); step_cycle("cancel setup1");
            killed_tag = ref_order[2];
            @(negedge clk); clear_inputs();
            recover_valid = 1'b1; recover_tag = ref_order[1];
            step_cycle("cancel recovery");
            @(negedge clk); clear_inputs();
            mark_cov(COV_SQUASH_COMPLETION);
            set_completion(1, killed_tag, 32'h96bad, 1'b1);
            query_tag[0] = killed_tag;
            step_cycle("completion for recovered entry");
            ext_expect(!query_done[0], "recovered entry completion ignored");

            // Completion and allocation on a just-reused tag are sampled
            // against the pre-edge valid set; the new entry can complete on
            // the following cycle, never through same-edge allocation.
            reset_case("completion_reallocation_adjacent");
            @(negedge clk); set_alloc(1'b1, 1'b0, 99, 0, 0); step_cycle("reallocation first");
            old_tag = ref_order[0];
            for (i = 0; i < DEPTH - 1; i = i + 1) begin
                @(negedge clk); set_alloc(1'b1, 1'b0, 100+i, 0, 0);
                head_tag = ref_order[0];
                set_completion(0, head_tag, 32'h9700+i, 1'b1);
                step_cycle("reallocation rotate");
            end
            ext_expect(ref_count == 1 && ref_next_tag == old_tag,
                       "reallocation returns to old tag");
            @(negedge clk); set_alloc(1'b1, 1'b0, 120, 0, 0);
            head_tag = ref_order[0];
            set_completion(0, head_tag, 32'h97aa, 1'b1);
            set_completion(1, old_tag, 32'h97ab, 1'b1);
            step_cycle("completion adjacent to reallocation");
            ext_expect(ref_count == 1 && ref_order[0] == old_tag,
                       "same-edge completion does not hit new allocation");
            @(negedge clk); clear_inputs();
            set_completion(0, old_tag, 32'h97bb, 1'b1);
            step_cycle("new allocation completes next cycle");
        end
    endtask

    task automatic repeated_completion_test;
        begin
            reset_case("repeated_completion");
            @(negedge clk); set_alloc(1'b1, 1'b0, 80, 0, 0); step_cycle("repeat setup");
            @(negedge clk); clear_inputs(); set_completion(0, ref_order[0], 32'h8000, 1'b1); step_cycle("first completion");
            @(negedge clk); clear_inputs(); set_completion(0, '0, 32'h8bad, 1'b1); step_cycle("completion after entry freed");
            ext_expect(ref_count == 0, "old completion cannot resurrect entry");
        end
    endtask

    task automatic invalid_completion_tag_test;
        begin
            reset_case("invalid_completion_tag");
            @(negedge clk); clear_inputs(); set_completion(0, '0, 32'h9000, 1'b1); step_cycle("invalid completion empty");
            ext_expect(ref_count == 0, "invalid completion leaves empty ROB");
        end
    endtask

    task automatic wraparound_test(input integer wraps);
        integer i;
        bit saw_wrap;
        logic [TAG_W-1:0] head_tag;
        begin
            reset_case("wraparound");
            saw_wrap = 1'b0;
            for (i = 0; i < wraps * DEPTH + 1; i = i + 1) begin
                @(negedge clk);
                set_alloc(1'b1, 1'b0, 100+i, 0, 0);
                if (ref_count > 0) begin
                    head_tag = ref_order[0];
                    set_completion(0, head_tag, 32'hA000+i, 1'b1);
                end
                if (alloc_tag[0] == '0 && i > 0)
                    saw_wrap = 1'b1;
                step_cycle("wrap alloc/complete");
            end
            ext_expect(saw_wrap, "ROB tag wraparound observed");
        end
    endtask

    task automatic full_with_same_cycle_commit_test;
        logic [TAG_W-1:0] head_tag;
        begin
            fill_to_full_test();
            head_tag = ref_order[0];
            @(negedge clk); set_alloc(1'b1, 1'b1, 130, 0, 0);
            set_completion(0, head_tag, 32'hD000, 1'b1);
            step_cycle("full same-cycle commit and dispatch");
            ext_expect(ref_count == DEPTH - 1,
                       "full ROB commits but does not bypass ready boundary");
        end
    endtask

    task automatic x0_and_no_destination_tests;
        logic [TAG_W-1:0] t0;
        logic [TAG_W-1:0] t1;
        begin
            // reg_write=1, rd=0 and reg_write=0, rd!=0 must both have no
            // architectural destination in the ROB.
            reset_case("x0_and_no_destination");
            @(negedge clk);
            present_alloc(1'b1, 1'b1,
                          make_uop(32'hB000, 5'd0, 1'b1, 0),
                          make_uop(32'hB004, 5'd7, 1'b0, 1));
            step_cycle("x0/no-destination allocation");
            t0 = ref_order[0]; t1 = ref_order[1];
            ext_expect(!ref_entries[t0].has_dest &&
                       !ref_entries[t1].has_dest,
                       "x0 and no-destination has_dest are clear");
            @(negedge clk); clear_inputs();
            set_completion(0, t0, 32'hB000, 1'b0);
            set_completion(1, t1, 32'hB004, 1'b0);
            #1;
            ext_expect(commit[0].valid && commit[1].valid &&
                       !commit[0].reg_write && !commit[1].reg_write,
                       "x0/no-destination commit has no writeback");
            step_cycle("x0/no-destination dual commit");

            // A dual commit containing x0 and a normal destination must only
            // expose writeback for the real destination.
            reset_case("x0_and_normal_dual_commit");
            @(negedge clk);
            present_alloc(1'b1, 1'b1,
                          make_uop(32'hB100, 5'd0, 1'b1, 0),
                          make_uop(32'hB104, 5'd8, 1'b1, 0));
            step_cycle("x0/normal allocation");
            t0 = ref_order[0]; t1 = ref_order[1];
            @(negedge clk); clear_inputs();
            set_completion(0, t0, 32'hB100, 1'b0);
            set_completion(1, t1, 32'hB108, 1'b1);
            #1;
            ext_expect(commit[0].valid && commit[1].valid &&
                       !commit[0].has_dest && !commit[0].reg_write &&
                       commit[1].has_dest && commit[1].reg_write &&
                       (commit[1].arch_rd == 5'd8),
                       "x0/normal dual commit writeback split");
            step_cycle("x0/normal dual commit");

            // Branch/store/CSR-like uops have no destination in this ROB
            // boundary.  Their type bits are accepted as input but are not
            // stored as unsupported ROB state.
            reset_case("special_uop_no_destination");
            @(negedge clk);
            present_alloc(1'b1, 1'b1,
                          make_uop(32'hB200, 5'd0, 1'b0, 2),
                          make_uop(32'hB204, 5'd0, 1'b0, 3));
            step_cycle("branch/CSR allocation");
            t0 = ref_order[0]; t1 = ref_order[1];
            @(negedge clk); clear_inputs();
            set_completion(0, t0, 32'hB200, 1'b0);
            set_completion(1, t1, 32'hB204, 1'b0);
            step_cycle("branch/CSR commit");

            // Keep x0 around a recovery point and verify it is preserved.
            reset_case("x0_recovery");
            @(negedge clk);
            present_alloc(1'b1, 1'b1,
                          make_uop(32'hB300, 5'd0, 1'b1, 0),
                          make_uop(32'hB304, 5'd9, 1'b1, 0));
            step_cycle("x0 recovery setup");
            @(negedge clk); clear_inputs();
            query_tag[0] = ref_order[0];
            recover_valid = 1'b1;
            recover_tag = ref_order[0];
            step_cycle("x0 recovery point");
            ext_expect(live_mask[query_tag[0]],
                       "x0 recovery point remains live");
        end
    endtask

    task automatic recovery_middle_tests;
        logic [TAG_W-1:0] recovery_point;
        logic [TAG_W-1:0] younger_tag;
        begin
            reset_case("recovery_middle");
            @(negedge clk); set_alloc(1'b1, 1'b1, 140, 0, 0); step_cycle("recovery setup0");
            @(negedge clk); set_alloc(1'b1, 1'b1, 141, 0, 0); step_cycle("recovery setup1");
            recovery_point = ref_order[2];
            younger_tag = ref_order[3];
            query_tag[0] = ref_order[0]; query_tag[1] = ref_order[1];
            query_tag[2] = ref_order[2]; query_tag[3] = ref_order[3];
            @(negedge clk); clear_inputs(); recover_valid = 1'b1; recover_tag = recovery_point;
            step_cycle("branch recovery middle");
            ext_expect(ref_count == 3, "recovery keeps older entries and recovery point");
            ext_expect(live_mask[recovery_point], "recovery point remains live");
            ext_expect(!live_mask[younger_tag], "younger entry killed by recovery");
        end
    endtask

    task automatic recovery_same_cycle_tests;
        logic [TAG_W-1:0] recovery_point;
        logic [TAG_W-1:0] head_tag;
        begin
            reset_case("recovery_same_cycle");
            @(negedge clk); set_alloc(1'b1, 1'b1, 150, 0, 0); step_cycle("recovery same setup0");
            @(negedge clk); set_alloc(1'b1, 1'b1, 151, 0, 0); step_cycle("recovery same setup1");
            recovery_point = ref_order[2];
            head_tag = ref_order[0];
            @(negedge clk); set_alloc(1'b1, 1'b1, 152, 0, 0);
            set_completion(0, head_tag, 32'hE000, 1'b1);
            recover_valid = 1'b1;
            recover_tag = recovery_point;
            step_cycle("completion commit recovery dispatch same cycle");
            ext_expect(ref_count == 2, "same-cycle recovery priority");
        end
    endtask

    task automatic recovery_boundary_tests;
        integer i;
        logic [TAG_W-1:0] target;
        logic [TAG_W-1:0] target2;
        logic [TAG_W-1:0] killed;
        begin
            reset_case("recovery_at_head");
            @(negedge clk); set_alloc(1'b1, 1'b1, 155, 0, 0); step_cycle("recovery head setup");
            target = ref_order[0];
            @(negedge clk); clear_inputs(); recover_valid = 1'b1; recover_tag = target;
            step_cycle("recover tag head");
            ext_expect(ref_count == 1 && live_mask[target],
                       "recovery head preserves recovery point");

            reset_case("recovery_at_head1");
            @(negedge clk); set_alloc(1'b1, 1'b1, 156, 0, 0); step_cycle("recovery head1 setup0");
            @(negedge clk); set_alloc(1'b1, 1'b1, 157, 0, 0); step_cycle("recovery head1 setup1");
            target = ref_order[1];
            @(negedge clk); clear_inputs(); recover_valid = 1'b1; recover_tag = target;
            step_cycle("recover tag head1");
            ext_expect(ref_count == 2 && live_mask[target],
                       "recovery head1 preserves older entries");

            reset_case("recovery_at_tail");
            @(negedge clk); set_alloc(1'b1, 1'b1, 158, 0, 0); step_cycle("recovery tail setup0");
            @(negedge clk); set_alloc(1'b1, 1'b1, 159, 0, 0); step_cycle("recovery tail setup1");
            target = ref_order[3];
            @(negedge clk); clear_inputs(); recover_valid = 1'b1; recover_tag = target;
            step_cycle("recover tag tail previous");
            ext_expect(ref_count == 4 && live_mask[target],
                       "recovery tail previous keeps all entries");

            reset_case("recovery_invalid_tag");
            @(negedge clk); clear_inputs(); recover_valid = 1'b1; recover_tag = '0;
            step_cycle("invalid recovery on empty");
            ext_expect(ref_count == 0 && live_mask == '0,
                       "invalid recovery is safe no-op");
            @(negedge clk); clear_inputs();
            set_alloc(1'b1, 1'b1, 160, 0, 0); step_cycle("invalid recovery setup");
            @(negedge clk); clear_inputs(); recover_valid = 1'b1;
            recover_tag = ref_next_tag + 2'b10;
            step_cycle("invalid recovery on nonempty");
            ext_expect(ref_count == 2,
                       "invalid recovery does not kill live entries");

            // Create a live window crossing tag 15 -> tag 0, then recover in
            // that wrapped window.
            reset_case("recovery_wraparound");
            @(negedge clk); set_alloc(1'b1, 1'b0, 161, 0, 0); step_cycle("recovery wrap initial");
            for (i = 0; i < DEPTH - 1; i = i + 1) begin
                @(negedge clk); set_alloc(1'b1, 1'b0, 162+i, 0, 0);
                set_completion(0, ref_order[0], 32'hA600+i, 1'b1);
                step_cycle("recovery wrap rotate");
            end
            @(negedge clk); set_alloc(1'b1, 1'b1, 180, 0, 0); step_cycle("recovery wrap window");
            target = ref_order[1];
            @(negedge clk); clear_inputs(); recover_valid = 1'b1; recover_tag = target;
            step_cycle("recovery across wrap");
            ext_expect(ref_count == 2 && live_mask[target],
                       "wrapped recovery keeps target and older entry");

            reset_case("recovery_incomplete_point");
            @(negedge clk); set_alloc(1'b1, 1'b1, 181, 0, 0); step_cycle("incomplete point setup");
            target = ref_order[1];
            @(negedge clk); clear_inputs();
            query_tag[0] = target; recover_valid = 1'b1; recover_tag = target;
            step_cycle("incomplete recovery point");
            ext_expect(live_mask[target] && !query_done[0],
                       "incomplete recovery point remains incomplete");

            reset_case("recovery_completed_point");
            @(negedge clk); set_alloc(1'b1, 1'b1, 182, 0, 0); step_cycle("completed point setup");
            target = ref_order[1];
            @(negedge clk); clear_inputs(); set_completion(1, target, 32'hA700, 1'b1);
            query_tag[0] = target; step_cycle("complete point before recovery");
            @(negedge clk); clear_inputs(); recover_valid = 1'b1; recover_tag = target;
            query_tag[0] = target; step_cycle("completed recovery point");
            ext_expect(live_mask[target] && query_done[0],
                       "completed recovery point remains completed");

            reset_case("recovery_point_same_completion");
            @(negedge clk); set_alloc(1'b1, 1'b1, 183, 0, 0); step_cycle("same completion setup");
            target = ref_order[1];
            @(negedge clk); clear_inputs();
            recover_valid = 1'b1; recover_tag = target;
            set_completion(1, target, 32'hA800, 1'b1);
            query_tag[0] = target; step_cycle("recovery point same completion");
            ext_expect(live_mask[target] && query_done[0],
                       "same-cycle recovery completion is retained");

            reset_case("recovery_point_same_commit");
            @(negedge clk); set_alloc(1'b1, 1'b1, 184, 0, 0); step_cycle("same commit setup");
            target = ref_order[0];
            @(negedge clk); clear_inputs();
            recover_valid = 1'b1; recover_tag = target;
            set_completion(0, target, 32'hA900, 1'b1);
            step_cycle("recovery point same commit");
            ext_expect(ref_count == 0 && !live_mask[target],
                       "committed recovery point is released");

            reset_case("recovery_dual_completion");
            @(negedge clk); set_alloc(1'b1, 1'b1, 185, 0, 0); step_cycle("dual recovery setup0");
            @(negedge clk); set_alloc(1'b1, 1'b1, 186, 0, 0); step_cycle("dual recovery setup1");
            target = ref_order[2];
            @(negedge clk); clear_inputs();
            recover_valid = 1'b1; recover_tag = target;
            set_completion(0, ref_order[0], 32'hAA00, 1'b1);
            set_completion(1, ref_order[1], 32'hAA01, 1'b1);
            step_cycle("recovery with dual completion");
            ext_expect(ref_count == 1 && live_mask[target],
                       "dual completion recovery keeps target");

            reset_case("recovery_immediate_reallocation");
            @(negedge clk); set_alloc(1'b1, 1'b1, 187, 0, 0); step_cycle("reallocation setup0");
            @(negedge clk); set_alloc(1'b1, 1'b1, 188, 0, 0); step_cycle("reallocation setup1");
            target = ref_order[1];
            killed = ref_order[3];
            @(negedge clk); clear_inputs(); recover_valid = 1'b1; recover_tag = target;
            step_cycle("reallocation recovery");
            @(negedge clk); clear_inputs(); set_alloc(1'b1, 1'b1, 189, 0, 0);
            step_cycle("reallocate recovered slots");
            ext_expect(ref_count == 4 && live_mask[killed],
                       "recovered slots are immediately reusable");
        end
    endtask

    task automatic consecutive_flush_test;
        begin
            reset_case("consecutive_flush");
            @(negedge clk); set_alloc(1'b1, 1'b1, 160, 0, 0); step_cycle("flush setup0");
            @(negedge clk); set_alloc(1'b1, 1'b1, 161, 0, 0); step_cycle("flush setup1");
            @(negedge clk); clear_inputs(); recover_valid = 1'b1; recover_tag = ref_order[2]; step_cycle("first flush");
            @(negedge clk); clear_inputs(); recover_valid = 1'b1; recover_tag = ref_order[1]; step_cycle("second flush");
            ext_expect(ref_count == 2, "consecutive flush preserves second recovery point");
        end
    endtask

    task automatic flush_empty_rob_test;
        begin
            reset_case("flush_empty");
            @(negedge clk); clear_inputs(); recover_valid = 1'b1; recover_tag = '0; step_cycle("flush empty ROB");
            ext_expect(ref_count == 0, "flush empty ROB remains empty");
        end
    endtask

    task automatic flush_full_rob_test;
        begin
            reset_case("flush_full");
            fill_to_full_test();
            @(negedge clk); clear_inputs(); recover_valid = 1'b1; recover_tag = ref_order[(DEPTH / 2) - 1]; step_cycle("flush full ROB");
            ext_expect(ref_count == (DEPTH / 2), "flush full ROB keeps recovery window");
        end
    endtask

    task automatic reset_during_activity_test;
        begin
            reset_case("reset_during_activity");
            @(negedge clk); set_alloc(1'b1, 1'b1, 180, 0, 0); step_cycle("activity before reset");
            @(negedge clk); rstn = 1'b0; clear_inputs();
            repeat (RESET_CYCLES) @(posedge clk);
            reset_model();
            rstn = 1'b1;
            @(negedge clk); #1;
            ext_expect(occupancy == 0, "reset clears active occupancy");
            ext_expect(live_mask == '0, "reset clears active live state");
            ext_expect(!commit[0].valid && !commit[1].valid,
                        "reset clears commit state");
        end
    endtask

    task automatic long_backpressure_test;
        integer i;
        begin
            reset_case("long_backpressure");
            fill_to_full_test();
            for (i = 0; i < BACKPRESSURE_CYCLES; i = i + 1) begin
                @(negedge clk); set_alloc(1'b1, 1'b1, 190+i, 0, 0); step_cycle("full backpressure hold");
            end
            ext_expect(ref_count == DEPTH, "backpressure holds full ROB");
        end
    endtask

    task automatic unsupported_exception_tests;
        begin
            $display("[ROB-EXT-SKIP] precise_exception_at_head_test: ROB16 has no exception input");
            $display("[ROB-EXT-SKIP] exception_not_at_head_test: ROB16 has no exception input");
            $display("[ROB-EXT-SKIP] exception_with_younger_completed_entries_test: ROB16 has no exception input");
            $display("[ROB-EXT-SKIP] physical_release_test: ROB16/commit_t have no physical register fields");
        end
    endtask

    task automatic tag_reuse_legal_completion_test;
        integer i;
        logic [TAG_W-1:0] old_tag;
        logic [TAG_W-1:0] head_tag;
        begin
            reset_case("tag_reuse_legal_completion");
            old_tag = '0;
            @(negedge clk); set_alloc(1'b1, 1'b0, 220, 0, 0); step_cycle("ABA first allocation");
            old_tag = ref_order[0];
            @(negedge clk); clear_inputs(); set_completion(0, old_tag, 32'hABCD, 1'b1); step_cycle("tag first commit");
            for (i = 0; i < DEPTH - 1; i = i + 1) begin
                @(negedge clk); set_alloc(1'b1, 1'b0, 221+i, 0, 0);
                if (ref_count > 0) begin
                    head_tag = ref_order[0];
                    set_completion(0, head_tag, 32'hAC00+i, 1'b1);
                end
                step_cycle("ABA tag rotation");
            end
            @(negedge clk); set_alloc(1'b1, 1'b0, 240, 0, 0);
            if (ref_count > 0) begin
                head_tag = ref_order[0];
                set_completion(0, head_tag, 32'hAD00, 1'b1);
            end
            step_cycle("ABA reuses tag0");
            ext_expect(ref_count == 1 && ref_order[0] == old_tag,
                       "ABA setup has a new live tag0");

            @(negedge clk); clear_inputs();
            set_completion(0, old_tag, 32'hDEAD_BEEF, 1'b1);
            step_cycle("new tag0 legal completion");
            ext_expect(ref_count == 0,
                       "newly reused tag can complete normally");
        end
    endtask

    task automatic unsupported_aba_old_completion_test;
        begin
            $display("[ROB-EXT-SKIP] tag_reuse_old_completion_test: completion_t has no generation/transaction ID; upstream must suppress stale responses");
        end
    endtask

    task automatic randomize_inputs;
        integer r;
        bit want0;
        bit want1;
        issue_uop_t random_uop0;
        issue_uop_t random_uop1;
        logic [TAG_W-1:0] invalid_tag;
        begin
            clear_inputs();
            r = $urandom(rng);
            want0 = (r % 100) < 65;
            // Do not create a dual packet when lane1 cannot accept it.  This
            // avoids inventing a lane1-only retry protocol not present in the
            // current ROB interface.
            want1 = want0 && alloc_ready[0] && alloc_ready[1] &&
                    (($urandom(rng) % 100) < 45);
            random_uop0 = make_uop(32'h8000 + cycle_no * 4,
                                   $urandom(rng) % 32,
                                   (($urandom(rng) % 100) < 75),
                                   $urandom(rng) % 4);
            random_uop1 = make_uop(32'h8004 + cycle_no * 4,
                                   $urandom(rng) % 32,
                                   (($urandom(rng) % 100) < 75),
                                   $urandom(rng) % 4);
            present_alloc(want0, want1, random_uop0, random_uop1);

            // Completion responses come from an independent delayed-response
            // scheduler, not from a same-cycle live-tag picker.
            drive_due_responses();

            if (($urandom(rng) % 100) < 15) begin
                // Invalid completion tag: choose the current free tail when
                // the ROB is not full.  This tag is outside the live set.
                if (ref_count < DEPTH) begin
                    invalid_tag = ref_next_tag;
                    if (!complete[0].valid)
                        set_completion(0, invalid_tag, 32'hBAD0 + cycle_no, 1'b1);
                    else if (!complete[1].valid)
                        set_completion(1, invalid_tag, 32'hBAD0 + cycle_no, 1'b1);
                end
            end

            if ((ref_count > 0) && (($urandom(rng) % 100) < 8)) begin
                recover_valid = 1'b1;
                recover_tag = ref_order[$urandom(rng) % ref_count];
            end

            for (r = 0; r < QUERY_W; r = r + 1) begin
                if ((ref_count > 0) && (($urandom(rng) % 100) < 70))
                    query_tag[r] = ref_order[$urandom(rng) % ref_count];
                else if (($urandom(rng) % 100) < 50)
                    query_tag[r] = ref_next_tag;
                else
                    query_tag[r] = $urandom(rng) & {TAG_W{1'b1}};
            end
        end
    endtask

    task automatic constrained_random_test;
        integer i;
        begin
            random_scheduler_active = 1'b1;
            reset_case("constrained_random");
            for (i = 0; i < random_cycles; i = i + 1) begin
                if (($urandom(rng) % 500) == 0) begin
                    rstn = 1'b0;
                    clear_inputs();
                    repeat (RESET_CYCLES) @(posedge clk);
                    reset_model();
                    clear_history();
                    cycle_no = 0;
                    rstn = 1'b1;
                    @(negedge clk);
                    test_start_time = $time;
                end
                randomize_inputs();
                step_cycle("random");
            end
            drain_random_scheduler();
            random_tests_finished = 1'b1;
        end
    endtask

    task automatic final_model_consistency_test;
        begin
            if (ref_count != 0)
                ext_fail("final reference model is not empty");
            if (live_mask != '0)
                ext_fail("final DUT live mask is not empty");
            if (occupancy != 0)
                ext_fail("final DUT occupancy is not empty");
            if (random_scheduler_active && responses_pending())
                ext_fail("final completion scheduler still has pending responses");
        end
    endtask

    initial begin
        integer cov_i;
        scoreboard_error_count = 0;
        assertion_error_count = 0;
        timeout_error_count = 0;
        protocol_error_count = 0;
        total_error_count = 0;
        cycle_no = 0;
        random_seed = 1;
        random_cycles = 1000;
        min_coverage = 90;
        stop_on_error_arg = 0;
        test_name = "all";
        random_scheduler_active = 1'b0;
        directed_tests_finished = 1'b0;
        random_tests_finished = 1'b0;
        test_finished = 1'b0;
        test_start_time = 0;
        for (cov_i = 0; cov_i < COV_MANDATORY_POINTS; cov_i = cov_i + 1)
            mandatory_cov_hit[cov_i] = 1'b0;
        plusarg_present = $value$plusargs("SEED=%d", random_seed);
        plusarg_present = $value$plusargs("CYCLES=%d", random_cycles);
        plusarg_present = $value$plusargs("TEST=%s", test_name);
        plusarg_present = $value$plusargs("MIN_COVERAGE=%d", min_coverage);
        plusarg_present = $value$plusargs("STOP_ON_ERROR=%d", stop_on_error_arg);
        rng = random_seed;
        rstn = 1'b0;
        clear_inputs();
        reset_model();
        clear_history();
        repeat (RESET_CYCLES) @(posedge clk);
        rstn = 1'b1;
        test_start_time = $time;

        if ((test_name == "all") || (test_name == "directed")) begin
            single_dispatch_single_commit_test();
            dual_dispatch_test();
            single_lane_valid_test();
            query_all_live_entries_test();
            query_uncompleted_completed_test();
            query_dead_and_released_test();
            query_same_entry_four_ports_test();
            query_wraparound_test();
            query_recovery_before_after_test();
            partial_dispatch_accept_test();
            fill_to_full_test();
            drain_to_empty_test();
            simultaneous_dispatch_commit_test();
            simultaneous_dual_dispatch_dual_commit_test();
            completion_order_tests();
            completion_edge_tests();
            completion_extended_tests();
            repeated_completion_test();
            invalid_completion_tag_test();
            wraparound_test(1);
            wraparound_test(3);
            full_with_same_cycle_commit_test();
            x0_and_no_destination_tests();
            recovery_middle_tests();
            recovery_same_cycle_tests();
            recovery_boundary_tests();
            consecutive_flush_test();
            flush_empty_rob_test();
            flush_full_rob_test();
            reset_during_activity_test();
            long_backpressure_test();
            tag_reuse_legal_completion_test();
            unsupported_aba_old_completion_test();
            unsupported_exception_tests();
            directed_tests_finished = 1'b1;
        end

        if ((test_name == "all") || (test_name == "random"))
            constrained_random_test();

        final_model_consistency_test();
        manual_cov_hit_count = mandatory_cov_count();
        manual_coverage = (100.0 * manual_cov_hit_count) /
                          COV_MANDATORY_POINTS;
        tool_coverage = rob_cov.get_coverage();
        coverage_ok = (manual_coverage >= min_coverage);
        if (!coverage_ok)
            ext_fail($sformatf("mandatory coverage %.2f%% below minimum %0d%%",
                               manual_coverage, min_coverage));

        if (test_name == "all")
            scope_complete = directed_tests_finished && random_tests_finished;
        else if (test_name == "directed")
            scope_complete = directed_tests_finished;
        else if (test_name == "random")
            scope_complete = random_tests_finished;
        else
            scope_complete = 1'b0;
        if (!scope_complete)
            ext_fail("selected test scope did not complete");

        $display("[ROB-EXT-COVER] tool=%0.2f%% mandatory=%0.2f%% minimum=%0d%% hit=%0d/%0d",
                 tool_coverage, manual_coverage, min_coverage,
                 manual_cov_hit_count, COV_MANDATORY_POINTS);
        $display("[ROB-EXT-ERRORS] total=%0d scoreboard=%0d assertion=%0d protocol=%0d timeout=%0d",
                 total_error_count, scoreboard_error_count,
                 assertion_error_count, protocol_error_count,
                 timeout_error_count);
        if ((total_error_count == 0) &&
            (scoreboard_error_count == 0) &&
            (assertion_error_count == 0) &&
            (protocol_error_count == 0) &&
            (timeout_error_count == 0) &&
            scope_complete && coverage_ok) begin
            $display("[ROB-EXT] PASS seed=%0d cycles=%0d scope=%s",
                     random_seed, random_cycles, test_name);
            test_finished = 1'b1;
            $finish;
        end else begin
            $display("[ROB-EXT] FAILURES=%0d seed=%0d cycles=%0d scope=%s",
                     total_error_count, random_seed, random_cycles, test_name);
            test_finished = 1'b1;
            $fatal(2);
            $finish;
        end
    end
endmodule
