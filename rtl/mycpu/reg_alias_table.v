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
    input  wire                  system_flush,
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
    
    // Checkpoint storage is deliberately kept as a packed RAM word.  The old
    // implementation described a three-dimensional, resettable register
    // array (ROB slots x 31 registers x {valid,tag,epoch}); Vivado therefore
    // built thousands of LUT/FFs and put the whole RAT on the rename timing
    // cone.  A packed word with no data reset is inferable as block RAM.
    localparam integer CP_ENTRY_W = 1 + `ROB_TAG_W + `UOP_EPOCH_W;
    localparam integer CP_MAP_W = 31 * CP_ENTRY_W;
    localparam integer CP_BANK_DEPTH = `ROB_DEPTH / 2;
    (* ram_style = "block" *) reg [CP_MAP_W-1:0] cp_map_mem_even [0:CP_BANK_DEPTH-1];
    (* ram_style = "block" *) reg [CP_MAP_W-1:0] cp_map_mem_odd  [0:CP_BANK_DEPTH-1];
    reg cp_slot_valid [0:`ROB_DEPTH-1];
    reg [`UOP_EPOCH_W-1:0] cp_slot_epoch [0:`ROB_DEPTH-1];
    // Recovery reads the selected RAM word on the recover edge and exposes it
    // through the view below for the following cycle.  Rename can continue to
    // see the restored map during that cycle; the architectural map is
    // committed at the next edge together with any newly allocated uops.
    reg [CP_MAP_W-1:0] cp_read_data_q;
    reg cp_restore_pending_q;
    reg cp_restore_valid_q;

    reg [31:0] restore_map_valid;
    reg [`ROB_TAG_W-1:0] restore_map_tag [0:31];
    reg [`UOP_EPOCH_W-1:0] restore_map_epoch [0:31];
    reg [31:0] view_map_valid;
    reg [`ROB_TAG_W-1:0] view_map_tag [0:31];
    reg [`UOP_EPOCH_W-1:0] view_map_epoch [0:31];
    reg [CP_MAP_W-1:0] cp_write_data0;
    reg [CP_MAP_W-1:0] cp_write_data1;

    integer i;
    integer r;

    integer v;

    // Decode the packed synchronous checkpoint word.  The validity filter is
    // kept identical to the former register-array implementation: a mapping
    // survives recovery only when its ROB owner is still live and has not
    // committed in the recovery cycle.
    always @(*) begin
        restore_map_valid = 32'h0;
        for (v = 0; v < 32; v = v + 1) begin
            restore_map_tag[v] = {`ROB_TAG_W{1'b0}};
            restore_map_epoch[v] = {`UOP_EPOCH_W{1'b0}};
        end
        for (v = 1; v < 32; v = v + 1) begin
            restore_map_tag[v] = cp_read_data_q[(v-1)*CP_ENTRY_W + 1 +: `ROB_TAG_W];
            restore_map_epoch[v] = cp_read_data_q[(v-1)*CP_ENTRY_W + 1 + `ROB_TAG_W +: `UOP_EPOCH_W];
            if (cp_restore_valid_q && cp_read_data_q[(v-1)*CP_ENTRY_W] &&
                rob_live_mask[restore_map_tag[v]] &&
                owner_has_dest[restore_map_tag[v]] &&
                (owner_rd[restore_map_tag[v]] == v[4:0]) &&
                (owner_epoch[restore_map_tag[v]] == restore_map_epoch[v]) &&
                !((commit_valid && commit_has_dest &&
                   (commit_rd == v[4:0]) &&
                   (commit_tag == restore_map_tag[v]) &&
                   (commit_epoch == restore_map_epoch[v])) ||
                  (commit1_valid && commit1_has_dest &&
                   (commit1_rd == v[4:0]) &&
                   (commit1_tag == restore_map_tag[v]) &&
                   (commit1_epoch == restore_map_epoch[v])))) begin
                restore_map_valid[v] = 1'b1;
            end
        end

        // During the one-cycle synchronous restore window, queries must see
        // the checkpoint even though map_valid/map_tag/map_epoch are updated
        // at the end of this cycle.  This avoids adding a rename bubble.
        for (v = 0; v < 32; v = v + 1) begin
            view_map_valid[v] = cp_restore_pending_q ? restore_map_valid[v] : map_valid[v];
            view_map_tag[v] = cp_restore_pending_q ? restore_map_tag[v] : map_tag[v];
            view_map_epoch[v] = cp_restore_pending_q ? restore_map_epoch[v] : map_epoch[v];
        end
    end

    // A set map_valid bit is not sufficient after ROB tag wrap or checkpoint
    // restore.  Only expose a dependency when the referenced ROB slot is
    // still owned by the same architectural destination and epoch.  Without
    // this identity check, rename can read a completed value from a reused
    // ROB tag and silently inject an old loop-iteration operand.
    wire query_map0_owned = view_map_valid[query_rs0] &&
                            rob_live_mask[view_map_tag[query_rs0]] &&
                            owner_has_dest[view_map_tag[query_rs0]] &&
                            (owner_rd[view_map_tag[query_rs0]] == query_rs0) &&
                            (owner_epoch[view_map_tag[query_rs0]] ==
                             view_map_epoch[query_rs0]);
    wire query_map1_owned = view_map_valid[query_rs1] &&
                            rob_live_mask[view_map_tag[query_rs1]] &&
                            owner_has_dest[view_map_tag[query_rs1]] &&
                            (owner_rd[view_map_tag[query_rs1]] == query_rs1) &&
                            (owner_epoch[view_map_tag[query_rs1]] ==
                             view_map_epoch[query_rs1]);
    wire query_map2_owned = view_map_valid[query_rs2] &&
                            rob_live_mask[view_map_tag[query_rs2]] &&
                            owner_has_dest[view_map_tag[query_rs2]] &&
                            (owner_rd[view_map_tag[query_rs2]] == query_rs2) &&
                            (owner_epoch[view_map_tag[query_rs2]] ==
                             view_map_epoch[query_rs2]);
    wire query_map3_owned = view_map_valid[query_rs3] &&
                            rob_live_mask[view_map_tag[query_rs3]] &&
                            owner_has_dest[view_map_tag[query_rs3]] &&
                            (owner_rd[view_map_tag[query_rs3]] == query_rs3) &&
                            (owner_epoch[view_map_tag[query_rs3]] ==
                             view_map_epoch[query_rs3]);

    assign query_pending0 = (query_rs0 != 5'h0) && query_map0_owned;
    assign query_tag0 = view_map_tag[query_rs0];
    assign query_epoch0 = view_map_epoch[query_rs0];
    assign query_pending1 = (query_rs1 != 5'h0) && query_map1_owned;
    assign query_tag1 = view_map_tag[query_rs1];
    assign query_epoch1 = view_map_epoch[query_rs1];
    wire lane0_writes_rs2 = alloc_valid && alloc_rf_we &&
                             (alloc_rd != 5'h0) && (alloc_rd == query_rs2);
    wire lane0_writes_rs3 = alloc_valid && alloc_rf_we &&
                            (alloc_rd != 5'h0) && (alloc_rd == query_rs3);
    assign query_pending2 = (query_rs2 != 5'h0) &&
                            (lane0_writes_rs2 || query_map2_owned);
    assign query_tag2 = lane0_writes_rs2 ? alloc_tag : view_map_tag[query_rs2];
    assign query_epoch2 = lane0_writes_rs2 ? alloc_epoch : view_map_epoch[query_rs2];
    assign query_pending3 = (query_rs3 != 5'h0) &&
                            (lane0_writes_rs3 || query_map3_owned);
    assign query_tag3 = lane0_writes_rs3 ? alloc_tag : view_map_tag[query_rs3];
    assign query_epoch3 = lane0_writes_rs3 ? alloc_epoch : view_map_epoch[query_rs3];

    // Build both checkpoint words from the map visible to rename.  The second
    // lane includes lane0's same-cycle destination, matching the original
    // dual-dispatch RAT semantics.
    integer w;
    always @(*) begin
        cp_write_data0 = {CP_MAP_W{1'b0}};
        cp_write_data1 = {CP_MAP_W{1'b0}};
        for (w = 1; w < 32; w = w + 1) begin
            cp_write_data0[(w-1)*CP_ENTRY_W] =
                (alloc_valid && alloc_rf_we && (alloc_rd == w[4:0])) ? 1'b1 : view_map_valid[w];
            cp_write_data0[(w-1)*CP_ENTRY_W + 1 +: `ROB_TAG_W] =
                (alloc_valid && alloc_rf_we && (alloc_rd == w[4:0])) ? alloc_tag : view_map_tag[w];
            cp_write_data0[(w-1)*CP_ENTRY_W + 1 + `ROB_TAG_W +: `UOP_EPOCH_W] =
                (alloc_valid && alloc_rf_we && (alloc_rd == w[4:0])) ? alloc_epoch : view_map_epoch[w];

            cp_write_data1[(w-1)*CP_ENTRY_W] =
                (alloc1_valid && alloc1_rf_we && (alloc1_rd == w[4:0])) ? 1'b1 :
                ((alloc_valid && alloc_rf_we && (alloc_rd == w[4:0])) ? 1'b1 : view_map_valid[w]);
            cp_write_data1[(w-1)*CP_ENTRY_W + 1 +: `ROB_TAG_W] =
                (alloc1_valid && alloc1_rf_we && (alloc1_rd == w[4:0])) ? alloc1_tag :
                ((alloc_valid && alloc_rf_we && (alloc_rd == w[4:0])) ? alloc_tag : view_map_tag[w]);
            cp_write_data1[(w-1)*CP_ENTRY_W + 1 + `ROB_TAG_W +: `UOP_EPOCH_W] =
                (alloc1_valid && alloc1_rf_we && (alloc1_rd == w[4:0])) ? alloc1_epoch :
                ((alloc_valid && alloc_rf_we && (alloc_rd == w[4:0])) ? alloc_epoch : view_map_epoch[w]);
        end
    end

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            map_valid <= 32'h0;
            cp_read_data_q <= {CP_MAP_W{1'b0}};
            cp_restore_pending_q <= 1'b0;
            cp_restore_valid_q <= 1'b0;
            for (i = 0; i < 32; i = i + 1) begin
                map_tag[i] <= {`ROB_TAG_W{1'b0}};
                map_epoch[i] <= {`UOP_EPOCH_W{1'b0}};
            end
            for (i = 0; i < `ROB_DEPTH; i = i + 1) begin
                owner_has_dest[i] <= 1'b0;
                owner_rd[i]       <= 5'h0;
                owner_epoch[i]    <= {`UOP_EPOCH_W{1'b0}};
                cp_slot_valid[i]  <= 1'b0;
                cp_slot_epoch[i]  <= {`UOP_EPOCH_W{1'b0}};
            end
        end else begin
            // A recovery starts a synchronous checkpoint read.  Queries are
            // served from cp_read_data_q during cp_restore_pending_q, so this
            // adds no ordinary rename bubble.
            if (recover_valid && system_flush) begin
                map_valid <= 32'h0;
                cp_restore_pending_q <= 1'b0;
                cp_restore_valid_q <= 1'b0;
                for (i = 0; i < `ROB_DEPTH; i = i + 1)
                    cp_slot_valid[i] <= 1'b0;
            end else if (recover_valid && !cp_restore_pending_q) begin
                if (!recover_tag[0])
                    cp_read_data_q <= cp_map_mem_even[recover_tag[`ROB_TAG_W-1:1]];
                else
                    cp_read_data_q <= cp_map_mem_odd[recover_tag[`ROB_TAG_W-1:1]];
                cp_restore_pending_q <= 1'b1;
                cp_restore_valid_q <= cp_slot_valid[recover_tag] &&
                                      (cp_slot_epoch[recover_tag] == recover_epoch);
                map_valid <= 32'h0;
                `ifndef SYNTHESIS
                if (!(cp_slot_valid[recover_tag] &&
                      (cp_slot_epoch[recover_tag] == recover_epoch))) begin
                    $fatal(1, "RAT Checkpoint missing for recover_tag=%0d, recover_epoch=%0d, system_flush=%b, cp_slot_valid=%b, cp_slot_epoch=%0d, rob_live_mask=%b", recover_tag, recover_epoch, system_flush, cp_slot_valid[recover_tag], cp_slot_epoch[recover_tag], rob_live_mask);
                end
                `endif
            end else if (cp_restore_pending_q) begin
                // Commit the RAM snapshot and merge any allocations accepted
                // in the restore cycle.  The latter is what preserves the
                // normal two-uop rename contract across a branch recovery.
                map_valid <= restore_map_valid;
                for (i = 1; i < 32; i = i + 1) begin
                    map_tag[i] <= restore_map_tag[i];
                    map_epoch[i] <= restore_map_epoch[i];
                end
                map_valid[0] <= 1'b0;
                cp_restore_pending_q <= 1'b0;
                cp_restore_valid_q <= 1'b0;
                if (alloc_valid) begin
                    owner_has_dest[alloc_tag] <= alloc_rf_we && (alloc_rd != 5'h0);
                    owner_rd[alloc_tag] <= alloc_rd;
                    owner_epoch[alloc_tag] <= alloc_epoch;
                    if (alloc_checkpoint) begin
                        cp_slot_valid[alloc_tag] <= 1'b1;
                        cp_slot_epoch[alloc_tag] <= alloc_epoch;
                        if (!alloc_tag[0])
                            cp_map_mem_even[alloc_tag[`ROB_TAG_W-1:1]] <= cp_write_data0;
                        else
                            cp_map_mem_odd[alloc_tag[`ROB_TAG_W-1:1]] <= cp_write_data0;
                    end else begin
                        cp_slot_valid[alloc_tag] <= 1'b0;
                    end
                end
                if (alloc1_valid) begin
                    owner_has_dest[alloc1_tag] <= alloc1_rf_we && (alloc1_rd != 5'h0);
                    owner_rd[alloc1_tag] <= alloc1_rd;
                    owner_epoch[alloc1_tag] <= alloc1_epoch;
                    if (alloc1_checkpoint) begin
                        cp_slot_valid[alloc1_tag] <= 1'b1;
                        cp_slot_epoch[alloc1_tag] <= alloc1_epoch;
                        if (!alloc1_tag[0])
                            cp_map_mem_even[alloc1_tag[`ROB_TAG_W-1:1]] <= cp_write_data1;
                        else
                            cp_map_mem_odd[alloc1_tag[`ROB_TAG_W-1:1]] <= cp_write_data1;
                    end else begin
                        cp_slot_valid[alloc1_tag] <= 1'b0;
                    end
                end
                if (alloc_valid && alloc_rf_we && (alloc_rd != 5'h0)) begin
                    map_valid[alloc_rd] <= 1'b1;
                    map_tag[alloc_rd] <= alloc_tag;
                    map_epoch[alloc_rd] <= alloc_epoch;
                end
                if (alloc1_valid && alloc1_rf_we && (alloc1_rd != 5'h0)) begin
                    map_valid[alloc1_rd] <= 1'b1;
                    map_tag[alloc1_rd] <= alloc1_tag;
                    map_epoch[alloc1_rd] <= alloc1_epoch;
                end
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
                    owner_rd[alloc_tag] <= alloc_rd;
                    owner_epoch[alloc_tag] <= alloc_epoch;
                    if (alloc_rf_we && (alloc_rd != 5'h0)) begin
                        map_valid[alloc_rd] <= 1'b1;
                        map_tag[alloc_rd] <= alloc_tag;
                        map_epoch[alloc_rd] <= alloc_epoch;
                    end
                    if (alloc_checkpoint) begin
                        cp_slot_valid[alloc_tag] <= 1'b1;
                        cp_slot_epoch[alloc_tag] <= alloc_epoch;
                        if (!alloc_tag[0])
                            cp_map_mem_even[alloc_tag[`ROB_TAG_W-1:1]] <= cp_write_data0;
                        else
                            cp_map_mem_odd[alloc_tag[`ROB_TAG_W-1:1]] <= cp_write_data0;
                    end else begin
                        cp_slot_valid[alloc_tag] <= 1'b0;
                    end
                end
                if (alloc1_valid) begin
                    owner_has_dest[alloc1_tag] <= alloc1_rf_we && (alloc1_rd != 5'h0);
                    owner_rd[alloc1_tag] <= alloc1_rd;
                    owner_epoch[alloc1_tag] <= alloc1_epoch;
                    if (alloc1_rf_we && (alloc1_rd != 5'h0)) begin
                        map_valid[alloc1_rd] <= 1'b1;
                        map_tag[alloc1_rd] <= alloc1_tag;
                        map_epoch[alloc1_rd] <= alloc1_epoch;
                    end
                    if (alloc1_checkpoint) begin
                        cp_slot_valid[alloc1_tag] <= 1'b1;
                        cp_slot_epoch[alloc1_tag] <= alloc1_epoch;
                        if (!alloc1_tag[0])
                            cp_map_mem_even[alloc1_tag[`ROB_TAG_W-1:1]] <= cp_write_data1;
                        else
                            cp_map_mem_odd[alloc1_tag[`ROB_TAG_W-1:1]] <= cp_write_data1;
                    end else begin
                        cp_slot_valid[alloc1_tag] <= 1'b0;
                    end
                end
                map_valid[0] <= 1'b0;
            end
        end
    end

endmodule
