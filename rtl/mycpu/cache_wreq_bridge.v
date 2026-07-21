`timescale 1ns / 1ps

module cache_wreq_bridge(
    input  wire         rstn     ,
    input  wire         cpu_clk  ,
    // Cache Write Interface
    output wire         dev_wrdy ,      // FIFO 可接收新的写请求
    output wire         dev_wdone,      // 写请求已在 bus_uclk 域真正发出
    input  wire [ 3:0]  cpu_wen  ,      // Cache的写主存使能信号，支持字节使能
    input  wire [31:0]  cpu_waddr,      // Cache的写主存地址
    input  wire [31:0]  cpu_wdata,      // Cache的写主存数据
    // SRAM-User Interface
    input  wire         bus_uclk ,
    output wire         bus_en   ,      // SRAM使能信号
    output wire [31:0]  bus_waddr,      // 写SRAM地址
    output wire [ 3:0]  bus_we   ,      // 写SRAM写使能，支持字节使能
    output wire [31:0]  bus_wdata       // 写SRAM数据
);

    wire [ 3:0] fifo_we;
    wire [31:0] fifo_waddr;
    wire [31:0] fifo_wdata;
    wire        fifo_empty;
    wire        fifo_full;

    wire        fifo_rd_en; 

    async_fifo #(
        .DATA_WIDTH(68)
    ) dc_wreq_fifo (
        .rstn       (rstn),
        // Write Port
        .wr_clk     (cpu_clk),
        .wr_en      ((cpu_wen != 4'h0)),
        .din        ({cpu_wen, cpu_waddr, cpu_wdata}),
        .full       (fifo_full),
        // Read Port
        .rd_clk     (bus_uclk),
        .rd_en      (fifo_rd_en),
        .dout       ({fifo_we, fifo_waddr, fifo_wdata}),
        .empty      (fifo_empty)
    );

    // fifo_empty 只表示当前没有待读写项，不能表示 SRAM 已完成写入。
    assign dev_wrdy = rstn && !fifo_full;

    // ==========================================
    // 修复后的 FIFO 读取与时序对齐逻辑
    // ==========================================
    
    reg fifo_rd_en_r;

    // 1. 产生读请求：FIFO 非空时连续取数。async_fifo 是 FWFT 结构，
    // 因此上一拍的读数据在本拍稳定，可以在没有气泡的情况下连续写 SRAM。
    wire fifo_rd_en_cmd = !fifo_empty;
    
    // 【老兵修复点】：现在这是全场唯一合法的驱动源！
    assign fifo_rd_en = fifo_rd_en_cmd;

    always @(posedge bus_uclk or negedge rstn) begin
        if (!rstn) 
            fifo_rd_en_r <= 1'b0;
        else 
            fifo_rd_en_r <= fifo_rd_en_cmd; // 锁存读命令
    end

    // 2. 数据有效标志 (Data Valid)
    // 根据 FIFO 的特性，读命令发出的下一拍，数据才会出现在 fifo_we,
    // fifo_wdata 等信号上；连续读时 fifo_rd_en_r 会保持为 1。
    wire data_valid = fifo_rd_en_r;

    // 地址计算保持不变
    wire        wr_peripheral = (fifo_waddr[31:16] == 16'hBFAF) ||
                                (fifo_waddr[31:16] == 16'hBFD0);
    wire [31:0] wr_word_addr  = {2'h0, fifo_waddr[31:2]};

    // 3. 只有当数据真正有效时，才驱动 SRAM 总线！
    assign bus_en    = data_valid;
    assign bus_waddr = wr_peripheral ? fifo_waddr : wr_word_addr;
    assign bus_we    = data_valid ? fifo_we : 4'h0; // 此时 fifo_we 已经是正确的 'f' 了！
    assign bus_wdata = fifo_wdata;

    // SRAM 没有显式 B 响应，以 bus_uclk 域真正发出写使能的时刻作为完成点。
    // 通过 toggle 跨时钟域，避免短脉冲被 cpu_clk 漏采样。
    reg done_toggle_bus;
    reg done_toggle_cpu1;
    reg done_toggle_cpu2;
    reg done_toggle_seen;
    reg dev_wdone_r;

    always @(posedge bus_uclk or negedge rstn) begin
        if (!rstn)
            done_toggle_bus <= 1'b0;
        else if (data_valid && (|fifo_we))
            done_toggle_bus <= ~done_toggle_bus;
    end

    always @(posedge cpu_clk or negedge rstn) begin
        if (!rstn) begin
            done_toggle_cpu1 <= 1'b0;
            done_toggle_cpu2 <= 1'b0;
            done_toggle_seen <= 1'b0;
            dev_wdone_r      <= 1'b0;
        end else begin
            done_toggle_cpu1 <= done_toggle_bus;
            done_toggle_cpu2 <= done_toggle_cpu1;
            dev_wdone_r      <= 1'b0;
            if (done_toggle_cpu2 != done_toggle_seen) begin
                done_toggle_seen <= done_toggle_cpu2;
                dev_wdone_r      <= 1'b1;
            end
        end
    end

    assign dev_wdone = dev_wdone_r;

endmodule
