`timescale 1ns/1ps

`include "defines.vh"
import cpu_types_pkg::*;

// DispatchQueue4 verification deliberately separates specification checks from
// observations of the current implementation.  The reference model below is
// an ordered set of accepted transactions; it does not reproduce the DUT's
// physical slots, free-slot scan, age comparator, or fast-lane picker.
module tb_dispatch_queue4;
    localparam integer DEPTH = 4;
    localparam integer TAG_W = `ROB_TAG_W;
    localparam integer SEQ_W = TAG_W + 1;
    localparam integer LANES = 2;
    localparam integer HISTORY_DEPTH = 32;
    localparam integer WATCHDOG_GAP_NS = 1_000_000;
    localparam integer PER_TEST_TIMEOUT_NS = 5_000_000;
    localparam integer GLOBAL_TIMEOUT_NS = 100_000_000;
    localparam integer MANDATORY_COV = 32;
    localparam bit STRICT_FULL_PAYLOAD = 1'b1;

    logic clk;
    logic rstn;
    logic flush;
    logic barrier_release;
    dispatch_uop_t enq [0:1];
    logic enq_ready [0:1];
    completion_t complete [0:1];
    commit_t commit [0:1];
    logic issue_valid [0:1];
    logic issue_ready [0:1];
    issue_uop_t issue [0:1];
    logic [2:0] occupancy;

    typedef struct {
        bit valid;
        longint unsigned seq_id;
        logic [SEQ_W-1:0] alloc_seq;
        logic [TAG_W-1:0] src0_tag;
        logic [TAG_W-1:0] src1_tag;
        bit src0_ready;
        bit src1_ready;
        logic [31:0] src0_value;
        logic [31:0] src1_value;
        bit barrier_blocked;
        issue_uop_t uop;
    } ref_entry_t;

    typedef struct {
        bit valid;
        bit via_commit;
        longint unsigned txn_id;
        integer due_cycle;
        logic [TAG_W-1:0] tag;
        logic [31:0] value;
    } completion_txn_t;

    localparam integer COMPLETION_Q_DEPTH = 32;
    completion_txn_t completion_q [0:COMPLETION_Q_DEPTH-1];
    bit producer_live [0:(1<<TAG_W)-1];
    integer completion_q_count;
    longint unsigned next_completion_txn_id;

    ref_entry_t ref_q [0:DEPTH-1];
    ref_entry_t ref_tmp [0:DEPTH-1];
    integer ref_count;
    logic [SEQ_W-1:0] ref_alloc_seq;
    longint unsigned next_seq_id;
    integer packet_id;
    bit ref_barrier_active;
    longint unsigned ref_barrier_owner_seq;

    logic exp_enq_ready [0:1];
    integer candidate_count;
    integer fast_candidate_count;
    integer match_idx [0:1];
    bit match_found [0:1];
    integer expected_issue_idx [0:1];
    bit expected_issue_valid [0:1];
    bit cycle_enq_fire [0:1];
    bit cycle_issue_fire [0:1];
    bit cycle_flush;

    bit output_hold_active [0:1];
    issue_uop_t output_hold [0:1];
    bit input_hold_active [0:1];
    dispatch_uop_t input_hold [0:1];

    integer scoreboard_error_count;
    integer assertion_error_count;
    integer protocol_error_count;
    integer timeout_error_count;
    integer spec_ambiguity_count;
    integer total_error_count;
    integer cycle_no;
    integer random_cycles;
    integer random_seed;
    integer min_coverage;
    integer stop_on_error_arg;
    integer strict_ambiguity_arg;
    integer rng;
    longint unsigned rng_state;
    string requested_test;
    string current_test;
    string history [0:HISTORY_DEPTH-1];
    bit history_valid [0:HISTORY_DEPTH-1];
    integer history_ptr;
    time test_start_time;
    time last_handshake_time;
    bit global_finished;
    bit coverage_gate;
    bit selected_test_completed;
    integer enq_total;
    integer deq_total;
    integer flush_total;
    integer wrap_total;
    integer max_occupancy;
    integer max_gap_cycles;

    bit mandatory_hit [0:MANDATORY_COV-1];
    integer manual_cov_hit_count;
    integer cov_occupancy;
    integer cov_enq_count;
    integer cov_deq_count;
    integer cov_input_mode;
    integer cov_output_mode;
    integer cov_event_mode;

    covergroup dispatch_queue_cg;
        cp_occupancy: coverpoint cov_occupancy {
            bins empty = {0};
            bins one = {1};
            bins two = {2};
            bins near_full = {3};
            bins full = {4};
        }
        cp_enq_count: coverpoint cov_enq_count { bins zero = {0}; bins one = {1}; bins two = {2}; }
        cp_deq_count: coverpoint cov_deq_count { bins zero = {0}; bins one = {1}; bins two = {2}; }
        cp_input_mode: coverpoint cov_input_mode { bins none = {0}; bins lane0 = {1}; bins lane1 = {2}; bins dual = {3}; }
        cp_output_mode: coverpoint cov_output_mode { bins none = {0}; bins lane0 = {1}; bins lane1 = {2}; bins both = {3}; }
        cp_event_mode: coverpoint cov_event_mode { bins normal = {0}; bins flush = {1}; bins barrier = {2}; }
        cx_enq_deq: cross cp_enq_count, cp_deq_count;
        cx_input_output: cross cp_input_mode, cp_output_mode;
    endgroup
    dispatch_queue_cg dq_cg = new();

    DispatchQueue4 dut (
        .clk            (clk),
        .rstn           (rstn),
        .flush          (flush),
        .barrier_release(barrier_release),
        .enq            (enq),
        .enq_ready      (enq_ready),
        .complete       (complete),
        .commit         (commit),
        .rob_head_valid (1'b0),
        .rob_head_tag   ({`ROB_TAG_W{1'b0}}),
        .issue_valid    (issue_valid),
        .issue_ready    (issue_ready),
        .issue          (issue),
        .occupancy      (occupancy)
    );

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    function automatic bit real_source(input ref_entry_t e, input integer which);
        begin
            if (which == 0)
                real_source = e.uop.src0_used && (e.uop.arch_rs1 != 5'd0);
            else
                real_source = e.uop.src1_used && (e.uop.arch_rs2 != 5'd0);
        end
    endfunction

    function automatic bit dispatch_real_source(input dispatch_uop_t p, input integer which);
        begin
            if (which == 0)
                dispatch_real_source = p.uop.src0_used && (p.uop.arch_rs1 != 5'd0);
            else
                dispatch_real_source = p.uop.src1_used && (p.uop.arch_rs2 != 5'd0);
        end
    endfunction

    function automatic bit completion_matches(input logic [TAG_W-1:0] tag);
        begin
            completion_matches =
                (complete[0].valid && complete[0].reg_write && complete[0].rob_tag == tag) ||
                (complete[1].valid && complete[1].reg_write && complete[1].rob_tag == tag) ||
                (commit[0].valid && commit[0].reg_write && commit[0].rob_tag == tag) ||
                (commit[1].valid && commit[1].reg_write && commit[1].rob_tag == tag);
        end
    endfunction

    function automatic logic [31:0] bypass_value(
        input logic [TAG_W-1:0] tag,
        input logic [31:0] base_value
    );
        begin
            // Lane priority is only used to make a deterministic value for
            // the illegal/conflicting case where several producers claim one
            // tag in one cycle.  check_bypass_conflict reports that case.
            if (complete[0].valid && complete[0].reg_write && complete[0].rob_tag == tag)
                bypass_value = complete[0].value;
            else if (complete[1].valid && complete[1].reg_write && complete[1].rob_tag == tag)
                bypass_value = complete[1].value;
            else if (commit[0].valid && commit[0].reg_write && commit[0].rob_tag == tag)
                bypass_value = commit[0].value;
            else if (commit[1].valid && commit[1].reg_write && commit[1].rob_tag == tag)
                bypass_value = commit[1].value;
            else
                bypass_value = base_value;
        end
    endfunction

    function automatic bit wake_entry(input ref_entry_t e, input integer which);
        logic [TAG_W-1:0] tag;
        begin
            tag = (which == 0) ? e.src0_tag : e.src1_tag;
            wake_entry = (!((which == 0) ? e.src0_ready : e.src1_ready)) &&
                         real_source(e, which) && completion_matches(tag);
        end
    endfunction

    function automatic logic [31:0] effective_source_value(input ref_entry_t e, input integer which);
        begin
            if (which == 0) begin
                if (real_source(e, 0) && !e.src0_ready && completion_matches(e.src0_tag))
                    effective_source_value = bypass_value(e.src0_tag, e.src0_value);
                else
                    effective_source_value = e.src0_value;
            end else begin
                if (real_source(e, 1) && !e.src1_ready && completion_matches(e.src1_tag))
                    effective_source_value = bypass_value(e.src1_tag, e.src1_value);
                else
                    effective_source_value = e.src1_value;
            end
        end
    endfunction

    function automatic logic [31:0] dispatch_effective_value(
        input dispatch_uop_t p,
        input integer which
    );
        begin
            if (which == 0) begin
                if (dispatch_real_source(p, 0) && completion_matches(p.src0_tag))
                    dispatch_effective_value = bypass_value(p.src0_tag, p.uop.src0_value);
                else
                    dispatch_effective_value = p.uop.src0_value;
            end else begin
                if (dispatch_real_source(p, 1) && completion_matches(p.src1_tag))
                    dispatch_effective_value = bypass_value(p.src1_tag, p.uop.src1_value);
                else
                    dispatch_effective_value = p.uop.src1_value;
            end
        end
    endfunction

    function automatic issue_uop_t effective_uop(input ref_entry_t e);
        issue_uop_t u;
        begin
            u = e.uop;
            u.src0_value = effective_source_value(e, 0);
            u.src1_value = effective_source_value(e, 1);
            effective_uop = u;
        end
    endfunction

    task automatic clear_ref_entry(inout ref_entry_t e);
        begin
            e.valid = 1'b0;
            e.seq_id = 0;
            e.alloc_seq = '0;
            e.src0_tag = '0;
            e.src1_tag = '0;
            e.src0_ready = 1'b0;
            e.src1_ready = 1'b0;
            e.src0_value = '0;
            e.src1_value = '0;
            e.barrier_blocked = 1'b0;
            e.uop = '0;
        end
    endtask

    function automatic bit entry_ready(input integer idx);
        begin
            // An unused source, or architectural x0, is intrinsically ready
            // in the abstract scheduler contract.  The producer should not
            // need a physical tag-0 wakeup to make such a uop issuable.
            entry_ready = ((!real_source(ref_q[idx], 0)) || ref_q[idx].src0_ready || wake_entry(ref_q[idx], 0)) &&
                          ((!real_source(ref_q[idx], 1)) || ref_q[idx].src1_ready || wake_entry(ref_q[idx], 1));
        end
    endfunction

    function automatic bit entry_is_serializing(input integer idx);
        begin
            entry_is_serializing = ref_q[idx].uop.serializing &&
                                   (ref_q[idx].uop.system_op != SYS_NONE);
        end
    endfunction

    function automatic bit ref_barrier_owner_live;
        integer i;
        begin
            ref_barrier_owner_live = 1'b0;
            if (ref_barrier_active)
                for (i = 0; i < ref_count; i = i + 1)
                    if (ref_q[i].valid &&
                        ref_q[i].seq_id == ref_barrier_owner_seq)
                        ref_barrier_owner_live = 1'b1;
        end
    endfunction

    function automatic bit entry_is_restricted(input integer idx);
        begin
            entry_is_restricted = ref_q[idx].uop.is_br_jmp ||
                                  ref_q[idx].uop.is_ld_st ||
                                  ref_q[idx].uop.is_call ||
                                  ref_q[idx].uop.is_ret ||
                                  ref_q[idx].uop.pred.taken ||
                                   ((ref_q[idx].uop.alu_op == `ALU_MULL) ||
                                    (ref_q[idx].uop.alu_op == `ALU_MULH) ||
                                    (ref_q[idx].uop.alu_op == `ALU_UMUL)) ||
                                  (ref_q[idx].uop.system_op != SYS_NONE);
        end
    endfunction

    function automatic bit entry_fast_capable(input integer idx);
        begin
            entry_fast_capable = !entry_is_restricted(idx) &&
                                 (ref_q[idx].uop.result_sel == `WD_ALU);
        end
    endfunction

    function automatic bit entry_candidate(input integer idx);
        begin
            entry_candidate = ref_q[idx].valid && entry_ready(idx) &&
                              !ref_q[idx].barrier_blocked;
        end
    endfunction

    function automatic integer count_candidates;
        integer i;
        begin
            count_candidates = 0;
            for (i = 0; i < ref_count; i = i + 1)
                count_candidates = count_candidates + entry_candidate(i);
        end
    endfunction

    function automatic integer count_fast_candidates;
        integer i;
        begin
            count_fast_candidates = 0;
            for (i = 0; i < ref_count; i = i + 1)
                if (entry_candidate(i) && entry_fast_capable(i))
                    count_fast_candidates = count_fast_candidates + 1;
        end
    endfunction

    function automatic dispatch_uop_t make_packet(
        input integer id,
        input integer kind,
        input bit wait0,
        input bit wait1
    );
        dispatch_uop_t p;
        begin
            p = '0;
            p.valid = 1'b1;
            p.src0_ready = !wait0;
            p.src1_ready = !wait1;
            p.src0_tag = (id + 5) & ((1 << TAG_W) - 1);
            p.src1_tag = (id + 9) & ((1 << TAG_W) - 1);
            p.uop.rob_tag = id & ((1 << TAG_W) - 1);
            p.uop.pc = 32'h1000_0000 + (id * 32'h10) + kind;
            p.uop.src0_value = 32'hA500_0000 ^ (id * 32'h0101_0101);
            p.uop.src1_value = 32'h5A00_0000 ^ (id * 32'h0011_1101);
            p.uop.arch_rs1 = ((id + 1) % 31) + 1;
            p.uop.arch_rs2 = ((id + 7) % 31) + 1;
            p.uop.src0_used = 1'b1;
            p.uop.src1_used = 1'b1;
            p.uop.imm = 32'hC300_0000 ^ (id * 32'h0001_0101);
            p.uop.npc_op = id[1:0];
            p.uop.reg_write = 1'b1;
            p.uop.arch_rd = ((id + 13) % 31) + 1;
            p.uop.result_sel = (kind == 2) ? `WD_RAM : `WD_ALU;
            p.uop.alu_op = (kind == 4) ? `ALU_MULL : ((id % 2) ? `ALU_XOR : `ALU_ADD);
            p.uop.src_a_sel = id[0];
            p.uop.src_b_sel = id[1];
            p.uop.store_mask = (kind == 2) ? `RAM_WE_W : (id[3:0] | 4'h1);
            p.uop.load_ext_op = (id % 5) + 1;
            p.uop.is_br_jmp = (kind == 1);
            p.uop.is_ld_st = (kind == 2);
            p.uop.is_call = (kind == 1) && id[0];
            p.uop.is_ret = (kind == 1) && !id[0];
            p.uop.system_op = (kind == 3) ? SYS_CSRRD : SYS_NONE;
            p.uop.csr_num = 14'h120 + id;
            p.uop.cacop_op = 5'h12 + id[2:0];
            p.uop.serializing = (kind == 3);
            p.uop.pred.ras_ptr = id[2:0];
            p.uop.pred.valid = (kind == 1);
            p.uop.pred.taken = (kind == 1) && id[0];
            p.uop.pred.target = 32'h2000_0000 + id;
            p.uop.pred.index = 10'h155 + id;
            p.uop.pred.ras_sp_before = id[2:0];
            p.uop.pred.ras_count_before = 4'h8 + id[1:0];
            make_packet = p;
        end
    endfunction

    function automatic integer next_rand(input integer modulo);
        begin
            // Use an explicit per-test LCG instead of simulator-global
            // $urandom state so the same +SEED reproduces across XSim runs.
            rng_state = rng_state * 64'd6364136223846793005 + 64'd1;
            next_rand = rng_state % modulo;
        end
    endfunction

    function automatic completion_t make_completion(
        input logic [TAG_W-1:0] tag,
        input logic [31:0] value,
        input bit reg_write
    );
        completion_t c;
        begin
            c = '0;
            c.valid = 1'b1;
            c.rob_tag = tag;
            c.value = value;
            c.reg_write = reg_write;
            make_completion = c;
        end
    endfunction

    function automatic commit_t make_commit(
        input logic [TAG_W-1:0] tag,
        input logic [31:0] value,
        input bit reg_write
    );
        commit_t c;
        begin
            c = '0;
            c.valid = 1'b1;
            c.rob_tag = tag;
            c.value = value;
            c.reg_write = reg_write;
            c.has_dest = reg_write;
            c.pc = 32'h4000_0000 + tag;
            c.arch_rd = 5'd17;
            make_commit = c;
        end
    endfunction

    task automatic schedule_completion_txn(
        input logic [TAG_W-1:0] tag,
        input logic [31:0] value,
        input integer delay,
        input bit via_commit
    );
        integer i;
        integer free_idx;
        begin
            free_idx = -1;
            for (i = 0; i < COMPLETION_Q_DEPTH; i = i + 1)
                if ((free_idx < 0) && !completion_q[i].valid)
                    free_idx = i;
            if (free_idx < 0 || completion_q_count >= COMPLETION_Q_DEPTH) begin
                record_protocol_error("legal completion transaction queue overflow");
            end else if (producer_live[tag]) begin
                record_protocol_error($sformatf(
                    "duplicate live completion producer tag=%0d", tag));
            end else begin
                completion_q[free_idx].valid = 1'b1;
                completion_q[free_idx].via_commit = via_commit;
                completion_q[free_idx].txn_id = next_completion_txn_id;
                completion_q[free_idx].due_cycle = cycle_no + ((delay < 1) ? 1 : delay);
                completion_q[free_idx].tag = tag;
                completion_q[free_idx].value = value;
                next_completion_txn_id = next_completion_txn_id + 1;
                completion_q_count = completion_q_count + 1;
                producer_live[tag] = 1'b1;
            end
        end
    endtask

    task automatic drive_due_completion_txns;
        integer i;
        integer lane_c;
        integer lane_m;
        begin
            complete[0] = '0; complete[1] = '0;
            commit[0] = '0; commit[1] = '0;
            lane_c = 0;
            lane_m = 0;
            // Transactions are unique by producer tag.  Array placement is
            // irrelevant; txn_id/due_cycle define their legal lifetime.
            for (i = 0; i < COMPLETION_Q_DEPTH; i = i + 1) begin
                if (completion_q[i].valid &&
                    completion_q[i].due_cycle <= cycle_no) begin
                    if (completion_q[i].via_commit && lane_m < LANES) begin
                        commit[lane_m] = make_commit(completion_q[i].tag,
                                                    completion_q[i].value, 1'b1);
                        lane_m = lane_m + 1;
                        completion_q[i].valid = 1'b0;
                        producer_live[completion_q[i].tag] = 1'b0;
                        completion_q_count = completion_q_count - 1;
                    end else if (!completion_q[i].via_commit && lane_c < LANES) begin
                        complete[lane_c] = make_completion(completion_q[i].tag,
                                                          completion_q[i].value, 1'b1);
                        lane_c = lane_c + 1;
                        completion_q[i].valid = 1'b0;
                        producer_live[completion_q[i].tag] = 1'b0;
                        completion_q_count = completion_q_count - 1;
                    end
                end
            end
        end
    endtask

    task automatic mark_cov(input integer point);
        begin
            if (point >= 0 && point < MANDATORY_COV)
                mandatory_hit[point] = 1'b1;
        end
    endtask

    function automatic integer manual_coverage_count;
        integer i;
        begin
            manual_coverage_count = 0;
            for (i = 0; i < MANDATORY_COV; i = i + 1)
                manual_coverage_count = manual_coverage_count + mandatory_hit[i];
        end
    endfunction

    function automatic bit full_suite_scope;
        begin
            full_suite_scope = (requested_test == "all") ||
                               (requested_test == "directed") ||
                               (requested_test == "random");
        end
    endfunction

    function automatic integer scoped_coverage_required;
        begin
            scoped_coverage_required = full_suite_scope() ? MANDATORY_COV : 1;
        end
    endfunction

    function automatic integer scoped_coverage_hit;
        begin
            scoped_coverage_hit = full_suite_scope() ? manual_coverage_count() :
                                  (selected_test_completed ? 1 : 0);
        end
    endfunction

    task automatic add_history(input string label);
        begin
            history[history_ptr] = $sformatf(
                "cyc=%0d %s enq=%b%b ready=%b%b issue=%b%b rdy=%b%b occ=%0d flush=%b barrier=%b",
                cycle_no, label, enq[1].valid, enq[0].valid,
                enq_ready[1], enq_ready[0], issue_valid[1], issue_valid[0],
                issue_ready[1], issue_ready[0], occupancy, flush, barrier_release);
            history_valid[history_ptr] = 1'b1;
            history_ptr = (history_ptr + 1) % HISTORY_DEPTH;
        end
    endtask

    task automatic dump_context(input string kind, input string message);
        integer i;
        begin
            $display("[DQ-%s] test=%s seed=%0d cycle=%0d %s",
                     kind, current_test, random_seed, cycle_no, message);
            $display("[DQ-STATE] dut_occ=%0d ref_occ=%0d enq_ready=%b%b issue_valid=%b%b issue_ready=%b%b flush=%b barrier_release=%b",
                     occupancy, ref_count, enq_ready[1], enq_ready[0],
                     issue_valid[1], issue_valid[0], issue_ready[1], issue_ready[0],
                     flush, barrier_release);
            $display("[DQ-BARRIER-DEBUG] ref_active=%b ref_owner_live=%b dut_active=%b dut_serializing=%b dut_blocked=%b next_found=%b",
                     ref_barrier_active, ref_barrier_owner_live(),
                     dut.barrier_active, dut.serializing_mask,
                     dut.barrier_blocked, dut.next_barrier_found);
            $display("[DQ-IN] e0=%h e1=%h c0=%h c1=%h m0=%h m1=%h",
                     enq[0], enq[1], complete[0], complete[1], commit[0], commit[1]);
            $display("[DQ-OUT] i0=%h i1=%h", issue[0], issue[1]);
            for (i = 0; i < ref_count; i = i + 1)
                $display("[DQ-REF] idx=%0d seq=%0d tag=%h pc=%h src0r=%b src1r=%b blocked=%b",
                         i, ref_q[i].seq_id, ref_q[i].uop.rob_tag, ref_q[i].uop.pc,
                         ref_q[i].src0_ready, ref_q[i].src1_ready,
                         ref_q[i].barrier_blocked);
            if (total_error_count <= 40) begin
                for (i = 0; i < HISTORY_DEPTH; i = i + 1)
                    if (history_valid[i])
                        $display("[DQ-HISTORY] %s", history[i]);
            end
        end
    endtask

    task automatic record_scoreboard_error(input string message);
        begin
            scoreboard_error_count = scoreboard_error_count + 1;
            total_error_count = total_error_count + 1;
            dump_context("SCOREBOARD-FAIL", message);
            if (stop_on_error_arg != 0)
                $fatal(2, "DispatchQueue scoreboard failure");
        end
    endtask

    task automatic record_assertion_error(input string message);
        begin
            assertion_error_count = assertion_error_count + 1;
            total_error_count = total_error_count + 1;
            dump_context("ASSERT-FAIL", message);
            if (stop_on_error_arg != 0)
                $fatal(2, "DispatchQueue assertion failure");
        end
    endtask

    task automatic record_protocol_error(input string message);
        begin
            protocol_error_count = protocol_error_count + 1;
            total_error_count = total_error_count + 1;
            dump_context("PROTOCOL-FAIL", message);
            if (stop_on_error_arg != 0)
                $fatal(2, "DispatchQueue protocol failure");
        end
    endtask

    task automatic record_ambiguity(input string message);
        begin
            spec_ambiguity_count = spec_ambiguity_count + 1;
            $display("[DQ-SPEC-AMBIGUITY] test=%s seed=%0d cycle=%0d %s",
                     current_test, random_seed, cycle_no, message);
            if (strict_ambiguity_arg != 0) begin
                total_error_count = total_error_count + 1;
                if (stop_on_error_arg != 0)
                    $fatal(2, "DispatchQueue strict specification ambiguity");
            end
        end
    endtask

    task automatic record_timeout(input string message);
        begin
            timeout_error_count = timeout_error_count + 1;
            total_error_count = total_error_count + 1;
            dump_context("WATCHDOG", message);
            $fatal(2, "DispatchQueue watchdog timeout");
        end
    endtask

    task automatic reset_ref_state;
        integer i;
        begin
            ref_count = 0;
            ref_alloc_seq = '0;
            ref_barrier_active = 1'b0;
            ref_barrier_owner_seq = '0;
            for (i = 0; i < DEPTH; i = i + 1) begin
                clear_ref_entry(ref_q[i]);
                clear_ref_entry(ref_tmp[i]);
            end
            output_hold_active[0] = 1'b0;
            output_hold_active[1] = 1'b0;
            input_hold_active[0] = 1'b0;
            input_hold_active[1] = 1'b0;
            completion_q_count = 0;
            next_completion_txn_id = 1;
            for (i = 0; i < COMPLETION_Q_DEPTH; i = i + 1)
                completion_q[i] = '{default:'0};
            for (i = 0; i < (1<<TAG_W); i = i + 1)
                producer_live[i] = 1'b0;
        end
    endtask

    task automatic clear_transient_inputs;
        begin
            complete[0] = '0;
            complete[1] = '0;
            commit[0] = '0;
            commit[1] = '0;
            flush = 1'b0;
            barrier_release = 1'b0;
        end
    endtask

    task automatic clear_all_inputs;
        begin
            enq[0] = '0;
            enq[1] = '0;
            issue_ready[0] = 1'b0;
            issue_ready[1] = 1'b0;
            clear_transient_inputs();
        end
    endtask

    task automatic begin_reset_test(input string name);
        begin
            current_test = name;
            test_start_time = $time;
            rstn = 1'b0;
            clear_all_inputs();
            reset_ref_state();
            repeat (2) @(posedge clk);
            @(negedge clk);
            rstn = 1'b1;
            #1;
            if (occupancy !== 3'd0)
                record_scoreboard_error("reset occupancy is not zero");
            if (issue_valid[0] || issue_valid[1])
                record_scoreboard_error("reset left issue valid asserted");
            if (!enq_ready[0] || !enq_ready[1])
                record_scoreboard_error("reset did not expose two free enqueue lanes");
            mark_cov(0);
        end
    endtask

    task automatic load_enq_lane(input integer lane, input dispatch_uop_t p);
        begin
            if (lane < 0 || lane >= LANES) begin
                record_protocol_error("invalid enqueue lane in test driver");
            end else if (rstn && !flush && enq[lane].valid && !enq_ready[lane]) begin
                record_protocol_error($sformatf("driver changed stalled enqueue lane %0d", lane));
            end else begin
                enq[lane] = p;
            end
        end
    endtask

    task automatic create_packet(
        output dispatch_uop_t p,
        input integer kind,
        input bit wait0,
        input bit wait1
    );
        begin
            p = make_packet(packet_id, kind, wait0, wait1);
            packet_id = packet_id + 1;
        end
    endtask

    task automatic enqueue_one(
        input integer lane,
        input integer kind,
        input bit wait0,
        input bit wait1
    );
        dispatch_uop_t p;
        begin
            create_packet(p, kind, wait0, wait1);
            load_enq_lane(lane, p);
        end
    endtask

    task automatic enqueue_dual(input integer kind0, input integer kind1);
        dispatch_uop_t p0;
        dispatch_uop_t p1;
        begin
            create_packet(p0, kind0, 1'b0, 1'b0);
            create_packet(p1, kind1, 1'b0, 1'b0);
            load_enq_lane(0, p0);
            load_enq_lane(1, p1);
        end
    endtask

    function automatic integer held_entry_index(input integer lane);
        integer i;
        begin
            held_entry_index = -1;
            if (output_hold_active[lane])
                for (i = 0; i < ref_count; i = i + 1)
                    if ((held_entry_index < 0) && ref_q[i].valid &&
                        ref_q[i].uop.rob_tag == output_hold[lane].rob_tag &&
                        ref_q[i].uop.pc == output_hold[lane].pc)
                        held_entry_index = i;
        end
    endfunction

    task automatic select_oldest_ready_outputs;
        integer i;
        integer held0;
        integer held1;
        issue_uop_t expected;
        begin
            // This selector is deliberately expressed only in terms of the
            // monotonically ordered abstract transaction list.  It does not
            // inspect DUT slots, alloc_seq, pick_oldest4 or priority loops.
            held0 = held_entry_index(0);
            held1 = held_entry_index(1);
            expected_issue_idx[0] = -1;
            expected_issue_idx[1] = -1;

            if (output_hold_active[0]) begin
                expected_issue_idx[0] = held0;
            end else begin
                for (i = 0; i < ref_count; i = i + 1)
                    if ((expected_issue_idx[0] < 0) && entry_candidate(i) &&
                        (i != held1))
                        expected_issue_idx[0] = i;
            end

            if (output_hold_active[1]) begin
                expected_issue_idx[1] = held1;
            end else begin
                for (i = 0; i < ref_count; i = i + 1)
                    if ((expected_issue_idx[1] < 0) && entry_candidate(i) &&
                        entry_fast_capable(i) &&
                        (i != expected_issue_idx[0]))
                        expected_issue_idx[1] = i;
            end

            for (i = 0; i < LANES; i = i + 1) begin
                expected_issue_valid[i] = (expected_issue_idx[i] >= 0);
                match_found[i] = 1'b0;
                match_idx[i] = -1;
                if (issue_valid[i] !== expected_issue_valid[i]) begin
                    record_scoreboard_error($sformatf(
                        "lane%0d oldest-ready valid mismatch: DUT=%b REF=%b oldest_idx=%0d",
                        i, issue_valid[i], expected_issue_valid[i], expected_issue_idx[i]));
                end else if (expected_issue_valid[i]) begin
                    expected = effective_uop(ref_q[expected_issue_idx[i]]);
                    if (issue[i].rob_tag !== expected.rob_tag ||
                        issue[i].pc !== expected.pc ||
                        (STRICT_FULL_PAYLOAD && issue[i] !== expected)) begin
                        record_scoreboard_error($sformatf(
                            "lane%0d violated oldest-ready: expected seq=%0d pc=%h, got pc=%h",
                            i, ref_q[expected_issue_idx[i]].seq_id,
                            expected.pc, issue[i].pc));
                    end else begin
                        match_found[i] = 1'b1;
                        match_idx[i] = expected_issue_idx[i];
                    end
                end
            end
        end
    endtask

    task automatic check_bypass_conflict;
        integer i;
        integer hits;
        logic [TAG_W-1:0] tag;
        begin
            for (i = 0; i < ref_count; i = i + 1) begin
                if (real_source(ref_q[i], 0) && !ref_q[i].src0_ready) begin
                    tag = ref_q[i].src0_tag;
                    hits = (complete[0].valid && complete[0].reg_write && complete[0].rob_tag == tag) +
                           (complete[1].valid && complete[1].reg_write && complete[1].rob_tag == tag) +
                           (commit[0].valid && commit[0].reg_write && commit[0].rob_tag == tag) +
                           (commit[1].valid && commit[1].reg_write && commit[1].rob_tag == tag);
                    if (hits > 1)
                        record_ambiguity("multiple producer responses claim the same source tag; bypass priority is unspecified");
                end
                if (real_source(ref_q[i], 1) && !ref_q[i].src1_ready) begin
                    tag = ref_q[i].src1_tag;
                    hits = (complete[0].valid && complete[0].reg_write && complete[0].rob_tag == tag) +
                           (complete[1].valid && complete[1].reg_write && complete[1].rob_tag == tag) +
                           (commit[0].valid && commit[0].reg_write && commit[0].rob_tag == tag) +
                           (commit[1].valid && commit[1].reg_write && commit[1].rob_tag == tag);
                    if (hits > 1)
                        record_ambiguity("multiple producer responses claim the same source tag; bypass priority is unspecified");
                end
            end
        end
    endtask

    task automatic check_pre(input string label);
        integer i;
        integer fires;
        integer output_mode;
        begin
            if (!rstn)
                return;

            candidate_count = count_candidates();
            fast_candidate_count = count_fast_candidates();
            exp_enq_ready[0] = (ref_count < DEPTH);
            exp_enq_ready[1] = (ref_count <= DEPTH-2);
            cycle_flush = flush;
            cycle_enq_fire[0] = enq[0].valid && enq_ready[0] && !flush;
            cycle_enq_fire[1] = enq[1].valid && enq_ready[1] && !flush;
            cycle_issue_fire[0] = issue_valid[0] && issue_ready[0] && !flush;
            cycle_issue_fire[1] = issue_valid[1] && issue_ready[1] && !flush;
            match_found[0] = 1'b0;
            match_found[1] = 1'b0;
            match_idx[0] = -1;
            match_idx[1] = -1;

            if ($isunknown(occupancy) || $isunknown(enq_ready[0]) || $isunknown(enq_ready[1]) ||
                $isunknown(issue_valid[0]) || $isunknown(issue_valid[1]))
                record_protocol_error("X/Z observed on queue control output");

            if ($unsigned(occupancy) > DEPTH)
                record_assertion_error("occupancy exceeds queue depth");
            if ($unsigned(occupancy) != ref_count)
                record_scoreboard_error($sformatf("occupancy mismatch: DUT=%0d REF=%0d", occupancy, ref_count));
            if (enq_ready[0] !== exp_enq_ready[0] || enq_ready[1] !== exp_enq_ready[1])
                record_scoreboard_error($sformatf("capacity ready mismatch: DUT=%b%b REF=%b%b",
                                                  enq_ready[1], enq_ready[0], exp_enq_ready[1], exp_enq_ready[0]));

            select_oldest_ready_outputs();

            for (i = 0; i < LANES; i = i + 1) begin
                if (issue_valid[i]) begin
                    if ($isunknown(issue[i]))
                        record_protocol_error($sformatf("issue lane%0d contains X/Z payload", i));
                end
                if (enq[i].valid && $isunknown(enq[i]))
                    record_protocol_error($sformatf("enqueue lane%0d contains X/Z payload", i));
            end

            if (cycle_issue_fire[0] && !match_found[0])
                record_scoreboard_error("lane0 handshake did not identify a live reference entry");
            if (cycle_issue_fire[1] && !match_found[1])
                record_scoreboard_error("lane1 handshake did not identify a live reference entry");
            if (cycle_issue_fire[0] && cycle_issue_fire[1] &&
                match_idx[0] == match_idx[1])
                record_protocol_error("two issue handshakes selected the same reference entry");

            if (flush && (cycle_enq_fire[0] || cycle_enq_fire[1] ||
                          cycle_issue_fire[0] || cycle_issue_fire[1]))
                record_ambiguity("flush is not reflected in ready/valid; outward handshakes are visible although RTL flush has priority");

            if (output_hold_active[0] && !flush &&
                ((!issue_valid[0]) || issue[0] !== output_hold[0]))
                record_assertion_error("issue lane0 changed while valid&&!ready");
            if (output_hold_active[1] && !flush &&
                ((!issue_valid[1]) || issue[1] !== output_hold[1]))
                record_assertion_error("issue lane1 changed while valid&&!ready");
            if (input_hold_active[0] && !flush && enq[0] !== input_hold[0])
                record_protocol_error("test driver changed enqueue lane0 while valid&&!ready");
            if (input_hold_active[1] && !flush && enq[1] !== input_hold[1])
                record_protocol_error("test driver changed enqueue lane1 while valid&&!ready");

            output_hold_active[0] = issue_valid[0] && !issue_ready[0];
            output_hold_active[1] = issue_valid[1] && !issue_ready[1];
            output_hold[0] = issue[0];
            output_hold[1] = issue[1];
            input_hold_active[0] = enq[0].valid && !enq_ready[0] && !flush;
            input_hold_active[1] = enq[1].valid && !enq_ready[1] && !flush;
            input_hold[0] = enq[0];
            input_hold[1] = enq[1];

            cov_occupancy = $unsigned(occupancy);
            cov_enq_count = cycle_enq_fire[0] + cycle_enq_fire[1];
            cov_deq_count = cycle_issue_fire[0] + cycle_issue_fire[1];
            cov_input_mode = {enq[1].valid, enq[0].valid};
            output_mode = {issue_ready[1], issue_ready[0]};
            cov_output_mode = output_mode;
            cov_event_mode = flush ? 1 : (barrier_release ? 2 : 0);
            dq_cg.sample();
            if (cov_occupancy == 0) mark_cov(0);
            else if (cov_occupancy == 1) mark_cov(1);
            else if (cov_occupancy == 2) mark_cov(2);
            else if (cov_occupancy == 3) mark_cov(3);
            else if (cov_occupancy == 4) mark_cov(4);
            if (cov_enq_count == 0) mark_cov(5);
            if (cov_enq_count == 1) mark_cov(6);
            if (cov_enq_count == 2) mark_cov(7);
            if (cov_deq_count == 0) mark_cov(8);
            if (cov_deq_count == 1) mark_cov(9);
            if (cov_deq_count == 2) mark_cov(10);
            if (enq[0].valid && !enq[1].valid) mark_cov(11);
            if (!enq[0].valid && enq[1].valid) mark_cov(12);
            if (enq[0].valid && enq[1].valid) mark_cov(13);
            if (issue_ready[0] && !issue_ready[1]) mark_cov(14);
            if (!issue_ready[0] && issue_ready[1]) mark_cov(15);
            if (issue_ready[0] && issue_ready[1]) mark_cov(16);
            if ((cov_enq_count != 0) && (cov_deq_count != 0)) mark_cov(17);
            if (occupancy == DEPTH && (cov_enq_count != 0 || cov_deq_count != 0)) mark_cov(18);
            if (occupancy == 0 && (cov_enq_count != 0 || cov_deq_count != 0)) mark_cov(19);
            if (flush) mark_cov(20);
            if ((issue_valid[0] && !issue_ready[0]) || (issue_valid[1] && !issue_ready[1])) mark_cov(21);
            if (barrier_release || ref_barrier_active) mark_cov(22);
            if (enq[0].valid && enq[0].uop.imm != 0) mark_cov(23);
            if (enq[0].valid && enq[1].valid &&
                (enq[0].uop.result_sel != enq[1].uop.result_sel ||
                 enq[0].uop.is_ld_st != enq[1].uop.is_ld_st)) mark_cov(24);
            if (flush && (enq[0].valid || enq[1].valid)) mark_cov(25);
            if (flush && (issue_valid[0] || issue_valid[1])) mark_cov(26);
            if (issue_valid[0] && issue_valid[1] && cycle_issue_fire[0] && cycle_issue_fire[1] &&
                match_idx[0] != match_idx[1]) mark_cov(27);
            if (ref_count > 0 && (test_start_time != $time)) mark_cov(28);
            if (enq[0].valid && enq[1].valid && issue_ready[0] && issue_ready[1]) mark_cov(29);
            if (ref_count > 0 && max_gap_cycles > 8) mark_cov(31);
            check_bypass_conflict();
            add_history(label);
        end
    endtask

    task automatic recompute_barrier_after_release;
        integer i;
        integer owner;
        begin
            // The release event belongs to the oldest serializing uop that
            // established the barrier.  Younger serializing uops may already
            // be live and must not prevent release of that older barrier.
            if (barrier_release && !ref_barrier_owner_live()) begin
                ref_barrier_active = 1'b0;
                ref_barrier_owner_seq = '0;
                for (i = 0; i < ref_count; i = i + 1)
                    ref_q[i].barrier_blocked = 1'b0;

                // If a younger serializing uop was already dispatched behind
                // the released owner, it becomes the next barrier owner.  Its
                // own entry is issuable; only entries younger than it remain
                // blocked.
                owner = -1;
                for (i = 0; i < ref_count; i = i + 1)
                    if (owner < 0 && entry_is_serializing(i))
                        owner = i;
                if (owner >= 0) begin
                    ref_barrier_active = 1'b1;
                    ref_barrier_owner_seq = ref_q[owner].seq_id;
                    for (i = owner + 1; i < ref_count; i = i + 1)
                        ref_q[i].barrier_blocked = 1'b1;
                end
            end
        end
    endtask

    task automatic ref_apply;
        integer i;
        integer j;
        integer kept;
        ref_entry_t n;
        bit removed;
        bit b0;
        bit b1;
        begin
            if (cycle_flush) begin
                reset_ref_state();
                flush_total = flush_total + 1;
                return;
            end

            // Apply abstract register wakeups before consuming issue handshakes.
            for (i = 0; i < ref_count; i = i + 1) begin
                if (wake_entry(ref_q[i], 0)) begin
                    ref_q[i].src0_ready = 1'b1;
                    ref_q[i].src0_value = bypass_value(ref_q[i].src0_tag, ref_q[i].src0_value);
                end
                if (wake_entry(ref_q[i], 1)) begin
                    ref_q[i].src1_ready = 1'b1;
                    ref_q[i].src1_value = bypass_value(ref_q[i].src1_tag, ref_q[i].src1_value);
                end
            end

            kept = 0;
            for (i = 0; i < ref_count; i = i + 1) begin
                removed = 1'b0;
                if (cycle_issue_fire[0] && match_found[0] && match_idx[0] == i)
                    removed = 1'b1;
                if (cycle_issue_fire[1] && match_found[1] && match_idx[1] == i)
                    removed = 1'b1;
                if (!removed) begin
                    ref_tmp[kept] = ref_q[i];
                    kept = kept + 1;
                end
            end
            for (i = 0; i < DEPTH; i = i + 1)
                clear_ref_entry(ref_q[i]);
            for (i = 0; i < kept; i = i + 1)
                ref_q[i] = ref_tmp[i];
            ref_count = kept;

            recompute_barrier_after_release();

            b0 = ref_barrier_active;
            if (cycle_enq_fire[0]) begin
                if (ref_count >= DEPTH) begin
                    record_scoreboard_error("reference overflow before lane0 enqueue");
                    return;
                end
                clear_ref_entry(n);
                n.valid = 1'b1;
                n.seq_id = next_seq_id;
                next_seq_id = next_seq_id + 1;
                n.alloc_seq = ref_alloc_seq;
                ref_alloc_seq = ref_alloc_seq + 1'b1;
                n.src0_tag = enq[0].src0_tag;
                n.src1_tag = enq[0].src1_tag;
                n.src0_ready = !dispatch_real_source(enq[0], 0) || enq[0].src0_ready ||
                               (dispatch_real_source(enq[0], 0) && completion_matches(enq[0].src0_tag));
                n.src1_ready = !dispatch_real_source(enq[0], 1) || enq[0].src1_ready ||
                               (dispatch_real_source(enq[0], 1) && completion_matches(enq[0].src1_tag));
                n.src0_value = dispatch_effective_value(enq[0], 0);
                n.src1_value = dispatch_effective_value(enq[0], 1);
                n.uop = enq[0].uop;
                n.barrier_blocked = b0;
                ref_q[ref_count] = n;
                ref_count = ref_count + 1;
                if (n.uop.serializing && n.uop.system_op != SYS_NONE &&
                    !ref_barrier_active) begin
                    ref_barrier_active = 1'b1;
                    ref_barrier_owner_seq = n.seq_id;
                end
            end
            if (cycle_enq_fire[1]) begin
                if (ref_count >= DEPTH) begin
                    record_scoreboard_error("reference overflow before lane1 enqueue");
                    return;
                end
                clear_ref_entry(n);
                n.valid = 1'b1;
                n.seq_id = next_seq_id;
                next_seq_id = next_seq_id + 1;
                n.alloc_seq = ref_alloc_seq;
                ref_alloc_seq = ref_alloc_seq + 1'b1;
                n.src0_tag = enq[1].src0_tag;
                n.src1_tag = enq[1].src1_tag;
                n.src0_ready = !dispatch_real_source(enq[1], 0) || enq[1].src0_ready ||
                               (dispatch_real_source(enq[1], 0) && completion_matches(enq[1].src0_tag));
                n.src1_ready = !dispatch_real_source(enq[1], 1) || enq[1].src1_ready ||
                               (dispatch_real_source(enq[1], 1) && completion_matches(enq[1].src1_tag));
                n.src0_value = dispatch_effective_value(enq[1], 0);
                n.src1_value = dispatch_effective_value(enq[1], 1);
                n.uop = enq[1].uop;
                n.barrier_blocked = b0 ||
                    (cycle_enq_fire[0] && enq[0].uop.serializing && enq[0].uop.system_op != SYS_NONE);
                ref_q[ref_count] = n;
                ref_count = ref_count + 1;
                if (n.uop.serializing && n.uop.system_op != SYS_NONE &&
                    !ref_barrier_active) begin
                    ref_barrier_active = 1'b1;
                    ref_barrier_owner_seq = n.seq_id;
                end
            end

            if (cycle_enq_fire[0] || cycle_enq_fire[1]) begin
                enq_total = enq_total + cycle_enq_fire[0] + cycle_enq_fire[1];
                if (ref_alloc_seq == '0) begin
                    wrap_total = wrap_total + 1;
                    mark_cov(30);
                end
            end
            if (cycle_issue_fire[0] || cycle_issue_fire[1]) begin
                deq_total = deq_total + cycle_issue_fire[0] + cycle_issue_fire[1];
                last_handshake_time = $time;
            end
            if (ref_count != 0 && !(cycle_issue_fire[0] || cycle_issue_fire[1]))
                max_gap_cycles = max_gap_cycles + 1;
            else
                max_gap_cycles = 0;
            if (max_gap_cycles > 8) mark_cov(31);
            if (ref_count > max_occupancy) max_occupancy = ref_count;
            if (ref_count < 0 || ref_count > DEPTH)
                record_scoreboard_error($sformatf("reference count out of bounds: %0d", ref_count));
        end
    endtask

    task automatic check_post(input string label);
        begin
            if (!rstn)
                return;
            if ($unsigned(occupancy) > DEPTH)
                record_assertion_error("post-edge occupancy exceeds queue depth");
            if ($unsigned(occupancy) != ref_count)
                record_scoreboard_error($sformatf("post-edge occupancy mismatch: DUT=%0d REF=%0d",
                                                  occupancy, ref_count));
            if (ref_count > max_occupancy) max_occupancy = ref_count;
            if (($time - last_handshake_time) > WATCHDOG_GAP_NS && ref_count != 0)
                record_timeout("queue made no progress beyond watchdog gap");
            add_history({"post ", label});
        end
    endtask

    task automatic step_cycle(input string label);
        begin
            if (($time - test_start_time) > PER_TEST_TIMEOUT_NS)
                record_timeout("per-test timeout");
            #1;
            check_pre(label);
            @(posedge clk);
            #1;
            ref_apply();
            check_post(label);
            if (cycle_flush) begin
                enq[0] = '0;
                enq[1] = '0;
                input_hold_active[0] = 1'b0;
                input_hold_active[1] = 1'b0;
            end else begin
                if (cycle_enq_fire[0]) begin
                    enq[0] = '0;
                    input_hold_active[0] = 1'b0;
                end
                if (cycle_enq_fire[1]) begin
                    enq[1] = '0;
                    input_hold_active[1] = 1'b0;
                end
            end
            clear_transient_inputs();
            cycle_no = cycle_no + 1;
        end
    endtask

    task automatic prepare_drain_responses;
        integer i;
        bit got0;
        bit got1;
        begin
            complete[0] = '0;
            complete[1] = '0;
            commit[0] = '0;
            commit[1] = '0;
            // A release is legal after the serializing owner has issued and
            // is no longer live.  Do not generate an early release while the
            // owner is still in the queue; the interface carries no owner
            // generation/phase and the RTL must keep younger uops blocked in
            // that case.
            barrier_release = ref_barrier_active && !ref_barrier_owner_live();
            got0 = 1'b0;
            got1 = 1'b0;
            for (i = 0; i < ref_count; i = i + 1) begin
                if (!got0 && real_source(ref_q[i], 0) && !ref_q[i].src0_ready) begin
                    complete[0] = make_completion(ref_q[i].src0_tag, 32'hD000_0000 + i, 1'b1);
                    got0 = 1'b1;
                end
                if (!got1 && real_source(ref_q[i], 1) && !ref_q[i].src1_ready) begin
                    complete[1] = make_completion(ref_q[i].src1_tag, 32'hD100_0000 + i, 1'b1);
                    got1 = 1'b1;
                end
            end
        end
    endtask

    task automatic drain_queue(input integer limit);
        integer i;
        begin
            // A pending enqueue is a real ready/valid transaction.  Keep it
            // stable until the DUT accepts it; only an explicit flush may
            // squash it here.
            if (!enq[0].valid) enq[0] = '0;
            if (!enq[1].valid) enq[1] = '0;
            issue_ready[0] = 1'b1;
            issue_ready[1] = 1'b1;
            clear_transient_inputs();
            for (i = 0; i < limit && ref_count != 0; i = i + 1) begin
                prepare_drain_responses();
                step_cycle("drain");
            end
            if (ref_count != 0 || occupancy != 0)
                record_timeout("drain phase could not empty DUT and reference model");
        end
    endtask

    task automatic end_test;
        begin
            if (enq[0].valid || enq[1].valid) begin
                flush = 1'b1;
                step_cycle("end_test_squash_pending_input");
            end
            drain_queue(DEPTH * 4 + 8);
        end
    endtask

    task automatic reset_with_valid_inputs_test;
        dispatch_uop_t p0;
        dispatch_uop_t p1;
        begin
            current_test = "reset_with_valid_inputs_test";
            test_start_time = $time;
            rstn = 1'b0;
            clear_all_inputs();
            reset_ref_state();
            create_packet(p0, 0, 1'b0, 1'b0);
            create_packet(p1, 0, 1'b0, 1'b0);
            enq[0] = p0;
            enq[1] = p1;
            issue_ready[0] = 1'b1;
            issue_ready[1] = 1'b1;
            repeat (2) @(posedge clk);
            if (occupancy !== 0 || issue_valid[0] || issue_valid[1])
                record_scoreboard_error("reset accepted or exposed pre-reset enqueue payload");
            @(negedge clk);
            rstn = 1'b1;
            enq[0] = '0;
            enq[1] = '0;
            #1;
            if (occupancy !== 0) record_scoreboard_error("reset-with-input occupancy not zero");
        end
    endtask

    task automatic reset_during_nonempty_queue_test;
        begin
            begin_reset_test("reset_during_nonempty_queue_test");
            enqueue_dual(0, 0);
            issue_ready[0] = 1'b0;
            issue_ready[1] = 1'b0;
            rstn = 1'b0;
            repeat (2) @(posedge clk);
            if (occupancy !== 0) record_scoreboard_error("reset during activity did not clear occupancy");
            reset_ref_state();
            @(negedge clk);
            rstn = 1'b1;
            #1;
        end
    endtask

    task automatic repeated_reset_test;
        integer i;
        begin
            current_test = "repeated_reset_test";
            for (i = 0; i < 3; i = i + 1) begin
                begin_reset_test("repeated_reset_test");
                rstn = 1'b0;
                repeat (2) @(posedge clk);
                reset_ref_state();
                @(negedge clk);
                rstn = 1'b1;
                #1;
                if (occupancy !== 0) record_scoreboard_error("repeated reset residual occupancy");
            end
        end
    endtask

    task automatic empty_queue_output_test;
        begin
            begin_reset_test("empty_queue_output_test");
            issue_ready[0] = 1'b1;
            issue_ready[1] = 1'b1;
            step_cycle("empty");
            end_test();
        end
    endtask

    task automatic basic_lane_enqueue_test(input integer lane, input string name);
        begin
            begin_reset_test(name);
            issue_ready[0] = 1'b0;
            issue_ready[1] = 1'b0;
            enqueue_one(lane, 0, 1'b0, 1'b0);
            step_cycle("lane enqueue");
            if (ref_count != 1) record_scoreboard_error("single lane enqueue was not accepted");
            end_test();
        end
    endtask

    task automatic lane0_only_enqueue_test;
        begin basic_lane_enqueue_test(0, "lane0_only_enqueue_test"); end
    endtask
    task automatic lane1_only_enqueue_test;
        begin basic_lane_enqueue_test(1, "lane1_only_enqueue_test"); end
    endtask

    task automatic alternating_lane_enqueue_test;
        integer i;
        begin
            begin_reset_test("alternating_lane_enqueue_test");
            // Keep the producer legal: once an enqueue is accepted the next
            // request may change.  Ready outputs are enabled so this test
            // exercises alternating lane acceptance without overwriting a
            // stalled request when the four-entry queue becomes full.
            issue_ready[0] = 1'b1;
            issue_ready[1] = 1'b1;
            for (i = 0; i < 6; i = i + 1) begin
                enqueue_one(i % 2, 0, 1'b0, 1'b0);
                step_cycle("alternating lane");
            end
            end_test();
        end
    endtask

    task automatic dual_enqueue_test;
        begin
            begin_reset_test("dual_enqueue_test");
            issue_ready[0] = 1'b0;
            issue_ready[1] = 1'b0;
            enqueue_dual(0, 0);
            step_cycle("dual enqueue");
            if (ref_count != 2) record_scoreboard_error("dual enqueue did not accept two lanes");
            end_test();
        end
    endtask

    task automatic dual_enqueue_repeated_test;
        integer i;
        begin
            begin_reset_test("dual_enqueue_repeated_test");
            issue_ready[0] = 1'b0;
            issue_ready[1] = 1'b0;
            for (i = 0; i < 2; i = i + 1) begin
                enqueue_dual(i % 2, (i + 1) % 2);
                step_cycle("dual repeated");
            end
            end_test();
        end
    endtask

    task automatic fill_to_full_test;
        begin
            begin_reset_test("fill_to_full_test");
            issue_ready[0] = 1'b0;
            issue_ready[1] = 1'b0;
            enqueue_dual(0, 0); step_cycle("fill 0");
            enqueue_dual(0, 0); step_cycle("fill 1");
            if (occupancy != DEPTH) record_scoreboard_error("fill-to-full did not reach depth");
            if (enq_ready[0] || enq_ready[1]) record_scoreboard_error("full queue exposes enqueue ready");
            end_test();
        end
    endtask

    task automatic full_hold_test;
        begin
            fill_to_full_test();
            // fill_to_full_test ends with a drain; repeat a direct full hold.
            begin_reset_test("full_hold_test");
            issue_ready[0] = 1'b0; issue_ready[1] = 1'b0;
            enqueue_dual(0, 0); step_cycle("full hold fill0");
            enqueue_dual(0, 0); step_cycle("full hold fill1");
            enqueue_dual(0, 0); step_cycle("full hold stalled");
            if (enq[0].valid !== 1'b1 || enq[1].valid !== 1'b1)
                record_protocol_error("driver did not hold full-queue enqueue request");
            flush = 1'b1;
            step_cycle("full hold flush");
            end_test();
        end
    endtask

    task automatic output_backpressure_test(input string name, input integer cycles);
        integer i;
        begin
            begin_reset_test(name);
            issue_ready[0] = 1'b0; issue_ready[1] = 1'b0;
            enqueue_dual(0, 0); step_cycle("backpressure fill");
            for (i = 0; i < cycles; i = i + 1)
                step_cycle("backpressure hold");
            issue_ready[0] = 1'b1; issue_ready[1] = 1'b1;
            end_test();
        end
    endtask

    task automatic flush_test(input string name, input integer fill_count, input bit with_enq, input bit with_deq);
        integer i;
        begin
            begin_reset_test(name);
            issue_ready[0] = with_deq; issue_ready[1] = with_deq;
            for (i = 0; i < fill_count; i = i + 1) begin
                if ((i % 2) == 0) enqueue_one(0, 0, 1'b0, 1'b0);
                else enqueue_one(1, 0, 1'b0, 1'b0);
                step_cycle("flush fill");
            end
            if (with_enq) enqueue_dual(0, 0);
            flush = 1'b1;
            step_cycle("flush event");
            if (ref_count != 0 || occupancy != 0)
                record_scoreboard_error("global flush did not clear abstract and DUT state");
            end_test();
        end
    endtask

    task automatic completion_wakeup_test;
        dispatch_uop_t p;
        logic [TAG_W-1:0] tag;
        begin
            begin_reset_test("completion_wakeup_test");
            issue_ready[0] = 1'b0; issue_ready[1] = 1'b0;
            create_packet(p, 0, 1'b1, 1'b0);
            tag = p.src0_tag;
            load_enq_lane(0, p);
            step_cycle("unresolved enqueue");
            if (issue_valid[0] || issue_valid[1]) record_scoreboard_error("unresolved source issued early");
            complete[0] = make_completion(tag, 32'hDEAD_BEEF, 1'b1);
            step_cycle("completion wake");
            issue_ready[0] = 1'b1; issue_ready[1] = 1'b1;
            end_test();
        end
    endtask

    task automatic commit_wakeup_test;
        dispatch_uop_t p;
        logic [TAG_W-1:0] tag;
        begin
            begin_reset_test("commit_wakeup_test");
            issue_ready[0] = 1'b0; issue_ready[1] = 1'b0;
            create_packet(p, 0, 1'b0, 1'b1);
            tag = p.src1_tag;
            load_enq_lane(0, p);
            step_cycle("commit unresolved enqueue");
            commit[0] = make_commit(tag, 32'hCAFE_BABE, 1'b1);
            step_cycle("commit wake");
            issue_ready[0] = 1'b1; issue_ready[1] = 1'b1;
            end_test();
        end
    endtask

    task automatic x0_wakeup_tag0_test;
        dispatch_uop_t p;
        begin
            begin_reset_test("x0_wakeup_tag0_test");
            issue_ready[0] = 1'b0; issue_ready[1] = 1'b0;
            create_packet(p, 0, 1'b0, 1'b0);
            p.uop.arch_rs1 = 5'd0;
            p.src0_tag = '0;
            p.src0_ready = 1'b1;
            load_enq_lane(0, p);
            step_cycle("x0 unresolved-looking enqueue");
            if (!issue_valid[0] && !issue_valid[1])
                record_scoreboard_error("x0 source was treated as an unresolved dependency");
            complete[0] = make_completion('0, 32'h1111_2222, 1'b1);
            step_cycle("x0 tag0 completion");
            if (issue_valid[0] && issue[0].src0_value == 32'h1111_2222)
                record_protocol_error("x0/tag0 completion incorrectly bypassed into source value");
            if (issue_valid[1] && issue[1].src0_value == 32'h1111_2222)
                record_protocol_error("x0/tag0 completion incorrectly bypassed into fast source value");
            issue_ready[0] = 1'b1; issue_ready[1] = 1'b1;
            end_test();
        end
    endtask

    task automatic non_regwrite_completion_test;
        dispatch_uop_t p;
        begin
            begin_reset_test("non_regwrite_completion_test");
            issue_ready[0] = 1'b0; issue_ready[1] = 1'b0;
            create_packet(p, 0, 1'b1, 1'b0);
            load_enq_lane(0, p);
            step_cycle("non-regwrite enqueue");
            complete[0] = make_completion(p.src0_tag, 32'h1234_5678, 1'b0);
            step_cycle("non-regwrite completion");
            if (issue_valid[0] || issue_valid[1])
                record_protocol_error("completion.valid with reg_write=0 woke a source; expected no register wakeup");
            issue_ready[0] = 1'b1; issue_ready[1] = 1'b1;
            end_test();
        end
    endtask

    task automatic dual_output_distinct_test;
        begin
            begin_reset_test("dual_output_distinct_test");
            issue_ready[0] = 1'b1; issue_ready[1] = 1'b1;
            enqueue_dual(0, 0);
            step_cycle("dual output enqueue");
            if (issue_valid[0] && issue_valid[1] && issue[0].pc == issue[1].pc)
                record_protocol_error("dual valid outputs identify the same PC");
            end_test();
        end
    endtask

    task automatic lane1_payload_test;
        begin
            begin_reset_test("lane1_payload_test");
            issue_ready[0] = 1'b0; issue_ready[1] = 1'b1;
            // One fast entry must not be duplicated onto lane1 while lane0
            // is stalled.  Use two fast entries so lane1 has a distinct,
            // legitimate candidate whose complete payload can be checked.
            enqueue_dual(0, 0);
            step_cycle("lane1 payload enqueue");
            if (issue_valid[1]) begin
                if (issue[1].arch_rs1 == 0 || issue[1].src0_used == 0 ||
                    issue[1].store_mask == 0 || issue[1].pred.target == 0)
                    record_scoreboard_error("lane1 payload control fields are zeroed or missing");
            end else
                record_protocol_error("two fast entries did not produce a distinct lane1 candidate");
            end_test();
        end
    endtask

    task automatic younger_restricted_issue_test;
        dispatch_uop_t older;
        dispatch_uop_t younger;
        begin
            begin_reset_test("younger_restricted_issue_test");
            issue_ready[0] = 1'b1;
            issue_ready[1] = 1'b0;
            create_packet(older, 0, 1'b1, 1'b0);
            create_packet(younger, 2, 1'b0, 1'b0);
            load_enq_lane(0, older);
            load_enq_lane(1, younger);
            step_cycle("younger restricted issue");
            if (!issue_valid[0])
                record_protocol_error("ready younger restricted uop was not issued on the general path");
            else if (issue[0].pc != younger.uop.pc)
                record_protocol_error($sformatf(
                    "younger restricted uop waited for older unresolved entry: got pc=%h expected pc=%h",
                    issue[0].pc, younger.uop.pc));
            end_test();
        end
    endtask

    task automatic same_cycle_events_test;
        begin
            begin_reset_test("same_cycle_events_test");
            issue_ready[0] = 1'b1; issue_ready[1] = 1'b1;
            enqueue_dual(0, 0);
            step_cycle("same-cycle dual enqueue");
            enqueue_dual(0, 0);
            step_cycle("same-cycle dual enqueue and issue");
            end_test();
        end
    endtask

    task automatic wraparound_test;
        integer i;
        begin
            begin_reset_test("wraparound_test");
            issue_ready[0] = 1'b1; issue_ready[1] = 1'b1;
            for (i = 0; i < 40; i = i + 1) begin
                enqueue_one(i % 2, i % 3, 1'b0, 1'b0);
                step_cycle("wraparound");
            end
            if (wrap_total == 0) record_scoreboard_error("allocation sequence did not wrap in stress test");
            end_test();
        end
    endtask

    task automatic barrier_test;
        begin
            begin_reset_test("barrier_test");
            issue_ready[0] = 1'b1; issue_ready[1] = 1'b1;
            enqueue_one(0, 3, 1'b0, 1'b0);
            step_cycle("barrier enqueue");
            enqueue_one(1, 0, 1'b0, 1'b0);
            step_cycle("younger behind barrier");
            barrier_release = 1'b1;
            step_cycle("barrier release");
            end_test();
        end
    endtask

    task automatic random_test;
        integer c;
        integer lane;
        integer percent;
        dispatch_uop_t p;
        begin
            begin_reset_test("random_test");
            issue_ready[0] = 1'b1;
            issue_ready[1] = 1'b1;
            // A real accepted-transaction warm-up guarantees that modulo age
            // wrap is exercised before random reset/flush can restart it.
            // Coverage point 30 is still set only by ref_apply observing the
            // abstract allocation sequence cross zero.
            for (c = 0; c < 18; c = c + 1) begin
                enqueue_dual(0, 0);
                step_cycle("random wrap warmup");
            end
            for (c = 0; c < random_cycles; c = c + 1) begin
                if (c != 0 && (c % 257) == 0) begin
                    rstn = 1'b0;
                    clear_all_inputs();
                    repeat (2) @(posedge clk);
                    reset_ref_state();
                    @(negedge clk);
                    rstn = 1'b1;
                end
                if (!enq[0].valid && enq_ready[0] && (next_rand(100) < 60)) begin
                    create_packet(p, next_rand(5), (next_rand(100) < 25), (next_rand(100) < 25));
                    if (!p.src0_ready) begin
                        if (producer_live[p.src0_tag]) p.src0_ready = 1'b1;
                        else schedule_completion_txn(p.src0_tag,
                            32'hD000_0000 ^ p.uop.pc, 1+next_rand(12), 1'b0);
                    end
                    if (!p.src1_ready) begin
                        if (producer_live[p.src1_tag]) p.src1_ready = 1'b1;
                        else schedule_completion_txn(p.src1_tag,
                            32'hD100_0000 ^ p.uop.pc, 1+next_rand(12), next_rand(2));
                    end
                    load_enq_lane(0, p);
                end
                if (!enq[1].valid && enq_ready[1] && (next_rand(100) < 60)) begin
                    create_packet(p, next_rand(5), (next_rand(100) < 25), (next_rand(100) < 25));
                    if (!p.src0_ready) begin
                        if (producer_live[p.src0_tag]) p.src0_ready = 1'b1;
                        else schedule_completion_txn(p.src0_tag,
                            32'hE000_0000 ^ p.uop.pc, 1+next_rand(12), 1'b0);
                    end
                    if (!p.src1_ready) begin
                        if (producer_live[p.src1_tag]) p.src1_ready = 1'b1;
                        else schedule_completion_txn(p.src1_tag,
                            32'hE100_0000 ^ p.uop.pc, 1+next_rand(12), next_rand(2));
                    end
                    load_enq_lane(1, p);
                end
                issue_ready[0] = (next_rand(100) < 65);
                issue_ready[1] = (next_rand(100) < 65);
                drive_due_completion_txns();
                flush = (next_rand(100) < 3);
                // Release only a barrier whose owner has already left the
                // queue.  An unconstrained pulse while the owner is still
                // live has no defined transaction identity and would turn a
                // legal barrier test into a false scoreboard failure.
                barrier_release = ref_barrier_active &&
                                  !ref_barrier_owner_live() &&
                                  (next_rand(100) < 4);
                step_cycle("random");
            end
            clear_transient_inputs();
            drain_queue(DEPTH * 8 + 32);
        end
    endtask

    // Wrappers retain the required directed-test names while sharing only
    // stimulus helpers.  The scoreboard remains common and abstract.
    task automatic single_enqueue_single_dequeue_test;
        begin begin_reset_test("single_enqueue_single_dequeue_test"); issue_ready[0]=1; issue_ready[1]=1; enqueue_one(0,0,0,0); step_cycle("single enq/deq"); end_test(); end
    endtask
    task automatic enqueue_with_idle_cycles_test;
        integer i; begin begin_reset_test("enqueue_with_idle_cycles_test"); issue_ready[0]=0; issue_ready[1]=0; for(i=0;i<3;i=i+1) step_cycle("idle"); enqueue_one(0,0,0,0); step_cycle("enqueue"); end_test(); end
    endtask
    task automatic dual_dispatch_until_full_test;
        begin fill_to_full_test(); end
    endtask
    task automatic lane_order_test;
        begin begin_reset_test("lane_order_test"); issue_ready[0]=0; issue_ready[1]=0; enqueue_dual(0,1); step_cycle("lane order"); if (ref_count != 2 || ref_q[0].seq_id >= ref_q[1].seq_id) record_scoreboard_error("lane0/lane1 acceptance order lost"); end_test(); end
    endtask
    task automatic input_payload_integrity_test;
        begin begin_reset_test("input_payload_integrity_test"); issue_ready[0]=1; issue_ready[1]=1; enqueue_dual(0,2); step_cycle("payload integrity"); end_test(); end
    endtask
    task automatic output_lane0_only_ready_test;
        begin output_backpressure_test("output_lane0_only_ready_test", 8); end
    endtask
    task automatic output_lane1_only_ready_test;
        begin begin_reset_test("output_lane1_only_ready_test"); issue_ready[0]=0; issue_ready[1]=1; enqueue_one(1,0,0,0); step_cycle("lane1 only"); end_test(); end
    endtask
    task automatic both_output_ready_test;
        begin dual_output_distinct_test(); end
    endtask
    task automatic alternating_output_ready_test;
        integer i; begin begin_reset_test("alternating_output_ready_test"); issue_ready[0]=0; issue_ready[1]=0; enqueue_dual(0,0); step_cycle("fill"); for(i=0;i<8;i=i+1) begin issue_ready[0]=i[0]; issue_ready[1]=!i[0]; step_cycle("alternating ready"); end end_test(); end
    endtask
    task automatic partial_dequeue_test;
        begin begin_reset_test("partial_dequeue_test"); issue_ready[0]=1; issue_ready[1]=0; enqueue_dual(0,0); step_cycle("partial"); end_test(); end
    endtask
    task automatic output_order_test;
        begin begin_reset_test("output_order_test"); issue_ready[0]=1; issue_ready[1]=1; enqueue_dual(0,0); step_cycle("order"); end_test(); end
    endtask
    task automatic full_with_single_dequeue_test;
        begin begin_reset_test("full_with_single_dequeue_test"); issue_ready[0]=0; issue_ready[1]=0; enqueue_dual(0,0); step_cycle("fill0"); enqueue_dual(0,0); step_cycle("fill1"); issue_ready[0]=1; issue_ready[1]=0; step_cycle("single dequeue full"); end_test(); end
    endtask
    task automatic full_with_dual_dequeue_test;
        begin begin_reset_test("full_with_dual_dequeue_test"); issue_ready[0]=0; issue_ready[1]=0; enqueue_dual(0,0); step_cycle("fill0"); enqueue_dual(0,0); step_cycle("fill1"); issue_ready[0]=1; issue_ready[1]=1; step_cycle("dual dequeue full"); end_test(); end
    endtask
    task automatic drain_to_empty_test;
        begin begin_reset_test("drain_to_empty_test"); issue_ready[0]=0; issue_ready[1]=0; enqueue_dual(0,0); step_cycle("fill"); drain_queue(16); end_test(); end
    endtask
    task automatic empty_with_single_enqueue_test;
        begin basic_lane_enqueue_test(0,"empty_with_single_enqueue_test"); end
    endtask
    task automatic empty_with_dual_enqueue_test;
        begin dual_enqueue_test(); end
    endtask
    task automatic almost_full_dual_enqueue_test;
        begin begin_reset_test("almost_full_dual_enqueue_test"); issue_ready[0]=0; issue_ready[1]=0; enqueue_dual(0,0); step_cycle("almost full"); enqueue_dual(0,0); step_cycle("full attempt"); end_test(); end
    endtask
    task automatic almost_empty_dual_dequeue_test;
        begin begin_reset_test("almost_empty_dual_dequeue_test"); issue_ready[0]=0; issue_ready[1]=0; enqueue_dual(0,0); step_cycle("almost empty"); issue_ready[0]=1; issue_ready[1]=1; step_cycle("dual dequeue"); end_test(); end
    endtask
    task automatic simultaneous_single_enqueue_single_dequeue_test;
        begin
            begin_reset_test("simultaneous_single_enqueue_single_dequeue_test");
            issue_ready[0]=0;issue_ready[1]=0;enqueue_dual(0,0);step_cycle("prefill two");
            enqueue_one(0,0,0,0);issue_ready[0]=1;issue_ready[1]=0;
            step_cycle("real simultaneous 1 enq 1 issue");
            if (cycle_enq_fire[0]+cycle_enq_fire[1] != 1 ||
                cycle_issue_fire[0]+cycle_issue_fire[1] != 1)
                record_scoreboard_error("did not realize simultaneous 1-enqueue/1-issue");
            end_test();
        end
    endtask
    task automatic simultaneous_dual_enqueue_single_dequeue_test;
        begin
            begin_reset_test("simultaneous_dual_enqueue_single_dequeue_test");
            issue_ready[0]=0;issue_ready[1]=0;enqueue_dual(0,0);step_cycle("prefill two");
            enqueue_dual(0,0);issue_ready[0]=1;issue_ready[1]=0;
            step_cycle("real simultaneous 2 enq 1 issue");
            if (cycle_enq_fire[0]+cycle_enq_fire[1] != 2 ||
                cycle_issue_fire[0]+cycle_issue_fire[1] != 1)
                record_scoreboard_error("did not realize simultaneous 2-enqueue/1-issue");
            end_test();
        end
    endtask
    task automatic simultaneous_single_enqueue_dual_dequeue_test;
        begin
            begin_reset_test("simultaneous_single_enqueue_dual_dequeue_test");
            issue_ready[0]=0;issue_ready[1]=0;enqueue_dual(0,0);step_cycle("prefill two");
            enqueue_one(0,0,0,0);issue_ready[0]=1;issue_ready[1]=1;
            step_cycle("real simultaneous 1 enq 2 issue");
            if (cycle_enq_fire[0]+cycle_enq_fire[1] != 1 ||
                cycle_issue_fire[0]+cycle_issue_fire[1] != 2)
                record_scoreboard_error("did not realize simultaneous 1-enqueue/2-issue");
            end_test();
        end
    endtask
    task automatic simultaneous_dual_enqueue_dual_dequeue_test;
        begin
            begin_reset_test("simultaneous_dual_enqueue_dual_dequeue_test");
            issue_ready[0]=0;issue_ready[1]=0;enqueue_dual(0,0);step_cycle("prefill two");
            enqueue_dual(0,0);issue_ready[0]=1;issue_ready[1]=1;
            step_cycle("real simultaneous 2 enq 2 issue");
            if (cycle_enq_fire[0]+cycle_enq_fire[1] != 2 ||
                cycle_issue_fire[0]+cycle_issue_fire[1] != 2)
                record_scoreboard_error("did not realize simultaneous 2-enqueue/2-issue");
            end_test();
        end
    endtask
    task automatic full_simultaneous_enqueue_dequeue_test;
        begin
            begin_reset_test("full_simultaneous_enqueue_dequeue_test");
            issue_ready[0]=0;issue_ready[1]=0;enqueue_dual(0,0);step_cycle("fill half");
            enqueue_dual(0,0);step_cycle("fill full");
            enqueue_one(0,0,0,0);issue_ready[0]=1;issue_ready[1]=0;
            step_cycle("full issue with enqueue request");
            if (cycle_enq_fire[0] || cycle_enq_fire[1])
                record_scoreboard_error("full queue illegally reused issuing slot in same cycle");
            end_test();
        end
    endtask
    task automatic empty_simultaneous_enqueue_dequeue_test;
        begin
            begin_reset_test("empty_simultaneous_enqueue_dequeue_test");
            issue_ready[0]=1;issue_ready[1]=1;enqueue_dual(0,0);
            #1;if(issue_valid[0]||issue_valid[1])record_protocol_error("empty queue illegally fell through");
            step_cycle("empty enqueue with issue ready");end_test();
        end
    endtask
    task automatic same_cycle_passthrough_test;
        begin begin_reset_test("same_cycle_passthrough_test"); issue_ready[0]=1; issue_ready[1]=1; enqueue_one(0,0,0,0); #1; if(issue_valid[0]||issue_valid[1]) record_protocol_error("DUT exposes fall-through output before enqueue edge"); step_cycle("no fall-through"); end_test(); end
    endtask
    task automatic single_wraparound_test;
        integer i;
        begin
            begin_reset_test("single_wraparound_test");issue_ready[0]=1;issue_ready[1]=0;
            for(i=0;i<40;i=i+1)begin enqueue_one(i%2,0,0,0);step_cycle("single wrap stream");end
            if(wrap_total<1)record_scoreboard_error("single-lane stream did not wrap allocation age");
            end_test();
        end
    endtask
    task automatic multiple_wraparound_test;
        integer i;integer start_wrap;
        begin
            begin_reset_test("multiple_wraparound_test");start_wrap=wrap_total;
            issue_ready[0]=1;issue_ready[1]=1;
            for(i=0;i<72;i=i+1)begin enqueue_dual(0,0);step_cycle("multiple dual wrap stream");end
            if((wrap_total-start_wrap)<4)record_scoreboard_error("dual stream did not cross multiple wraps");
            end_test();
        end
    endtask
    task automatic wraparound_with_dual_enqueue_test;
        integer i;integer start_wrap;
        begin
            begin_reset_test("wraparound_with_dual_enqueue_test");start_wrap=wrap_total;
            issue_ready[0]=1;issue_ready[1]=1;
            for(i=0;i<20;i=i+1)begin enqueue_dual(0,0);step_cycle("dual enqueue wrap");end
            if(wrap_total==start_wrap)record_scoreboard_error("dual enqueue did not cross wrap");
            end_test();
        end
    endtask
    task automatic wraparound_with_dual_dequeue_test;
        integer i;integer dual_fires;
        begin
            begin_reset_test("wraparound_with_dual_dequeue_test");dual_fires=0;
            issue_ready[0]=1;issue_ready[1]=1;
            for(i=0;i<20;i=i+1)begin
                enqueue_dual(0,0);step_cycle("dual dequeue wrap");
                if(cycle_issue_fire[0]&&cycle_issue_fire[1])dual_fires=dual_fires+1;
            end
            if(wrap_total<1||dual_fires<8)record_scoreboard_error("wrap test lacked real dual dequeue traffic");
            end_test();
        end
    endtask
    task automatic wraparound_with_backpressure_test;
        integer i;
        begin
            begin_reset_test("wraparound_with_backpressure_test");
            for(i=0;i<80;i=i+1)begin
                issue_ready[0]=(i%5)!=0;issue_ready[1]=(i%3)!=0;
                if(enq_ready[1])enqueue_dual(0,0);else if(enq_ready[0])enqueue_one(0,0,0,0);
                step_cycle("wrap with asymmetric backpressure");
            end
            if(wrap_total<1)record_scoreboard_error("backpressured stream did not wrap");
            end_test();
        end
    endtask
    task automatic wraparound_with_flush_test;
        integer i;
        begin
            begin_reset_test("wraparound_with_flush_test");issue_ready[0]=1;issue_ready[1]=1;
            for(i=0;i<15;i=i+1)begin enqueue_dual(0,0);step_cycle("approach wrap");end
            flush=1;step_cycle("flush near wrap");
            if(dut.next_alloc_seq!==0)record_scoreboard_error("flush did not reset allocation sequence");
            enqueue_dual(0,0);step_cycle("post-flush wrap restart");end_test();
        end
    endtask
    task automatic wraparound_near_full_test;
        begin fill_to_full_test(); end
    endtask
    task automatic long_output_backpressure_test;
        begin output_backpressure_test("long_output_backpressure_test", 64); end
    endtask
    task automatic random_output_backpressure_test;
        begin random_test(); end
    endtask
    task automatic lane0_backpressure_test;
        integer i;
        begin
            begin_reset_test("lane0_backpressure_test");
            issue_ready[0]=0;issue_ready[1]=0;enqueue_dual(0,0);step_cycle("fill");
            issue_ready[0]=0;issue_ready[1]=1;
            for(i=0;i<8;i=i+1)step_cycle("lane0 stalled lane1 independent");
            issue_ready[0]=1;issue_ready[1]=0;step_cycle("release lane0");
            end_test();
        end
    endtask
    task automatic lane1_backpressure_test;
        integer i;
        begin
            begin_reset_test("lane1_backpressure_test");
            issue_ready[0]=0;issue_ready[1]=0;enqueue_dual(0,0);step_cycle("fill two");
            enqueue_one(0,0,0,0);step_cycle("fill third");
            issue_ready[0]=1;issue_ready[1]=0;
            for(i=0;i<8;i=i+1)step_cycle("lane1 stalled lane0 independent");
            issue_ready[0]=0;issue_ready[1]=1;step_cycle("release lane1");
            end_test();
        end
    endtask
    task automatic asymmetric_backpressure_test;
        integer i;
        begin
            begin_reset_test("asymmetric_backpressure_test");
            issue_ready[0]=0;issue_ready[1]=0;enqueue_dual(0,0);step_cycle("fill two");
            enqueue_dual(0,0);step_cycle("fill four");
            for(i=0;i<12;i=i+1)begin
                issue_ready[0]=i[0];issue_ready[1]=!i[0];
                step_cycle("asymmetric lane ready");
            end
            end_test();
        end
    endtask
    task automatic full_queue_backpressure_test;
        begin full_hold_test(); end
    endtask
    task automatic flush_empty_queue_test;
        begin flush_test("flush_empty_queue_test", 0, 0, 0); end
    endtask
    task automatic flush_single_entry_test;
        begin flush_test("flush_single_entry_test", 1, 0, 0); end
    endtask
    task automatic flush_full_queue_test;
        begin flush_test("flush_full_queue_test", 4, 0, 0); end
    endtask
    task automatic flush_with_enqueue_same_cycle_test;
        begin flush_test("flush_with_enqueue_same_cycle_test", 1, 1, 0); end
    endtask
    task automatic flush_with_dequeue_same_cycle_test;
        begin flush_test("flush_with_dequeue_same_cycle_test", 1, 0, 1); end
    endtask
    task automatic flush_with_dual_enqueue_same_cycle_test;
        begin flush_test("flush_with_dual_enqueue_same_cycle_test", 2, 1, 0); end
    endtask
    task automatic flush_with_dual_dequeue_same_cycle_test;
        begin flush_test("flush_with_dual_dequeue_same_cycle_test", 2, 0, 1); end
    endtask
    task automatic consecutive_flush_test;
        begin begin_reset_test("consecutive_flush_test"); flush=1; step_cycle("flush1"); flush=1; step_cycle("flush2"); end_test(); end
    endtask
    task automatic flush_during_backpressure_test;
        begin output_backpressure_test("flush_during_backpressure_test", 8); flush=1; step_cycle("flush backpressure"); end_test(); end
    endtask
    task automatic flush_near_wraparound_test;
        begin flush_test("flush_near_wraparound_test", 4, 1, 1); end
    endtask
    task automatic older_entries_preserved_test;
        begin current_test="older_entries_preserved_test";record_ambiguity("older_entries_preserved_test skipped: current interface has global flush and no recovery tag"); end
    endtask
    task automatic younger_entries_killed_test;
        begin flush_full_queue_test(); end
    endtask
    task automatic recovery_point_preserved_test;
        begin current_test="recovery_point_preserved_test";record_ambiguity("recovery_point_preserved_test skipped: no recovery-point interface exists"); end
    endtask
    task automatic killed_entry_never_output_test;
        begin flush_full_queue_test(); end
    endtask
    task automatic flush_then_immediate_refill_test;
        begin begin_reset_test("flush_then_immediate_refill_test"); enqueue_dual(0,0); flush=1; step_cycle("flush"); enqueue_dual(0,0); step_cycle("refill"); end_test(); end
    endtask

    task automatic run_directed_tests;
        begin
            reset_with_valid_inputs_test();
            reset_during_nonempty_queue_test();
            repeated_reset_test();
            empty_queue_output_test();
            lane0_only_enqueue_test();
            lane1_only_enqueue_test();
            alternating_lane_enqueue_test();
            single_enqueue_single_dequeue_test();
            enqueue_with_idle_cycles_test();
            dual_enqueue_test();
            dual_enqueue_repeated_test();
            fill_to_full_test();
            full_hold_test();
            lane_order_test();
            input_payload_integrity_test();
            output_lane0_only_ready_test();
            output_lane1_only_ready_test();
            both_output_ready_test();
            alternating_output_ready_test();
            partial_dequeue_test();
            output_order_test();
            full_with_single_dequeue_test();
            full_with_dual_dequeue_test();
            drain_to_empty_test();
            empty_with_single_enqueue_test();
            empty_with_dual_enqueue_test();
            almost_full_dual_enqueue_test();
            almost_empty_dual_dequeue_test();
            simultaneous_single_enqueue_single_dequeue_test();
            simultaneous_dual_enqueue_single_dequeue_test();
            simultaneous_single_enqueue_dual_dequeue_test();
            simultaneous_dual_enqueue_dual_dequeue_test();
            full_simultaneous_enqueue_dequeue_test();
            empty_simultaneous_enqueue_dequeue_test();
            same_cycle_passthrough_test();
            single_wraparound_test();
            multiple_wraparound_test();
            wraparound_with_dual_enqueue_test();
            wraparound_with_dual_dequeue_test();
            wraparound_with_backpressure_test();
            wraparound_with_flush_test();
            wraparound_near_full_test();
            long_output_backpressure_test();
            random_output_backpressure_test();
            lane0_backpressure_test();
            lane1_backpressure_test();
            asymmetric_backpressure_test();
            full_queue_backpressure_test();
            flush_empty_queue_test();
            flush_single_entry_test();
            flush_full_queue_test();
            flush_with_enqueue_same_cycle_test();
            flush_with_dequeue_same_cycle_test();
            flush_with_dual_enqueue_same_cycle_test();
            flush_with_dual_dequeue_same_cycle_test();
            consecutive_flush_test();
            flush_during_backpressure_test();
            flush_near_wraparound_test();
            older_entries_preserved_test();
            younger_entries_killed_test();
            recovery_point_preserved_test();
            killed_entry_never_output_test();
            flush_then_immediate_refill_test();
            barrier_test();
            completion_wakeup_test();
            commit_wakeup_test();
            x0_wakeup_tag0_test();
            non_regwrite_completion_test();
            dual_output_distinct_test();
            lane1_payload_test();
            younger_restricted_issue_test();
        end
    endtask

    task automatic run_selected_test;
        begin
            case (requested_test)
                "reset_with_valid_inputs_test": reset_with_valid_inputs_test();
                "reset_during_nonempty_queue_test": reset_during_nonempty_queue_test();
                "repeated_reset_test": repeated_reset_test();
                "empty_queue_output_test": empty_queue_output_test();
                "lane0_only_enqueue_test": lane0_only_enqueue_test();
                "lane1_only_enqueue_test": lane1_only_enqueue_test();
                "alternating_lane_enqueue_test": alternating_lane_enqueue_test();
                "single_enqueue_single_dequeue_test": single_enqueue_single_dequeue_test();
                "dual_enqueue_test": dual_enqueue_test();
                "dual_enqueue_repeated_test": dual_enqueue_repeated_test();
                "fill_to_full_test": fill_to_full_test();
                "full_hold_test": full_hold_test();
                "lane_order_test": lane_order_test();
                "input_payload_integrity_test": input_payload_integrity_test();
                "output_lane0_only_ready_test": output_lane0_only_ready_test();
                "output_lane1_only_ready_test": output_lane1_only_ready_test();
                "both_output_ready_test": both_output_ready_test();
                "alternating_output_ready_test": alternating_output_ready_test();
                "partial_dequeue_test": partial_dequeue_test();
                "output_order_test": output_order_test();
                "full_with_single_dequeue_test": full_with_single_dequeue_test();
                "full_with_dual_dequeue_test": full_with_dual_dequeue_test();
                "drain_to_empty_test": drain_to_empty_test();
                "empty_with_single_enqueue_test": empty_with_single_enqueue_test();
                "empty_with_dual_enqueue_test": empty_with_dual_enqueue_test();
                "almost_full_dual_enqueue_test": almost_full_dual_enqueue_test();
                "almost_empty_dual_dequeue_test": almost_empty_dual_dequeue_test();
                "simultaneous_single_enqueue_single_dequeue_test": simultaneous_single_enqueue_single_dequeue_test();
                "simultaneous_dual_enqueue_single_dequeue_test": simultaneous_dual_enqueue_single_dequeue_test();
                "simultaneous_single_enqueue_dual_dequeue_test": simultaneous_single_enqueue_dual_dequeue_test();
                "simultaneous_dual_enqueue_dual_dequeue_test": simultaneous_dual_enqueue_dual_dequeue_test();
                "full_simultaneous_enqueue_dequeue_test": full_simultaneous_enqueue_dequeue_test();
                "empty_simultaneous_enqueue_dequeue_test": empty_simultaneous_enqueue_dequeue_test();
                "same_cycle_events_test": same_cycle_events_test();
                "same_cycle_passthrough_test": same_cycle_passthrough_test();
                "wraparound_test": wraparound_test();
                "single_wraparound_test": single_wraparound_test();
                "multiple_wraparound_test": multiple_wraparound_test();
                "wraparound_with_dual_enqueue_test": wraparound_with_dual_enqueue_test();
                "wraparound_with_dual_dequeue_test": wraparound_with_dual_dequeue_test();
                "wraparound_with_backpressure_test": wraparound_with_backpressure_test();
                "wraparound_with_flush_test": wraparound_with_flush_test();
                "wraparound_near_full_test": wraparound_near_full_test();
                "long_output_backpressure_test": long_output_backpressure_test();
                "random_output_backpressure_test": random_output_backpressure_test();
                "lane0_backpressure_test": lane0_backpressure_test();
                "lane1_backpressure_test": lane1_backpressure_test();
                "asymmetric_backpressure_test": asymmetric_backpressure_test();
                "full_queue_backpressure_test": full_queue_backpressure_test();
                "flush_empty_queue_test": flush_empty_queue_test();
                "flush_single_entry_test": flush_single_entry_test();
                "flush_full_queue_test": flush_full_queue_test();
                "flush_with_enqueue_same_cycle_test": flush_with_enqueue_same_cycle_test();
                "flush_with_dequeue_same_cycle_test": flush_with_dequeue_same_cycle_test();
                "flush_with_dual_enqueue_same_cycle_test": flush_with_dual_enqueue_same_cycle_test();
                "flush_with_dual_dequeue_same_cycle_test": flush_with_dual_dequeue_same_cycle_test();
                "consecutive_flush_test": consecutive_flush_test();
                "flush_during_backpressure_test": flush_during_backpressure_test();
                "flush_near_wraparound_test": flush_near_wraparound_test();
                "older_entries_preserved_test": older_entries_preserved_test();
                "younger_entries_killed_test": younger_entries_killed_test();
                "recovery_point_preserved_test": recovery_point_preserved_test();
                "killed_entry_never_output_test": killed_entry_never_output_test();
                "flush_then_immediate_refill_test": flush_then_immediate_refill_test();
                "barrier_test": barrier_test();
                "completion_wakeup_test": completion_wakeup_test();
                "commit_wakeup_test": commit_wakeup_test();
                "x0_wakeup_tag0_test": x0_wakeup_tag0_test();
                "non_regwrite_completion_test": non_regwrite_completion_test();
                "dual_output_distinct_test": dual_output_distinct_test();
                "lane1_payload_test": lane1_payload_test();
                "younger_restricted_issue_test": younger_restricted_issue_test();
                default: begin
                    $display("[DQ-PROTOCOL-FAIL] unknown TEST=%s", requested_test);
                    $fatal(2, "unknown DispatchQueue TEST name");
                end
            endcase
        end
    endtask

    task automatic report_summary;
        integer i;
        real manual_percent;
        real tool_percent;
        integer scoped_hit;
        integer scoped_required;
        real scoped_percent;
        begin
            manual_cov_hit_count = manual_coverage_count();
            manual_percent = 100.0 * manual_cov_hit_count / MANDATORY_COV;
            scoped_hit = scoped_coverage_hit();
            scoped_required = scoped_coverage_required();
            scoped_percent = 100.0 * scoped_hit / scoped_required;
            tool_percent = dq_cg.get_inst_coverage();
            $display("[DQ-SUMMARY] test=%s seed=%0d cycles=%0d enq=%0d deq=%0d flush=%0d wraps=%0d max_occ=%0d",
                     requested_test, random_seed, cycle_no, enq_total, deq_total,
                     flush_total, wrap_total, max_occupancy);
            $display("[DQ-ERRORS] scoreboard=%0d assertion=%0d protocol=%0d timeout=%0d ambiguity=%0d total=%0d",
                     scoreboard_error_count, assertion_error_count, protocol_error_count,
                     timeout_error_count, spec_ambiguity_count, total_error_count);
            $display("[DQ-COVERAGE] scoped=%0d/%0d (%0.2f%%) global_mandatory=%0d/%0d (%0.2f%%) tool=%0.2f%% min=%0d%%",
                     scoped_hit, scoped_required, scoped_percent,
                     manual_cov_hit_count, MANDATORY_COV, manual_percent,
                     tool_percent, min_coverage);
            if (full_suite_scope())
                for (i = 0; i < MANDATORY_COV; i = i + 1)
                    if (!mandatory_hit[i]) $display("[DQ-COVER-MISS] point=%0d", i);
            if (scoped_hit < scoped_required || scoped_percent < min_coverage)
                $display("[DQ-COVER-FAIL] mandatory scenarios or MIN_COVERAGE threshold not met");
            if (scoreboard_error_count == 0 && assertion_error_count == 0 &&
                protocol_error_count == 0 && timeout_error_count == 0 &&
                scoped_hit == scoped_required && scoped_percent >= min_coverage)
                $display("[DQ-PASS] DispatchQueue abstract-behavior verification passed; ambiguity reports=%0d", spec_ambiguity_count);
            else
                $display("[DQ-FAILURES] DispatchQueue verification failed; DUT or protocol issue requires review");
        end
    endtask

    property p_occupancy_bound;
        @(posedge clk) disable iff (!rstn) $unsigned(occupancy) <= DEPTH;
    endproperty
    a_occupancy_bound: assert property (p_occupancy_bound)
        else record_assertion_error("SVA occupancy bound");

    property p_empty_no_issue;
        @(posedge clk) disable iff (!rstn) (occupancy == 0) |-> !issue_valid[0] && !issue_valid[1];
    endproperty
    a_empty_no_issue: assert property (p_empty_no_issue)
        else record_assertion_error("SVA empty queue produced issue valid");

    property p_full_no_capacity;
        @(posedge clk) disable iff (!rstn) (occupancy == DEPTH) |-> !enq_ready[0] && !enq_ready[1];
    endproperty
    a_full_no_capacity: assert property (p_full_no_capacity)
        else record_assertion_error("SVA full queue exposed enqueue ready");

    property p_output0_stable;
        @(posedge clk) disable iff (!rstn || flush)
            (issue_valid[0] && !issue_ready[0]) |=> issue_valid[0] && $stable(issue[0]);
    endproperty
    a_output0_stable: assert property (p_output0_stable)
        else record_assertion_error("SVA issue lane0 valid&&!ready payload instability");

    property p_output1_stable;
        @(posedge clk) disable iff (!rstn || flush)
            (issue_valid[1] && !issue_ready[1]) |=> issue_valid[1] && $stable(issue[1]);
    endproperty
    a_output1_stable: assert property (p_output1_stable)
        else record_assertion_error("SVA issue lane1 valid&&!ready payload instability");

    property p_dual_issue_distinct;
        @(posedge clk) disable iff (!rstn || flush)
            (issue_valid[0] && issue_ready[0] && issue_valid[1] && issue_ready[1]) |->
            (issue[0].pc != issue[1].pc);
    endproperty
    a_dual_issue_distinct: assert property (p_dual_issue_distinct)
        else record_assertion_error("SVA simultaneous issue handshakes are not distinct");

    property p_no_x_issue;
        @(posedge clk) disable iff (!rstn)
            issue_valid[0] |-> !$isunknown(issue[0]);
    endproperty
    a_no_x_issue: assert property (p_no_x_issue)
        else record_assertion_error("SVA issue lane0 contains X/Z");

    initial begin
        integer i;
        global_finished = 1'b0;
        random_seed = 1;
        random_cycles = 1000;
        min_coverage = 90;
        stop_on_error_arg = 0;
        strict_ambiguity_arg = 0;
        requested_test = "all";
        i = $value$plusargs("SEED=%d", random_seed);
        i = $value$plusargs("CYCLES=%d", random_cycles);
        i = $value$plusargs("MIN_COVERAGE=%d", min_coverage);
        i = $value$plusargs("STOP_ON_ERROR=%d", stop_on_error_arg);
        i = $value$plusargs("STRICT_AMBIGUITY=%d", strict_ambiguity_arg);
        i = $value$plusargs("TEST=%s", requested_test);
        // Full suites, including random-only regressions, must close manual
        // mandatory coverage.  A named single test reports diagnostic
        // coverage but is not misrepresented as a full-suite closure run.
        coverage_gate = (requested_test == "all") ||
                        (requested_test == "directed") ||
                        (requested_test == "random");
        selected_test_completed = 1'b0;
        rng = random_seed;
        rng_state = random_seed;
        cycle_no = 0;
        packet_id = 1;
        next_seq_id = 1;
        scoreboard_error_count = 0;
        assertion_error_count = 0;
        protocol_error_count = 0;
        timeout_error_count = 0;
        spec_ambiguity_count = 0;
        total_error_count = 0;
        enq_total = 0;
        deq_total = 0;
        flush_total = 0;
        wrap_total = 0;
        max_occupancy = 0;
        max_gap_cycles = 0;
        history_ptr = 0;
        last_handshake_time = 0;
        for (i = 0; i < HISTORY_DEPTH; i = i + 1) begin
            history_valid[i] = 1'b0;
            history[i] = "";
        end
        for (i = 0; i < MANDATORY_COV; i = i + 1)
            mandatory_hit[i] = 1'b0;
        clear_all_inputs();
        rstn = 1'b0;
        reset_ref_state();
        repeat (3) @(posedge clk);
        @(negedge clk);
        rstn = 1'b1;

        if (requested_test == "random")
            random_test();
        else if (requested_test == "directed" || requested_test == "all")
            run_directed_tests();
        else begin
            run_selected_test();
            selected_test_completed = 1'b1;
        end
        global_finished = 1'b1;
        report_summary();
        if (total_error_count != 0 || scoped_coverage_hit() < scoped_coverage_required() ||
            (100 * scoped_coverage_hit() / scoped_coverage_required()) < min_coverage)
            $finish(2);
        else
            $finish(0);
    end

    initial begin
        #GLOBAL_TIMEOUT_NS;
        if (!global_finished) begin
            timeout_error_count = timeout_error_count + 1;
            total_error_count = total_error_count + 1;
            $display("[DQ-WATCHDOG] global timeout seed=%0d cycle=%0d", random_seed, cycle_no);
            $finish(2);
        end
    end
endmodule
