`timescale 1ns / 1ps

`include "defines.vh"

import cpu_types_pkg::*;

// In-order retirement buffer. Lane 0 is older and lane 1 is the
// next consecutive entry; both are represented as arrays at the boundary.
module ReorderBuffer (
    input  logic                    clk,
    input  logic                    rstn,

    input  logic [1:0]              alloc_valid,
    output logic [1:0]              alloc_ready,
    output uop_id_t                 alloc_id [0:1],
    input  issue_uop_t              alloc_uop [0:1],

    input  completion_t              complete [0:1],

    input  logic                    recover_valid,
    input  uop_id_t                 recover_id,

    output commit_t                 commit [0:1],

    input  uop_id_t                 query_id [0:3],
    output logic                    query_done [0:3],
    output logic [31:0]             query_value [0:3],

    output logic [`ROB_DEPTH-1:0]   live_mask,
    output uop_id_t                 head_id,
    output logic [`ROB_TAG_W:0]     occupancy
);

    reg [`ROB_DEPTH-1:0] valid;
    reg [`ROB_DEPTH-1:0] done;
    reg [31:0] pc [0:`ROB_DEPTH-1];
    reg        has_dest [0:`ROB_DEPTH-1];
    reg        result_we [0:`ROB_DEPTH-1];
    reg [4:0]  rd [0:`ROB_DEPTH-1];
    reg [31:0] value [0:`ROB_DEPTH-1];
    reg [`UOP_EPOCH_W-1:0] epoch [0:`ROB_DEPTH-1];

    reg [`ROB_TAG_W-1:0] head;
    reg [`ROB_TAG_W-1:0] tail;
    reg [`UOP_EPOCH_W-1:0] tail_epoch;
    reg [`ROB_TAG_W:0] count;
    integer i;

    function [`ROB_TAG_W-1:0] tag_distance;
        input [`ROB_TAG_W-1:0] newer_tag;
        input [`ROB_TAG_W-1:0] older_tag;
        begin
            tag_distance = newer_tag - older_tag;
        end
    endfunction

    wire [`ROB_TAG_W-1:0] head1 = head +
                                   {{(`ROB_TAG_W-1){1'b0}}, 1'b1};

    genvar q;
    generate
        for (q = 0; q < 4; q = q + 1) begin : GEN_QUERY
            // Rename observes only registered ROB completion state.  A
            // same-cycle completion/dispatch collision is recovered by the
            // scheduler's local registered wakeup packet, avoiding a global
            // completion -> ROB query -> dispatch-ready combinational path.
            assign query_done[q] = valid[query_id[q].rob_tag] &&
                                    (epoch[query_id[q].rob_tag] == query_id[q].epoch) &&
                                    done[query_id[q].rob_tag] &&
                                    result_we[query_id[q].rob_tag];
            assign query_value[q] = value[query_id[q].rob_tag];
        end
    endgenerate

    wire [`ROB_TAG_W-1:0] recover_distance =
        tag_distance(recover_id.rob_tag, head);
    wire recover_match = valid[recover_id.rob_tag] &&
                         (epoch[recover_id.rob_tag] == recover_id.epoch);
    wire head1_in_recovery = !recover_valid ||
                             (tag_distance(head1, head) <= recover_distance);
    // Retirement observes only registered ROB state.  A completion first
    // records done/value/result_we at this edge and becomes eligible to
    // retire on the following cycle.  This deliberately removes the long
    // completion -> commit -> wakeup/ready combinational path.
    wire commit0_valid = valid[head] && done[head];
    wire commit1_valid = (count > {{`ROB_TAG_W{1'b0}}, 1'b1}) &&
                         valid[head1] &&
                         done[head1] &&
                         commit0_valid && head1_in_recovery;
    wire alloc0_fire = alloc_valid[0] && alloc_ready[0];
    wire alloc1_fire = alloc_valid[1] && alloc_ready[1];

    // Recovery has priority over allocation in the sequential state update.
    // Reflect that priority at the ready/valid boundary so a source cannot
    // observe a false allocation fire in the recovery cycle.
    // Retirement and allocation share an edge.  Include the entries retired
    // on that edge in the advertised space so a full ROB need not insert a
    // bubble before reusing its head slot.  Allocation writes occur after the
    // retirement clears in the sequential block, so a reused slot remains
    // valid with the new epoch/tag payload.
    wire [`ROB_TAG_W:0] free_after_commit =
        `ROB_DEPTH - count + commit0_valid + commit1_valid;
    assign alloc_ready[0] = !recover_valid && (free_after_commit >= 1);
    assign alloc_ready[1] = !recover_valid && (free_after_commit >= 2);
    assign alloc_id[0].rob_tag = tail;
    assign alloc_id[0].epoch = tail_epoch;
    assign alloc_id[1].rob_tag = tail + {{(`ROB_TAG_W-1){1'b0}}, 1'b1};
    assign alloc_id[1].epoch = tail_epoch + (tail == {`ROB_TAG_W{1'b1}});

    assign commit[0].valid = commit0_valid;
    assign commit[0].uop_id.rob_tag = head;
    assign commit[0].uop_id.epoch = epoch[head];
    assign commit[0].pc = pc[head];
    assign commit[0].has_dest = has_dest[head];
    assign commit[0].reg_write = result_we[head];
    assign commit[0].arch_rd = rd[head];
    assign commit[0].value = value[head];
    assign head_id.rob_tag = head;
    assign head_id.epoch = epoch[head];

    assign commit[1].valid = commit1_valid;
    assign commit[1].uop_id.rob_tag = head1;
    assign commit[1].uop_id.epoch = epoch[head1];
    assign commit[1].pc = pc[head1];
    assign commit[1].has_dest = has_dest[head1];
    assign commit[1].reg_write = result_we[head1];
    assign commit[1].arch_rd = rd[head1];
    assign commit[1].value = value[head1];

    assign live_mask = valid;
    assign occupancy = count;

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            valid <= {`ROB_DEPTH{1'b0}};
            done  <= {`ROB_DEPTH{1'b0}};
            head  <= {`ROB_TAG_W{1'b0}};
            tail  <= {`ROB_TAG_W{1'b0}};
            tail_epoch <= {`UOP_EPOCH_W{1'b0}};
            count <= {(`ROB_TAG_W+1){1'b0}};
            for (i = 0; i < `ROB_DEPTH; i = i + 1) begin
                pc[i] <= 32'h0;
                has_dest[i] <= 1'b0;
                result_we[i] <= 1'b0;
                rd[i] <= 5'h0;
                value[i] <= 32'h0;
                epoch[i] <= {`UOP_EPOCH_W{1'b0}};
            end
        end else begin
            if (complete[0].valid && valid[complete[0].uop_id.rob_tag] &&
                (epoch[complete[0].uop_id.rob_tag] == complete[0].uop_id.epoch)) begin
                done[complete[0].uop_id.rob_tag] <= 1'b1;
                value[complete[0].uop_id.rob_tag] <= complete[0].value;
                result_we[complete[0].uop_id.rob_tag] <= complete[0].reg_write;
            end
            if (complete[1].valid && valid[complete[1].uop_id.rob_tag] &&
                (epoch[complete[1].uop_id.rob_tag] == complete[1].uop_id.epoch)) begin
                done[complete[1].uop_id.rob_tag] <= 1'b1;
                value[complete[1].uop_id.rob_tag] <= complete[1].value;
                result_we[complete[1].uop_id.rob_tag] <= complete[1].reg_write;
            end

            if (commit0_valid) begin
                valid[head] <= 1'b0;
                done[head] <= 1'b0;
            end
            if (commit1_valid) begin
                valid[head1] <= 1'b0;
                done[head1] <= 1'b0;
            end
            if (commit0_valid || commit1_valid)
                head <= head + commit0_valid + commit1_valid;

            if (recover_valid && recover_match) begin
                for (i = 0; i < `ROB_DEPTH; i = i + 1) begin
                    if (valid[i] &&
                        (tag_distance(i[`ROB_TAG_W-1:0], head) >
                         recover_distance)) begin
                        valid[i] <= 1'b0;
                        done[i] <= 1'b0;
                    end
                end
                tail <= recover_id.rob_tag + {{(`ROB_TAG_W-1){1'b0}}, 1'b1};
                // Keep the packed uop ID as a continuous modular allocation
                // sequence.  Execution/LSU recovery cancels killed work;
                // adding another epoch step here breaks age comparisons after
                // repeated loop recoveries when the epoch field is only two
                // bits wide.
                tail_epoch <= recover_id.epoch +
                              (recover_id.rob_tag == {`ROB_TAG_W{1'b1}});
                count <= {1'b0, recover_distance} + 1'b1 -
                         commit0_valid - commit1_valid;
            end else if (recover_valid) begin
                // An empty/invalid recovery target has no entries to kill.
                // Commit side effects already performed above remain valid,
                // but recovery must not create a phantom ROB entry.
                count <= count - commit0_valid - commit1_valid;
            end else begin
                if (alloc0_fire) begin
                    valid[tail] <= 1'b1;
                    epoch[tail] <= alloc_id[0].epoch;
                    done[tail] <= 1'b0;
                    pc[tail] <= alloc_uop[0].pc;
                    has_dest[tail] <= alloc_uop[0].reg_write &&
                                      (alloc_uop[0].arch_rd != 5'h0);
                    result_we[tail] <= alloc_uop[0].reg_write &&
                                       (alloc_uop[0].arch_rd != 5'h0);
                    rd[tail] <= alloc_uop[0].arch_rd;
                    value[tail] <= 32'h0;
                end
                if (alloc1_fire) begin
                    valid[alloc_id[1].rob_tag] <= 1'b1;
                    epoch[alloc_id[1].rob_tag] <= alloc_id[1].epoch;
                    done[alloc_id[1].rob_tag] <= 1'b0;
                    pc[alloc_id[1].rob_tag] <= alloc_uop[1].pc;
                    has_dest[alloc_id[1].rob_tag] <= alloc_uop[1].reg_write &&
                                              (alloc_uop[1].arch_rd != 5'h0);
                    result_we[alloc_id[1].rob_tag] <= alloc_uop[1].reg_write &&
                                               (alloc_uop[1].arch_rd != 5'h0);
                    rd[alloc_id[1].rob_tag] <= alloc_uop[1].arch_rd;
                    value[alloc_id[1].rob_tag] <= 32'h0;
                end

                if (alloc0_fire || alloc1_fire) begin
                    tail <= tail + alloc0_fire + alloc1_fire;
                    if ((alloc0_fire && !alloc1_fire &&
                         (tail == {`ROB_TAG_W{1'b1}})) ||
                        (alloc0_fire && alloc1_fire &&
                         (tail >= (`ROB_DEPTH-2))))
                        tail_epoch <= tail_epoch + 1'b1;
                end
                count <= count + alloc0_fire + alloc1_fire -
                         commit0_valid - commit1_valid;
            end
        end
    end

endmodule
