`timescale 1ns/1ps

`include "defines.vh"

module tb_dcache;
    logic cpu_rstn;
    logic cpu_clk;
    logic [3:0] data_ren;
    logic [31:0] data_addr;
    logic data_cacheable;
    wire data_rready;
    wire data_valid;
    wire [31:0] data_rdata;
    logic [3:0] data_wen;
    logic [31:0] data_wdata;
    wire data_wready;
    wire data_wposted;
    wire data_wresp;
    logic dev_wrdy;
    wire [3:0] cpu_wen;
    wire [31:0] cpu_waddr;
    wire [31:0] cpu_wdata;
    logic dev_rrdy;
    wire [3:0] cpu_ren;
    wire [31:0] cpu_raddr;
    logic dev_rvalid;
    logic [31:0] dev_rdata;
    logic maint_valid;
    wire maint_ready;
    wire maint_done;
    logic maint_all;
    logic [1:0] maint_mode;
    logic [31:0] maint_addr;
    logic [31:0] maint_ctag;
    integer refill_left;
    bit hold_read_ready;
    bit read_seen;
    bit write_seen;
    bit mmio_response_seen;
    integer bus_read_requests;
    integer i;

    `include "tb_common.svh"

    DCache dut (
        .cpu_rstn      (cpu_rstn),
        .cpu_clk       (cpu_clk),
        .data_ren      (data_ren),
        .data_addr     (data_addr),
        .data_cacheable(data_cacheable),
        .data_rready   (data_rready),
        .data_valid    (data_valid),
        .data_rdata    (data_rdata),
        .data_wen      (data_wen),
        .data_wdata    (data_wdata),
        .data_wready   (data_wready),
        .data_wposted  (data_wposted),
        .data_wresp    (data_wresp),
        .dev_wrdy      (dev_wrdy),
        .dev_wdone     (1'b1),
        .dev_widle     (1'b1),
        .cpu_wen       (cpu_wen),
        .cpu_waddr     (cpu_waddr),
        .cpu_wdata     (cpu_wdata),
        .dev_rrdy      (dev_rrdy),
        .cpu_ren       (cpu_ren),
        .cpu_raddr     (cpu_raddr),
        .dev_rvalid    (dev_rvalid),
        .dev_rdata     (dev_rdata),
        .maint_valid   (maint_valid),
        .maint_ready   (maint_ready),
        .maint_done    (maint_done),
        .maint_all     (maint_all),
        .maint_mode    (maint_mode),
        .maint_addr    (maint_addr),
        .maint_ctag    (maint_ctag)
    );

    initial begin
        cpu_clk = 1'b0;
        forever #5 cpu_clk = ~cpu_clk;
    end

    // Eight-word refill BFM.  The first word is A0000000 and subsequent words
    // increment by one, making the selected word and refill order observable.
    always @(negedge cpu_clk) begin
        dev_wrdy = 1'b1;
        dev_rrdy = !hold_read_ready;
        dev_rvalid = 1'b0;
        dev_rdata = 32'h0;

        if (refill_left > 0) begin
            dev_rvalid = 1'b1;
            dev_rdata = 32'hA000_0000 + (8 - refill_left);
            refill_left = refill_left - 1;
        end
        if ((cpu_ren != 4'h0) && (refill_left == 0))
            refill_left = 8;

        // dev_rrdy is assigned above.  Allow the combinational cpu_ren pulse
        // to settle before sampling it, so the BFM does not miss the request
        // on the same edge that releases read-bus backpressure.
        #1;
        if ((cpu_ren != 4'h0) && (refill_left == 0))
            refill_left = 8;

    end

    always @(posedge cpu_clk) begin
        if (cpu_rstn && (cpu_ren != 4'h0) && dev_rrdy)
            bus_read_requests <= bus_read_requests + 1;
    end

    task automatic idle_cpu_request;
        begin
            data_ren = 4'h0;
            data_wen = 4'h0;
            data_addr = 32'h0;
            data_wdata = 32'h0;
            data_cacheable = 1'b0;
        end
    endtask

    task automatic issue_read(input logic [31:0] address,
                              input logic [31:0] expected,
                              input bit expect_bus_refill);
        integer requests_before;
        begin
            requests_before = bus_read_requests;
            read_seen = 1'b0;
            @(negedge cpu_clk);
            data_addr = address;
            data_ren = 4'hf;
            data_cacheable = 1'b1;
            if (!expect_bus_refill)
                tb_expect(data_rready, "DCache accepts hit read");
            @(posedge cpu_clk);
            #1;
            data_ren = 4'h0;
            for (i = 0; i < 80; i = i + 1) begin
                @(negedge cpu_clk);
                #1;
                if (data_valid) begin
                    read_seen = 1'b1;
                    if (data_rdata != expected) begin
                        $display("[UNIT-FAIL] DCache read address=%08x expected=%08x actual=%08x refill=%0b",
                                 address, expected, data_rdata, expect_bus_refill);
                        $fatal(2);
                    end
                end
            end
            tb_expect(read_seen, "DCache read response");
            if (expect_bus_refill)
                tb_expect(bus_read_requests > requests_before,
                          "DCache invalid/missing line issues refill");
            else
                tb_expect(bus_read_requests == requests_before,
                          "DCache hit does not issue refill");
        end
    endtask

    task automatic issue_maintenance(input logic [1:0] mode,
                                     input logic [31:0] address);
        bit done_seen;
        begin
            done_seen = 1'b0;
            @(negedge cpu_clk);
            maint_mode = mode;
            maint_addr = address;
            maint_all = 1'b0;
            maint_valid = 1'b1;
            tb_expect(maint_ready, "DCache accepts CACOP maintenance");
            @(posedge cpu_clk); #1;
            maint_valid = 1'b0;
            for (i = 0; i < 12; i = i + 1) begin
                @(negedge cpu_clk); #1;
                if (maint_done)
                    done_seen = 1'b1;
            end
            tb_expect(done_seen, "DCache CACOP maintenance completes");
            $display("[UNIT] maintenance mode=%0d index=%0d line_enabled0=%0b line_enabled1=%0b",
                     mode, address[9:5], dut.line_enabled0[address[9:5]], dut.line_enabled1[address[9:5]]);
        end
    endtask

    initial begin
        cpu_rstn = 1'b0;
        hold_read_ready = 1'b0;
        refill_left = 0;
        bus_read_requests = 0;
        idle_cpu_request();
        dev_wrdy = 1'b1;
        dev_rrdy = 1'b1;
        dev_rvalid = 1'b0;
        dev_rdata = 32'h0;
        maint_valid = 1'b0;
        maint_all = 1'b0;
        maint_mode = 2'b00;
        maint_addr = 32'h0;
        maint_ctag = 32'h0;
        repeat (4) @(posedge cpu_clk);
        cpu_rstn = 1'b1;

        // Miss/refill with read-bus backpressure.
        hold_read_ready = 1'b1;
        @(negedge cpu_clk);
        data_addr = 32'h0000_1000;
        data_ren = 4'hf;
        data_cacheable = 1'b1;
        @(posedge cpu_clk);
        #1;
        data_ren = 4'h0;
        repeat (3) @(negedge cpu_clk);
        tb_expect(cpu_ren == 4'h0, "DCache holds miss while read bus blocked");
        hold_read_ready = 1'b0;
        for (i = 0; i < 80; i = i + 1) begin
            @(negedge cpu_clk);
            #1;
            if (data_valid) begin
                read_seen = 1'b1;
                tb_expect(data_rdata == 32'hA000_0000,
                          "DCache miss/refill data");
            end
        end
        tb_expect(read_seen, "DCache miss/refill response");

        // The same address must now hit without issuing a memory refill.
        issue_read(32'h0000_1000, 32'hA000_0000, 1'b0);

        // Write-through store and cache-line update.
        write_seen = 1'b0;
        @(negedge cpu_clk);
        data_addr = 32'h0000_1000;
        data_wen = 4'hf;
        data_wdata = 32'hDEAD_BEEF;
        data_cacheable = 1'b1;
        #1;
        tb_expect(data_wposted, "DCache cacheable store is posted");
        @(posedge cpu_clk);
        #1;
        data_wen = 4'h0;
        for (i = 0; i < 12; i = i + 1) begin
            @(negedge cpu_clk);
            #1;
            if (cpu_wen == 4'hf) begin
                write_seen = 1'b1;
                tb_expect(cpu_waddr == 32'h0000_1000,
                          "DCache write address");
                tb_expect(cpu_wdata == 32'hDEAD_BEEF,
                          "DCache write data");
            end
        end
        tb_expect(write_seen, "DCache write-through bus request");
        issue_read(32'h0000_1000, 32'hDEAD_BEEF, 1'b0);

        // CACOP 0x01 uses mode00 (index invalidate).  The following access
        // must miss and refill rather than returning the previously updated
        // cache copy.
        issue_maintenance(2'b00, 32'h0000_1000);
        issue_read(32'h0000_1000, 32'hA000_0000, 1'b1);

        // CACOP 0x09 uses mode01.  This cache is write-through and has no
        // dirty state, so writeback-invalidate is functionally invalidate.
        issue_maintenance(2'b01, 32'h0000_1000);
        issue_read(32'h0000_1000, 32'hA000_0000, 1'b1);

        // Uncached/MMIO stores are not posted and must report a write response.
        @(negedge cpu_clk);
        data_addr = 32'hBFAF_0000;
        data_wen = 4'hf;
        data_wdata = 32'h1122_3344;
        data_cacheable = 1'b0;
        #1;
        tb_expect(!data_wposted, "DCache MMIO store is not posted");
        @(posedge cpu_clk);
        #1;
        data_wen = 4'h0;
        mmio_response_seen = 1'b0;
        for (i = 0; i < 20; i = i + 1) begin
            @(negedge cpu_clk);
            #1;
            if (data_wresp)
                mmio_response_seen = 1'b1;
        end
        tb_expect(mmio_response_seen, "DCache MMIO write response");

        tb_note("DCache baseline PASS");
        $finish;
    end
endmodule
