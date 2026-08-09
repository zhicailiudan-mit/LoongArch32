`timescale 1ns / 1ps

module async_fifo #(
    parameter DATA_WIDTH = 32,
    parameter FIFO_DEPTH = 4    // 2^n
) (
    input  wire         rstn,
    // Write Port
    input  wire         wr_clk,
    input  wire         wr_en,
    input  wire [DATA_WIDTH-1:0] din,
    output wire         full,
    // Read Port
    input  wire         rd_clk,
    input  wire         rd_en,
    output wire [DATA_WIDTH-1:0] dout,
    output wire         empty
);

    localparam ADDR_WIDTH = $clog2(FIFO_DEPTH);

    reg [DATA_WIDTH-1:0] mem [0:FIFO_DEPTH-1];
    reg [DATA_WIDTH-1:0] dout_fwft, dout_hold;

    reg [ADDR_WIDTH:0] wr_ptr_bin, wr_ptr_gray;
    reg [ADDR_WIDTH:0] rd_ptr_bin, rd_ptr_gray;

    reg [ADDR_WIDTH:0] wr_ptr_gray_rdclk1, wr_ptr_gray_rdclk2;
    reg [ADDR_WIDTH:0] rd_ptr_gray_wrclk1, rd_ptr_gray_wrclk2;

    wire [ADDR_WIDTH:0] wr_ptr_bin_next  = wr_ptr_bin + 1;
    wire [ADDR_WIDTH:0] wr_ptr_gray_next = (wr_ptr_bin_next >> 1) ^ wr_ptr_bin_next;

    integer i;
    always @(posedge wr_clk or negedge rstn) begin
        if (!rstn) begin
            wr_ptr_bin  <= 0;
            wr_ptr_gray <= 0;
            for (i = 0; i < FIFO_DEPTH; i = i + 1)
                mem[i] <= {DATA_WIDTH{1'b0}};
        end else begin
            if (wr_en & !full) begin
                mem[wr_ptr_bin[ADDR_WIDTH-1:0]] <= din;
                wr_ptr_bin  <= wr_ptr_bin_next;
                wr_ptr_gray <= wr_ptr_gray_next;
            end
        end
    end

    assign full = (wr_ptr_gray_next == {~rd_ptr_gray_wrclk2[ADDR_WIDTH:ADDR_WIDTH-1], rd_ptr_gray_wrclk2[ADDR_WIDTH-2:0]});

    always @(posedge rd_clk or negedge rstn)
        dout_fwft <= !rstn ? {DATA_WIDTH{1'b0}} : mem[rd_ptr_bin[ADDR_WIDTH-1:0]]; 
    always @(posedge rd_clk)
        if (rd_en & !empty) dout_hold <= dout_fwft;     
        
    assign dout = (rd_en & !empty) ? dout_fwft : dout_hold;

    always @(posedge rd_clk or negedge rstn) begin
        if (!rstn) begin
            rd_ptr_bin  <= 0;
            rd_ptr_gray <= 0;
        end else if (rd_en && !empty) begin
            rd_ptr_bin  <= rd_ptr_bin + 1'b1;
            rd_ptr_gray <= (rd_ptr_bin + 1'b1) ^ ((rd_ptr_bin + 1'b1) >> 1);
        end
    end

    assign empty = (rd_ptr_gray == wr_ptr_gray_rdclk2);

    always @(posedge rd_clk or negedge rstn) begin
        if (!rstn) begin
            wr_ptr_gray_rdclk1 <= 0;
            wr_ptr_gray_rdclk2 <= 0;
        end else begin
            wr_ptr_gray_rdclk1 <= wr_ptr_gray;
            wr_ptr_gray_rdclk2 <= wr_ptr_gray_rdclk1;
        end
    end

    always @(posedge wr_clk or negedge rstn) begin
        if (!rstn) begin
            rd_ptr_gray_wrclk1 <= 0;
            rd_ptr_gray_wrclk2 <= 0;
        end else begin
            rd_ptr_gray_wrclk1 <= rd_ptr_gray;
            rd_ptr_gray_wrclk2 <= rd_ptr_gray_wrclk1;
        end
    end

endmodule

// Per-clock-domain reset synchronizer used by the XPM CDC channels below.
// Assertion follows the board reset asynchronously; deassertion must pass
// through every stage in the destination clock domain.
module ResetDomainSync #(
    parameter integer STAGES = 2
) (
    input  wire clk,
    input  wire async_rstn,
    output wire sync_rstn
);

    (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *)
    reg [STAGES-1:0] sync_pipe;

    always @(posedge clk or negedge async_rstn) begin
        if (!async_rstn)
            sync_pipe <= {STAGES{1'b0}};
        else
            sync_pipe <= {sync_pipe[STAGES-2:0], 1'b1};
    end

    assign sync_rstn = sync_pipe[STAGES-1];


endmodule

// Ready/valid wrapper around the Vivado 2019.2 XPM asynchronous FIFO.
// No status or payload signal crosses the module boundary without being
// handled by the XPM primitive.  The read side uses FWFT so rd_valid/rd_data
// remain stable until the consumer accepts the packet.
module CdcAsyncFifo #(
    parameter integer DATA_WIDTH = 32,
    parameter integer FIFO_DEPTH = 16,
    parameter integer SYNC_STAGES = 2
) (
    input  wire                  wr_clk,
    input  wire                  wr_rstn,
    input  wire                  wr_valid,
    output wire                  wr_ready,
    input  wire [DATA_WIDTH-1:0] wr_data,
    input  wire                  rd_clk,
    input  wire                  rd_rstn,
    output wire                  rd_valid,
    input  wire                  rd_ready,
    output wire [DATA_WIDTH-1:0] rd_data
);

    localparam integer COUNT_WIDTH = $clog2(FIFO_DEPTH) + 1;

    wire fifo_full;
    wire fifo_empty;
    wire wr_rst_busy;
    wire rd_rst_busy;
    reg  xpm_rst;
    wire fifo_wr_en = wr_valid && wr_ready;
    wire fifo_rd_en = rd_valid && rd_ready;

    // xpm_fifo_async requires rst to be synchronous to wr_clk.
    always @(posedge wr_clk)
        xpm_rst <= !wr_rstn;

    assign wr_ready = wr_rstn && !wr_rst_busy && !fifo_full;
    assign rd_valid = rd_rstn && !rd_rst_busy && !fifo_empty;

    xpm_fifo_async #(
        .FIFO_MEMORY_TYPE    ("auto"),
        .ECC_MODE            ("no_ecc"),
        .RELATED_CLOCKS      (0),
        .FIFO_WRITE_DEPTH    (FIFO_DEPTH),
        .WRITE_DATA_WIDTH    (DATA_WIDTH),
        .WR_DATA_COUNT_WIDTH (COUNT_WIDTH),
        .PROG_FULL_THRESH    (FIFO_DEPTH - 3),
        .FULL_RESET_VALUE    (0),
        .USE_ADV_FEATURES    ("0000"),
        .READ_MODE           ("fwft"),
        .FIFO_READ_LATENCY   (0),
        .READ_DATA_WIDTH     (DATA_WIDTH),
        .RD_DATA_COUNT_WIDTH (COUNT_WIDTH),
        .PROG_EMPTY_THRESH   (3),
        .DOUT_RESET_VALUE    ("0"),
        .CDC_SYNC_STAGES     (SYNC_STAGES)
    ) u_xpm_fifo_async (
        .sleep         (1'b0),
        .rst           (xpm_rst),
        .wr_clk        (wr_clk),
        .wr_en         (fifo_wr_en),
        .din           (wr_data),
        .full          (fifo_full),
        .prog_full     (),
        .wr_data_count (),
        .overflow      (),
        .wr_rst_busy   (wr_rst_busy),
        .almost_full   (),
        .wr_ack        (),
        .rd_clk        (rd_clk),
        .rd_en         (fifo_rd_en),
        .dout          (rd_data),
        .empty         (fifo_empty),
        .prog_empty    (),
        .rd_data_count (),
        .underflow     (),
        .rd_rst_busy   (rd_rst_busy),
        .almost_empty  (),
        .data_valid    (),
        .injectsbiterr (1'b0),
        .injectdbiterr (1'b0),
        .sbiterr       (),
        .dbiterr       ()
    );


endmodule
