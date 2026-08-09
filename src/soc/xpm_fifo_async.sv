`timescale 1ns / 1ps

`ifdef VERILATOR

/*
 * Verilator-only stub for Xilinx xpm_fifo_async.
 *
 * The official CI runs Verilator lint before Vivado synthesis.
 * Verilator cannot automatically load the Xilinx XPM HDL library,
 * so this module declaration is provided for lint elaboration only.
 *
 * Vivado does not define VERILATOR. Therefore, this stub is excluded
 * from Vivado synthesis, and Vivado continues to use the real Xilinx
 * xpm_fifo_async implementation.
 *
 * This module does not model FIFO behavior. Its outputs are fixed only
 * to prevent false combinational feedback paths during static lint.
 */

module xpm_fifo_async #(
    parameter         FIFO_MEMORY_TYPE     = "auto",
    parameter         ECC_MODE             = "no_ecc",
    parameter integer RELATED_CLOCKS       = 0,
    parameter integer FIFO_WRITE_DEPTH     = 2048,
    parameter integer WRITE_DATA_WIDTH     = 32,
    parameter integer WR_DATA_COUNT_WIDTH  = 1,
    parameter integer PROG_FULL_THRESH     = 10,
    parameter integer FULL_RESET_VALUE     = 0,
    parameter         USE_ADV_FEATURES     = "0707",
    parameter         READ_MODE            = "std",
    parameter integer FIFO_READ_LATENCY    = 1,
    parameter integer READ_DATA_WIDTH      = 32,
    parameter integer RD_DATA_COUNT_WIDTH  = 1,
    parameter integer PROG_EMPTY_THRESH    = 10,
    parameter         DOUT_RESET_VALUE     = "0",
    parameter integer CDC_SYNC_STAGES      = 2
) (
    input  wire                            sleep,
    input  wire                            rst,

    input  wire                            wr_clk,
    input  wire                            wr_en,
    input  wire [WRITE_DATA_WIDTH-1:0]     din,

    output wire                            full,
    output wire                            prog_full,
    output wire [WR_DATA_COUNT_WIDTH-1:0]  wr_data_count,
    output wire                            overflow,
    output wire                            wr_rst_busy,
    output wire                            almost_full,
    output wire                            wr_ack,

    input  wire                            rd_clk,
    input  wire                            rd_en,

    output wire [READ_DATA_WIDTH-1:0]       dout,
    output wire                            empty,
    output wire                            prog_empty,
    output wire [RD_DATA_COUNT_WIDTH-1:0]  rd_data_count,
    output wire                            underflow,
    output wire                            rd_rst_busy,
    output wire                            almost_empty,
    output wire                            data_valid,

    input  wire                            injectsbiterr,
    input  wire                            injectdbiterr,
    output wire                            sbiterr,
    output wire                            dbiterr
);

    /*
     * Lint-only idle state.
     *
     * Keep full low and empty high so the surrounding ready/valid logic
     * does not form artificial combinational feedback loops.
     */
    assign full          = 1'b0;
    assign prog_full     = 1'b0;
    assign wr_data_count = {WR_DATA_COUNT_WIDTH{1'b0}};
    assign overflow      = 1'b0;
    assign wr_rst_busy   = 1'b0;
    assign almost_full   = 1'b0;
    assign wr_ack        = 1'b0;

    assign dout          = {READ_DATA_WIDTH{1'b0}};
    assign empty         = 1'b1;
    assign prog_empty    = 1'b1;
    assign rd_data_count = {RD_DATA_COUNT_WIDTH{1'b0}};
    assign underflow     = 1'b0;
    assign rd_rst_busy   = 1'b0;
    assign almost_empty  = 1'b1;
    assign data_valid    = 1'b0;

    assign sbiterr       = 1'b0;
    assign dbiterr       = 1'b0;

endmodule

`endif