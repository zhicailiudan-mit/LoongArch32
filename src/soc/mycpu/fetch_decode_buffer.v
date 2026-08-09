`timescale 1ns / 1ps

`include "defines.vh"

// Elastic instruction packet between IBUF and decode/rename.
// A consumed packet may be replaced in the same cycle, preserving 1 IPC.
module FetchDecodeBuffer (
    input  wire         cpu_clk,
    input  wire         cpu_rstn,
    input  wire         flush,

    input  wire         in_valid,
    output wire         in_ready,
    input  wire [31:0]  in_pc,
    input  wire [31:0]  in_inst,
    input  wire [ 2:0]  in_ras_ptr,
    input  wire         in_pred_valid,
    input  wire         in_pred_taken,
    input  wire [31:0]  in_pred_target,
    input  wire [ 9:0]  in_pred_index,
    input  wire [ 2:0]  in_ras_sp_before,
    input  wire [ 3:0]  in_ras_count_before,
    input  wire         in_perf_btb_hit,
    input  wire         in1_valid,
    input  wire [31:0]  in1_pc,
    input  wire [31:0]  in1_inst,
    input  wire [ 2:0]  in1_ras_ptr,
    input  wire         in1_pred_valid,
    input  wire         in1_pred_taken,
    input  wire [31:0]  in1_pred_target,
    input  wire [ 9:0]  in1_pred_index,
    input  wire [ 2:0]  in1_ras_sp_before,
    input  wire [ 3:0]  in1_ras_count_before,
    input  wire         in1_perf_btb_hit,

    output reg          out_valid,
    input  wire         out_ready,
    output reg  [31:0]  out_pc,
    output reg  [31:0]  out_inst,
    output reg  [ 2:0]  out_ras_ptr,
    output reg          out_pred_valid,
    output reg          out_pred_taken,
    output reg  [31:0]  out_pred_target,
    output reg  [ 9:0]  out_pred_index,
    output reg  [ 2:0]  out_ras_sp_before,
    output reg  [ 3:0]  out_ras_count_before,
    output reg          out_perf_btb_hit,
    output reg          out1_valid,
    output reg  [31:0]  out1_pc,
    output reg  [31:0]  out1_inst,
    output reg  [ 2:0]  out1_ras_ptr,
    output reg          out1_pred_valid,
    output reg          out1_pred_taken,
    output reg  [31:0]  out1_pred_target,
    output reg  [ 9:0]  out1_pred_index,
    output reg  [ 2:0]  out1_ras_sp_before,
    output reg  [ 3:0]  out1_ras_count_before,
    output reg          out1_perf_btb_hit
);

    assign in_ready = !out_valid || out_ready;

    always @(posedge cpu_clk or negedge cpu_rstn) begin
        if (!cpu_rstn) begin
            out_valid            <= 1'b0;
            out_pc               <= 32'h0;
            out_inst             <= 32'h0;
            out_ras_ptr          <= 3'h0;
            out_pred_valid       <= 1'b0;
            out_pred_taken       <= 1'b0;
            out_pred_target      <= 32'h0;
            out_pred_index       <= 10'h0;
            out_ras_sp_before    <= 3'h0;
            out_ras_count_before <= 4'h0;
            out_perf_btb_hit      <= 1'b0;
            out1_valid            <= 1'b0;
            out1_pc               <= 32'h0;
            out1_inst             <= 32'h0;
            out1_ras_ptr          <= 3'h0;
            out1_pred_valid       <= 1'b0;
            out1_pred_taken       <= 1'b0;
            out1_pred_target      <= 32'h0;
            out1_pred_index       <= 10'h0;
            out1_ras_sp_before    <= 3'h0;
            out1_ras_count_before <= 4'h0;
            out1_perf_btb_hit      <= 1'b0;
        end
        else if (flush) begin
            out_valid <= 1'b0;
            out1_valid <= 1'b0;
        end
        else if (in_ready) begin
            out_valid <= in_valid;
            out1_valid <= in_valid && in1_valid;
            if (in_valid) begin
                out_pc               <= in_pc;
                out_inst             <= in_inst;
                out_ras_ptr          <= in_ras_ptr;
                out_pred_valid       <= in_pred_valid;
                out_pred_taken       <= in_pred_taken;
                out_pred_target      <= in_pred_target;
                out_pred_index       <= in_pred_index;
                out_ras_sp_before    <= in_ras_sp_before;
                out_ras_count_before <= in_ras_count_before;
                out_perf_btb_hit      <= in_perf_btb_hit;
            end
            if (in_valid && in1_valid) begin
                out1_pc               <= in1_pc;
                out1_inst             <= in1_inst;
                out1_ras_ptr          <= in1_ras_ptr;
                out1_pred_valid       <= in1_pred_valid;
                out1_pred_taken       <= in1_pred_taken;
                out1_pred_target      <= in1_pred_target;
                out1_pred_index       <= in1_pred_index;
                out1_ras_sp_before    <= in1_ras_sp_before;
                out1_ras_count_before <= in1_ras_count_before;
                out1_perf_btb_hit      <= in1_perf_btb_hit;
            end
        end
    end

endmodule
