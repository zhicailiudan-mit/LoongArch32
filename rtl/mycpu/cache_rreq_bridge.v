`timescale 1ns / 1ps

module cache_rreq_bridge #(
    parameter BLK_LEN = 4,
    parameter CWF_EN  = 0
)(
    input  wire         rstn      ,
    input  wire         cpu_clk   ,
    input  wire         w_hold    ,     // 有效则表示总线收到写数据请求（每个请求只有效一个SRAM时钟）
    input  wire         r_hold    ,     // 有效则表示总线收到读数据请求（每个请求只有效一个SRAM时钟）

    // Cache Read Interface
    output wire         dev_rrdy  ,
    // Byte-enable mask from the cache.  This is a 4-bit value: a byte/half
    // word load may legally assert only bit 1, 2, or 3.  Keeping this as a
    // scalar silently drops such requests when it is used as FIFO wr_en.
    input  wire [ 3:0]   cpu_ren   ,
    input  wire [31:0]  cpu_raddr ,
    input  wire         cpu_rburst,
    output reg          dev_rvalid,
    output reg  [31:0]  dev_rdata ,

    // SRAM-BUS Interface
    input  wire         bus_uclk  ,
    output wire         bus_en    ,
    output wire [31:0]  bus_raddr ,
    input  wire [31:0]  bus_rdata
);

    // ============================================================
    // CWF 地址生成函数
    // CWF_EN = 0: 普通顺序 cur + 1 / cur - 1
    // CWF_EN = 1: 块内回绕 next / prev
    // ============================================================

    function [31:0] next_addr;
        input [31:0] cur_addr;
        input [31:0] base_addr;
        begin
            if (CWF_EN != 0) begin
                if (cur_addr == base_addr + (BLK_LEN - 1))
                    next_addr = base_addr;
                else
                    next_addr = cur_addr + 32'h1;
            end else begin
                next_addr = cur_addr + 32'h1;
            end
        end
    endfunction

    function [31:0] prev_addr;
        input [31:0] cur_addr;
        input [31:0] base_addr;
        begin
            if (CWF_EN != 0) begin
                if (cur_addr == base_addr)
                    prev_addr = base_addr + (BLK_LEN - 1);
                else
                    prev_addr = cur_addr - 32'h1;
            end else begin
                prev_addr = cur_addr - 32'h1;
            end
        end
    endfunction

    // ============================================================
    // FIFO：接收 Cache 发来的读请求
    // ============================================================

    wire [31:0] fifo_raddr;
    wire        fifo_rburst;
    wire        fifo_empty;

    wire        fifo_rd_en = !(w_hold | r_hold) & !fifo_empty;

    async_fifo #(
        .DATA_WIDTH(33),
        .FIFO_DEPTH(4)
    ) u_rreq_fifo (
        .rstn       (rstn),

        // Write Port
        .wr_clk     (cpu_clk),
        .wr_en      (|cpu_ren),
        .din        ({cpu_rburst, cpu_raddr}),
        .full       (),

        // Read Port
        .rd_clk     (bus_uclk),
        .rd_en      (fifo_rd_en),
        .dout       ({fifo_rburst, fifo_raddr}),
        .empty      (fifo_empty)
    );

    assign dev_rrdy = fifo_empty;

    // ============================================================
    // 新读请求检测
    // ============================================================

    reg fifo_rd_en_r;

    always @(posedge bus_uclk or negedge rstn) begin
        if (!rstn)
            fifo_rd_en_r <= 1'b0;
        else
            fifo_rd_en_r <= fifo_rd_en;
    end

    wire new_rreq = !fifo_rd_en_r & fifo_rd_en;

    // ============================================================
    // 请求地址信息
    // ============================================================

    wire        rd_peripheral = (fifo_raddr[31:16] == 16'hBFAF) ||
                                (fifo_raddr[31:16] == 16'hBFD0);

    // 读主存使用 word address；读外设使用 byte address
    wire [31:0] rd_word_addr = {2'h0, fifo_raddr[31:2]};

    // 当前 Cache 块的 word 对齐基地址
    // BLK_LEN=8 时，例如 rd_word_addr = xxx5，则 base = xxx0
    wire [31:0] rd_base_word_addr = rd_word_addr - (rd_word_addr % BLK_LEN);

    reg         ren_r;
    reg [ 7:0] rd_cnt;
    reg [31:0] rd_addr;
    reg         req_burst_r;

    // 当前正在处理请求的块基地址，用于 CWF 回绕
    reg [31:0] req_base_word_addr;

    // ============================================================
    // hold 信号打一拍
    // ============================================================

    reg r_hold_r;
    reg w_hold_r;

    always @(posedge bus_uclk or negedge rstn) begin
        if (!rstn)
            r_hold_r <= 1'b0;
        else
            r_hold_r <= r_hold;
    end

    always @(posedge bus_uclk or negedge rstn) begin
        if (!rstn)
            w_hold_r <= 1'b0;
        else
            w_hold_r <= w_hold;
    end

    // ============================================================
    // 读请求控制
    // ============================================================

    // 外设只读一个 word；主存读一个 Cache block
    // DCache non-cacheable reads are single-beat requests.  Only a request
    // explicitly marked as a burst may consume a complete cache line.
    wire [7:0] req_len = (req_burst_r && !rd_peripheral) ? BLK_LEN : 8'h1;
    wire read_end = (rd_cnt == req_len) & !(w_hold | w_hold_r);

    // 后续读地址请求；BLK_LEN=1 时仅用于 write-collision rollback 后重发。
    wire ren_f = ren_r;

    wire rd_bus_en = new_rreq | ren_f;

    // 本拍 ICache 是否真的向 SRAM 发出了读地址
    wire ic_issue = rd_bus_en & !(w_hold | r_hold);

    // 上一拍 ICache 是否真的向 SRAM 发出了读地址
    reg ic_issue_r;

    always @(posedge bus_uclk or negedge rstn) begin
        if (!rstn)
            ic_issue_r <= 1'b0;
        else
            ic_issue_r <= ic_issue;
    end

    // 写请求会污染上一拍 ICache 读出的数据，因此需要撤销上一拍读地址
    wire w_hold_rollback =
        w_hold & ic_issue_r & !rd_peripheral & (rd_cnt != 8'h0);

    always @(posedge bus_uclk or negedge rstn) begin
        if (!rstn) begin
            ren_r              <= 1'b0;
            rd_cnt             <= 8'h0;
            rd_addr            <= 32'h0;
            req_base_word_addr <= 32'h0;
            req_burst_r        <= 1'b0;
        end else begin

            // ------------------------------
            // ren_r 更新
            // ------------------------------
            if (read_end) begin
                ren_r <= 1'b0;
            end else if (new_rreq & fifo_rburst & !rd_peripheral && (BLK_LEN > 1)) begin
                ren_r <= 1'b1;
            end else if (w_hold_rollback) begin
                ren_r <= 1'b1;
            end else if (ic_issue && (rd_cnt == BLK_LEN - 1)) begin
                ren_r <= 1'b0;
            end

            // ------------------------------
            // rd_cnt 更新
            // rd_cnt 表示已经发出的 ICache 读地址数量
            // ------------------------------
            if (read_end) begin
                rd_cnt <= 8'h0;
            end else if (w_hold_rollback) begin
                rd_cnt <= rd_cnt - 8'h1;
            end else if (ic_issue) begin
                rd_cnt <= rd_cnt + 8'h1;
            end

            // ------------------------------
            // rd_addr 更新
            // rd_addr 保存下一次要发出的读地址
            // ------------------------------
            if (new_rreq) begin
                req_base_word_addr <= rd_base_word_addr;
                rd_addr            <= next_addr(rd_word_addr, rd_base_word_addr);
                req_burst_r        <= fifo_rburst;
            end else if (w_hold_rollback) begin
                rd_addr <= prev_addr(rd_addr, req_base_word_addr);
            end else if (ic_issue && ren_f) begin
                rd_addr <= next_addr(rd_addr, req_base_word_addr);
            end
        end
    end

    // ============================================================
    // 返回数据给 Cache
    //
    // r_hold:
    //   当前拍仍可能是上一拍 ICache 读地址返回的数据，所以不屏蔽 r_hold；
    //   下一拍 r_hold_r 是 DCache 读数据返回，所以要屏蔽。
    //
    // w_hold:
    //   写请求当拍和下一拍 bus_rdata 都不是 ICache 指令，所以 w_hold / w_hold_r 都要屏蔽。
    // ============================================================

    wire rd_sram = !(w_hold | w_hold_r | r_hold_r) &&
                   (rd_cnt != 8'h0) && (rd_cnt <= req_len);

    reg [7:0] cwf_cnt;

    // Non-burst DCache/peripheral reads return exactly one beat.  Their
    // response used to be generated as a one-cycle pulse in cpu_clk while
    // the request bookkeeping lived in bus_uclk.  With a phase difference
    // between the two clocks that pulse could be missed, leaving DCache in
    // R_UNC_WAIT and the LSU in WAIT_LOAD forever.  Capture the beat in the
    // bus clock domain and transfer an event with a toggle.
    reg [7:0]  single_cwf_cnt;
    reg [31:0] single_rdata_bus;
    reg        single_toggle_bus;
    reg        single_toggle_cpu1;
    reg        single_toggle_cpu2;
    reg        single_toggle_seen;

    wire single_beat = !req_burst_r &&
                       (single_cwf_cnt < rd_cnt) &&
                       (rd_peripheral | rd_sram);

    always @(posedge bus_uclk or negedge rstn) begin
        if (!rstn) begin
            single_cwf_cnt <= 8'h0;
            single_rdata_bus <= 32'h0;
            single_toggle_bus <= 1'b0;
        end else begin
            if (new_rreq) begin
                single_cwf_cnt <= 8'h0;
            end else if (single_beat) begin
                single_rdata_bus <= bus_rdata;
                single_toggle_bus <= ~single_toggle_bus;
                single_cwf_cnt <= single_cwf_cnt + 8'h1;
            end
        end
    end

    always @(posedge cpu_clk or negedge rstn) begin
        if (!rstn) begin
            dev_rvalid <= 1'b0;
            dev_rdata  <= 32'h0;
            single_toggle_cpu1 <= 1'b0;
            single_toggle_cpu2 <= 1'b0;
            single_toggle_seen <= 1'b0;
        end else begin
            single_toggle_cpu1 <= single_toggle_bus;
            single_toggle_cpu2 <= single_toggle_cpu1;

            if (single_toggle_cpu2 != single_toggle_seen) begin
                single_toggle_seen <= single_toggle_cpu2;
                dev_rvalid <= 1'b1;
                dev_rdata  <= single_rdata_bus;
            end else if (req_burst_r &&
                         (cwf_cnt < rd_cnt) &&
                         (rd_peripheral | rd_sram)) begin
                dev_rvalid <= 1'b1;
                dev_rdata  <= bus_rdata;
            end else begin
                dev_rvalid <= 1'b0;
            end
        end
    end

    always @(posedge cpu_clk or negedge rstn) begin
        if (!rstn) begin
            cwf_cnt <= 8'h0;
        end else begin
            if (fifo_rd_en) begin
                cwf_cnt <= 8'h0;
            end else if (req_burst_r &&
                         (cwf_cnt < rd_cnt) &&
                         (rd_peripheral | rd_sram)) begin
                cwf_cnt <= cwf_cnt + 8'h1;
            end
        end
    end

    // ============================================================
    // SRAM-BUS 输出
    // ============================================================

    assign bus_en = rd_bus_en & !(w_hold | r_hold);

    assign bus_raddr =
        ren_f ? rd_addr :
        (rd_peripheral ? fifo_raddr : rd_word_addr);

endmodule
