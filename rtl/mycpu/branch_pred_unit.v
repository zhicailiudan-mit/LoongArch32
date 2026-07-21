`timescale 1ns / 1ps

`include "defines.vh"

`define BHT_IDX_W 10
`define BHT_ENTRY (1 << `BHT_IDX_W)
`define BHT_TAG_W 8

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
    input  wire         pl_suspend ,

    // predict branch direction and target
    output wire [31:0]  pred_target,
    output wire         pred_taken_out,
    output wire [ 9:0]  pred_index_out,
    output wire [ 2:0]  pred_ras_sp_before,
    output wire [ 3:0]  pred_ras_count_before,
    output wire         pred_error ,

    // signals to correct BHT
    input  wire         ex_valid   ,
    input  wire         ex_is_bj   ,
    input  wire         ex_is_call ,
    input  wire         ex_is_ret  ,
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

    wire [`BHT_TAG_W-1:0] if_tag =
        if_pc[9:2] ^ if_pc[17:10] ^ if_pc[25:18] ^ {2'b00, if_pc[31:26]};

    wire [`BHT_TAG_W-1:0] ex_tag =
        ex_pc[9:2] ^ ex_pc[17:10] ^ ex_pc[25:18] ^ {2'b00, ex_pc[31:26]};

    wire [31:0] pc_hash       = if_pc ^ (if_pc >> 10) ^ (if_pc >> 20);
    wire [31:0] ex_pc_hash    = ex_pc ^ (ex_pc >> 10) ^ (ex_pc >> 20);

    wire [`BHT_IDX_W-1:0] index          = pc_hash[`BHT_IDX_W+1:2];
    wire [`BHT_IDX_W-1:0] ex_index_real  = ex_pc_hash[`BHT_IDX_W+1:2];

    wire hit = (tag[index] == if_tag) && valid[index];

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
    // A BTB tag match alone is not enough to classify an instruction as
    // control flow.  Aliasing can make an ordinary ALU/load/store PC hit an
    // old branch entry.  The fetch instruction is already available at this
    // boundary, so qualify all taken predictions with the LA32R branch/jump
    // opcode range (JIRL, B/BL and the conditional branches).
    wire [5:0] if_major_op = ifetch_inst[31:26];
    wire if_is_control = ifetch_valid &&
                         (if_major_op >= 6'h13) &&
                         (if_major_op <= 6'h1b);
    wire ras_pred_taken = if_is_control & hit_ret & !ras_empty;

    wire btb_pred_taken = if_is_control & hit & !hit_ret &
                          (hit_call | history[index][1]);

    wire pred_taken = ras_pred_taken | btb_pred_taken;

    assign pred_target = ras_pred_taken ? ras_top :
                         btb_pred_taken ? target[index] :
                                          if_pc + 32'h4;
    assign pred_taken_out        = pred_taken;
    assign pred_index_out        = index;
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
            end
        end
        else if (train_valid && !train_is_bj && train_pred_valid && train_pred_taken) begin
            if (valid[train_index] && (tag[train_index] == train_tag)) begin
                entry_call[train_index] <= 1'b0;
                entry_ret [train_index] <= 1'b0;
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
    assign pred_ras_sp_before    = 3'h0;
    assign pred_ras_count_before = 4'h0;

`endif

endmodule
