`timescale 1ns/1ps
`include "defines.vh"

module tb_axi_cache_bridge;
    logic aclk = 0;
    logic aresetn = 0;
    always #5 aclk = ~aclk;

    logic ic_cpu_ren = 0;
    logic [31:0] ic_cpu_raddr = 0;
    wire ic_dev_rrdy, ic_dev_rvalid;
    wire [31:0] ic_dev_rdata;
    logic dc_cpu_ren = 0;
    logic [31:0] dc_cpu_raddr = 0;
    logic dc_cpu_rburst = 0;
    wire dc_dev_rrdy, dc_dev_rvalid;
    wire [31:0] dc_dev_rdata;
    logic [3:0] dc_cpu_wen = 0;
    logic [31:0] dc_cpu_waddr = 0, dc_cpu_wdata = 0;
    wire dc_dev_wrdy;

    wire [3:0] arid;
    wire [31:0] araddr;
    wire [7:0] arlen;
    wire [2:0] arsize;
    wire [1:0] arburst, arlock;
    wire [3:0] arcache;
    wire [2:0] arprot;
    wire arvalid;
    logic arready = 1;
    logic [3:0] rid = 0;
    logic [31:0] rdata = 0;
    logic [1:0] rresp = 0;
    logic rlast = 0, rvalid = 0;
    wire rready;
    wire [3:0] awid;
    wire [31:0] awaddr;
    wire [7:0] awlen;
    wire [2:0] awsize;
    wire [1:0] awburst, awlock;
    wire [3:0] awcache;
    wire [2:0] awprot;
    wire awvalid;
    logic awready = 0;
    wire [3:0] wid;
    wire [31:0] wdata;
    wire [3:0] wstrb;
    wire wlast, wvalid;
    logic wready = 0;
    logic [3:0] bid = 0;
    logic [1:0] bresp = 0;
    logic bvalid = 0;
    wire bready;

    AxiCacheBridge dut (.*);

    task automatic check_ok(input bit cond, input string msg);
        if (!cond) begin
            $display("[AXI-BRIDGE-FAIL] %s", msg);
            $fatal(1);
        end
    endtask

    task automatic send_read_beats(input integer count, input [31:0] base);
        integer k;
        begin
            for (k = 0; k < count; k = k + 1) begin
                @(negedge aclk);
                rvalid = 1;
                rdata = base + k;
                rlast = (k == count-1);
                #1;
                check_ok(rready, "bridge deasserted rready inside burst");
                @(posedge aclk);
            end
            @(negedge aclk);
            rvalid = 0;
            rlast = 0;
        end
    endtask

    integer k;
    integer dc_seen;
    integer ic_seen;
    logic [31:0] expected_ic [0:7];

    initial begin
        repeat (3) @(posedge aclk);
        aresetn = 1;

        // Enqueue I and D reads together. D owns the first AXI transaction,
        // while I remains pending rather than being dropped.
        @(negedge aclk);
        ic_cpu_ren = 1;
        ic_cpu_raddr = 32'h1c00_000c;
        dc_cpu_ren = 1;
        dc_cpu_raddr = 32'h1c40_0000;
        dc_cpu_rburst = 1;
        @(posedge aclk);
        #1;
        ic_cpu_ren = 0;
        dc_cpu_ren = 0;

        wait (arvalid);
        check_ok(arid == 4'h1 && araddr == 32'h1c40_0000,
               "D-cache request did not win first arbitration");
        check_ok(arlen == 7 && arsize == 3'b010 && arburst == 2'b01,
               "D-cache refill is not an 8-beat word INCR burst");
        @(posedge aclk);

        fork
            begin
                dc_seen = 0;
                while (dc_seen < 8) begin
                    @(negedge aclk);
                    if (dc_dev_rvalid) begin
                        check_ok(dc_dev_rdata == 32'hd000_0000 + dc_seen,
                               "D-cache beat data/order mismatch");
                        dc_seen = dc_seen + 1;
                    end
                end
            end
            send_read_beats(8, 32'hd000_0000);
        join

        wait (arvalid);
        check_ok(arid == 4'h0 && araddr == 32'h1c00_0000 && arlen == 7,
               "I-cache request was lost or not line aligned");
        @(posedge aclk);
        send_read_beats(8, 32'h1000_0000);

        expected_ic[0]=32'h1000_0003; expected_ic[1]=32'h1000_0004;
        expected_ic[2]=32'h1000_0005; expected_ic[3]=32'h1000_0006;
        expected_ic[4]=32'h1000_0007; expected_ic[5]=32'h1000_0000;
        expected_ic[6]=32'h1000_0001; expected_ic[7]=32'h1000_0002;
        ic_seen = 0;
        while (ic_seen < 8) begin
            @(negedge aclk);
            if (ic_dev_rvalid) begin
                check_ok(ic_dev_rdata == expected_ic[ic_seen],
                       "I-cache critical-word-first reorder mismatch");
                ic_seen = ic_seen + 1;
            end
        end

        // UART/uncached reads retain the exact byte address and are single beat.
        @(negedge aclk);
        dc_cpu_ren = 1;
        dc_cpu_raddr = 32'h1f00_0005;
        dc_cpu_rburst = 0;
        @(posedge aclk);
        #1;
        dc_cpu_ren = 0;
        wait (arvalid);
        check_ok(araddr == 32'h1f00_0005 && arlen == 0,
               "uncached UART read address/length changed");
        @(posedge aclk);
        send_read_beats(1, 32'h0000_0021);

        // AW and W are independent and remain asserted through backpressure.
        @(negedge aclk);
        dc_cpu_wen = 4'b0001;
        dc_cpu_waddr = 32'h1f00_0000;
        dc_cpu_wdata = 32'h0000_0041;
        @(posedge aclk);
        #1;
        dc_cpu_wen = 0;
        check_ok(awvalid && wvalid && awaddr == 32'h1f00_0000,
               "UART write was not latched");
        check_ok(wstrb == 4'b0001 && wdata == 32'h41 && wlast,
               "UART byte write strobe/data mismatch");
        repeat (2) @(posedge aclk);
        check_ok(awvalid && wvalid, "AXI write valid was not held under stall");
        @(negedge aclk); awready = 1; wready = 1;
        @(posedge aclk); #1;
        @(negedge aclk); awready = 0; wready = 0;
        wait (bready);
        bvalid = 1;
        @(posedge aclk); #1;
        bvalid = 0;
        check_ok(dc_dev_wrdy, "write response did not release cache interface");

        $display("[AXI-BRIDGE-PASS]");
        $finish;
    end
endmodule
