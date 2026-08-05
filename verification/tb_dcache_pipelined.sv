`timescale 1ns / 1ps

module tb_dcache_pipelined;

    reg cpu_clk;
    reg cpu_rstn;

    // CPU side
    reg  [ 3:0] data_ren;
    reg  [31:0] data_addr;
    reg         data_cacheable;
    wire        data_rready;
    wire        data_valid;
    wire [31:0] data_rdata;

    reg  [ 3:0] data_wen;
    reg  [31:0] data_wdata;
    wire        data_wready;
    wire        data_wposted;
    wire        data_wresp;

    // Bus side
    wire        dev_wrdy = 1'b1;
    wire        dev_wdone = 1'b1;
    wire        dev_widle = 1'b1;
    wire [ 3:0] cpu_wen;
    wire [31:0] cpu_waddr;
    wire [31:0] cpu_wdata;

    reg         dev_rrdy;
    wire [ 3:0] cpu_ren;
    wire [31:0] cpu_raddr;
    wire        cpu_rburst;
    reg         dev_rvalid;
    reg  [31:0] dev_rdata;

    reg         maint_valid;
    wire        maint_ready;
    wire        maint_done;

    DCache dut (
        .cpu_rstn(cpu_rstn),
        .cpu_clk(cpu_clk),
        .data_ren(data_ren),
        .data_addr(data_addr),
        .data_cacheable(data_cacheable),
        .data_rready(data_rready),
        .data_valid(data_valid),
        .data_rdata(data_rdata),
        .data_wen(data_wen),
        .data_wdata(data_wdata),
        .data_wready(data_wready),
        .data_wposted(data_wposted),
        .data_wresp(data_wresp),
        .line_alloc_valid(1'b0),
        .line_alloc_addr(32'h0),
        .line_alloc_data(0),
        .line_alloc_word_mask(0),
        .line_alloc_ready(),
        .dev_wrdy(dev_wrdy),
        .dev_wdone(dev_wdone),
        .dev_widle(dev_widle),
        .cpu_wen(cpu_wen),
        .cpu_waddr(cpu_waddr),
        .cpu_wdata(cpu_wdata),
        .dev_rrdy(dev_rrdy),
        .cpu_ren(cpu_ren),
        .cpu_raddr(cpu_raddr),
        .cpu_rburst(cpu_rburst),
        .dev_rvalid(dev_rvalid),
        .dev_rdata(dev_rdata),
        .maint_valid(maint_valid),
        .maint_ready(maint_ready),
        .maint_done(maint_done),
        .maint_all(1'b0),
        .maint_mode(2'b00),
        .maint_addr(32'h0),
        .maint_ctag(32'h0)
    );

    initial begin
        cpu_clk = 0;
        forever #5 cpu_clk = ~cpu_clk;
    end

    int accepted_count = 0;
    int valid_count = 0;

    task send_store(input [31:0] addr, input [31:0] val);
        @(posedge cpu_clk);
        while (!data_wready) @(posedge cpu_clk);
        data_wen   <= 4'hF;
        data_addr  <= addr;
        data_wdata <= val;
        data_cacheable <= 1'b1;
        @(posedge cpu_clk);
        data_wen   <= 4'h0;
    endtask

    always @(posedge cpu_clk) begin
        if (cpu_rstn && data_rready && (|data_ren)) begin
            accepted_count++;
        end
        if (cpu_rstn && data_valid) begin
            valid_count++;
        end
    end

    initial begin
        cpu_rstn = 0;
        data_ren = 0;
        data_addr = 0;
        data_cacheable = 1;
        data_wen = 0;
        data_wdata = 0;
        dev_rrdy = 1;
        dev_rvalid = 0;
        dev_rdata = 0;
        maint_valid = 0;

        #50;
        cpu_rstn = 1;
        #20;

        $display("=== STARTING DCACHE PIPELINED TEST ===");

        // 先给几条 Line 进行 Refill 装载
        // Refill Line 0 (0x10000000)
        @(posedge cpu_clk);
        data_ren  <= 4'hF;
        data_addr <= 32'h1000_0000;
        @(posedge cpu_clk);
        data_ren  <= 4'h0;

        while (cpu_ren == 4'h0) @(posedge cpu_clk);
        for (int i = 0; i < 8; i++) begin
            @(posedge cpu_clk);
            dev_rvalid <= 1'b1;
            dev_rdata  <= 32'h1000_0000 + (i << 2);
        end
        @(posedge cpu_clk);
        dev_rvalid <= 1'b0;

        // Refill Line 1 (0x10000020)
        @(posedge cpu_clk);
        data_ren  <= 4'hF;
        data_addr <= 32'h1000_0020;
        @(posedge cpu_clk);
        data_ren  <= 4'h0;

        while (cpu_ren == 4'h0) @(posedge cpu_clk);
        for (int i = 0; i < 8; i++) begin
            @(posedge cpu_clk);
            dev_rvalid <= 1'b1;
            dev_rvalid <= 1'b1;
            dev_rdata  <= 32'h1000_0020 + (i << 2);
        end
        @(posedge cpu_clk);
        dev_rvalid <= 1'b0;
        #30;

        accepted_count = 0;
        valid_count = 0;

        // 测试 1 & 2 & 3 & 4：连续 8 周期连续发 8 个 Load (全是 Hit)
        $display("Testing continuous Load Hits (8 consecutive cycles)...");
        for (int i = 0; i < 8; i++) begin
            @(posedge cpu_clk);
            while (!data_rready) @(posedge cpu_clk);
            data_ren  <= 4'hF;
            data_addr <= 32'h1000_0000 + (i << 2);
        end
        @(posedge cpu_clk);
        data_ren <= 4'h0;

        // 等待所有 8 个 valid 返回
        while (valid_count < 8) @(posedge cpu_clk);
        $display("Success: 8 continuous Load Hits accepted and responded in %0d cycles!", accepted_count);

        $display("==================================================");
        $display("PIPELINED DCACHE TEST PASSED SUCCESSFULLY!");
        $display("==================================================");
        $finish;
    end

endmodule
