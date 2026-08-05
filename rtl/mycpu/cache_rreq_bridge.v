`timescale 1ns / 1ps

// Cache read bridge between the CPU and SRAM clock domains. Requests and
// returned words cross only through XPM asynchronous FIFOs.
module cache_rreq_bridge #(
    parameter integer BLK_LEN = 4,
    parameter integer CWF_EN  = 0
)(
    input  wire         cpu_rstn,
    input  wire         cpu_clk,
    input  wire         bus_rstn,
    input  wire         bus_uclk,
    input  wire         bus_grant,
    output wire         bus_req_valid,
    output wire         bus_transaction_done,
    output wire         dev_rrdy,
    input  wire [ 3:0]  cpu_ren,
    input  wire [31:0]  cpu_raddr,
    input  wire         cpu_rburst,
    output wire         dev_rvalid,
    output wire [31:0]  dev_rdata,
    output wire         bus_en,
    output wire [31:0]  bus_raddr,
    input  wire [31:0]  bus_rdata
);

    localparam integer REQUEST_WIDTH = 33;
    localparam integer FIFO_DEPTH    = 16;

    function [31:0] next_addr;
        input [31:0] cur_addr;
        input [31:0] base_addr;
        begin
            if (CWF_EN != 0) begin
                if (cur_addr == base_addr + (BLK_LEN - 1))
                    next_addr = base_addr;
                else
                    next_addr = cur_addr + 32'd1;
            end else begin
                next_addr = cur_addr + 32'd1;
            end
        end
    endfunction

    wire                     cpu_request_valid = (cpu_ren != 4'h0);
    wire                     cpu_request_ready;
    wire [REQUEST_WIDTH-1:0] cpu_request_data = {cpu_rburst, cpu_raddr};
    wire                     bus_request_valid;
    wire                     bus_request_ready;
    wire [REQUEST_WIDTH-1:0] bus_request_data;
    wire                     bus_request_burst = bus_request_data[32];
    wire [31:0]              bus_request_addr  = bus_request_data[31:0];

    CdcAsyncFifo #(
        .DATA_WIDTH (REQUEST_WIDTH),
        .FIFO_DEPTH (FIFO_DEPTH),
        .SYNC_STAGES(2)
    ) u_read_request_fifo (
        .wr_clk   (cpu_clk),
        .wr_rstn  (cpu_rstn),
        .wr_valid (cpu_request_valid),
        .wr_ready (cpu_request_ready),
        .wr_data  (cpu_request_data),
        .rd_clk   (bus_uclk),
        .rd_rstn  (bus_rstn),
        .rd_valid (bus_request_valid),
        .rd_ready (bus_request_ready),
        .rd_data  (bus_request_data)
    );

    assign dev_rrdy = cpu_request_ready;

    reg         request_active;
    reg  [31:0] request_base_addr;
    reg  [31:0] request_next_addr;
    reg  [ 7:0] request_len;
    reg  [ 7:0] issue_count;
    reg  [ 7:0] response_count;
    reg         issued_d;

    wire [31:0] accepted_word_addr = {2'b00, bus_request_addr[31:2]};
    wire [31:0] accepted_base_addr =
        accepted_word_addr - (accepted_word_addr % BLK_LEN);

    assign bus_request_ready = !request_active && !issued_d;

    wire response_write_ready;
    wire response_write_valid = issued_d;
    wire response_write_fire = response_write_valid && response_write_ready;

    // Request valid to arbiter: active read request with remaining beats
    // and space in the response FIFO to hold returning data.
    assign bus_req_valid = request_active &&
                           (issue_count < request_len) &&
                           response_write_ready;

    // Issue beat to SRAM only when granted by arbiter.
    wire bus_issue = bus_req_valid && bus_grant;

    assign bus_en    = bus_issue;
    assign bus_raddr = request_next_addr;

    wire last_response_fire = response_write_fire &&
                              ((response_count + 8'd1) == request_len);
    assign bus_transaction_done = last_response_fire;

    always @(posedge bus_uclk or negedge bus_rstn) begin
        if (!bus_rstn) begin
            request_active    <= 1'b0;
            request_base_addr <= 32'h0000_0000;
            request_next_addr <= 32'h0000_0000;
            request_len       <= 8'd0;
            issue_count       <= 8'd0;
            response_count    <= 8'd0;
            issued_d          <= 1'b0;
        end else begin
            issued_d <= bus_issue;

            if (bus_request_valid && bus_request_ready) begin
                request_active    <= 1'b1;
                request_base_addr <= accepted_base_addr;
                request_next_addr <= accepted_word_addr;
                request_len       <= bus_request_burst ? BLK_LEN : 1;
                issue_count       <= 8'd0;
                response_count    <= 8'd0;
            end else begin
                if (bus_issue) begin
                    issue_count       <= issue_count + 8'd1;
                    request_next_addr <= next_addr(request_next_addr,
                                                   request_base_addr);
                end

                if (response_write_fire) begin
                    response_count <= response_count + 8'd1;
                    if ((response_count + 8'd1) == request_len) begin
                        request_active <= 1'b0;
                        issue_count    <= 8'd0;
                        response_count <= 8'd0;
                    end
                end
            end
        end
    end

    CdcAsyncFifo #(
        .DATA_WIDTH (32),
        .FIFO_DEPTH (FIFO_DEPTH),
        .SYNC_STAGES(2)
    ) u_read_response_fifo (
        .wr_clk   (bus_uclk),
        .wr_rstn  (bus_rstn),
        .wr_valid (response_write_valid),
        .wr_ready (response_write_ready),
        .wr_data  (bus_rdata),
        .rd_clk   (cpu_clk),
        .rd_rstn  (cpu_rstn),
        .rd_valid (dev_rvalid),
        .rd_ready (1'b1),
        .rd_data  (dev_rdata)
    );

`ifndef SYNTHESIS
    initial begin
        if (BLK_LEN < 1 || BLK_LEN > FIFO_DEPTH)
            $error("cache_rreq_bridge BLK_LEN must be 1..FIFO_DEPTH");
    end

    always @(posedge bus_uclk) begin
        if (bus_rstn && response_write_valid && !response_write_ready)
            $fatal(1, "[RREQ-CDC] response FIFO backpressured an issued SRAM read");
        if (bus_rstn && bus_issue && !bus_grant)
            $fatal(1, "[RREQ-CDC] bus_issue without bus_grant");
        if (bus_rstn && bus_req_valid && !bus_grant && bus_en)
            $fatal(1, "[RREQ-CDC] bus_en asserted without bus_grant");
        if (bus_rstn && response_count > issue_count)
            $fatal(1, "[RREQ-CDC] response_count exceeded issue_count");
    end
`endif

endmodule
