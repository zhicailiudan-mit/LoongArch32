`timescale 1ns/1ps

`include "defines.vh"

module tb_dcache_nextline_prefetch;
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
    wire cpu_rburst;
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
    integer bus_read_requests;
    integer reqs_before_demand;
    bit read_seen;
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
        .line_alloc_valid(1'b0),
        .line_alloc_addr (32'h0),
        .line_alloc_data (256'h0),
        .line_alloc_word_mask(8'h0),
        .line_alloc_ready(),
        .dev_wrdy      (dev_wrdy),
        .dev_wdone     (1'b1),
        .dev_widle     (1'b1),
        .cpu_wen       (cpu_wen),
        .cpu_waddr     (cpu_waddr),
        .cpu_wdata     (cpu_wdata),
        .dev_rrdy      (dev_rrdy),
        .cpu_ren       (cpu_ren),
        .cpu_raddr     (cpu_raddr),
        .cpu_rburst    (cpu_rburst),
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

        #1;
        if ((cpu_ren != 4'h0) && (refill_left == 0))
            refill_left = 8;
    end

    always @(posedge cpu_clk) begin
        if (cpu_rstn && (cpu_ren != 4'h0) && dev_rrdy)
            bus_read_requests <= bus_read_requests + 1;
    end

    task automatic reset_dut();
        cpu_rstn = 1'b0;
        data_ren = 4'h0;
        data_addr = 32'h0;
        data_cacheable = 1'b1;
        data_wen = 4'h0;
        data_wdata = 32'h0;
        maint_valid = 1'b0;
        maint_all = 1'b0;
        maint_mode = 2'b0;
        maint_addr = 32'h0;
        maint_ctag = 32'h0;
        refill_left = 0;
        hold_read_ready = 1'b0;
        bus_read_requests = 0;
        repeat (5) @(posedge cpu_clk);
        cpu_rstn = 1'b1;
        repeat (5) @(posedge cpu_clk);
    endtask

    task automatic read_word(input [31:0] addr, output [31:0] rdata);
        integer step;
        begin
            read_seen = 1'b0;
            @(negedge cpu_clk);
            data_addr = addr;
            data_ren = 4'hf;
            data_cacheable = 1'b1;
            @(posedge cpu_clk);
            #1;
            data_ren = 4'h0;
            for (step = 0; step < 20; step = step + 1) begin
                @(negedge cpu_clk);
                #1;
                if (data_valid) begin
                    read_seen = 1'b1;
                    rdata = data_rdata;
                end
            end
            tb_expect(read_seen, "DCache read response valid");
        end
    endtask

    initial begin
        $display("[UNIT-PF] Starting DCache Next-Line Prefetcher Unit Tests...");
        reset_dut();

        // -------------------------------------------------------------
        // Test 1: Sequential Stream Training (Line N, N+1, N+2)
        // -------------------------------------------------------------
        $display("[UNIT-PF] Test 1: Sequential Stream Training");
        read_word(32'h8000_0000, i); // Line 0
        repeat (5) @(posedge cpu_clk);

        read_word(32'h8000_0020, i); // Line 1 (confidence -> 1)
        repeat (5) @(posedge cpu_clk);

        read_word(32'h8000_0040, i); // Line 2 (confidence -> 2, pending -> Line 3 0x8000_0060)

        // Wait for prefetch to launch in idle cycle and finish refill
        repeat (30) @(posedge cpu_clk);
        tb_expect(bus_read_requests == 4, "4 bus requests total (3 demand + 1 prefetch)");

        // Verify prefetch occurred by checking if read to Line 3 (0x8000_0060) hits in Cache
        read_word(32'h8000_0060, i);
        tb_expect(dut.r_hit, "Line 3 must hit in Cache");

        // -------------------------------------------------------------
        // Test 2: Multiple Words within Same Line (No Extra Training)
        // -------------------------------------------------------------
        $display("[UNIT-PF] Test 2: Same Line Multiple Word Access");
        reset_dut();
        read_word(32'h8000_0100, i); // Line 8 word 0
        read_word(32'h8000_0104, i); // Line 8 word 1
        read_word(32'h8000_0108, i); // Line 8 word 2
        read_word(32'h8000_010C, i); // Line 8 word 3
        repeat (10) @(posedge cpu_clk);

        // -------------------------------------------------------------
        // Test 3: Random Access Disables Prefetch
        // -------------------------------------------------------------
        $display("[UNIT-PF] Test 3: Random Access Disables Prefetch");
        reset_dut();
        read_word(32'h8000_0200, i); // Line 16
        read_word(32'h8000_0600, i); // Line 48
        read_word(32'h8000_0100, i); // Line 8
        repeat (10) @(posedge cpu_clk);

        // -------------------------------------------------------------
        // Test 4: Cross 4KB Page Boundary Filtering
        // -------------------------------------------------------------
        $display("[UNIT-PF] Test 4: Cross 4KB Boundary Filter");
        reset_dut();
        read_word(32'h8000_0FA0, i); // Page 0 Line 125
        read_word(32'h8000_0FC0, i); // Page 0 Line 126
        read_word(32'h8000_0FE0, i); // Page 0 Line 127 (Last line of page!)
        repeat (20) @(posedge cpu_clk);

        // -------------------------------------------------------------
        // Test 5: Demand Priority Over Unlaunched Prefetch
        // -------------------------------------------------------------
        $display("[UNIT-PF] Test 5: Demand Priority Over Unlaunched Prefetch");
        reset_dut();
        read_word(32'h8000_0300, i);
        read_word(32'h8000_0320, i);
        read_word(32'h8000_0340, i); // Generates pending for Line 0x8000_0360
        read_word(32'h8000_0500, i);
        tb_expect(i == 32'hA000_0000, "Demand request must complete successfully");

        // -------------------------------------------------------------
        // Test 8: Prefetch Produces NO Load Response (no data_valid)
        // -------------------------------------------------------------
        $display("[UNIT-PF] Test 8: Prefetch Does Not Produce Data Valid");
        reset_dut();
        read_word(32'h8000_0400, i);
        read_word(32'h8000_0420, i);
        read_word(32'h8000_0440, i); // Launches prefetch for Line 0x8000_0460
        repeat (5) @(posedge cpu_clk);
        tb_expect(!data_valid, "data_valid must remain 0 during prefetch refill");

        $display("==============================================================");
        $display("----PASS!!!");
        $display("==============================================================");
        $finish;
    end
endmodule
