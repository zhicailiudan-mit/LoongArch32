`timescale 1ns / 1ps
`include "defines.vh"

module mycpu_top(
    input  wire        cpu_rstn,
    input  wire        cpu_clk,
    input  wire        sram_uclk,

    // BUS Interface 0 (SRAM)
    output wire        sram_bus_en   ,
    output wire [31:0] sram_bus_addr ,
    output wire [ 3:0] sram_bus_we   ,
    output wire [31:0] sram_bus_wdata,
    input  wire [31:0] sram_bus_rdata,
    
    // BUS Interface 1 (Peripheral)
    output wire        peri_bus_en   ,
    output wire [31:0] peri_bus_addr ,
    output wire [ 3:0] peri_bus_we   ,
    output wire [31:0] peri_bus_wdata,
    input  wire [31:0] peri_bus_rdata
);

    // ICache Interface
    wire        cpu2ic_rreq  ;
    wire        ic2cpu_ready ;
    wire [31:0] cpu2ic_addr  ;
    wire        cpu2ic_cacheable;
    wire        cpu2ic_dual  ;
    wire        ic2cpu_valid ;
    wire [31:0] ic2cpu_inst  ;
    wire        ic2cpu_valid1;
    wire [31:0] ic2cpu_inst1 ;
    wire        cpu2ic_pderr ;

    wire        dev2ic_rrdy  ;
    wire [ 3:0] ic2dev_ren   ;
    wire [31:0] ic2dev_raddr ;
    wire        dev2ic_rvalid;
    wire [31:0] dev2ic_rdata ;

    // DCache Interface
    wire [ 3:0] cpu2dc_ren   ;
    wire [31:0] cpu2dc_addr  ;
    wire        cpu2dc_cacheable;
    wire        dc2cpu_rready;
    wire        dc2cpu_valid ;
    wire [31:0] dc2cpu_rdata ;
    wire [ 3:0] cpu2dc_wen   ;
    wire [31:0] cpu2dc_wdata ;
    wire        dc2cpu_wready;
    wire        dc2cpu_wposted;
    wire        dc2cpu_wresp ;
    wire        dc_line_alloc_valid;
    wire [31:0] dc_line_alloc_addr;
    wire [`CACHE_BLK_SIZE-1:0] dc_line_alloc_data;
    wire [`CACHE_BLK_LEN-1:0] dc_line_alloc_word_mask;
    wire        dc_line_alloc_ready;

    wire        dev2dc_wrdy  ;
    wire        dev2dc_wdone ;
    wire [ 3:0] dc2dev_wen   ;
    wire [31:0] dc2dev_waddr ;
    wire [31:0] dc2dev_wdata ;
    wire        dev2dc_rrdy  ;
    wire [ 3:0] dc2dev_ren   ;
    wire [31:0] dc2dev_raddr ;
    wire        dc2dev_rburst;
    wire        dev2dc_rvalid;
    wire [31:0] dev2dc_rdata ;

    wire        ic_maint_valid, ic_maint_ready, ic_maint_done;
    wire        dc_maint_valid, dc_maint_ready, dc_maint_done;
    wire        cache_maint_all;
    wire [1:0]  cache_maint_mode;
    wire [31:0] cache_maint_addr;
    wire [31:0] cache_maint_ctag;
    
    MyCpu u_mycpu (
        .cpu_rstn       (cpu_rstn    ),
        .cpu_clk        (cpu_clk     ),
        // Instruction Fetch Interface
        .ifetch_rreq    (cpu2ic_rreq ),
        .ifetch_ready   (ic2cpu_ready),
        .ifetch_addr    (cpu2ic_addr ),
        .ifetch_cacheable(cpu2ic_cacheable),
        .ifetch_dual    (cpu2ic_dual ),
        .ifetch_valid   (ic2cpu_valid),
        .ifetch_inst    (ic2cpu_inst ),
        .ifetch1_valid  (ic2cpu_valid1),
        .ifetch1_inst   (ic2cpu_inst1),
        .pred_error     (cpu2ic_pderr),
        // Data Access Interface
        .daccess_ren    (cpu2dc_ren  ),
        .daccess_addr   (cpu2dc_addr ),
        .daccess_cacheable(cpu2dc_cacheable),
        .daccess_rready (dc2cpu_rready),
        .daccess_valid  (dc2cpu_valid),
        .daccess_rdata  (dc2cpu_rdata),
        .daccess_wen    (cpu2dc_wen  ),
        .daccess_wdata  (cpu2dc_wdata),
        .daccess_wready (dc2cpu_wready),
        .daccess_wposted(dc2cpu_wposted),
        .daccess_wresp  (dc2cpu_wresp),
        .daccess_line_alloc_valid(dc_line_alloc_valid),
        .daccess_line_alloc_addr(dc_line_alloc_addr),
        .daccess_line_alloc_data(dc_line_alloc_data),
        .daccess_line_alloc_word_mask(dc_line_alloc_word_mask),
        .daccess_line_alloc_ready(dc_line_alloc_ready),
        .icache_maint_valid(ic_maint_valid),
        .icache_maint_ready(ic_maint_ready),
        .icache_maint_done (ic_maint_done),
        .dcache_maint_valid(dc_maint_valid),
        .dcache_maint_ready(dc_maint_ready),
        .dcache_maint_done (dc_maint_done),
        .cache_maint_all   (cache_maint_all),
        .cache_maint_mode  (cache_maint_mode),
        .cache_maint_addr  (cache_maint_addr),
        .cache_maint_ctag  (cache_maint_ctag)
    );

    ICache u_icache (
        .cpu_rstn       (cpu_rstn     ),
        .cpu_clk        (cpu_clk      ),
        // Interface to CPU
        .inst_rreq      (cpu2ic_rreq  ),
        .inst_ready     (ic2cpu_ready ),
        .inst_addr      (cpu2ic_addr  ),
        .inst_cacheable (cpu2ic_cacheable),
        .inst_dual      (cpu2ic_dual  ),
        .inst_valid     (ic2cpu_valid ),
        .inst_out       (ic2cpu_inst  ),
        .inst1_valid    (ic2cpu_valid1),
        .inst1_out      (ic2cpu_inst1 ),
        .pred_error     (cpu2ic_pderr ),
        // Interface to Bus
        .dev_rrdy       (dev2ic_rrdy  ),
        .cpu_ren        (ic2dev_ren   ),
        .cpu_raddr      (ic2dev_raddr ),
        .dev_rvalid     (dev2ic_rvalid),
        .dev_rdata      (dev2ic_rdata ),
        .maint_valid    (ic_maint_valid),
        .maint_ready    (ic_maint_ready),
        .maint_done     (ic_maint_done),
        .maint_all      (cache_maint_all),
        .maint_mode     (cache_maint_mode),
        .maint_addr     (cache_maint_addr),
        .maint_ctag     (cache_maint_ctag)
    );

    DCache u_dcache (
        .cpu_rstn       (cpu_rstn     ),
        .cpu_clk        (cpu_clk      ),
        // Interface to CPU
        .data_ren       (cpu2dc_ren   ),
        .data_addr      (cpu2dc_addr  ),
        .data_cacheable (cpu2dc_cacheable),
        .data_rready    (dc2cpu_rready),
        .data_valid     (dc2cpu_valid ),
        .data_rdata     (dc2cpu_rdata ),
        .data_wen       (cpu2dc_wen   ),
        .data_wdata     (cpu2dc_wdata ),
        .data_wready    (dc2cpu_wready),
        .data_wposted   (dc2cpu_wposted),
        .data_wresp     (dc2cpu_wresp ),
        .line_alloc_valid(dc_line_alloc_valid),
        .line_alloc_addr(dc_line_alloc_addr),
        .line_alloc_data(dc_line_alloc_data),
        .line_alloc_word_mask(dc_line_alloc_word_mask),
        .line_alloc_ready(dc_line_alloc_ready),
        // Interface to Bus
        .dev_wrdy       (dev2dc_wrdy  ),
        .dev_wdone      (dev2dc_wdone ),
        .cpu_wen        (dc2dev_wen   ),
        .cpu_waddr      (dc2dev_waddr ),
        .cpu_wdata      (dc2dev_wdata ),
        .dev_rrdy       (dev2dc_rrdy  ),
        .cpu_ren        (dc2dev_ren   ),
        .cpu_raddr      (dc2dev_raddr ),
        .cpu_rburst     (dc2dev_rburst),
        .dev_rvalid     (dev2dc_rvalid),
        .dev_rdata      (dev2dc_rdata ),
        .maint_valid    (dc_maint_valid),
        .maint_ready    (dc_maint_ready),
        .maint_done     (dc_maint_done),
        .maint_all      (cache_maint_all),
        .maint_mode     (cache_maint_mode),
        .maint_addr     (cache_maint_addr),
        .maint_ctag     (cache_maint_ctag)
    );

    sram_bus_master u_sram_bus (
        .cpu_rstn       (cpu_rstn      ),
        .cpu_clk        (cpu_clk       ),
        .sram_uclk      (sram_uclk     ),
        // ICache Interface
        .ic_dev_rrdy    (dev2ic_rrdy   ),
        .ic_cpu_ren     (|ic2dev_ren   ),
        .ic_cpu_raddr   (ic2dev_raddr  ),
        .ic_dev_rvalid  (dev2ic_rvalid ),
        .ic_dev_rdata   (dev2ic_rdata  ),
        // DCache Interface
        .dc_dev_wrdy    (dev2dc_wrdy   ),
        .dc_dev_wdone   (dev2dc_wdone  ),
        .dc_cpu_wen     (dc2dev_wen    ),
        .dc_cpu_waddr   (dc2dev_waddr  ),
        .dc_cpu_wdata   (dc2dev_wdata  ),
        .dc_dev_rrdy    (dev2dc_rrdy   ),
        .dc_cpu_ren     (dc2dev_ren    ),
        .dc_cpu_raddr   (dc2dev_raddr  ),
        .dc_cpu_rburst  (dc2dev_rburst ),
        .dc_dev_rvalid  (dev2dc_rvalid ),
        .dc_dev_rdata   (dev2dc_rdata  ),
        // SRAM-BUS Interface 0 (SRAM)
        .bus_en0        (sram_bus_en   ),
        .bus_addr0      (sram_bus_addr ),
        .bus_we0        (sram_bus_we   ),
        .bus_wdata0     (sram_bus_wdata),
        .bus_rdata0     (sram_bus_rdata),
        // SRAM-BUS Interface 1 (Peripheral)
        .bus_en1        (peri_bus_en   ),
        .bus_addr1      (peri_bus_addr ),
        .bus_we1        (peri_bus_we   ),
        .bus_wdata1     (peri_bus_wdata),
        .bus_rdata1     (peri_bus_rdata)
    );

endmodule
