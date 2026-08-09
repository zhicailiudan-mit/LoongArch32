`default_nettype none

module thinpad_top(
    input wire clk_50M,
    input wire clk_11M0592,

    input wire clock_btn,
    input wire reset_btn,

    input  wire [3:0]  touch_btn,
    input  wire [31:0] dip_sw,
    output wire [15:0] leds,
    output wire [7:0]  dpy0,
    output wire [7:0]  dpy1,

    inout  wire [31:0] base_ram_data,
    output wire [19:0] base_ram_addr,
    output wire [3:0]  base_ram_be_n,
    output wire        base_ram_ce_n,
    output wire        base_ram_oe_n,
    output wire        base_ram_we_n,

    inout  wire [31:0] ext_ram_data,
    output wire [19:0] ext_ram_addr,
    output wire [3:0]  ext_ram_be_n,
    output wire        ext_ram_ce_n,
    output wire        ext_ram_oe_n,
    output wire        ext_ram_we_n,

    output wire txd,
    input  wire rxd,

    output wire [22:0] flash_a,
    inout  wire [15:0] flash_d,
    output wire        flash_rp_n,
    output wire        flash_vpen,
    output wire        flash_ce_n,
    output wire        flash_oe_n,
    output wire        flash_we_n,
    output wire        flash_byte_n,

    output wire [2:0] video_red,
    output wire [2:0] video_green,
    output wire [1:0] video_blue,
    output wire       video_hsync,
    output wire       video_vsync,
    output wire       video_clk,
    output wire       video_de
);

    // ------------------------------------------------------------------
    // Clock generation (clk_pll IP, MMCM)
    //   in : clk_50M (board 50 MHz crystal)
    //   out: clk_out1 -> cpu_clk       (60.7 MHz - CI timing-safe, was
    //                                    "66 MHz" requested but 100 MHz
    //                                    delivered via MMCM divide 17)
    //        clk_out2 -> io_clk_100M   (spare, 100 MHz)
    //        clk_out3 -> sram_uclk     (70 MHz, 0 deg   - SRAM user clk)
    //        clk_out4 -> sram_wclk     (70 MHz, 90 deg  - SRAM WE clk)
    // Regenerate the IP with Input Clock = 50 MHz before synthesis;
    // Vivado will recompute M/D so VCO stays inside 800~1600 MHz.
    // ------------------------------------------------------------------
    wire cpu_clk;
    wire io_clk_100M;
    wire sram_uclk;
    wire sram_wclk;
    wire pll_locked;

    clk_pll u_clk_pll (
        .clk_in1  (clk_50M),
        .clk_out1 (cpu_clk),
        .clk_out2 (io_clk_100M),
        .clk_out3 (sram_uclk),
        .clk_out4 (sram_wclk),
        .locked   (pll_locked)
    );

    // Assert from the board/MMCM reset immediately, but release reset through
    // a synchronizer in each independent clock domain.
    wire raw_rstn = ~(reset_btn | ~pll_locked);
    wire cpu_rstn;
    wire sram_rstn;
    ResetDomainSync #(.STAGES(8)) u_cpu_reset_sync (
        .clk        (cpu_clk),
        .async_rstn (raw_rstn),
        .sync_rstn  (cpu_rstn)
    );
    ResetDomainSync #(.STAGES(8)) u_sram_reset_sync (
        .clk        (sram_uclk),
        .async_rstn (raw_rstn),
        .sync_rstn  (sram_rstn)
    );

    wire        base_sram_bus_en;
    wire [31:0] base_sram_bus_addr;
    wire [3:0]  base_sram_bus_we;
    wire [31:0] base_sram_bus_wdata;
    wire [31:0] base_sram_bus_rdata;
    wire        ext_sram_bus_en;
    wire [31:0] ext_sram_bus_addr;
    wire [3:0]  ext_sram_bus_we;
    wire [31:0] ext_sram_bus_wdata;
    wire [31:0] ext_sram_bus_rdata;

    wire        peri_bus_en;
    wire [31:0] peri_bus_addr;
    wire [3:0]  peri_bus_we;
    wire [31:0] peri_bus_wdata;
    wire [31:0] peri_bus_rdata;

    localparam [31:0] UART_DATA_ADDR = 32'h1f00_0000;
    localparam [31:0] UART_STAT_ADDR = 32'h1f00_0005;

    function automatic is_uart_data_addr;
        input [31:0] addr;
        begin
            is_uart_data_addr = (addr == 32'h1f00_0000) ||
                                (addr == 32'hbf00_0000) ||
                                (addr == 32'hbfd0_03f8);
        end
    endfunction

    function automatic is_uart_status_addr;
        input [31:0] addr;
        begin
            is_uart_status_addr = (addr == 32'h1f00_0005) ||
                                  (addr == 32'hbf00_0005) ||
                                  (addr == 32'hbfd0_03fc);
        end
    endfunction

    function automatic is_uart_window_addr;
        input [31:0] addr;
        begin
            // Include +0..+5 so the supervisor's 16550 divisor/LCR writes
            // are accepted even though this minimal UART does not need to
            // expose every register as state.
            is_uart_window_addr =
                ((addr >= 32'h1f00_0000) && (addr <= 32'h1f00_0005)) ||
                ((addr >= 32'hbf00_0000) && (addr <= 32'hbf00_0005)) ||
                ((addr >= 32'hbfd0_03f8) && (addr <= 32'hbfd0_03fc));
        end
    endfunction

    wire conf_bus_sel = (peri_bus_addr[31:16] == 16'hBFAF);
    wire uart_bus_sel = is_uart_window_addr(peri_bus_addr);
    wire conf_bus_en  = peri_bus_en && conf_bus_sel;

    wire [31:0] conf_bus_rdata;
    wire [ 4:0] conf_ram_random_mask;
    wire [15:0] conf_leds;
    wire [ 1:0] conf_led_rg0;
    wire [ 1:0] conf_led_rg1;
    wire [ 7:0] conf_num_csn;
    wire [ 6:0] conf_num_a_g;
    wire [31:0] conf_num_data;
    wire [ 3:0] conf_btn_key_col;
    wire [ 3:0] conf_btn_key_row = ~touch_btn;

    mycpu_top u_cpu (
        .cpu_rstn       (cpu_rstn),
        .cpu_clk        (cpu_clk),
        .sram_rstn      (sram_rstn),
        .sram_uclk      (sram_uclk),

        .base_sram_bus_en    (base_sram_bus_en),
        .base_sram_bus_addr  (base_sram_bus_addr),
        .base_sram_bus_we    (base_sram_bus_we),
        .base_sram_bus_wdata (base_sram_bus_wdata),
        .base_sram_bus_rdata (base_sram_bus_rdata),
        .ext_sram_bus_en     (ext_sram_bus_en),
        .ext_sram_bus_addr   (ext_sram_bus_addr),
        .ext_sram_bus_we     (ext_sram_bus_we),
        .ext_sram_bus_wdata  (ext_sram_bus_wdata),
        .ext_sram_bus_rdata  (ext_sram_bus_rdata),

        .peri_bus_en    (peri_bus_en),
        .peri_bus_addr  (peri_bus_addr),
        .peri_bus_we    (peri_bus_we),
        .peri_bus_wdata (peri_bus_wdata),
        .peri_bus_rdata (peri_bus_rdata)
    );

    confreg #(
        .SIMULATION     (1'b0)
    ) u_confreg (
        .aclk           (cpu_clk),
        .timer_clk      (cpu_clk),
        .aresetn        (cpu_rstn),

        .bus_en         (conf_bus_en),
        .bus_addr       (peri_bus_addr),
        .bus_we         (conf_bus_sel ? peri_bus_we : 4'h0),
        .bus_wdata      (peri_bus_wdata),
        .bus_rdata      (conf_bus_rdata),

        .ram_random_mask(conf_ram_random_mask),
        .led            (conf_leds),
        .led_rg0        (conf_led_rg0),
        .led_rg1        (conf_led_rg1),
        .num_csn        (conf_num_csn),
        .num_a_g        (conf_num_a_g),
        .num_data       (conf_num_data),
        .switch         (dip_sw[7:0]),
        .btn_key_col    (conf_btn_key_col),
        .btn_key_row    (conf_btn_key_row),
        .btn_step       (2'b11)
    );

    sram_ctrl #(20) u_base_ram_ctrl (
        .rstn       (sram_rstn),
        .usr_clk    (sram_uclk),
        .wen_clk    (sram_wclk),
        .usr_en     (base_sram_bus_en),
        .usr_addr   (base_sram_bus_addr),
        .usr_we     (base_sram_bus_we),
        .usr_wdata  (base_sram_bus_wdata),
        .usr_rdata  (base_sram_bus_rdata),
        .sram_addr  (base_ram_addr),
        .sram_data  (base_ram_data),
        .sram_oen   (base_ram_oe_n),
        .sram_cen   (base_ram_ce_n),
        .sram_wen   (base_ram_we_n),
        .sram_ben   (base_ram_be_n)
    );

    sram_ctrl #(20) u_ext_ram_ctrl (
        .rstn       (sram_rstn),
        .usr_clk    (sram_uclk),
        .wen_clk    (sram_wclk),
        .usr_en     (ext_sram_bus_en),
        .usr_addr   (ext_sram_bus_addr),
        .usr_we     (ext_sram_bus_we),
        .usr_wdata  (ext_sram_bus_wdata),
        .usr_rdata  (ext_sram_bus_rdata),
        .sram_addr  (ext_ram_addr),
        .sram_data  (ext_ram_data),
        .sram_oen   (ext_ram_oe_n),
        .sram_cen   (ext_ram_ce_n),
        .sram_wen   (ext_ram_we_n),
        .sram_ben   (ext_ram_be_n)
    );

    wire        uart_rx_ready_raw;
    wire [7:0]  uart_rx_data_raw;
    reg         uart_rx_valid;
    reg  [7:0]  uart_rx_data;

    wire        uart_tx_busy;
    reg         uart_tx_start;
    reg  [7:0]  uart_tx_data;

    wire uart_data_read  = peri_bus_en && (peri_bus_we == 4'h0) &&
                           is_uart_data_addr(peri_bus_addr);
    wire uart_data_write = peri_bus_en && (peri_bus_we != 4'h0) &&
                           is_uart_data_addr(peri_bus_addr);
    wire uart_rx_capture = uart_rx_ready_raw && !uart_rx_valid;
    wire uart_rx_clear   = uart_rx_capture || (uart_rx_ready_raw && uart_data_read);

    // UART frequency must match the actual cpu_clk period.  The supervisor's
    // 16550 setup selects approximately 115200 baud (DLL=0x0e at its
    // reference clock), so the fixed implementation uses that line rate and
    // accepts the divisor/LCR writes as harmless configuration writes.
    localparam integer CPU_CLK_HZ = 60_714_286;
    localparam integer UART_BAUD  = 115_200;

    async_receiver #(
        .ClkFrequency(CPU_CLK_HZ),
        .Baud        (UART_BAUD)
    ) u_uart_rx (
        .clk            (cpu_clk),
        .RxD            (rxd),
        .RxD_data_ready (uart_rx_ready_raw),
        .RxD_clear      (uart_rx_clear),
        .RxD_data       (uart_rx_data_raw)
    );

    async_transmitter #(
        .ClkFrequency(CPU_CLK_HZ),
        .Baud        (UART_BAUD)
    ) u_uart_tx (
        .clk       (cpu_clk),
        .TxD_start (uart_tx_start),
        .TxD_data  (uart_tx_data),
        .TxD       (txd),
        .TxD_busy  (uart_tx_busy)
    );

    always @(posedge cpu_clk or negedge cpu_rstn) begin
        if (!cpu_rstn) begin
            uart_rx_valid <= 1'b0;
            uart_rx_data  <= 8'h00;
        end else begin
            if (uart_rx_capture) begin
                uart_rx_valid <= 1'b1;
                uart_rx_data  <= uart_rx_data_raw;
            end else if (uart_data_read) begin
                uart_rx_valid <= 1'b0;
            end
        end
    end

    always @(posedge cpu_clk or negedge cpu_rstn) begin
        if (!cpu_rstn) begin
            uart_tx_start <= 1'b0;
            uart_tx_data  <= 8'h00;
        end else begin
            uart_tx_start <= uart_data_write && !uart_tx_busy;
            if (uart_data_write && !uart_tx_busy) begin
                uart_tx_data <= peri_bus_wdata[7:0];
            end
        end
    end

    // Required monitor semantics: bit0=RX_READY, bit5=TX_READY.
    wire [31:0] uart_status = {26'h0, !uart_tx_busy, 4'h0, uart_rx_valid};

    wire [31:0] uart_bus_rdata_next =
        is_uart_data_addr(peri_bus_addr)   ? {24'h0, uart_rx_data} :
        is_uart_status_addr(peri_bus_addr) ? uart_status :
        32'h0000_0000;

    // sram_bus_master samples peripheral read data one cycle after the request.
    // confreg already registers read data internally; UART data is registered here.
    reg [31:0] uart_bus_rdata_r;
    reg        peri_read_conf_r;
    reg        peri_read_uart_r;
    always @(posedge cpu_clk or negedge cpu_rstn) begin
        if (!cpu_rstn) begin
            uart_bus_rdata_r <= 32'h0000_0000;
            peri_read_conf_r <= 1'b0;
            peri_read_uart_r <= 1'b0;
        end else if (peri_bus_en && (peri_bus_we == 4'h0)) begin
            peri_read_conf_r <= conf_bus_sel;
            peri_read_uart_r <= uart_bus_sel;
            if (uart_bus_sel) begin
                uart_bus_rdata_r <= uart_bus_rdata_next;
            end
        end
    end

    assign peri_bus_rdata = peri_read_conf_r ? conf_bus_rdata    :
                            peri_read_uart_r ? uart_bus_rdata_r :
                            32'h0000_0000;

    assign flash_d      = 16'hzzzz;
    assign flash_a      = 23'h000000;
    assign flash_rp_n   = 1'b1;
    assign flash_vpen   = 1'b1;
    assign flash_ce_n   = 1'b1;
    assign flash_oe_n   = 1'b1;
    assign flash_we_n   = 1'b1;
    assign flash_byte_n = 1'b1;

    assign video_red   = 3'b000;
    assign video_green = 3'b000;
    assign video_blue  = 2'b00;
    assign video_hsync = 1'b1;
    assign video_vsync = 1'b1;
    assign video_clk   = clk_50M;
    assign video_de    = 1'b0;

    assign leds = conf_leds;

    SEG7_LUT u_seg_low  (.oSEG1(dpy0), .iDIG(conf_num_data[3:0]));
    SEG7_LUT u_seg_high (.oSEG1(dpy1), .iDIG(conf_num_data[7:4]));

    wire unused_conf = ^{
        conf_led_rg0,
        conf_led_rg1,
        conf_num_csn,
        conf_num_a_g,
        conf_ram_random_mask,
        conf_btn_key_col
    };
    wire unused_inputs = clk_11M0592 ^ clock_btn ^ io_clk_100M ^ unused_conf;
    wire unused_inputs_keep = unused_inputs;

endmodule

`default_nettype wire
