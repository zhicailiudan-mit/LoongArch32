`timescale 1ns / 1ps

`include "defines.vh"

// Cache-facing to AXI3/AXI4-compatible master bridge used by the official
// LA32R SoC shell. It accepts one queued I-cache read and one queued D-cache
// read, maintains one AXI read transaction in flight, and independently
// maintains one AXI write transaction in flight.
module AxiCacheBridge (
    input  wire        aclk,
    input  wire        aresetn,

    output wire        ic_dev_rrdy,
    input  wire        ic_cpu_ren,
    input  wire [31:0] ic_cpu_raddr,
    output reg         ic_dev_rvalid,
    output reg  [31:0] ic_dev_rdata,

    output wire        dc_dev_rrdy,
    input  wire [3:0]  dc_cpu_ren,
    input  wire [31:0] dc_cpu_raddr,
    input  wire        dc_cpu_rburst,
    output reg         dc_dev_rvalid,
    output reg  [31:0] dc_dev_rdata,

    output wire        dc_dev_wrdy,
    output wire        dc_dev_wdone,
    input  wire [3:0]  dc_cpu_wen,
    input  wire [31:0] dc_cpu_waddr,
    input  wire [31:0] dc_cpu_wdata,

    output wire [3:0]  arid,
    output wire [31:0] araddr,
    output wire [7:0]  arlen,
    output wire [2:0]  arsize,
    output wire [1:0]  arburst,
    output wire [1:0]  arlock,
    output wire [3:0]  arcache,
    output wire [2:0]  arprot,
    output wire        arvalid,
    input  wire        arready,
    input  wire [3:0]  rid,
    input  wire [31:0] rdata,
    input  wire [1:0]  rresp,
    input  wire        rlast,
    input  wire        rvalid,
    output wire        rready,

    output wire [3:0]  awid,
    output wire [31:0] awaddr,
    output wire [7:0]  awlen,
    output wire [2:0]  awsize,
    output wire [1:0]  awburst,
    output wire [1:0]  awlock,
    output wire [3:0]  awcache,
    output wire [2:0]  awprot,
    output wire        awvalid,
    input  wire        awready,
    output wire [3:0]  wid,
    output wire [31:0] wdata,
    output wire [3:0]  wstrb,
    output wire        wlast,
    output wire        wvalid,
    input  wire        wready,
    input  wire [3:0]  bid,
    input  wire [1:0]  bresp,
    input  wire        bvalid,
    output wire        bready
);
    localparam OWNER_IC = 1'b0;
    localparam OWNER_DC = 1'b1;

    reg        ic_pending;
    reg [31:0] ic_pending_addr;
    reg        dc_pending;
    reg [31:0] dc_pending_addr;
    reg [3:0]  dc_pending_ren;
    reg        dc_pending_burst;

    reg        read_active;
    reg        read_owner;
    reg [31:0] read_addr;
    reg [31:0] read_original_addr;
    reg [7:0]  read_len;
    reg [2:0]  read_size;
    reg        arvalid_r;
    reg        ar_sent;
    reg [2:0]  read_beat;

    reg [31:0] ic_line [0:`CACHE_BLK_LEN-1];
    reg        ic_emit;
    reg [2:0]  ic_emit_start;
    reg [2:0]  ic_emit_count;

    integer i;

    assign ic_dev_rrdy = aresetn && !ic_pending && !ic_emit;
    assign dc_dev_rrdy = aresetn && !dc_pending;

    assign arid    = read_owner == OWNER_DC ? 4'h1 : 4'h0;
    assign araddr  = read_addr;
    assign arlen   = read_len;
    assign arsize  = read_size;
    // D-cache bursts start at the demanded word and wrap inside the line so
    // the critical word is returned first. I-cache bursts remain incrementing
    // because their line is buffered and reordered locally below.
    assign arburst = (read_owner == OWNER_DC && (read_len != 0)) ?
                     2'b10 : 2'b01;
    assign arlock  = 2'b00;
    assign arcache = 4'b0011;
    assign arprot  = 3'b000;
    assign arvalid = arvalid_r;
    assign rready  = read_active && ar_sent;

    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            ic_pending <= 1'b0;
            ic_pending_addr <= 32'h0;
            dc_pending <= 1'b0;
            dc_pending_addr <= 32'h0;
            dc_pending_ren <= 4'h0;
            dc_pending_burst <= 1'b0;
            read_active <= 1'b0;
            read_owner <= OWNER_IC;
            read_addr <= 32'h0;
            read_original_addr <= 32'h0;
            read_len <= 8'h0;
            read_size <= 3'b010;
            arvalid_r <= 1'b0;
            ar_sent <= 1'b0;
            read_beat <= 3'h0;
            ic_emit <= 1'b0;
            ic_emit_start <= 3'h0;
            ic_emit_count <= 3'h0;
            ic_dev_rvalid <= 1'b0;
            ic_dev_rdata <= 32'h0;
            dc_dev_rvalid <= 1'b0;
            dc_dev_rdata <= 32'h0;
            for (i = 0; i < `CACHE_BLK_LEN; i = i + 1)
                ic_line[i] <= 32'h0;
        end else begin
            ic_dev_rvalid <= 1'b0;
            dc_dev_rvalid <= 1'b0;

            if (ic_cpu_ren && ic_dev_rrdy) begin
                ic_pending <= 1'b1;
                ic_pending_addr <= ic_cpu_raddr;
            end
            if (dc_cpu_ren && dc_dev_rrdy) begin
                dc_pending <= 1'b1;
                dc_pending_addr <= dc_cpu_raddr;
                dc_pending_ren <= dc_cpu_ren;
                dc_pending_burst <= dc_cpu_rburst;
            end

            // D-cache has priority only at transaction boundaries. An I-cache
            // request already accepted into its pending slot cannot be lost.
            if (!read_active) begin
                if (dc_pending) begin
                    dc_pending <= 1'b0;
                    read_active <= 1'b1;
                    read_owner <= OWNER_DC;
                    read_addr <= dc_pending_addr;
                    read_original_addr <= dc_pending_addr;
                    read_len <= dc_pending_burst ?
                                (`CACHE_BLK_LEN - 1) : 8'h0;
                    case (dc_pending_ren)
                        4'b0001, 4'b0010, 4'b0100, 4'b1000:
                            read_size <= 3'b000;
                        4'b0011, 4'b0110, 4'b1100:
                            read_size <= 3'b001;
                        default:
                            read_size <= 3'b010;
                    endcase
                    if (dc_pending_burst)
                        read_size <= 3'b010;
                    arvalid_r <= 1'b1;
                    ar_sent <= 1'b0;
                    read_beat <= 3'h0;
                end else if (ic_pending && !ic_emit) begin
                    ic_pending <= 1'b0;
                    read_active <= 1'b1;
                    read_owner <= OWNER_IC;
                    // AXI INCR must begin at the line base. Beats are buffered
                    // and later emitted in the critical-word-first order that
                    // the existing ICache refill state machine expects.
                    read_addr <= {ic_pending_addr[31:5], 5'b00000};
                    read_original_addr <= ic_pending_addr;
                    read_len <= `CACHE_BLK_LEN - 1;
                    read_size <= 3'b010;
                    arvalid_r <= 1'b1;
                    ar_sent <= 1'b0;
                    read_beat <= 3'h0;
                end
            end

            if (arvalid_r && arready) begin
                arvalid_r <= 1'b0;
                ar_sent <= 1'b1;
            end

            if (rvalid && rready) begin
                if (read_owner == OWNER_DC) begin
                    dc_dev_rvalid <= 1'b1;
                    dc_dev_rdata <= rdata;
                end else begin
                    ic_line[read_beat] <= rdata;
                end

                if (rlast || (read_beat == read_len[2:0])) begin
                    read_active <= 1'b0;
                    ar_sent <= 1'b0;
                    read_beat <= 3'h0;
                    if (read_owner == OWNER_IC) begin
                        ic_emit <= 1'b1;
                        ic_emit_start <= read_original_addr[4:2];
                        ic_emit_count <= 3'h0;
                    end
                end else begin
                    read_beat <= read_beat + 3'd1;
                end
            end

            if (ic_emit) begin
                ic_dev_rvalid <= 1'b1;
                ic_dev_rdata <= ic_line[ic_emit_start + ic_emit_count];
                if (ic_emit_count == `CACHE_BLK_LEN - 1) begin
                    ic_emit <= 1'b0;
                    ic_emit_count <= 3'h0;
                end else begin
                    ic_emit_count <= ic_emit_count + 3'd1;
                end
            end
        end
    end

    reg        write_busy;
    reg        awvalid_r;
    reg        wvalid_r;
    reg [31:0] write_addr;
    reg [31:0] write_data;
    reg [3:0]  write_strb;

    assign dc_dev_wrdy = aresetn && !write_busy;
    assign dc_dev_wdone = aresetn && write_busy && !awvalid_r &&
                          !wvalid_r && bvalid && bready;
    assign awid    = 4'h2;
    assign awaddr  = write_addr;
    assign awlen   = 8'h00;
    assign awsize  = 3'b010;
    assign awburst = 2'b01;
    assign awlock  = 2'b00;
    assign awcache = 4'b0011;
    assign awprot  = 3'b000;
    assign awvalid = awvalid_r;
    assign wid     = 4'h2;
    assign wdata   = write_data;
    assign wstrb   = write_strb;
    assign wlast   = 1'b1;
    assign wvalid  = wvalid_r;
    assign bready  = write_busy && !awvalid_r && !wvalid_r;

    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            write_busy <= 1'b0;
            awvalid_r <= 1'b0;
            wvalid_r <= 1'b0;
            write_addr <= 32'h0;
            write_data <= 32'h0;
            write_strb <= 4'h0;
        end else begin
            if ((dc_cpu_wen != 4'h0) && dc_dev_wrdy) begin
                write_busy <= 1'b1;
                awvalid_r <= 1'b1;
                wvalid_r <= 1'b1;
                write_addr <= dc_cpu_waddr;
                write_data <= dc_cpu_wdata;
                write_strb <= dc_cpu_wen;
            end
            if (awvalid_r && awready)
                awvalid_r <= 1'b0;
            if (wvalid_r && wready)
                wvalid_r <= 1'b0;
            if (bvalid && bready)
                write_busy <= 1'b0;
        end
    end

    // Responses are completed even when SLVERR/DECERR is reported; exception
    // plumbing is not yet present in this core. Keep IDs/responses observable
    // to synthesis and lint without changing architectural data behavior.
    wire unused_axi_response = ^{rid, rresp, bid, bresp};
endmodule
