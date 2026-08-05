`timescale 1ns / 1ps

// Simulation-only BTB/BTFNT diagnostics.  No output from this module feeds
// CPU control, ready/valid, prediction, recovery, or cache behavior.
module BtbDiagnostics (
    input logic        clk,
    input logic        rstn,
    input logic        branch_fire,
    input logic [31:0] branch_pc,
    input logic        branch_btb_hit,
    input logic        branch_conditional,
    input logic        branch_backward,
    input logic        branch_jirl,
    input logic        predicted_taken,
    input logic        actual_taken,
    input logic        direction_mispredict,
    input logic        target_mispredict,
    input logic        btb_update,
    input logic        btb_update_conditional,
    input logic        btb_update_backward,
    input logic        commit0_valid,
    input logic        commit1_valid,
    input logic        issue0_fire,
    input logic        issue1_fire,
    input logic        system_issue_fire,
    input logic        recovery
);
`ifndef SYNTHESIS
    localparam integer DIAG_CYCLES = 99999;
    localparam integer WINDOW_SPLIT = 50000;
    localparam integer PC_TABLE_SIZE = 512;

    logic [63:0] cycles;
    logic diag_printed;
    logic recovery_penalty_active;

    logic [63:0] branch_resolve_count;
    logic [63:0] branch_resolve_btb_hit;
    logic [63:0] branch_resolve_btb_miss;
    logic [63:0] conditional_branch_count;
    logic [63:0] conditional_btb_hit;
    logic [63:0] conditional_btb_miss;
    logic [63:0] backward_conditional_count;
    logic [63:0] backward_conditional_btb_hit;
    logic [63:0] backward_conditional_btb_miss;
    logic [63:0] forward_conditional_count;
    logic [63:0] forward_conditional_btb_hit;
    logic [63:0] forward_conditional_btb_miss;
    logic [63:0] unconditional_branch_count;
    logic [63:0] unconditional_btb_hit;
    logic [63:0] jirl_count;
    logic [63:0] jirl_btb_hit;

    logic [63:0] btb_hit_pred_taken;
    logic [63:0] btb_hit_pred_not_taken;
    logic [63:0] btb_miss_pred_taken;
    logic [63:0] btb_miss_pred_not_taken;
    logic [63:0] predicted_taken_count;
    logic [63:0] taken_count;
    logic [63:0] mispredict_count;
    logic [63:0] pred_nt_actual_nt;
    logic [63:0] pred_nt_actual_t;
    logic [63:0] pred_t_actual_nt;
    logic [63:0] pred_t_actual_t;

    logic [63:0] direction_mispredict_count;
    logic [63:0] target_mispredict_count;
    logic [63:0] both_direction_and_target_mispredict_count;
    logic [63:0] correct_not_taken;
    logic [63:0] correct_taken_target;
    logic [63:0] direction_miss;
    logic [63:0] target_miss;

    logic [63:0] btb_update_count;
    logic [63:0] btb_update_conditional_count;
    logic [63:0] btb_update_backward_count;

    logic [63:0] unique_branch_pc_count;
    logic [63:0] unique_conditional_branch_pc_count;
    logic [63:0] unique_backward_branch_pc_count;
    logic [63:0] pc_table_overflow_count;
    logic pc_table_overflow_warned;

    logic pc_valid [0:PC_TABLE_SIZE-1];
    logic [31:0] pc_key [0:PC_TABLE_SIZE-1];
    logic [63:0] pc_dynamic [0:PC_TABLE_SIZE-1];
    logic [63:0] pc_taken [0:PC_TABLE_SIZE-1];
    logic [63:0] pc_hit [0:PC_TABLE_SIZE-1];
    logic [63:0] pc_pred_taken [0:PC_TABLE_SIZE-1];
    logic [63:0] pc_mispredict [0:PC_TABLE_SIZE-1];

    logic pc_match_found;
    logic pc_free_found;
    integer pc_match_index;
    integer pc_free_index;
    integer scan_i;

    typedef struct packed {
        logic [63:0] cycles;
        logic [63:0] branch_count;
        logic [63:0] taken_count;
        logic [63:0] predicted_taken_count;
        logic [63:0] mispredict_count;
        logic [63:0] pred_nt_actual_nt;
        logic [63:0] pred_nt_actual_t;
        logic [63:0] pred_t_actual_nt;
        logic [63:0] pred_t_actual_t;
        logic [63:0] btb_hit;
        logic [63:0] btb_miss;
        logic [63:0] backward_count;
        logic [63:0] backward_hit;
        logic [63:0] direction_miss;
        logic [63:0] target_miss;
        logic [63:0] retired_uops;
        logic [63:0] recovery_loss_cycles;
    } window_t;
    window_t window [0:1];

    wire any_issue = issue0_fire | issue1_fire | system_issue_fire;
    wire recovery_loss_cycle = recovery_penalty_active & !any_issue;
    wire diag_branch_fire = branch_fire && (cycles < DIAG_CYCLES);
    wire diag_update_fire = btb_update && (cycles < DIAG_CYCLES);

    wire [63:0] branch_resolve_count_next = branch_resolve_count + diag_branch_fire;
    wire [63:0] branch_resolve_btb_hit_next = branch_resolve_btb_hit +
                                               (diag_branch_fire && branch_btb_hit);
    wire [63:0] branch_resolve_btb_miss_next = branch_resolve_btb_miss +
                                                (diag_branch_fire && !branch_btb_hit);
    wire [63:0] conditional_branch_count_next = conditional_branch_count +
                                                (diag_branch_fire && branch_conditional);
    wire [63:0] conditional_btb_hit_next = conditional_btb_hit +
        (diag_branch_fire && branch_conditional && branch_btb_hit);
    wire [63:0] conditional_btb_miss_next = conditional_btb_miss +
        (diag_branch_fire && branch_conditional && !branch_btb_hit);
    wire [63:0] backward_conditional_count_next = backward_conditional_count +
        (diag_branch_fire && branch_backward);
    wire [63:0] backward_conditional_btb_hit_next = backward_conditional_btb_hit +
        (diag_branch_fire && branch_backward && branch_btb_hit);
    wire [63:0] backward_conditional_btb_miss_next = backward_conditional_btb_miss +
        (diag_branch_fire && branch_backward && !branch_btb_hit);

    wire [63:0] pred_nt_actual_nt_next = pred_nt_actual_nt +
        (diag_branch_fire && !predicted_taken && !actual_taken);
    wire [63:0] pred_nt_actual_t_next = pred_nt_actual_t +
        (diag_branch_fire && !predicted_taken && actual_taken);
    wire [63:0] pred_t_actual_nt_next = pred_t_actual_nt +
        (diag_branch_fire && predicted_taken && !actual_taken);
    wire [63:0] pred_t_actual_t_next = pred_t_actual_t +
        (diag_branch_fire && predicted_taken && actual_taken);
    wire [63:0] mispredict_count_next = mispredict_count +
        (diag_branch_fire && direction_mispredict);
    wire [63:0] btb_hit_pred_taken_next = btb_hit_pred_taken +
        (diag_branch_fire && branch_btb_hit && predicted_taken);
    wire [63:0] btb_hit_pred_not_taken_next = btb_hit_pred_not_taken +
        (diag_branch_fire && branch_btb_hit && !predicted_taken);
    wire [63:0] btb_miss_pred_taken_next = btb_miss_pred_taken +
        (diag_branch_fire && !branch_btb_hit && predicted_taken);
    wire [63:0] btb_miss_pred_not_taken_next = btb_miss_pred_not_taken +
        (diag_branch_fire && !branch_btb_hit && !predicted_taken);

    wire [63:0] correct_not_taken_next = correct_not_taken +
        (diag_branch_fire && !predicted_taken && !actual_taken);
    wire [63:0] correct_taken_target_next = correct_taken_target +
        (diag_branch_fire && predicted_taken && actual_taken &&
         !target_mispredict);
    wire [63:0] direction_miss_next = direction_miss +
        (diag_branch_fire && direction_mispredict);
    wire [63:0] target_miss_next = target_miss +
        (diag_branch_fire && target_mispredict);

    function automatic real pct(input logic [63:0] n, input logic [63:0] d);
        begin
            pct = (d == 0) ? 0.0 : (100.0 * real'(n) / real'(d));
        end
    endfunction

    function automatic real ratio(input logic [63:0] n, input logic [63:0] d);
        begin
            ratio = (d == 0) ? 0.0 : (real'(n) / real'(d));
        end
    endfunction

    always_comb begin
        pc_match_found = 1'b0;
        pc_free_found = 1'b0;
        pc_match_index = 0;
        pc_free_index = 0;
        for (scan_i = 0; scan_i < PC_TABLE_SIZE; scan_i = scan_i + 1) begin
            if (!pc_match_found && pc_valid[scan_i] &&
                (pc_key[scan_i] == branch_pc)) begin
                pc_match_found = 1'b1;
                pc_match_index = scan_i;
            end
            if (!pc_free_found && !pc_valid[scan_i]) begin
                pc_free_found = 1'b1;
                pc_free_index = scan_i;
            end
        end
    end

    task automatic update_window(input integer w);
        begin
            window[w].cycles <= window[w].cycles + 1;
            window[w].retired_uops <= window[w].retired_uops +
                                      commit0_valid + commit1_valid;
            if (recovery_loss_cycle)
                window[w].recovery_loss_cycles <=
                    window[w].recovery_loss_cycles + 1;
            if (branch_fire) begin
                window[w].branch_count <= window[w].branch_count + 1;
                window[w].taken_count <= window[w].taken_count + actual_taken;
                window[w].predicted_taken_count <=
                    window[w].predicted_taken_count + predicted_taken;
                window[w].mispredict_count <= window[w].mispredict_count +
                                               direction_mispredict;
                window[w].pred_nt_actual_nt <= window[w].pred_nt_actual_nt +
                    (!predicted_taken && !actual_taken);
                window[w].pred_nt_actual_t <= window[w].pred_nt_actual_t +
                    (!predicted_taken && actual_taken);
                window[w].pred_t_actual_nt <= window[w].pred_t_actual_nt +
                    (predicted_taken && !actual_taken);
                window[w].pred_t_actual_t <= window[w].pred_t_actual_t +
                    (predicted_taken && actual_taken);
                window[w].btb_hit <= window[w].btb_hit + branch_btb_hit;
                window[w].btb_miss <= window[w].btb_miss + !branch_btb_hit;
                window[w].backward_count <= window[w].backward_count +
                                             branch_backward;
                window[w].backward_hit <= window[w].backward_hit +
                                           (branch_backward && branch_btb_hit);
                window[w].direction_miss <= window[w].direction_miss +
                                             direction_mispredict;
                window[w].target_miss <= window[w].target_miss +
                                          target_mispredict;
            end
        end
    endtask

    task automatic print_top_branch_pcs;
        integer selected [0:7];
        integer rank;
        integer i;
        integer j;
        integer best;
        logic already_selected;
        begin
            for (rank = 0; rank < 8; rank = rank + 1)
                selected[rank] = -1;
            $display("top_branch_pcs:");
            for (rank = 0; rank < 8; rank = rank + 1) begin
                best = -1;
                for (i = 0; i < PC_TABLE_SIZE; i = i + 1) begin
                    already_selected = 1'b0;
                    for (j = 0; j < rank; j = j + 1)
                        if (selected[j] == i)
                            already_selected = 1'b1;
                    if (pc_valid[i] && !already_selected &&
                        ((best < 0) || (pc_dynamic[i] > pc_dynamic[best])))
                        best = i;
                end
                selected[rank] = best;
                if (best >= 0)
                    $display("pc=%08h dynamic=%0d taken=%0d hit=%0d pred_taken=%0d miss=%0d",
                             pc_key[best], pc_dynamic[best], pc_taken[best],
                             pc_hit[best], pc_pred_taken[best],
                             pc_mispredict[best]);
            end
        end
    endtask

    task automatic print_window(input integer w, input string name);
        begin
            $display("%s:", name);
            $display("cycles=%0d", window[w].cycles);
            $display("branches=%0d taken=%0d predicted_taken=%0d mispredict=%0d",
                     window[w].branch_count, window[w].taken_count,
                     window[w].predicted_taken_count,
                     window[w].mispredict_count);
            $display("pred_nt_actual_nt=%0d pred_nt_actual_t=%0d pred_t_actual_nt=%0d pred_t_actual_t=%0d",
                     window[w].pred_nt_actual_nt, window[w].pred_nt_actual_t,
                     window[w].pred_t_actual_nt, window[w].pred_t_actual_t);
            $display("btb_hit=%0d btb_miss=%0d btb_hit_rate=%.2f%%",
                     window[w].btb_hit, window[w].btb_miss,
                     pct(window[w].btb_hit, window[w].branch_count));
            $display("backward_conditional=%0d backward_btb_hit=%0d",
                     window[w].backward_count, window[w].backward_hit);
            $display("direction_mispredict=%0d target_mispredict=%0d mispredict_rate=%.2f%%",
                     window[w].direction_miss, window[w].target_miss,
                     pct(window[w].mispredict_count, window[w].branch_count));
            $display("retired_uops=%0d retire_ipc=%.4f recovery_loss_cycles=%0d",
                     window[w].retired_uops,
                     ratio(window[w].retired_uops, window[w].cycles),
                     window[w].recovery_loss_cycles);
        end
    endtask

    task automatic print_diag;
        begin
            $display("[BTB-DIAG-BEGIN]");
            $display("cycles=%0d", DIAG_CYCLES);
            $display("branch_resolve_count=%0d", branch_resolve_count);
            $display("unique_branch_pc_count=%0d", unique_branch_pc_count);
            $display("unique_conditional_branch_pc_count=%0d", unique_conditional_branch_pc_count);
            $display("unique_backward_branch_pc_count=%0d", unique_backward_branch_pc_count);
            $display("dynamic_per_unique=%.4f", ratio(branch_resolve_count,
                                                       unique_branch_pc_count));
            $display("pc_table_overflow_count=%0d", pc_table_overflow_count);
            $display("btb:");
            $display("resolve_hit=%0d resolve_miss=%0d resolve_hit_rate=%.2f%%",
                     branch_resolve_btb_hit, branch_resolve_btb_miss,
                     pct(branch_resolve_btb_hit, branch_resolve_count));
            $display("conditional:");
            $display("count=%0d hit=%0d miss=%0d hit_rate=%.2f%%",
                     conditional_branch_count, conditional_btb_hit,
                     conditional_btb_miss,
                     pct(conditional_btb_hit, conditional_branch_count));
            $display("backward_conditional:");
            $display("count=%0d hit=%0d miss=%0d hit_rate=%.2f%%",
                     backward_conditional_count,
                     backward_conditional_btb_hit,
                     backward_conditional_btb_miss,
                     pct(backward_conditional_btb_hit,
                         backward_conditional_count));
            $display("forward_conditional:");
            $display("count=%0d hit=%0d miss=%0d hit_rate=%.2f%%",
                     forward_conditional_count, forward_conditional_btb_hit,
                     forward_conditional_btb_miss,
                     pct(forward_conditional_btb_hit,
                         forward_conditional_count));
            $display("unconditional_count=%0d unconditional_hit=%0d jirl_count=%0d jirl_hit=%0d",
                     unconditional_branch_count, unconditional_btb_hit,
                     jirl_count, jirl_btb_hit);
            $display("prediction:");
            $display("pred_taken=%0d pred_not_taken=%0d",
                     predicted_taken_count,
                     branch_resolve_count - predicted_taken_count);
            $display("btb_hit_pred_taken=%0d btb_hit_pred_not_taken=%0d",
                     btb_hit_pred_taken, btb_hit_pred_not_taken);
            $display("btb_miss_pred_taken=%0d btb_miss_pred_not_taken=%0d",
                     btb_miss_pred_taken, btb_miss_pred_not_taken);
            $display("correct_not_taken=%0d correct_taken_target=%0d direction_miss=%0d target_miss=%0d",
                     correct_not_taken, correct_taken_target,
                     direction_miss, target_miss);
            $display("both_direction_and_target_mispredict_count=%0d",
                     both_direction_and_target_mispredict_count);
            $display("pred_nt_actual_nt=%0d pred_nt_actual_t=%0d pred_t_actual_nt=%0d pred_t_actual_t=%0d",
                     pred_nt_actual_nt, pred_nt_actual_t,
                     pred_t_actual_nt, pred_t_actual_t);
            $display("update:");
            $display("btb_update_count=%0d conditional_update=%0d backward_update=%0d",
                     btb_update_count, btb_update_conditional_count,
                     btb_update_backward_count);
            print_window(0, "window_a");
            print_window(1, "window_b");
            print_top_branch_pcs();
            $display("[BTB-DIAG-END]");
        end
    endtask

    integer reset_i;
    always_ff @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            cycles <= 0;
            diag_printed <= 1'b0;
            recovery_penalty_active <= 1'b0;
            branch_resolve_count <= 0;
            branch_resolve_btb_hit <= 0;
            branch_resolve_btb_miss <= 0;
            conditional_branch_count <= 0;
            conditional_btb_hit <= 0;
            conditional_btb_miss <= 0;
            backward_conditional_count <= 0;
            backward_conditional_btb_hit <= 0;
            backward_conditional_btb_miss <= 0;
            forward_conditional_count <= 0;
            forward_conditional_btb_hit <= 0;
            forward_conditional_btb_miss <= 0;
            unconditional_branch_count <= 0;
            unconditional_btb_hit <= 0;
            jirl_count <= 0;
            jirl_btb_hit <= 0;
            btb_hit_pred_taken <= 0;
            btb_hit_pred_not_taken <= 0;
            btb_miss_pred_taken <= 0;
            btb_miss_pred_not_taken <= 0;
            predicted_taken_count <= 0;
            taken_count <= 0;
            mispredict_count <= 0;
            pred_nt_actual_nt <= 0;
            pred_nt_actual_t <= 0;
            pred_t_actual_nt <= 0;
            pred_t_actual_t <= 0;
            direction_mispredict_count <= 0;
            target_mispredict_count <= 0;
            both_direction_and_target_mispredict_count <= 0;
            correct_not_taken <= 0;
            correct_taken_target <= 0;
            direction_miss <= 0;
            target_miss <= 0;
            btb_update_count <= 0;
            btb_update_conditional_count <= 0;
            btb_update_backward_count <= 0;
            unique_branch_pc_count <= 0;
            unique_conditional_branch_pc_count <= 0;
            unique_backward_branch_pc_count <= 0;
            pc_table_overflow_count <= 0;
            pc_table_overflow_warned <= 1'b0;
            window[0] <= '0;
            window[1] <= '0;
            for (reset_i = 0; reset_i < PC_TABLE_SIZE; reset_i = reset_i + 1) begin
                pc_valid[reset_i] <= 1'b0;
                pc_key[reset_i] <= 32'h0;
                pc_dynamic[reset_i] <= 0;
                pc_taken[reset_i] <= 0;
                pc_hit[reset_i] <= 0;
                pc_pred_taken[reset_i] <= 0;
                pc_mispredict[reset_i] <= 0;
            end
        end else begin
            cycles <= cycles + 1;

            if (recovery)
                recovery_penalty_active <= 1'b1;
            else if (any_issue)
                recovery_penalty_active <= 1'b0;

            if (cycles < WINDOW_SPLIT)
                update_window(0);
            else if (cycles < DIAG_CYCLES)
                update_window(1);

            if (diag_update_fire) begin
                btb_update_count <= btb_update_count + 1;
                btb_update_conditional_count <= btb_update_conditional_count +
                                                 btb_update_conditional;
                btb_update_backward_count <= btb_update_backward_count +
                                              btb_update_backward;
            end

            if (diag_branch_fire) begin
                branch_resolve_count <= branch_resolve_count_next;
                branch_resolve_btb_hit <= branch_resolve_btb_hit_next;
                branch_resolve_btb_miss <= branch_resolve_btb_miss_next;
                conditional_branch_count <= conditional_branch_count_next;
                conditional_btb_hit <= conditional_btb_hit_next;
                conditional_btb_miss <= conditional_btb_miss_next;
                backward_conditional_count <= backward_conditional_count_next;
                backward_conditional_btb_hit <= backward_conditional_btb_hit_next;
                backward_conditional_btb_miss <= backward_conditional_btb_miss_next;
                forward_conditional_count <= forward_conditional_count +
                    (branch_conditional && !branch_backward);
                forward_conditional_btb_hit <= forward_conditional_btb_hit +
                    (branch_conditional && !branch_backward && branch_btb_hit);
                forward_conditional_btb_miss <= forward_conditional_btb_miss +
                    (branch_conditional && !branch_backward && !branch_btb_hit);
                unconditional_branch_count <= unconditional_branch_count +
                                               !branch_conditional;
                unconditional_btb_hit <= unconditional_btb_hit +
                    (!branch_conditional && branch_btb_hit);
                jirl_count <= jirl_count + branch_jirl;
                jirl_btb_hit <= jirl_btb_hit + (branch_jirl && branch_btb_hit);
                btb_hit_pred_taken <= btb_hit_pred_taken_next;
                btb_hit_pred_not_taken <= btb_hit_pred_not_taken_next;
                btb_miss_pred_taken <= btb_miss_pred_taken_next;
                btb_miss_pred_not_taken <= btb_miss_pred_not_taken_next;
                predicted_taken_count <= predicted_taken_count + predicted_taken;
                taken_count <= taken_count + actual_taken;
                mispredict_count <= mispredict_count_next;
                pred_nt_actual_nt <= pred_nt_actual_nt_next;
                pred_nt_actual_t <= pred_nt_actual_t_next;
                pred_t_actual_nt <= pred_t_actual_nt_next;
                pred_t_actual_t <= pred_t_actual_t_next;
                direction_mispredict_count <= direction_mispredict_count +
                                               direction_mispredict;
                target_mispredict_count <= target_mispredict_count +
                                            target_mispredict;
                both_direction_and_target_mispredict_count <=
                    both_direction_and_target_mispredict_count +
                    (direction_mispredict && target_mispredict);
                correct_not_taken <= correct_not_taken_next;
                correct_taken_target <= correct_taken_target_next;
                direction_miss <= direction_miss_next;
                target_miss <= target_miss_next;

                if (pc_match_found) begin
                    pc_dynamic[pc_match_index] <= pc_dynamic[pc_match_index] + 1;
                    pc_taken[pc_match_index] <= pc_taken[pc_match_index] + actual_taken;
                    pc_hit[pc_match_index] <= pc_hit[pc_match_index] + branch_btb_hit;
                    pc_pred_taken[pc_match_index] <= pc_pred_taken[pc_match_index] +
                                                     predicted_taken;
                    pc_mispredict[pc_match_index] <= pc_mispredict[pc_match_index] +
                                                     direction_mispredict +
                                                     target_mispredict;
                end else if (pc_free_found) begin
                    pc_valid[pc_free_index] <= 1'b1;
                    pc_key[pc_free_index] <= branch_pc;
                    pc_dynamic[pc_free_index] <= 1;
                    pc_taken[pc_free_index] <= actual_taken;
                    pc_hit[pc_free_index] <= branch_btb_hit;
                    pc_pred_taken[pc_free_index] <= predicted_taken;
                    pc_mispredict[pc_free_index] <= direction_mispredict +
                                                    target_mispredict;
                    unique_branch_pc_count <= unique_branch_pc_count + 1;
                    unique_conditional_branch_pc_count <=
                        unique_conditional_branch_pc_count + branch_conditional;
                    unique_backward_branch_pc_count <=
                        unique_backward_branch_pc_count + branch_backward;
                end else begin
                    pc_table_overflow_count <= pc_table_overflow_count + 1;
                    if (!pc_table_overflow_warned) begin
                        $warning("BTB diagnostic PC table full; subsequent new PCs counted in overflow_count");
                        pc_table_overflow_warned <= 1'b1;
                    end
                end

                // All equations use next values including this resolve edge.
                if (branch_resolve_count_next !=
                    branch_resolve_btb_hit_next + branch_resolve_btb_miss_next)
                    $fatal(1, "BTB diag branch hit/miss conservation failed");
                if (conditional_branch_count_next !=
                    conditional_btb_hit_next + conditional_btb_miss_next)
                    $fatal(1, "BTB diag conditional hit/miss conservation failed");
                if (backward_conditional_count_next !=
                    backward_conditional_btb_hit_next +
                    backward_conditional_btb_miss_next)
                    $fatal(1, "BTB diag backward hit/miss conservation failed");
                if (branch_resolve_count_next !=
                    pred_nt_actual_nt_next + pred_nt_actual_t_next +
                    pred_t_actual_nt_next + pred_t_actual_t_next)
                    $fatal(1, "BTB diag prediction quadrant conservation failed");
                if (mispredict_count_next !=
                    pred_nt_actual_t_next + pred_t_actual_nt_next)
                    $fatal(1, "BTB diag direction-mispredict conservation failed");
                if (branch_resolve_count_next !=
                    correct_not_taken_next + correct_taken_target_next +
                    direction_miss_next + target_miss_next)
                    $fatal(1, "BTB diag outcome classification conservation failed");
                if (btb_hit_pred_taken_next + btb_hit_pred_not_taken_next !=
                    branch_resolve_btb_hit_next)
                    $fatal(1, "BTB diag hit prediction conservation failed");
                if (btb_miss_pred_taken_next + btb_miss_pred_not_taken_next !=
                    branch_resolve_btb_miss_next)
                    $fatal(1, "BTB diag miss prediction conservation failed");
                if (btb_miss_pred_taken_next != 0)
                    $fatal(1,
                           "BTB miss predicted taken: pc=%08h pred_taken=%0b fetch_btb_hit=%0b",
                           branch_pc, predicted_taken, branch_btb_hit);
                if (direction_mispredict && target_mispredict)
                    $fatal(1, "direction and target miss classifications overlap");
            end

            if ((cycles == DIAG_CYCLES) && !diag_printed) begin
                print_diag();
                diag_printed <= 1'b1;
            end
        end
    end
`endif
endmodule
