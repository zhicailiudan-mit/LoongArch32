`timescale 1ns / 1ps

`include "defines.vh"

module sram_bus_master(
    input  wire         cpu_rstn     ,      // low active
    input  wire         cpu_clk      ,
    input  wire         sram_rstn    ,
    input  wire         sram_uclk    ,
    // ICache Interface
    output wire         ic_dev_rrdy  ,      // 给ICache读主存的就绪信号（就绪时ICache才能发出读主存请求）
    input  wire         ic_cpu_ren   ,      // ICache的读主存使能信号
    input  wire [31:0]  ic_cpu_raddr ,      // ICache的读主存地址
    output wire         ic_dev_rvalid,      // 返回给ICache的指令有效信号（有效n个周期则返回n条指令）
    output wire [31:0]  ic_dev_rdata ,      // 返回给ICache的指令
    // DCache Interface
    output wire         dc_dev_wrdy  ,
    output wire         dc_dev_wdone ,
    output wire         dc_dev_widle ,
    input  wire [ 3:0]  dc_cpu_wen   ,      // DCache的写主存使能信号，支持字节使能
    input  wire [31:0]  dc_cpu_waddr ,      // DCache的写主存地址
    input  wire [31:0]  dc_cpu_wdata ,      // DCache的写主存数据
    output wire         dc_dev_rrdy  ,      // 给DCache读主存的就绪信号（就绪时DCache才能发出读主存请求）
    // DCache read byte-enable mask. Keep all four bits: byte/halfword
    // loads may use masks 0010/0100/1000, not only bit 0.
    input  wire [ 3:0]  dc_cpu_ren   ,      // DCache的读主存使能信号
    input  wire [31:0]  dc_cpu_raddr ,      // DCache的读主存地址
    input  wire         dc_cpu_rburst,      // 1=Cache行读取，0=非缓存单字读取
    output wire         dc_dev_rvalid,      // 返回给DCache的数据有效信号（有效n个周期则返回n个有效数据）
    output wire [31:0]  dc_dev_rdata ,      // 返回给DCache的读主存数据
    // SRAM-BUS Interface 0 (SRAM)
    output wire         bus_en0      ,      // 访问SRAM的使能信号
    output reg  [31:0]  bus_addr0    ,      // 访问SRAM的地址，读/写共用
    output wire [ 3:0]  bus_we0      ,      // 写SRAM写使能，支持字节使能
    output wire [31:0]  bus_wdata0   ,      // 写SRAM数据
    input  wire [31:0]  bus_rdata0   ,      // 读SRAM数据
    // SRAM-BUS Interface 1 (Peripheral)
    output wire         bus_en1      ,      // 访问外设的使能信号
    output reg  [31:0]  bus_addr1    ,      // 访问外设的地址，读/写共用
    output wire [ 3:0]  bus_we1      ,      // 写外设写使能，支持字节使能
    output wire [31:0]  bus_wdata1   ,      // 写外设数据
    input  wire [31:0]  bus_rdata1          // 读外设数据
);

`ifdef ENABLE_ICACHE    localparam IC_BLK_LEN = `CACHE_BLK_LEN;
`else                   localparam IC_BLK_LEN = 1;
`endif

