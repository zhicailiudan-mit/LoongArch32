`timescale 1ns / 1ps

module cache_wreq_bridge(
    input  wire         cpu_rstn,
    input  wire         cpu_clk,
    input  wire         bus_rstn,
    // Cache Write Interface
    output wire         dev_wrdy,       // request FIFO can accept one write
    output wire         dev_wdone,      // one accepted write reached the bus
    output wire         dev_widle,      // no accepted write remains outstanding
    input  wire [ 3:0]  cpu_wen,
    input  wire [31:0]  cpu_waddr,
    input  wire [31:0]  cpu_wdata,
    // SRAM-User Interface
    input  wire         bus_uclk,
    input  wire         bus_grant,
    output wire         bus_req_valid,
    output wire         bus_transaction_done,
    output wire         bus_en,
    output wire [31:0]  bus_waddr,
    output wire [ 3:0]  bus_we,
    output wire [31:0]  bus_wdata
);

    localparam integer REQUEST_WIDTH = 68;
    localparam integer FIFO_DEPTH = 16;

    // ------------------------------------------------------------------
    // CPU -> SRAM write-request channel
    // ------------------------------------------------------------------
    wire                     request_valid = (cpu_wen != 4'h0);
    wire                     request_ready;
    wire [REQUEST_WIDTH-1:0] request_payload =
        {cpu_wen, cpu_waddr, cpu_wdata};
    wire                     request_fire = request_valid && request_ready;

    wire                     bus_request_valid;
    wire                     bus_request_ready;
    wire [REQUEST_WIDTH-1:0] bus_request_payload;
    wire [ 3:0]              bus_request_we = bus_request_payload[67:64];
    wire [31:0]              bus_request_addr = bus_request_payload[63:32];
    wire [31:0]              bus_request_data = bus_request_payload[31:0];

    CdcAsyncFifo #(
        .DATA_WIDTH (REQUEST_WIDTH),
        .FIFO_DEPTH (FIFO_DEPTH),
        .SYNC_STAGES(2)
    ) u_write_request_fifo (
        .wr_clk   (cpu_clk),
        .wr_rstn  (cpu_rstn),
        .wr_valid (request_valid),
        .wr_ready (request_ready),
        .wr_data  (request_payload),
        .rd_clk   (bus_uclk),
        .rd_rstn  (bus_rstn),
        .rd_valid (bus_request_valid),
        .rd_ready (bus_request_ready),
        .rd_data  (bus_request_payload)
    );

    assign dev_wrdy = request_ready;

    // ------------------------------------------------------------------
    // SRAM -> CPU completion channel
    // ------------------------------------------------------------------
    wire completion_write_ready;
    wire completion_read_valid;
    wire completion_read_ready = 1'b1;
    wire completion_fire = completion_read_valid && completion_read_ready;

    // SRAM has no separate response channel.  A write completes when its
    // byte-enable is actually presented to the SRAM/peripheral bus.  Couple
    // request pop, bus write and completion-token push atomically so neither
    // a write nor its acknowledgement can be lost under backpressure.
    assign bus_req_valid = bus_request_valid && completion_write_ready &&
                           (|bus_request_we);

    wire bus_write_fire = bus_req_valid && bus_grant;
    assign bus_transaction_done = bus_write_fire;

    assign bus_request_ready = bus_write_fire;
    assign bus_en             = bus_write_fire;
    assign bus_we             = bus_write_fire ? bus_request_we : 4'h0;
    assign bus_wdata          = bus_request_data;

    wire wr_peripheral = (bus_request_addr[31:16] == 16'hBFAF) ||
                         (bus_request_addr[31:16] == 16'hBFD0);
    wire [31:0] wr_word_addr = {2'b00, bus_request_addr[31:2]};
    assign bus_waddr = wr_peripheral ? bus_request_addr : wr_word_addr;

    CdcAsyncFifo #(
        .DATA_WIDTH (1),
        .FIFO_DEPTH (FIFO_DEPTH),
        .SYNC_STAGES(2)
    ) u_write_completion_fifo (
        .wr_clk   (bus_uclk),
        .wr_rstn  (bus_rstn),
        .wr_valid (bus_write_fire),
        .wr_ready (completion_write_ready),
        .wr_data  (1'b1),
        .rd_clk   (cpu_clk),
        .rd_rstn  (cpu_rstn),
        .rd_valid (completion_read_valid),
        .rd_ready (completion_read_ready),
        .rd_data  ()
    );

    assign dev_wdone = completion_fire;

    // Track accepted-but-not-completed writes entirely in the CPU domain.
    // This replaces the old multi-bit Gray counter and makes dev_widle exact
    // even when several completion tokens arrive in consecutive CPU cycles.
    // At most one request FIFO plus one completion FIFO can be resident:
    // 16 + 16 entries.  Six bits cover the full legal outstanding range.
    reg [5:0] outstanding_count;
    always @(posedge cpu_clk or negedge cpu_rstn) begin
        if (!cpu_rstn)
            outstanding_count <= 6'd0;
        else begin
            case ({request_fire, completion_fire})
                2'b10: outstanding_count <= outstanding_count + 6'd1;
                2'b01: outstanding_count <= outstanding_count - 6'd1;
                default: outstanding_count <= outstanding_count;
            endcase
        end
    end

    assign dev_widle = cpu_rstn && (outstanding_count == 6'd0) &&
                       !request_valid;

`ifndef SYNTHESIS
    always @(posedge cpu_clk) begin
        if (cpu_rstn && completion_fire && !request_fire &&
            (outstanding_count == 6'd0))
            $fatal(1, "[WREQ-CDC] completion without an outstanding write");
    end

    always @(posedge bus_uclk) begin
        if (bus_rstn && bus_en && !(|bus_we))
            $fatal(1, "[WREQ-CDC] bus_en asserted without a write mask");
        if (bus_rstn && bus_write_fire && !bus_grant)
            $fatal(1, "[WREQ-CDC] bus_write_fire without bus_grant");
        if (bus_rstn && bus_req_valid && !bus_grant && bus_request_ready)
            $fatal(1, "[WREQ-CDC] write FIFO popped without bus_grant");
    end
`endif

endmodule
