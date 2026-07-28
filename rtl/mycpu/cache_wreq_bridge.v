`timescale 1ns / 1ps

module cache_wreq_bridge(
    input  wire         rstn     ,
    input  wire         cpu_clk  ,
    // Cache Write Interface
    output wire         dev_wrdy ,      // FIFO 可接收新的写请求
    output wire         dev_wdone,      // 写请求已在 bus_uclk 域真正发出
    output wire         dev_widle,      // 所有被 FIFO 接受的写请求是否已在 bus_uclk 域真正产生总线写使能
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
    // 跨时钟域写完成计数与 dev_widle 导出
    // ==========================================
    wire write_fifo_push = (cpu_wen != 4'h0) && !fifo_full;

    reg [3:0] write_enq_count_cpu;
    always @(posedge cpu_clk or negedge rstn) begin
        if (!rstn)
            write_enq_count_cpu <= 4'd0;
        else if (write_fifo_push)
            write_enq_count_cpu <= write_enq_count_cpu + 4'd1;
    end

    // ==========================================
    // 修复后的 POP / SEND 两状态机
    // ==========================================
    localparam RD_POP  = 1'b0;
    localparam RD_SEND = 1'b1;

    reg rd_state;

    wire fifo_pop = (rd_state == RD_POP) && !fifo_empty;
    assign fifo_rd_en = fifo_pop;

    always @(posedge bus_uclk or negedge rstn) begin
        if (!rstn) begin
            rd_state <= RD_POP;
        end else begin
            case (rd_state)
                RD_POP: begin
                    if (!fifo_empty)
                        rd_state <= RD_SEND;
                end

                RD_SEND: begin
                    rd_state <= RD_POP;
                end

                default: begin
                    rd_state <= RD_POP;
                end
            endcase
        end
    end

    wire data_valid = (rd_state == RD_SEND);

    // 地址计算保持不变
    wire        wr_peripheral = (fifo_waddr[31:16] == 16'hBFAF) ||
                                (fifo_waddr[31:16] == 16'hBFD0);
    wire [31:0] wr_word_addr  = {2'h0, fifo_waddr[31:2]};

    // 只有当数据真正有效时，才驱动 SRAM 总线！
    assign bus_en    = data_valid;
    assign bus_waddr = wr_peripheral ? fifo_waddr : wr_word_addr;
    assign bus_we    = data_valid ? fifo_we : 4'h0;
    assign bus_wdata = fifo_wdata;

    wire write_bus_fire = data_valid && (|fifo_we);

    reg [3:0] write_done_count_bus_bin;
    reg [3:0] write_done_count_bus_gray;

    wire [3:0] write_done_count_bus_bin_next = write_done_count_bus_bin + 4'd1;
    wire [3:0] write_done_count_bus_gray_next = write_done_count_bus_bin_next ^ (write_done_count_bus_bin_next >> 1);

    always @(posedge bus_uclk or negedge rstn) begin
        if (!rstn) begin
            write_done_count_bus_bin  <= 4'd0;
            write_done_count_bus_gray <= 4'd0;
        end else if (write_bus_fire) begin
            write_done_count_bus_bin  <= write_done_count_bus_bin_next;
            write_done_count_bus_gray <= write_done_count_bus_gray_next;
        end
    end

    reg [3:0] sync_gray_1;
    reg [3:0] sync_gray_2;
    always @(posedge cpu_clk or negedge rstn) begin
        if (!rstn) begin
            sync_gray_1 <= 4'd0;
            sync_gray_2 <= 4'd0;
        end else begin
            sync_gray_1 <= write_done_count_bus_gray;
            sync_gray_2 <= sync_gray_1;
        end
    end

    wire [3:0] write_done_count_cpu_sync;
    assign write_done_count_cpu_sync[3] = sync_gray_2[3];
    assign write_done_count_cpu_sync[2] = sync_gray_2[3] ^ sync_gray_2[2];
    assign write_done_count_cpu_sync[1] = sync_gray_2[3] ^ sync_gray_2[2] ^ sync_gray_2[1];
    assign write_done_count_cpu_sync[0] = sync_gray_2[3] ^ sync_gray_2[2] ^ sync_gray_2[1] ^ sync_gray_2[0];

    assign dev_widle = (write_enq_count_cpu == write_done_count_cpu_sync) && (cpu_wen == 4'h0);

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
