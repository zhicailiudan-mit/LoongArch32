`timescale 1ns / 1ps

`include "defines.vh"

`define BHT_IDX_W 10
`define BHT_ENTRY (1 << `BHT_IDX_W)
// With the existing hashed 10-bit index, PC[31:12] is an exact complementary
// tag: equal tag + equal index uniquely identifies every aligned PC[31:2].
`define BHT_TAG_W 20

`define RAS_ENTRY 8
`define RAS_CNT_W 4

module BranchPredUnit (
    input  wire         cpu_clk    ,
    input  wire         cpu_rstn   ,
    input  wire [31:0]  if_pc      ,
    input  wire [31:0]  id_pc      ,
    input  wire         if_valid   ,
    input  wire         redirect_valid,
    input  wire [31:0]  redirect_pc,
    input  wire         ifetch_valid,
    input  wire [31:0]  ifetch_inst,
    input  wire         id_valid   ,
    input  wire         id_fire    ,
    input  wire         id_pred_valid_in,
    input  wire         id_pred_taken_in,
    input  wire [31:0]  id_pred_target_in,
    input  wire [ 9:0]  id_pred_index_in,
    input  wire [ 2:0]  id_ras_sp_before_in,
    input  wire [ 3:0]  id_ras_count_before_in,
    input  wire         id_perf_btb_hit_in,
    input  wire         pl_suspend ,

    // predict branch direction and target
    output wire [31:0]  pred_target,
    output wire         pred_taken_out,
    output wire [ 9:0]  pred_index_out,
    output wire [31:0]  pred1_target,
    output wire         pred1_taken_out,
    output wire [ 9:0]  pred1_index_out,
    output wire         pred1_btb_hit_out,
    output wire [ 2:0]  pred_ras_sp_before,
    output wire [ 3:0]  pred_ras_count_before,
    output wire         pred_error ,

    // Simulation-only performance observation.  These outputs describe the
    // same resolved branch event used by pred_error; they never feed control.
    output wire         perf_branch_fire,
    output wire         perf_predicted_taken,
    output wire         perf_actual_taken,
    output wire         perf_mispredict,
    output wire         perf_pred_btb_hit_out,
    output wire         perf_resolved_btb_hit,
    output wire [31:0]  perf_resolved_pc,
    output wire         perf_resolved_conditional,
    output wire         perf_resolved_backward,
    output wire         perf_resolved_jirl,
    output wire         perf_direction_mispredict,
    output wire         perf_target_mispredict,
    output wire         perf_btb_update,
    output wire         perf_btb_update_conditional,
    output wire         perf_btb_update_backward,

    // signals to correct BHT
    input  wire         ex_valid   ,
    input  wire         ex_is_bj   ,
    input  wire         ex_is_call ,
    input  wire         ex_is_ret  ,
    input  wire         ex_is_conditional,
    input  wire         ex_offset_negative,
    input  wire [31:0]  ex_pc      ,
    input  wire         real_taken ,
    input  wire [31:0]  real_target,

    input  wire [2:0 ]  ex_ras_ptr ,
    output wire [2:0 ]  if_ras_ptr
);

`ifdef ENABLE_BPU

    // ------------------------------------------------------------
    // BHT / BTB
    // ------------------------------------------------------------
    (* ram_style = "distributed" *) reg  [`BHT_TAG_W-1:0] tag     [`BHT_ENTRY-1:0];
    reg  [`BHT_ENTRY-1:0] valid;
    (* ram_style = "distributed" *) reg  [           1:0] history [`BHT_ENTRY-1:0];
    (* ram_style = "distributed" *) reg  [          31:0] target  [`BHT_ENTRY-1:0];

    (* ram_style = "distributed" *) reg                   entry_call [`BHT_ENTRY-1:0];
    (* ram_style = "distributed" *) reg                   entry_ret  [`BHT_ENTRY-1:0];
    (* ram_style = "distributed" *) reg                   entry_conditional [`BHT_ENTRY-1:0];
    (* ram_style = "distributed" *) reg                   entry_backward    [`BHT_ENTRY-1:0];
    wire [`BHT_TAG_W-1:0] if_tag = if_pc[31:12];
    wire [31:0] if_pc1 = if_pc + 32'd4;
    wire [`BHT_TAG_W-1:0] if_tag1 = if_pc1[31:12];

    wire [`BHT_TAG_W-1:0] ex_tag = ex_pc[31:12];

    wire [31:0] pc_hash       = if_pc ^ (if_pc >> 10) ^ (if_pc >> 20);
    wire [31:0] pc1_hash      = if_pc1 ^ (if_pc1 >> 10) ^ (if_pc1 >> 20);
    wire [31:0] ex_pc_hash    = ex_pc ^ (ex_pc >> 10) ^ (ex_pc >> 20);

    wire [`BHT_IDX_W-1:0] index          = pc_hash[`BHT_IDX_W+1:2];
    wire [`BHT_IDX_W-1:0] index1         = pc1_hash[`BHT_IDX_W+1:2];
    wire [`BHT_IDX_W-1:0] ex_index_real  = ex_pc_hash[`BHT_IDX_W+1:2];

    wire hit = (tag[index] == if_tag) && valid[index];
    wire hit1 = (tag[index1] == if_tag1) && valid[index1];

    wire hit_call = hit & entry_call[index];
    wire hit_ret  = hit & entry_ret [index];

    // ------------------------------------------------------------
    // RAS

    reg [31:0] ras_stack [`RAS_ENTRY-1:0];
    reg [ 2:0] ras_sp;
    reg [`RAS_CNT_W-1:0] ras_count;

    wire ras_empty = (ras_count == 4'd0);
    wire ras_full  = (ras_count == `RAS_ENTRY);

    wire [ 2:0] ras_sp_dec = ras_sp - 3'd1;
    reg                  ras_fix_valid;
    reg [ 2:0]           ras_fix_waddr;
    reg [31:0]           ras_fix_wdata;
    wire                 ras_fix_hit = ras_fix_valid && (ras_sp_dec == ras_fix_waddr);
    wire [31:0]          ras_top     = ras_fix_hit ? ras_fix_wdata : ras_stack[ras_sp_dec];

    // ------------------------------------------------------------
    // IF阶段预测
    // ------------------------------------------------------------
    // if_pc selects the next request while ifetch_inst belongs to an older
    // returning request, so that instruction cannot qualify this lookup.
    // Conditional entries use BTFNT from the decoded immediate sign captured
    // at resolution; other branch/jump classes retain their existing policy.
    wire conditional_pred_taken = entry_conditional[index] &
                                  entry_backward[index];
    wire nonconditional_pred_taken = !entry_conditional[index] &
                                     (hit_call | history[index][1]);
    wire ras_pred_taken = hit_ret & !ras_empty;
    wire btb_pred_taken = hit & !hit_ret &
                          (conditional_pred_taken |
                           nonconditional_pred_taken);

    wire pred_taken = ras_pred_taken | btb_pred_taken;

    // Lane1 deliberately excludes CALL and every JIRL/RET entry.  It reads
    // the same BTB state but performs no speculative RAS operation.
    wire lane1_supported = hit1 && !entry_call[index1] && !entry_ret[index1];
    wire lane1_conditional_taken = entry_conditional[index1] &
                                   entry_backward[index1];
    wire lane1_direct_taken = !entry_conditional[index1] &
                              history[index1][1];
    wire pred1_taken = lane1_supported &
                       (lane1_conditional_taken | lane1_direct_taken);

    assign pred_target = ras_pred_taken ? ras_top :
                         btb_pred_taken ? target[index] :
                                          if_pc + 32'h4;
    assign pred_taken_out        = pred_taken;
    assign pred_index_out        = index;
    assign pred1_target          = pred1_taken ? target[index1] : if_pc + 32'd8;
    assign pred1_taken_out       = pred1_taken;
    assign pred1_index_out       = index1;
    assign pred1_btb_hit_out     = hit1;
    assign pred_ras_sp_before    = ras_sp;
    assign pred_ras_count_before = ras_count;

    // ------------------------------------------------------------
    wire if_pipe_fire = if_valid;

    wire ras_spec_push = if_pipe_fire & hit_call;
    wire ras_spec_pop  = if_pipe_fire & ras_pred_taken;

    // ------------------------------------------------------------
    // Prediction metadata follows the instruction through IBUF.
    // When the backend really accepts the ID instruction, capture
    // that packet for the next EX-stage prediction check.
    // ------------------------------------------------------------
    reg [`BHT_IDX_W-1:0] ex_index;

    reg                  ex_pred_valid;

    reg                  ex_pred_taken;
    reg [31:0]           ex_pred_target;
    reg                  ex_perf_btb_hit;

    reg [2:0]            ex_ras_sp_before;
    reg [`RAS_CNT_W-1:0] ex_ras_count_before;

    reg [ 2:0]           ras_sp_next;
    reg [`RAS_CNT_W-1:0] ras_count_next;
    wire                 ras_stack_we    = ras_spec_push;
    wire [ 2:0]          ras_stack_waddr = ras_sp;
    wire [31:0]          ras_stack_wdata = if_pc + 32'h4;

    always @(posedge cpu_clk or negedge cpu_rstn) begin
        if (!cpu_rstn) begin
            ex_index       <= 'h0;
            ex_pred_valid  <= 1'b0;
            ex_pred_taken  <= 1'b0;
            ex_pred_target <= 32'h0;
            ex_perf_btb_hit <= 1'b0;

            ex_ras_sp_before    <= 3'h0;
            ex_ras_count_before <= 4'h0;
        end
        else begin
            if (pred_error) begin
                ex_pred_valid <= 1'b0;
            end
            else if (id_fire) begin
                ex_index       <= id_pred_index_in;
                ex_pred_valid  <= id_pred_valid_in;
                ex_pred_taken  <= id_pred_taken_in;
                ex_pred_target <= id_pred_target_in;
                ex_perf_btb_hit <= id_perf_btb_hit_in;

                ex_ras_sp_before    <= id_ras_sp_before_in;
                ex_ras_count_before <= id_ras_count_before_in;
            end
            else if (!ex_valid) begin
                ex_pred_valid <= 1'b0;
            end
        end
    end

    wire prediction_taken_error =
        ex_pred_valid &&
        (
            ( ex_is_bj && (ex_pred_taken != real_taken)) ||
            (!ex_is_bj &&  ex_pred_taken)
        );

    wire prediction_target_error =
        ex_pred_valid &&
        ex_is_bj && real_taken &&
        (ex_pred_target != real_target);

    wire prediction_mismatch = prediction_taken_error |
                               prediction_target_error;
    wire ex_fire = ex_valid & !pl_suspend;

    // A held EX packet may keep its comparison result for several cycles,
    // but correction is an event and may only fire when EX can advance.
    // pred_error clears the issue/execute valid on that edge, so a second lock keyed by
    // ex_pc is redundant and only adds a long compare to the redirect path.
    assign pred_error = ex_fire & prediction_mismatch;
`ifndef SYNTHESIS
    // Every resolved branch must still own the prediction packet captured
    // when that instruction was fetched; otherwise all downstream diagnostic
    // classifications would be comparing different instructions.
    always @(posedge cpu_clk) begin
        if (cpu_rstn && ex_fire && ex_is_bj && !ex_pred_valid)
            $fatal(1, "BTB diag: resolved branch has no fetch prediction metadata");
    end

    assign perf_branch_fire     = ex_fire & ex_is_bj;
    assign perf_predicted_taken = ex_pred_taken;
    assign perf_actual_taken    = real_taken;
    assign perf_mispredict      = ex_fire & ex_is_bj & prediction_taken_error;
    assign perf_pred_btb_hit_out = hit;
    assign perf_resolved_btb_hit = ex_perf_btb_hit;
    assign perf_resolved_pc = ex_pc;
    assign perf_resolved_conditional = ex_is_conditional;
    assign perf_resolved_backward = ex_is_conditional & ex_offset_negative;
    assign perf_resolved_jirl = ex_is_ret;
    assign perf_direction_mispredict = ex_fire & ex_is_bj &
                                        prediction_taken_error;
    assign perf_target_mispredict = ex_fire & ex_is_bj &
                                     !prediction_taken_error &
                                     prediction_target_error;
    assign perf_btb_update = train_valid & train_is_bj;
    assign perf_btb_update_conditional = perf_btb_update &
                                          train_is_conditional;
    assign perf_btb_update_backward = perf_btb_update_conditional &
                                       train_offset_negative;
`else
    assign perf_branch_fire     = 1'b0;
    assign perf_predicted_taken = 1'b0;
    assign perf_actual_taken    = 1'b0;
    assign perf_mispredict      = 1'b0;
    assign perf_pred_btb_hit_out = 1'b0;
    assign perf_resolved_btb_hit = 1'b0;
    assign perf_resolved_pc = 32'h0;
    assign perf_resolved_conditional = 1'b0;
    assign perf_resolved_backward = 1'b0;
    assign perf_resolved_jirl = 1'b0;
    assign perf_direction_mispredict = 1'b0;
    assign perf_target_mispredict = 1'b0;
    assign perf_btb_update = 1'b0;
    assign perf_btb_update_conditional = 1'b0;
    assign perf_btb_update_backward = 1'b0;
`endif

    wire call_pred_error =
        ex_fire && ex_pred_valid && ex_is_call &&
        ((!ex_pred_taken) || (ex_pred_target != real_target));

    // ------------------------------------------------------------
    // RAS更新 / 回滚
    // ------------------------------------------------------------
    always @(*) begin
        ras_sp_next     = ras_sp;
        ras_count_next  = ras_count;

        if (pred_error) begin
            // Restore to the RAS state before the EX instruction.
            ras_sp_next    = ex_ras_sp_before;
            ras_count_next = ex_ras_count_before;

            // Apply the real CALL/RET behavior of the EX instruction.
            if (ex_valid && ex_is_call) begin
                ras_sp_next     = ex_ras_sp_before + 3'd1;

                if (ex_ras_count_before != `RAS_ENTRY)
                    ras_count_next = ex_ras_count_before + 4'd1;
                else
                    ras_count_next = ex_ras_count_before;
            end
            else if (ex_valid && ex_is_ret) begin
                if (ex_ras_count_before != 4'd0) begin
                    ras_sp_next    = ex_ras_sp_before - 3'd1;
                    ras_count_next = ex_ras_count_before - 4'd1;
                end
            end
        end
        else begin
            // Normal path: speculative CALL push.
            if (ras_spec_push) begin
                ras_sp_next     = ras_sp + 3'd1;

                if (!ras_full)
                    ras_count_next = ras_count + 4'd1;
            end

            // Normal path: speculative RET pop.
            else if (ras_spec_pop) begin
                if (!ras_empty) begin
                    ras_sp_next    = ras_sp - 3'd1;
                    ras_count_next = ras_count - 4'd1;
                end
            end
        end
    end

    always @(posedge cpu_clk or negedge cpu_rstn) begin
        if (!cpu_rstn) begin
            ras_sp        <= 3'h0;
            ras_count     <= 4'h0;
            ras_fix_valid <= 1'b0;
            ras_fix_waddr <= 3'h0;
            ras_fix_wdata <= 32'h0;
        end
        else begin
            ras_sp    <= ras_sp_next;
            ras_count <= ras_count_next;

            if (ras_fix_valid)
                ras_stack[ras_fix_waddr] <= ras_fix_wdata;
            if (ras_stack_we)
                ras_stack[ras_stack_waddr] <= ras_stack_wdata;

            ras_fix_valid <= call_pred_error;
            ras_fix_waddr <= ex_ras_sp_before;
            ras_fix_wdata <= ex_pc + 32'h4;
        end
    end

    // ------------------------------------------------------------
    // BHT / BTB 更新
    // ------------------------------------------------------------
    reg                  train_valid;
    reg                  train_is_bj;
    reg                  train_is_call;
    reg                  train_is_ret;
    reg                  train_is_conditional;
    reg                  train_offset_negative;
    reg                  train_real_taken;
    reg                  train_pred_valid;
    reg                  train_pred_taken;
    reg [`BHT_IDX_W-1:0] train_index;
    reg [`BHT_TAG_W-1:0] train_tag;
    reg [31:0]           train_target;

    always @(posedge cpu_clk or negedge cpu_rstn) begin
        if (!cpu_rstn) begin
            train_valid      <= 1'b0;
            train_is_bj      <= 1'b0;
            train_is_call    <= 1'b0;
            train_is_ret     <= 1'b0;
            train_is_conditional <= 1'b0;
            train_offset_negative <= 1'b0;
            train_real_taken <= 1'b0;
            train_pred_valid <= 1'b0;
            train_pred_taken <= 1'b0;
            train_index      <= 'h0;
            train_tag        <= 'h0;
            train_target     <= 32'h0;
        end
        else begin
            train_valid      <= ex_fire;
            train_is_bj      <= ex_is_bj;
            train_is_call    <= ex_is_call;
            train_is_ret     <= ex_is_ret;
            train_is_conditional <= ex_is_conditional;
            train_offset_negative <= ex_offset_negative;
            train_real_taken <= real_taken;
            train_pred_valid <= ex_pred_valid;
            train_pred_taken <= ex_pred_taken;
            train_index      <= ex_index_real;
            train_tag        <= ex_tag;
            train_target     <= real_target;
        end
    end

    wire train_hit = valid[train_index] && (tag[train_index] == train_tag);

    wire add_entry     = train_valid & train_is_bj & (~valid[train_index]);
    wire update_entry  = train_valid & train_is_bj & train_hit;
    wire replace_entry = train_valid & train_is_bj & valid[train_index] &
                         (tag[train_index] != train_tag);

    // Only reset valid[]. tag/history/target/entry_* are protected by valid bits.
    // These arrays do not need explicit reset.
    always @(posedge cpu_clk or negedge cpu_rstn) begin
        if (!cpu_rstn) begin
            valid <= {`BHT_ENTRY{1'b0}};
        end
        else begin
            if (train_valid) begin
                if (train_is_bj) begin
                    if (add_entry | replace_entry) begin
                        valid[train_index] <= 1'b1;
                    end
                end

                else if (train_pred_valid && train_pred_taken) begin
                    if (valid[train_index] &&
                        (tag[train_index] == train_tag)) begin
                        valid[train_index] <= 1'b0;
                    end
                end
            end
        end
    end

    // BHT/BTB write port, no reset, single write address train_index.
    always @(posedge cpu_clk) begin
        if (train_valid && train_is_bj) begin
            if (add_entry | replace_entry) begin
                tag       [train_index] <= train_tag;
                history   [train_index] <= train_real_taken ? 2'b10 : 2'b01;
                target    [train_index] <= train_target;
                entry_call[train_index] <= train_is_call;
                entry_ret [train_index] <= train_is_ret;
                entry_conditional[train_index] <= train_is_conditional;
                entry_backward[train_index] <= train_offset_negative;
            end
            else if (update_entry) begin
                if (train_real_taken) begin
                    if (history[train_index] != 2'b11)
                        history[train_index] <= history[train_index] + 2'b01;
                    target[train_index] <= train_target;
                end
                else if (history[train_index] != 2'b00) begin
                    history[train_index] <= history[train_index] - 2'b01;
                end
                entry_call[train_index] <= train_is_call;
                entry_ret [train_index] <= train_is_ret;
                entry_conditional[train_index] <= train_is_conditional;
                entry_backward[train_index] <= train_offset_negative;
            end
        end
        else if (train_valid && !train_is_bj && train_pred_valid && train_pred_taken) begin
            if (valid[train_index] && (tag[train_index] == train_tag)) begin
                entry_call[train_index] <= 1'b0;
                entry_ret [train_index] <= 1'b0;
                entry_conditional[train_index] <= 1'b0;
                entry_backward[train_index] <= 1'b0;
            end
        end
    end

    assign if_ras_ptr = ras_sp;

`else

    assign if_ras_ptr  = 3'b0;
    assign pred_error  = ex_valid & real_taken & !pl_suspend;
    assign pred_target = if_pc + 32'h4;
    assign pred_taken_out        = 1'b0;
    assign pred_index_out        = 10'h0;
    assign pred1_target          = if_pc + 32'd8;
    assign pred1_taken_out       = 1'b0;
    assign pred1_index_out       = 10'h0;
    assign pred1_btb_hit_out     = 1'b0;
    assign pred_ras_sp_before    = 3'h0;
    assign pred_ras_count_before = 4'h0;
`ifndef SYNTHESIS
    assign perf_branch_fire      = ex_valid & ex_is_bj & !pl_suspend;
    assign perf_predicted_taken  = 1'b0;
    assign perf_actual_taken     = real_taken;
    assign perf_mispredict       = ex_valid & ex_is_bj & real_taken &
                                   !pl_suspend;
    assign perf_pred_btb_hit_out = 1'b0;
    assign perf_resolved_btb_hit = 1'b0;
    assign perf_resolved_pc = ex_pc;
    assign perf_resolved_conditional = ex_is_conditional;
    assign perf_resolved_backward = ex_is_conditional & ex_offset_negative;
    assign perf_resolved_jirl = ex_is_ret;
    assign perf_direction_mispredict = perf_mispredict;
    assign perf_target_mispredict = 1'b0;
    assign perf_btb_update = 1'b0;
    assign perf_btb_update_conditional = 1'b0;
    assign perf_btb_update_backward = 1'b0;
`else
    assign perf_branch_fire      = 1'b0;
    assign perf_predicted_taken  = 1'b0;
    assign perf_actual_taken     = 1'b0;
    assign perf_mispredict       = 1'b0;
    assign perf_pred_btb_hit_out = 1'b0;
    assign perf_resolved_btb_hit = 1'b0;
    assign perf_resolved_pc = 32'h0;
    assign perf_resolved_conditional = 1'b0;
    assign perf_resolved_backward = 1'b0;
    assign perf_resolved_jirl = 1'b0;
    assign perf_direction_mispredict = 1'b0;
    assign perf_target_mispredict = 1'b0;
    assign perf_btb_update = 1'b0;
    assign perf_btb_update_conditional = 1'b0;
    assign perf_btb_update_backward = 1'b0;
`endif

`endif

endmodule
