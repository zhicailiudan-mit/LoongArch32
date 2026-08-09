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
    output wire         dc_dev_rrdy1,
    input  wire [ 3:0]  dc_cpu_ren1,
    input  wire [31:0]  dc_cpu_raddr1,
    input  wire         dc_cpu_rburst1,
    output wire         dc_dev_rvalid1,
    output wire [31:0]  dc_dev_rdata1,
    // BaseRAM bus (word address; low 20 bits select the 4 MiB bank)
    output wire         bus_en_base      ,
    output reg  [31:0]  bus_addr_base    ,
    output wire [ 3:0]  bus_we_base      ,
    output wire [31:0]  bus_wdata_base   ,
    input  wire [31:0]  bus_rdata_base   ,
    // ExtRAM bus (independent physical SRAM)
    output wire         bus_en_ext       ,
    output reg  [31:0]  bus_addr_ext     ,
    output wire [ 3:0]  bus_we_ext       ,
    output wire [31:0]  bus_wdata_ext    ,
    input  wire [31:0]  bus_rdata_ext    ,
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

    wire        ic_rd_bus_en, dc_rd_bus_en, dc1_rd_bus_en, dc_wr_bus_en;
    wire [31:0] ic_bus_raddr, dc_bus_raddr, dc1_bus_raddr, dc_bus_waddr;
    wire        dc_mem_dev_rvalid;
    wire [31:0] dc_mem_dev_rdata;
    wire        dc1_rfifo_rdy;
    wire        dc1_mem_dev_rvalid;
    wire [31:0] dc1_mem_dev_rdata;

    // Cache-side addresses are physical byte addresses.  DMW translation is
    // already complete before the cache reaches this module, so MMIO must be
    // recognized in the 0x1fxxxxxx physical window.  Keep the old aliases as
    // a compatibility path for legacy simulation images.
    function automatic is_soc_peripheral_addr;
        input [31:0] addr;
        begin
            is_soc_peripheral_addr =
                ((addr >= 32'h1f00_0000) && (addr < 32'h1f60_0000)) ||
                (addr[31:16] == 16'hBFAF) ||
                (addr[31:16] == 16'hBFD0);
        end
    endfunction

    function automatic is_ext_word_addr;
        input [31:0] word_addr;
        begin
            // 0x1c400000..0x1c7fffff becomes
            // 0x07100000..0x071fffff after byte-to-word conversion.
            is_ext_word_addr = (word_addr >= 32'h0710_0000) &&
                               (word_addr <  32'h0720_0000);
        end
    endfunction

    wire        dc_cpu_r_peripheral = (dc_cpu_ren != 4'h0) &&
                                      is_soc_peripheral_addr(dc_cpu_raddr);
    wire [ 3:0] dc_cpu_r_mem        = dc_cpu_r_peripheral ? 4'h0 : dc_cpu_ren;

    wire        dc_cpu_wvalid = (dc_cpu_wen != 4'h0);
    wire        dc_cpu_w_peripheral = dc_cpu_wvalid &&
                                      is_soc_peripheral_addr(dc_cpu_waddr);
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
    assign dc_dev_rrdy1 = fifo_init_done & dc1_rfifo_rdy;
    assign dc_dev_rvalid1 = dc1_mem_dev_rvalid;
    assign dc_dev_rdata1  = dc1_mem_dev_rdata;

    // ------------------------------------------------------------------
    // Independent BaseRAM/ExtRAM arbiters (sram_uclk domain)
    // ------------------------------------------------------------------
    wire ic_bus_req_valid, ic_bus_grant, ic_bus_transaction_done;
    wire dc_bus_req_valid, dc_bus_grant, dc_bus_transaction_done;
    wire dc1_bus_req_valid, dc1_bus_grant, dc1_bus_transaction_done;
    wire dc_wr_bus_req_valid, dc_wr_bus_grant, dc_wr_bus_transaction_done;

    localparam [1:0] LOCK_NONE    = 2'b00;
    localparam [1:0] LOCK_DC_READ = 2'b01;
    localparam [1:0] LOCK_IC_READ = 2'b10;
    localparam [1:0] LOCK_DC1_READ = 2'b11;

    wire ic_bank_ext    = is_ext_word_addr(ic_bus_raddr);
    wire dc_bank_ext    = is_ext_word_addr(dc_bus_raddr);
    wire dc1_bank_ext   = is_ext_word_addr(dc1_bus_raddr);
    wire dc_wr_bank_ext = is_ext_word_addr(dc_bus_waddr);

    wire base_ic_req = ic_bus_req_valid && !ic_bank_ext;
    wire base_dc_req = dc_bus_req_valid && !dc_bank_ext;
    wire base_dc1_req = dc1_bus_req_valid && !dc1_bank_ext;
    wire base_wr_req = dc_wr_bus_req_valid && !dc_wr_bank_ext;
    wire ext_ic_req  = ic_bus_req_valid &&  ic_bank_ext;
    wire ext_dc_req  = dc_bus_req_valid &&  dc_bank_ext;
    wire ext_dc1_req = dc1_bus_req_valid && dc1_bank_ext;
    wire ext_wr_req  = dc_wr_bus_req_valid && dc_wr_bank_ext;

    reg [1:0] base_lock_owner;
    reg [1:0] ext_lock_owner;
    reg base_dc_bus_grant_r, base_ic_bus_grant_r, base_wr_bus_grant_r;
    reg ext_dc_bus_grant_r,  ext_ic_bus_grant_r,  ext_wr_bus_grant_r;
    reg base_dc1_bus_grant_r, ext_dc1_bus_grant_r;

    // Reads keep their normal low-latency priority, but a continuously busy
    // read stream must not starve an accepted L2 SBUF/WBB drain forever.
    // The request at the write FIFO head is stable until granted, so a small
    // saturating wait counter per physical bank is sufficient.  Once the
    // bound is reached, grant exactly one write at the next unlocked bank
    // arbitration point; the counter resets on the real SRAM write fire.
    localparam [3:0] WRITE_STARVE_LIMIT = 4'd15;
    reg [3:0] base_wr_wait_count;
    reg [3:0] ext_wr_wait_count;
    wire base_wr_starved = (base_wr_wait_count == WRITE_STARVE_LIMIT);
    wire ext_wr_starved  = (ext_wr_wait_count  == WRITE_STARVE_LIMIT);

    always @(posedge sram_uclk or negedge sram_rstn) begin
        if (!sram_rstn) begin
            base_wr_wait_count <= 4'd0;
            ext_wr_wait_count  <= 4'd0;
        end else begin
            if (!base_wr_req || (dc_wr_bus_en && !dc_wr_bank_ext))
                base_wr_wait_count <= 4'd0;
            else if (!base_wr_starved)
                base_wr_wait_count <= base_wr_wait_count + 4'd1;

            if (!ext_wr_req || (dc_wr_bus_en && dc_wr_bank_ext))
                ext_wr_wait_count <= 4'd0;
            else if (!ext_wr_starved)
                ext_wr_wait_count <= ext_wr_wait_count + 4'd1;
        end
    end

    always @(*) begin
        base_dc_bus_grant_r = 1'b0;
        base_ic_bus_grant_r = 1'b0;
        base_wr_bus_grant_r = 1'b0;
        ext_dc_bus_grant_r  = 1'b0;
        ext_ic_bus_grant_r  = 1'b0;
        ext_wr_bus_grant_r  = 1'b0;
        base_dc1_bus_grant_r = 1'b0;
        ext_dc1_bus_grant_r  = 1'b0;

        case (base_lock_owner)
            LOCK_DC_READ: base_dc_bus_grant_r = base_dc_req;
            LOCK_IC_READ: base_ic_bus_grant_r = base_ic_req;
            LOCK_DC1_READ: base_dc1_bus_grant_r = base_dc1_req;
            default: begin
                // Demand reads retain priority over WCB/write traffic within
                // each physical SRAM bank until the bounded starvation limit.
                if (base_wr_req && base_wr_starved)
                    base_wr_bus_grant_r = 1'b1;
                else if (base_dc_req)
                    base_dc_bus_grant_r = 1'b1;
                else if (base_dc1_req)
                    base_dc1_bus_grant_r = 1'b1;
                else if (base_ic_req)
                    base_ic_bus_grant_r = 1'b1;
                else if (base_wr_req)
                    base_wr_bus_grant_r = 1'b1;
            end
        endcase

        case (ext_lock_owner)
            LOCK_DC_READ: ext_dc_bus_grant_r = ext_dc_req;
            LOCK_IC_READ: ext_ic_bus_grant_r = ext_ic_req;
            LOCK_DC1_READ: ext_dc1_bus_grant_r = ext_dc1_req;
            default: begin
                if (ext_wr_req && ext_wr_starved)
                    ext_wr_bus_grant_r = 1'b1;
                else if (ext_dc_req)
                    ext_dc_bus_grant_r = 1'b1;
                else if (ext_dc1_req)
                    ext_dc1_bus_grant_r = 1'b1;
                else if (ext_ic_req)
                    ext_ic_bus_grant_r = 1'b1;
                else if (ext_wr_req)
                    ext_wr_bus_grant_r = 1'b1;
            end
        endcase
    end

    assign dc_bus_grant    = dc_bank_ext ? ext_dc_bus_grant_r : base_dc_bus_grant_r;
    assign dc1_bus_grant   = dc1_bank_ext ? ext_dc1_bus_grant_r : base_dc1_bus_grant_r;
    assign ic_bus_grant    = ic_bank_ext ? ext_ic_bus_grant_r : base_ic_bus_grant_r;
    assign dc_wr_bus_grant = dc_wr_bank_ext ? ext_wr_bus_grant_r : base_wr_bus_grant_r;

    always @(posedge sram_uclk or negedge sram_rstn) begin
        if (!sram_rstn) begin
            base_lock_owner <= LOCK_NONE;
            ext_lock_owner  <= LOCK_NONE;
        end else begin
            case (base_lock_owner)
                LOCK_NONE: begin
                    if (dc_rd_bus_en && !dc_bank_ext) begin
                        if (!dc_bus_transaction_done)
                            base_lock_owner <= LOCK_DC_READ;
                    end else if (dc1_rd_bus_en && !dc1_bank_ext) begin
                        if (!dc1_bus_transaction_done)
                            base_lock_owner <= LOCK_DC1_READ;
                    end else if (ic_rd_bus_en && !ic_bank_ext) begin
                        if (!ic_bus_transaction_done)
                            base_lock_owner <= LOCK_IC_READ;
                    end
                end
                LOCK_DC_READ: begin
                    if (dc_bus_transaction_done)
                        base_lock_owner <= LOCK_NONE;
                end
                LOCK_DC1_READ: begin
                    if (dc1_bus_transaction_done)
                        base_lock_owner <= LOCK_NONE;
                end
                LOCK_IC_READ: begin
                    if (ic_bus_transaction_done)
                        base_lock_owner <= LOCK_NONE;
                end
                default: base_lock_owner <= LOCK_NONE;
            endcase

            case (ext_lock_owner)
                LOCK_NONE: begin
                    if (dc_rd_bus_en && dc_bank_ext) begin
                        if (!dc_bus_transaction_done)
                            ext_lock_owner <= LOCK_DC_READ;
                    end else if (dc1_rd_bus_en && dc1_bank_ext) begin
                        if (!dc1_bus_transaction_done)
                            ext_lock_owner <= LOCK_DC1_READ;
                    end else if (ic_rd_bus_en && ic_bank_ext) begin
                        if (!ic_bus_transaction_done)
                            ext_lock_owner <= LOCK_IC_READ;
                    end
                end
                LOCK_DC_READ: begin
                    if (dc_bus_transaction_done)
                        ext_lock_owner <= LOCK_NONE;
                end
                LOCK_DC1_READ: begin
                    if (dc1_bus_transaction_done)
                        ext_lock_owner <= LOCK_NONE;
                end
                LOCK_IC_READ: begin
                    if (ic_bus_transaction_done)
                        ext_lock_owner <= LOCK_NONE;
                end
                default: ext_lock_owner <= LOCK_NONE;
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
        .bus_rdata      (ic_bank_ext ? bus_rdata_ext : bus_rdata_base)
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
        .bus_rdata      (dc_bank_ext ? bus_rdata_ext : bus_rdata_base)
    );

    cache_rreq_bridge #(
        .BLK_LEN        (DC_BLK_LEN   ),
        .CWF_EN         (1            )
    ) u_dc1_rreq_bridge (
        .cpu_rstn       (cpu_rstn     ),
        .cpu_clk        (cpu_clk      ),
        .bus_rstn       (sram_rstn    ),
        .bus_uclk       (sram_uclk    ),
        .bus_grant      (dc1_bus_grant),
        .bus_req_valid  (dc1_bus_req_valid),
        .bus_transaction_done(dc1_bus_transaction_done),
        .dev_rrdy       (dc1_rfifo_rdy),
        .cpu_ren        (dc_cpu_ren1 ),
        .cpu_raddr      (dc_cpu_raddr1),
        .cpu_rburst     (dc_cpu_rburst1),
        .dev_rvalid     (dc1_mem_dev_rvalid),
        .dev_rdata      (dc1_mem_dev_rdata),
        .bus_en         (dc1_rd_bus_en),
        .bus_raddr      (dc1_bus_raddr),
        .bus_rdata      (dc1_bank_ext ? bus_rdata_ext : bus_rdata_base)
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

    wire base_wr_mem_en = wr_mem_en && !dc_wr_bank_ext;
    wire base_rd_mem_en = rd_mem_en && !dc_bank_ext;
    wire base_dc1_mem_en = dc1_rd_bus_en && !dc1_bank_ext;
    wire base_ic_mem_en = ic_rd_bus_en && !ic_bank_ext;
    wire ext_wr_mem_en  = wr_mem_en && dc_wr_bank_ext;
    wire ext_rd_mem_en  = rd_mem_en && dc_bank_ext;
    wire ext_dc1_mem_en = dc1_rd_bus_en && dc1_bank_ext;
    wire ext_ic_mem_en  = ic_rd_bus_en && ic_bank_ext;

    assign bus_en_base = base_wr_mem_en | base_rd_mem_en | base_dc1_mem_en | base_ic_mem_en;
    assign bus_en_ext  = ext_wr_mem_en  | ext_rd_mem_en  | ext_dc1_mem_en | ext_ic_mem_en;
    assign bus_en1     = peri_write_fire | rd_peri_en;

    always @(*) begin
        if      (base_wr_mem_en) bus_addr_base = dc_bus_waddr;
        else if (base_rd_mem_en) bus_addr_base = dc_bus_raddr;
        else if (base_dc1_mem_en) bus_addr_base = dc1_bus_raddr;
        else if (base_ic_mem_en) bus_addr_base = ic_bus_raddr;
        else                     bus_addr_base = 32'hF0F0F0F0;

        if      (ext_wr_mem_en) bus_addr_ext = dc_bus_waddr;
        else if (ext_rd_mem_en) bus_addr_ext = dc_bus_raddr;
        else if (ext_dc1_mem_en) bus_addr_ext = dc1_bus_raddr;
        else if (ext_ic_mem_en) bus_addr_ext = ic_bus_raddr;
        else                    bus_addr_ext = 32'hF1F1F1F1;

        if      (peri_write_fire) bus_addr1 = dc_cpu_waddr;
        else if (rd_peri_en  ) bus_addr1 = dc_cpu_raddr;
        else                   bus_addr1 = 32'hF1F1F1F1;
    end

    assign bus_we_base = bus_we & {4{base_wr_mem_en}};
    assign bus_we_ext  = bus_we & {4{ext_wr_mem_en }};
    assign bus_we1     = peri_write_fire ? dc_cpu_wen : 4'h0;

    assign bus_wdata_base = bus_wdata;
    assign bus_wdata_ext  = bus_wdata;
    assign bus_wdata1     = dc_cpu_wdata;


endmodule
