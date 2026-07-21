`timescale 1ns/1ps

`include "defines.vh"

module tb_rat32;
    logic clk;
    logic rstn;
    logic alloc_valid;
    logic alloc_rf_we;
    logic [4:0] alloc_rd;
    logic [`ROB_TAG_W-1:0] alloc_tag;
    logic alloc_checkpoint;
    logic alloc1_valid;
    logic alloc1_rf_we;
    logic [4:0] alloc1_rd;
    logic [`ROB_TAG_W-1:0] alloc1_tag;
    logic alloc1_checkpoint;
    logic recover_valid;
    logic [`ROB_TAG_W-1:0] recover_tag;
    logic [`ROB_DEPTH-1:0] rob_live_mask;
    logic commit_valid;
    logic commit_has_dest;
    logic [4:0] commit_rd;
    logic [`ROB_TAG_W-1:0] commit_tag;
    logic commit1_valid;
    logic commit1_has_dest;
    logic [4:0] commit1_rd;
    logic [`ROB_TAG_W-1:0] commit1_tag;
    logic [4:0] query_rs0, query_rs1, query_rs2, query_rs3;
    wire query_pending0, query_pending1, query_pending2, query_pending3;
    wire [`ROB_TAG_W-1:0] query_tag0, query_tag1, query_tag2, query_tag3;

    `include "tb_common.svh"

    RAT32 dut (
        .clk             (clk),
        .rstn            (rstn),
        .alloc_valid     (alloc_valid),
        .alloc_rf_we     (alloc_rf_we),
        .alloc_rd        (alloc_rd),
        .alloc_tag       (alloc_tag),
        .alloc_checkpoint(alloc_checkpoint),
        .alloc1_valid    (alloc1_valid),
        .alloc1_rf_we    (alloc1_rf_we),
        .alloc1_rd       (alloc1_rd),
        .alloc1_tag      (alloc1_tag),
        .alloc1_checkpoint(alloc1_checkpoint),
        .recover_valid   (recover_valid),
        .recover_tag     (recover_tag),
        .rob_live_mask   (rob_live_mask),
        .commit_valid    (commit_valid),
        .commit_has_dest (commit_has_dest),
        .commit_rd       (commit_rd),
        .commit_tag      (commit_tag),
        .commit1_valid   (commit1_valid),
        .commit1_has_dest(commit1_has_dest),
        .commit1_rd      (commit1_rd),
        .commit1_tag     (commit1_tag),
        .query_rs0       (query_rs0),
        .query_pending0  (query_pending0),
        .query_tag0      (query_tag0),
        .query_rs1       (query_rs1),
        .query_pending1  (query_pending1),
        .query_tag1      (query_tag1),
        .query_rs2       (query_rs2),
        .query_pending2  (query_pending2),
        .query_tag2      (query_tag2),
        .query_rs3       (query_rs3),
        .query_pending3  (query_pending3),
        .query_tag3      (query_tag3)
    );

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    task automatic clear_inputs;
        begin
            alloc_valid = 1'b0;
            alloc_rf_we = 1'b0;
            alloc_rd = 5'd0;
            alloc_tag = '0;
            alloc_checkpoint = 1'b0;
            alloc1_valid = 1'b0;
            alloc1_rf_we = 1'b0;
            alloc1_rd = 5'd0;
            alloc1_tag = '0;
            alloc1_checkpoint = 1'b0;
            recover_valid = 1'b0;
            recover_tag = '0;
            rob_live_mask = '0;
            commit_valid = 1'b0;
            commit_has_dest = 1'b0;
            commit_rd = 5'd0;
            commit_tag = '0;
            commit1_valid = 1'b0;
            commit1_has_dest = 1'b0;
            commit1_rd = 5'd0;
            commit1_tag = '0;
        end
    endtask

    initial begin
        rstn = 1'b0;
        clear_inputs();
        query_rs0 = 5'd0;
        query_rs1 = 5'd5;
        query_rs2 = 5'd6;
        query_rs3 = 5'd7;
        repeat (3) @(posedge clk);
        rstn = 1'b1;
        @(negedge clk);

        tb_expect(!query_pending0, "RAT r0 is never pending after reset");
        tb_expect(!query_pending1, "RAT reset mapping is empty");

        alloc_valid = 1'b1;
        alloc_rf_we = 1'b1;
        alloc_rd = 5'd5;
        alloc_tag = 4'd2;
        @(posedge clk);
        #1;
        alloc_valid = 1'b0;
        tb_expect(query_pending1 && query_tag1 == 4'd2,
                  "RAT records single allocation");

        // The older lane allocation must be visible to the younger lane
        // source query in the same cycle.
        @(negedge clk);
        alloc_valid = 1'b1;
        alloc_rf_we = 1'b1;
        alloc_rd = 5'd6;
        alloc_tag = 4'd3;
        query_rs2 = 5'd6;
        #1;
        tb_expect(query_pending2 && query_tag2 == 4'd3,
                  "RAT same-cycle lane0 to lane1 bypass");
        @(posedge clk);
        #1;
        alloc_valid = 1'b0;
        tb_expect(query_pending2 && query_tag2 == 4'd3,
                  "RAT retains lane0 allocation");

        // r0 must not acquire a dependency even when a tag-zero allocation
        // is presented.
        @(negedge clk);
        alloc_valid = 1'b1;
        alloc_rf_we = 1'b1;
        alloc_rd = 5'd0;
        alloc_tag = 4'd0;
        query_rs0 = 5'd0;
        @(posedge clk);
        #1;
        alloc_valid = 1'b0;
        tb_expect(!query_pending0, "RAT suppresses r0 dependency");

        // A commit clears only the matching current producer.
        @(negedge clk);
        commit_valid = 1'b1;
        commit_has_dest = 1'b1;
        commit_rd = 5'd5;
        commit_tag = 4'd2;
        #1;
        tb_expect(query_pending1, "RAT remains pending before commit edge");
        @(posedge clk);
        #1;
        commit_valid = 1'b0;
        tb_expect(!query_pending1, "RAT clears committed producer");
        tb_expect(query_pending2 && query_tag2 == 4'd3,
                  "RAT preserves independent producer");

        // Checkpoint is taken before younger allocation; recovery restores
        // the checkpoint map and removes the younger mapping.
        @(negedge clk);
        alloc_valid = 1'b1;
        alloc_rf_we = 1'b0;
        alloc_rd = 5'd0;
        alloc_tag = 4'd6;
        alloc_checkpoint = 1'b1;
        @(posedge clk);
        #1;
        alloc_valid = 1'b1;
        alloc_rf_we = 1'b1;
        alloc_rd = 5'd11;
        alloc_tag = 4'd7;
        alloc_checkpoint = 1'b0;
        @(posedge clk);
        #1;
        alloc_valid = 1'b0;
        tb_expect(query_pending3 == 1'b0 || query_rs3 != 5'd11,
                  "RAT checkpoint setup completed");
        query_rs3 = 5'd11;
        #1;
        tb_expect(query_pending3 && query_tag3 == 4'd7,
                  "RAT records younger mapping before recovery");

        @(negedge clk);
        recover_valid = 1'b1;
        recover_tag = 4'd6;
        rob_live_mask = '0;
        rob_live_mask[2] = 1'b1;
        rob_live_mask[3] = 1'b1;
        @(posedge clk);
        #1;
        recover_valid = 1'b0;
        tb_expect(!query_pending3, "RAT recovery removes younger mapping");
        query_rs1 = 5'd5;
        tb_expect(!query_pending1, "RAT recovery preserves committed state");
        query_rs2 = 5'd6;
        tb_expect(query_pending2 && query_tag2 == 4'd3,
                  "RAT recovery restores older live mapping");

        tb_note("RAT32 baseline PASS");
        $finish;
    end
endmodule
