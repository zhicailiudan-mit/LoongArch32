`timescale 1ns / 1ps

`include "defines.vh"

module RegAliasTable (
    input  wire                  clk,
    input  wire                  rstn,

    input  wire                  alloc_valid,
    input  wire                  alloc_rf_we,
    input  wire [4:0]            alloc_rd,
    input  wire [`ROB_TAG_W-1:0] alloc_tag,
    input  wire [`UOP_EPOCH_W-1:0] alloc_epoch,
    input  wire                  alloc_checkpoint,
    input  wire                  alloc1_valid,
    input  wire                  alloc1_rf_we,
    input  wire [4:0]            alloc1_rd,
    input  wire [`ROB_TAG_W-1:0] alloc1_tag,
    input  wire [`UOP_EPOCH_W-1:0] alloc1_epoch,
    input  wire                  alloc1_checkpoint,

    input  wire                  recover_valid,
    input  wire [`ROB_TAG_W-1:0] recover_tag,
    input  wire [`UOP_EPOCH_W-1:0] recover_epoch,
    input  wire [`ROB_DEPTH-1:0] rob_live_mask,

    input  wire                  commit_valid,
    input  wire                  commit_has_dest,
    input  wire [4:0]            commit_rd,
    input  wire [`ROB_TAG_W-1:0] commit_tag,
    input  wire [`UOP_EPOCH_W-1:0] commit_epoch,
    input  wire                  commit1_valid,
    input  wire                  commit1_has_dest,
    input  wire [4:0]            commit1_rd,
    input  wire [`ROB_TAG_W-1:0] commit1_tag,
    input  wire [`UOP_EPOCH_W-1:0] commit1_epoch,

    input  wire [4:0]            query_rs0,
    output wire                  query_pending0,
    output wire [`ROB_TAG_W-1:0] query_tag0,
    output wire [`UOP_EPOCH_W-1:0] query_epoch0,
    input  wire [4:0]            query_rs1,
    output wire                  query_pending1,
    output wire [`ROB_TAG_W-1:0] query_tag1,
    output wire [`UOP_EPOCH_W-1:0] query_epoch1,
    input  wire [4:0]            query_rs2,
    output wire                  query_pending2,
    output wire [`ROB_TAG_W-1:0] query_tag2,
    output wire [`UOP_EPOCH_W-1:0] query_epoch2,
    input  wire [4:0]            query_rs3,
    output wire                  query_pending3,
    output wire [`ROB_TAG_W-1:0] query_tag3,
    output wire [`UOP_EPOCH_W-1:0] query_epoch3
);

    reg [31:0] map_valid;
    reg [`ROB_TAG_W-1:0] map_tag [0:31];
    reg [`UOP_EPOCH_W-1:0] map_epoch [0:31];
    // Recovery is only issued when the recovery uop is at the ROB head.  In
    // that state every older producer has already committed, so recovery must
    // discard all speculative mappings and retain at most the recovery uop's
    // own destination.  Keeping a full RAT snapshot indexed only by ROB tag is
    // unsafe: after tag wrap an old snapshot can make an unrelated new owner
    // look live (ABA).  Record the current owner of each ROB slot instead.
    reg                  owner_has_dest [0:`ROB_DEPTH-1];
    reg [4:0]            owner_rd       [0:`ROB_DEPTH-1];
    reg [`UOP_EPOCH_W-1:0] owner_epoch  [0:`ROB_DEPTH-1];
    
    reg cp_slot_valid [0:`ROB_DEPTH-1];
    reg [`UOP_EPOCH_W-1:0] cp_slot_epoch [0:`ROB_DEPTH-1];
    reg cp_map_valid [0:`ROB_DEPTH-1][1:31];
    reg [`ROB_TAG_W-1:0] cp_map_tag [0:`ROB_DEPTH-1][1:31];
    reg [`UOP_EPOCH_W-1:0] cp_map_epoch [0:`ROB_DEPTH-1][1:31];

    integer i;
    integer r;

    reg is_valid_cp;
    reg cp_val;
    reg [`UOP_EPOCH_W-1:0] cp_ep;
    reg [`ROB_TAG_W-1:0] cp_tg;
    reg producer_is_alive;
    reg producer_is_committing;

    assign query_pending0 = (query_rs0 != 5'h0) && map_valid[query_rs0];
    assign query_tag0 = map_tag[query_rs0];
    assign query_epoch0 = map_epoch[query_rs0];
    assign query_pending1 = (query_rs1 != 5'h0) && map_valid[query_rs1];
    assign query_tag1 = map_tag[query_rs1];
    assign query_epoch1 = map_epoch[query_rs1];
    wire lane0_writes_rs2 = alloc_valid && alloc_rf_we &&
                            (alloc_rd != 5'h0) && (alloc_rd == query_rs2);
    wire lane0_writes_rs3 = alloc_valid && alloc_rf_we &&
                            (alloc_rd != 5'h0) && (alloc_rd == query_rs3);
    assign query_pending2 = (query_rs2 != 5'h0) &&
                            (lane0_writes_rs2 || map_valid[query_rs2]);
    assign query_tag2 = lane0_writes_rs2 ? alloc_tag : map_tag[query_rs2];
    assign query_epoch2 = lane0_writes_rs2 ? alloc_epoch : map_epoch[query_rs2];
    assign query_pending3 = (query_rs3 != 5'h0) &&
                            (lane0_writes_rs3 || map_valid[query_rs3]);
    assign query_tag3 = lane0_writes_rs3 ? alloc_tag : map_tag[query_rs3];
    assign query_epoch3 = lane0_writes_rs3 ? alloc_epoch : map_epoch[query_rs3];

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            map_valid <= 32'h0;
            for (i = 0; i < 32; i = i + 1) begin
                map_tag[i] <= {`ROB_TAG_W{1'b0}};
                map_epoch[i] <= {`UOP_EPOCH_W{1'b0}};
            end
            for (i = 0; i < `ROB_DEPTH; i = i + 1) begin
                owner_has_dest[i] <= 1'b0;
                owner_rd[i]       <= 5'h0;
                owner_epoch[i]    <= {`UOP_EPOCH_W{1'b0}};
                cp_slot_valid[i]  <= 1'b0;
            end
        end else if (recover_valid) begin
            // Restore from the snapshot taken at dispatch.
            is_valid_cp = cp_slot_valid[recover_tag] && (cp_slot_epoch[recover_tag] == recover_epoch);
            `ifndef SYNTHESIS
            if (recover_valid && !is_valid_cp) begin
                // Missing checkpoint. Safe to clear RAT for exception flush.
            end
            `endif
            for (r = 1; r < 32; r = r + 1) begin
                cp_val = cp_map_valid[recover_tag][r];
                cp_ep  = cp_map_epoch[recover_tag][r];
                cp_tg  = cp_map_tag[recover_tag][r];
                
                producer_is_committing = (commit_valid && (commit_tag == cp_tg) && (commit_epoch == cp_ep)) ||
                                         (commit1_valid && (commit1_tag == cp_tg) && (commit1_epoch == cp_ep));
                                         
                producer_is_alive = rob_live_mask[cp_tg] && owner_has_dest[cp_tg] && 
                                    (owner_rd[cp_tg] == r[4:0]) && (owner_epoch[cp_tg] == cp_ep);
                
                map_valid[r] <= is_valid_cp && cp_val && producer_is_alive && !producer_is_committing;
                map_tag[r]   <= cp_tg;
                map_epoch[r] <= cp_ep;
            end
            map_valid[0] <= 1'b0;
        end else begin
            if (commit_valid && commit_has_dest && (commit_rd != 5'h0) &&
                map_valid[commit_rd] && (map_tag[commit_rd] == commit_tag) &&
                (map_epoch[commit_rd] == commit_epoch))
                map_valid[commit_rd] <= 1'b0;
            if (commit1_valid && commit1_has_dest && (commit1_rd != 5'h0) &&
                map_valid[commit1_rd] && (map_tag[commit1_rd] == commit1_tag) &&
                (map_epoch[commit1_rd] == commit1_epoch))
                map_valid[commit1_rd] <= 1'b0;

            if (alloc_valid) begin
                owner_has_dest[alloc_tag] <= alloc_rf_we && (alloc_rd != 5'h0);
                owner_rd[alloc_tag]       <= alloc_rd;
                owner_epoch[alloc_tag]    <= alloc_epoch;
            end
            if (alloc1_valid) begin
                owner_has_dest[alloc1_tag] <= alloc1_rf_we && (alloc1_rd != 5'h0);
                owner_rd[alloc1_tag]       <= alloc1_rd;
                owner_epoch[alloc1_tag]    <= alloc1_epoch;
            end

            if (alloc_valid && alloc_rf_we && (alloc_rd != 5'h0)) begin
                map_valid[alloc_rd] <= 1'b1;
                map_tag[alloc_rd]   <= alloc_tag;
                map_epoch[alloc_rd] <= alloc_epoch;
            end
            if (alloc1_valid && alloc1_rf_we && (alloc1_rd != 5'h0)) begin
                map_valid[alloc1_rd] <= 1'b1;
                map_tag[alloc1_rd]   <= alloc1_tag;
                map_epoch[alloc1_rd] <= alloc1_epoch;
            end

            if (alloc_valid) begin
                if (alloc_checkpoint) begin
                    cp_slot_valid[alloc_tag] <= 1'b1;
                    cp_slot_epoch[alloc_tag] <= alloc_epoch;
                    for (r = 1; r < 32; r = r + 1) begin
                        if (alloc_rf_we && (alloc_rd == r[4:0])) begin
                            cp_map_valid[alloc_tag][r] <= 1'b1;
                            cp_map_tag[alloc_tag][r]   <= alloc_tag;
                            cp_map_epoch[alloc_tag][r] <= alloc_epoch;
                        end else begin
                            cp_map_valid[alloc_tag][r] <= map_valid[r];
                            cp_map_tag[alloc_tag][r]   <= map_tag[r];
                            cp_map_epoch[alloc_tag][r] <= map_epoch[r];
                        end
                    end
                end else begin
                    cp_slot_valid[alloc_tag] <= 1'b0;
                end
            end
            
            if (alloc1_valid) begin
                if (alloc1_checkpoint) begin
                    cp_slot_valid[alloc1_tag] <= 1'b1;
                    cp_slot_epoch[alloc1_tag] <= alloc1_epoch;
                    for (r = 1; r < 32; r = r + 1) begin
                        if (alloc1_rf_we && (alloc1_rd == r[4:0])) begin
                            cp_map_valid[alloc1_tag][r] <= 1'b1;
                            cp_map_tag[alloc1_tag][r]   <= alloc1_tag;
                            cp_map_epoch[alloc1_tag][r] <= alloc1_epoch;
                        end else if (alloc_valid && alloc_rf_we && (alloc_rd == r[4:0])) begin
                            cp_map_valid[alloc1_tag][r] <= 1'b1;
                            cp_map_tag[alloc1_tag][r]   <= alloc_tag;
                            cp_map_epoch[alloc1_tag][r] <= alloc_epoch;
                        end else begin
                            cp_map_valid[alloc1_tag][r] <= map_valid[r];
                            cp_map_tag[alloc1_tag][r]   <= map_tag[r];
                            cp_map_epoch[alloc1_tag][r] <= map_epoch[r];
                        end
                    end
                end else begin
                    cp_slot_valid[alloc1_tag] <= 1'b0;
                end
            end

            map_valid[0] <= 1'b0;
        end
    end

endmodule