`ifdef ENABLE_DCACHE    localparam DC_BLK_LEN = `CACHE_BLK_LEN;
`else                   localparam DC_BLK_LEN = 1;
`endif

    wire        fifo_init_done = 1'b1;

    wire        ic_rfifo_rdy;
    wire        dc_rfifo_rdy;
    wire        dc_wfifo_rdy;
    wire        dc_wdone;
    wire        dc_mem_widle;
    assign      ic_dev_rrdy = fifo_init_done & ic_rfifo_rdy;

    wire [ 3:0] bus_we;
    wire [31:0] bus_wdata;

    wire        ic_rd_bus_en, dc_rd_bus_en, dc_wr_bus_en;
    wire [31:0] ic_bus_raddr, dc_bus_raddr, dc_bus_waddr;
    wire        dc_mem_dev_rvalid;
    wire [31:0] dc_mem_dev_rdata;

    wire        dc_cpu_r_peripheral = (dc_cpu_ren != 4'h0) &&
                                      ((dc_cpu_raddr[31:16] == 16'hBFAF) ||
                                       (dc_cpu_raddr[31:16] == 16'hBFD0));
    wire [ 3:0] dc_cpu_r_mem        = dc_cpu_r_peripheral ? 4'h0 : dc_cpu_ren;

    wire        dc_cpu_wvalid = (dc_cpu_wen != 4'h0);
    wire        dc_cpu_w_peripheral = dc_cpu_wvalid &&
                                      ((dc_cpu_waddr[31:16] == 16'hBFAF) ||
                                       (dc_cpu_waddr[31:16] == 16'hBFD0));
    wire [ 3:0] dc_cpu_w_mem = dc_cpu_w_peripheral ? 4'h0 : dc_cpu_wen;
    wire        peri_write_fire = dc_cpu_w_peripheral;

    reg         peri_wdone_r;
    always @(posedge cpu_clk or negedge cpu_rstn) begin
        if (!cpu_rstn)
            peri_wdone_r <= 1'b0;
        else
            peri_wdone_r <= peri_write_fire;
    end

    assign      dc_dev_wrdy  = fifo_init_done &
                               (dc_cpu_w_peripheral ? 1'b1 : dc_wfifo_rdy);
    assign      dc_dev_wdone = fifo_init_done & (dc_wdone | peri_wdone_r);
    assign      dc_dev_widle = dc_mem_widle && !peri_write_fire &&
                               !peri_wdone_r;

    wire        wr_mem_en  = dc_wr_bus_en;
    wire        rd_mem_en  = dc_rd_bus_en;

    reg         dc_peri_req_d1;
    reg         dc_peri_req_d2;
    reg  [31:0] dc_peri_rdata_r;
    wire        dc_peri_busy  = dc_peri_req_d1 | dc_peri_req_d2;
    wire        dc_peri_rrdy  = !dc_peri_busy;
    wire        rd_peri_en    = dc_cpu_r_peripheral & dc_peri_rrdy;
    wire        dc_peri_rvalid = dc_peri_req_d2;

    assign      dc_dev_rrdy = fifo_init_done & dc_rfifo_rdy & dc_peri_rrdy;

    always @(posedge cpu_clk or negedge cpu_rstn) begin
        if (!cpu_rstn) begin
            dc_peri_req_d1 <= 1'b0;
            dc_peri_req_d2 <= 1'b0;
            dc_peri_rdata_r <= 32'h0000_0000;
        end else begin
            dc_peri_req_d1 <= rd_peri_en;
            dc_peri_req_d2 <= dc_peri_req_d1;
            if (dc_peri_req_d1) begin
                dc_peri_rdata_r <= bus_rdata1;
            end
        end
    end

    assign dc_dev_rvalid = dc_peri_rvalid ? 1'b1          : dc_mem_dev_rvalid;
    assign dc_dev_rdata  = dc_peri_rvalid ? dc_peri_rdata_r : dc_mem_dev_rdata;

    // ------------------------------------------------------------------
    // SRAM0 Bus Arbiter & Owner Lock State Machine (sram_uclk domain)
    // ------------------------------------------------------------------
    wire ic_bus_req_valid, ic_bus_grant, ic_bus_transaction_done;
    wire dc_bus_req_valid, dc_bus_grant, dc_bus_transaction_done;
    wire dc_wr_bus_req_valid, dc_wr_bus_grant, dc_wr_bus_transaction_done;

    localparam [1:0] LOCK_NONE    = 2'b00;
    localparam [1:0] LOCK_DC_READ = 2'b01;
    localparam [1:0] LOCK_IC_READ = 2'b10;

    reg [1:0] lock_owner;
    reg [1:0] rr_ptr; // 0 = DC write, 1 = DC read, 2 = IC read

    reg dc_bus_grant_r;
    reg ic_bus_grant_r;
    reg dc_wr_bus_grant_r;

    always @(*) begin
        dc_bus_grant_r    = 1'b0;
        ic_bus_grant_r    = 1'b0;
        dc_wr_bus_grant_r = 1'b0;

        case (lock_owner)
            LOCK_DC_READ: begin
                dc_bus_grant_r = dc_bus_req_valid;
            end
            LOCK_IC_READ: begin
                ic_bus_grant_r = ic_bus_req_valid;
            end
            default: begin // LOCK_NONE
                case (rr_ptr)
                    2'd0: begin
                        if (dc_wr_bus_req_valid)
                            dc_wr_bus_grant_r = 1'b1;
                        else if (dc_bus_req_valid)
                            dc_bus_grant_r = 1'b1;
                        else if (ic_bus_req_valid)
                            ic_bus_grant_r = 1'b1;
                    end
                    2'd1: begin
                        if (dc_bus_req_valid)
                            dc_bus_grant_r = 1'b1;
                        else if (ic_bus_req_valid)
                            ic_bus_grant_r = 1'b1;
                        else if (dc_wr_bus_req_valid)
                            dc_wr_bus_grant_r = 1'b1;
                    end
                    default: begin
                        if (ic_bus_req_valid)
                            ic_bus_grant_r = 1'b1;
                        else if (dc_wr_bus_req_valid)
                            dc_wr_bus_grant_r = 1'b1;
                        else if (dc_bus_req_valid)
                            dc_bus_grant_r = 1'b1;
                    end
                endcase
            end
        endcase
    end

    assign dc_bus_grant    = dc_bus_grant_r;
    assign ic_bus_grant    = ic_bus_grant_r;
    assign dc_wr_bus_grant = dc_wr_bus_grant_r;

    always @(posedge sram_uclk or negedge sram_rstn) begin
        if (!sram_rstn) begin
            lock_owner <= LOCK_NONE;
            rr_ptr     <= 2'd0;
        end else begin
            case (lock_owner)
                LOCK_NONE: begin
                    if (dc_rd_bus_en) begin
                        if (!dc_bus_transaction_done)
                            lock_owner <= LOCK_DC_READ;
                        rr_ptr <= 2'd2;
                    end else if (ic_rd_bus_en) begin
                        if (!ic_bus_transaction_done)
                            lock_owner <= LOCK_IC_READ;
                        rr_ptr <= 2'd0;
                    end else if (dc_wr_bus_en) begin
                        rr_ptr <= 2'd1;
                    end
                end
                LOCK_DC_READ: begin
                    if (dc_bus_transaction_done)
                        lock_owner <= LOCK_NONE;
                end
                LOCK_IC_READ: begin
                    if (ic_bus_transaction_done)
                        lock_owner <= LOCK_NONE;
                end
                default: begin
                    lock_owner <= LOCK_NONE;
                end
            endcase
        end
    end

    // ICache Read-request
    cache_rreq_bridge #(
        .BLK_LEN        (IC_BLK_LEN   ),
        .CWF_EN         (1            )
    ) u_ic_rreq_bridge (
        .cpu_rstn       (cpu_rstn     ),
        .cpu_clk        (cpu_clk      ),
        .bus_rstn       (sram_rstn    ),
        .bus_uclk       (sram_uclk    ),
        .bus_grant      (ic_bus_grant ),
        .bus_req_valid  (ic_bus_req_valid),
        .bus_transaction_done(ic_bus_transaction_done),
        // Cache Read Interface
        .dev_rrdy       (ic_rfifo_rdy ),
        .cpu_ren        (ic_cpu_ren   ),
        .cpu_raddr      (ic_cpu_raddr ),
        .cpu_rburst     (1'b1         ),
        .dev_rvalid     (ic_dev_rvalid),
        .dev_rdata      (ic_dev_rdata ),
        // SRAM-User Interface
        .bus_en         (ic_rd_bus_en ),
        .bus_raddr      (ic_bus_raddr ),
        .bus_rdata      (bus_rdata0   )
    );

    // DCache Read-request
    cache_rreq_bridge #(
        .BLK_LEN        (DC_BLK_LEN   ),
        .CWF_EN         (1            )
    ) u_dc_rreq_bridge (
        .cpu_rstn       (cpu_rstn     ),
        .cpu_clk        (cpu_clk      ),
        .bus_rstn       (sram_rstn    ),
        .bus_uclk       (sram_uclk    ),
        .bus_grant      (dc_bus_grant ),
        .bus_req_valid  (dc_bus_req_valid),
        .bus_transaction_done(dc_bus_transaction_done),
        // Cache Read Interface
        .dev_rrdy       (dc_rfifo_rdy ),
        .cpu_ren        (dc_cpu_r_mem ),
        .cpu_raddr      (dc_cpu_raddr ),
        .cpu_rburst     (dc_cpu_rburst),
        .dev_rvalid     (dc_mem_dev_rvalid),
        .dev_rdata      (dc_mem_dev_rdata ),
        // SRAM-User Interface
        .bus_en         (dc_rd_bus_en ),
        .bus_raddr      (dc_bus_raddr ),
        .bus_rdata      (bus_rdata0   )
    );

    // DCache Write-request
    cache_wreq_bridge u_dc_wreq_bridge (
        .cpu_rstn       (cpu_rstn     ),
        .cpu_clk        (cpu_clk      ),
        .bus_rstn       (sram_rstn    ),
        .bus_uclk       (sram_uclk    ),
        .bus_grant      (dc_wr_bus_grant),
        .bus_req_valid  (dc_wr_bus_req_valid),
        .bus_transaction_done(dc_wr_bus_transaction_done),
        // Cache Write Interface
        .dev_wrdy       (dc_wfifo_rdy ),
        .dev_wdone      (dc_wdone      ),
        .dev_widle      (dc_mem_widle ),
        .cpu_wen        (dc_cpu_w_mem ),
        .cpu_waddr      (dc_cpu_waddr ),
        .cpu_wdata      (dc_cpu_wdata ),
        // SRAM-User Interface
        .bus_en         (dc_wr_bus_en ),
        .bus_waddr      (dc_bus_waddr ),
        .bus_we         (bus_we       ),
        .bus_wdata      (bus_wdata    )
    );

    assign bus_en0 = wr_mem_en  | rd_mem_en | ic_rd_bus_en;
    assign bus_en1 = peri_write_fire | rd_peri_en;

    always @(*) begin
        if      (wr_mem_en   ) bus_addr0 = dc_bus_waddr;
        else if (rd_mem_en   ) bus_addr0 = dc_bus_raddr;
        else if (ic_rd_bus_en) bus_addr0 = ic_bus_raddr;
        else                   bus_addr0 = 32'hF0F0F0F0;
        
        if      (peri_write_fire) bus_addr1 = dc_cpu_waddr;
        else if (rd_peri_en  ) bus_addr1 = dc_cpu_raddr;
        else                   bus_addr1 = 32'hF1F1F1F1;
    end
    
    assign bus_we0 = bus_we & {4{wr_mem_en }};
    assign bus_we1    = peri_write_fire ? dc_cpu_wen : 4'h0;

    assign bus_wdata0 = bus_wdata;
    assign bus_wdata1 = dc_cpu_wdata;

`ifndef SYNTHESIS
    // Assertions for SRAM0 arbitration and bus one-hot safety
    always @(posedge sram_uclk) begin
        if (sram_rstn) begin
            // 1. One-hot or zero for bus_en
            if ((dc_wr_bus_en + dc_rd_bus_en + ic_rd_bus_en) > 1)
                $fatal(1, "[SRAM-ARB] Violation: multiple bus_en asserted simultaneously!");

            // 2. Lock owner non-overlap violation
            if ((lock_owner == LOCK_DC_READ) && (ic_rd_bus_en || dc_wr_bus_en))
                $fatal(1, "[SRAM-ARB] Violation: non-DCache read owner fired during DCache read lock!");
            if ((lock_owner == LOCK_IC_READ) && (dc_rd_bus_en || dc_wr_bus_en))
                $fatal(1, "[SRAM-ARB] Violation: non-ICache read owner fired during ICache read lock!");
        end
    end
`endif

endmodule
