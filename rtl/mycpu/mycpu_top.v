`timescale 1ns / 1ps
`include "defines.vh"

module mycpu_top(
    input  wire        cpu_rstn,
    input  wire        cpu_clk,
    input  wire        sram_rstn,
    input  wire        sram_uclk,

    // BaseRAM bus
    output wire        base_sram_bus_en   ,
    output wire [31:0] base_sram_bus_addr ,
    output wire [ 3:0] base_sram_bus_we   ,
    output wire [31:0] base_sram_bus_wdata,
    input  wire [31:0] base_sram_bus_rdata,
    // ExtRAM bus
    output wire        ext_sram_bus_en    ,
    output wire [31:0] ext_sram_bus_addr  ,
    output wire [ 3:0] ext_sram_bus_we    ,
    output wire [31:0] ext_sram_bus_wdata ,
    input  wire [31:0] ext_sram_bus_rdata ,
    
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
    wire [ 2:0] cpu2dc_load_tid;
    wire        dc2cpu_rready;
    wire        dc2cpu_valid ;
    wire [31:0] dc2cpu_rdata ;
    wire [ 2:0] dc2cpu_response_tid;
    wire [ 3:0] cpu2dc_wen   ;
    wire [31:0] cpu2dc_wdata ;
    wire        dc2cpu_wready;
    wire        dc2cpu_wposted;
    wire        dc2cpu_wresp ;

    wire        dev2dc_wrdy  ;
    wire        dev2dc_wdone ;
    wire        dev2dc_widle ;
    wire [ 3:0] dc2dev_wen   ;
    wire [31:0] dc2dev_waddr ;
    wire [31:0] dc2dev_wdata ;
    wire        dc2dev_wcacheable;
    wire        dev2dc_rrdy  ;
    wire [ 3:0] dc2dev_ren   ;
    wire [31:0] dc2dev_raddr ;
    wire        dc2dev_rburst;
    wire        dev2dc_rvalid;
    wire [31:0] dev2dc_rdata ;
    wire        dev2dc_rrdy1;
    wire [ 3:0] dc2dev_ren1;
    wire [31:0] dc2dev_raddr1;
    wire        dc2dev_rburst1;
    wire        dev2dc_rvalid1;
    wire [31:0] dev2dc_rdata1;

    // TaggedDCache refill lanes terminate at the simulation-tree L2.  The
    // existing dc2dev_* / dev2dc_* signals remain the L2-to-SRAM bridge
    // interface, preserving the dual BaseRAM/ExtRAM arbitration below.
    wire [ 3:0] dc2l2_ren0;
    wire [31:0] dc2l2_raddr0;
    wire        dc2l2_rburst0;
    wire        l2_to_dcache_rrdy0;
    wire        l2_to_dcache_rvalid0;
    wire [31:0] l2_to_dcache_rdata0;
    wire [ 3:0] dc2l2_ren1;
    wire [31:0] dc2l2_raddr1;
    wire        dc2l2_rburst1;
    wire        l2_to_dcache_rrdy1;
    wire        l2_to_dcache_rvalid1;
    wire [31:0] l2_to_dcache_rdata1;

    wire        ic_maint_valid, ic_maint_ready, ic_maint_done;
    wire        dc_maint_valid, dc_maint_ready, dc_maint_done_core;
    wire        dc_maint_done;
    wire        l2_store_wrdy, l2_store_wdone, l2_store_widle;
    wire [ 3:0] l2_to_sram_wen;
    wire [31:0] l2_to_sram_waddr;
    wire [31:0] l2_to_sram_wdata;
    wire        l2_maint_done;
    assign dc_maint_done = dc_maint_done_core && l2_maint_done;
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
        .daccess_load_tid(cpu2dc_load_tid),
        .daccess_rready (dc2cpu_rready),
        .daccess_valid  (dc2cpu_valid),
        .daccess_rdata  (dc2cpu_rdata),
        .daccess_response_tid(dc2cpu_response_tid),
        .daccess_wen    (cpu2dc_wen  ),
        .daccess_wdata  (cpu2dc_wdata),
        .daccess_wready (dc2cpu_wready),
        .daccess_wposted(dc2cpu_wposted),
        .daccess_wresp  (dc2cpu_wresp),
        .daccess_line_alloc_valid(),
        .daccess_line_alloc_addr(),
        .daccess_line_alloc_data(),
        .daccess_line_alloc_word_mask(),
        .daccess_line_alloc_ready(1'b0),
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

    TaggedDCache u_dcache (
        .cpu_rstn       (cpu_rstn     ),
        .cpu_clk        (cpu_clk      ),
        // Interface to CPU
        .data_ren       (cpu2dc_ren   ),
        .data_addr      (cpu2dc_addr  ),
        .data_cacheable (cpu2dc_cacheable),
        .data_rtid      (cpu2dc_load_tid),
        .data_rready    (dc2cpu_rready),
        .data_valid     (dc2cpu_valid ),
        .data_rdata     (dc2cpu_rdata ),
        .data_rtid_out  (dc2cpu_response_tid),
        .data_wen       (cpu2dc_wen   ),
        .data_wdata     (cpu2dc_wdata ),
        .data_wready    (dc2cpu_wready),
        .data_wposted   (dc2cpu_wposted),
        .data_wresp     (dc2cpu_wresp ),
        // Full-line allocation is intentionally disabled.  Keep the legacy
        // DCache sideband tied off instead of allowing a partial handshake.
        .line_alloc_valid(1'b0),
        .line_alloc_addr(32'h00000000),
        .line_alloc_data(256'd0),
        .line_alloc_word_mask(8'd0),
        .line_alloc_ready(),
        // Interface to Bus
        .dev_wrdy       (l2_store_wrdy),
        .dev_wdone      (l2_store_wdone),
        .dev_widle      (l2_store_widle),
        .cpu_wen        (dc2dev_wen   ),
        .cpu_waddr      (dc2dev_waddr ),
        .cpu_wdata      (dc2dev_wdata ),
        .cpu_wcacheable (dc2dev_wcacheable),
        .dev_rrdy       (l2_to_dcache_rrdy0),
        .cpu_ren        (dc2l2_ren0   ),
        .cpu_raddr      (dc2l2_raddr0 ),
        .cpu_rburst     (dc2l2_rburst0),
        .dev_rvalid     (l2_to_dcache_rvalid0),
        .dev_rdata      (l2_to_dcache_rdata0 ),
        .dev_rrdy1      (l2_to_dcache_rrdy1 ),
        .cpu_ren1       (dc2l2_ren1  ),
        .cpu_raddr1     (dc2l2_raddr1),
        .cpu_rburst1    (dc2l2_rburst1),
        .dev_rvalid1    (l2_to_dcache_rvalid1),
        .dev_rdata1     (l2_to_dcache_rdata1),
        .maint_valid    (dc_maint_valid),
        .maint_ready    (dc_maint_ready),
        .maint_done     (dc_maint_done_core),
        .maint_all      (cache_maint_all),
        .maint_mode     (cache_maint_mode),
        .maint_addr     (cache_maint_addr),
        .maint_ctag     (cache_maint_ctag)
    );

    // 32 KiB BRAM-native validation L2 (512 sets, 2 ways, 32-byte lines).
    // It owns both refill lanes and the DCache Store completion path between
    // TaggedDCache and the SRAM bridge.  Keep the legacy L2DCache module in
    // L2DCache.v as a one-line rollback target for simulation.
    L2DCacheBram64 #(.SET_COUNT(512)) u_l2_dcache (
        .cpu_rstn        (cpu_rstn),
        .cpu_clk        (cpu_clk),
        // Upper lane 0: TaggedDCache
        .up0_cpu_ren    (dc2l2_ren0),
        .up0_cpu_raddr  (dc2l2_raddr0),
        .up0_cpu_rburst (dc2l2_rburst0),
        .up0_dev_rrdy   (l2_to_dcache_rrdy0),
        .up0_dev_rvalid (l2_to_dcache_rvalid0),
        .up0_dev_rdata  (l2_to_dcache_rdata0),
        // Upper lane 1: TaggedDCache
        .up1_cpu_ren    (dc2l2_ren1),
        .up1_cpu_raddr  (dc2l2_raddr1),
        .up1_cpu_rburst (dc2l2_rburst1),
        .up1_dev_rrdy   (l2_to_dcache_rrdy1),
        .up1_dev_rvalid (l2_to_dcache_rvalid1),
        .up1_dev_rdata  (l2_to_dcache_rdata1),
        // Lower lane 0: SRAM bridge
        .mem0_cpu_ren    (dc2dev_ren),
        .mem0_cpu_raddr  (dc2dev_raddr),
        .mem0_cpu_rburst (dc2dev_rburst),
        .mem0_dev_rrdy   (dev2dc_rrdy),
        .mem0_dev_rvalid (dev2dc_rvalid),
        .mem0_dev_rdata  (dev2dc_rdata),
        // Lower lane 1: SRAM bridge
        .mem1_cpu_ren    (dc2dev_ren1),
        .mem1_cpu_raddr  (dc2dev_raddr1),
        .mem1_cpu_rburst (dc2dev_rburst1),
        .mem1_dev_rrdy   (dev2dc_rrdy1),
        .mem1_dev_rvalid (dev2dc_rvalid1),
        .mem1_dev_rdata  (dev2dc_rdata1),
        // Upper Store path: DCache WCB -> L2 line merge / bypass.
        .up_store_wen    (dc2dev_wen),
        .up_store_addr   (dc2dev_waddr),
        .up_store_wdata  (dc2dev_wdata),
        .up_store_cacheable(dc2dev_wcacheable),
        .up_store_wrdy   (l2_store_wrdy),
        .up_store_wdone  (l2_store_wdone),
        .up_store_widle  (l2_store_widle),
        // Lower Store path: L2 WBB/SBUF -> original SRAM write bridge.
        .mem_store_wen   (l2_to_sram_wen),
        .mem_store_addr  (l2_to_sram_waddr),
        .mem_store_wdata (l2_to_sram_wdata),
        .mem_store_wrdy  (dev2dc_wrdy),
        .mem_store_wdone (dev2dc_wdone),
        .mem_store_widle (dev2dc_widle),
        .invalidate_all  (dc_maint_valid),
        .maint_done      (l2_maint_done)
    );

    sram_bus_master u_sram_bus (
        .cpu_rstn       (cpu_rstn      ),
        .cpu_clk        (cpu_clk       ),
        .sram_rstn      (sram_rstn     ),
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
        .dc_dev_widle   (dev2dc_widle  ),
        .dc_cpu_wen     (l2_to_sram_wen),
        .dc_cpu_waddr   (l2_to_sram_waddr),
        .dc_cpu_wdata   (l2_to_sram_wdata),
        .dc_dev_rrdy    (dev2dc_rrdy   ),
        .dc_cpu_ren     (dc2dev_ren    ),
        .dc_cpu_raddr   (dc2dev_raddr  ),
        .dc_cpu_rburst  (dc2dev_rburst ),
        .dc_dev_rvalid  (dev2dc_rvalid ),
        .dc_dev_rdata   (dev2dc_rdata  ),
        .dc_dev_rrdy1   (dev2dc_rrdy1  ),
        .dc_cpu_ren1    (dc2dev_ren1   ),
        .dc_cpu_raddr1  (dc2dev_raddr1 ),
        .dc_cpu_rburst1 (dc2dev_rburst1),
        .dc_dev_rvalid1 (dev2dc_rvalid1),
        .dc_dev_rdata1  (dev2dc_rdata1 ),
        // BaseRAM bus
        .bus_en_base    (base_sram_bus_en   ),
        .bus_addr_base  (base_sram_bus_addr ),
        .bus_we_base    (base_sram_bus_we   ),
        .bus_wdata_base (base_sram_bus_wdata),
        .bus_rdata_base (base_sram_bus_rdata),
        // ExtRAM bus
        .bus_en_ext     (ext_sram_bus_en    ),
        .bus_addr_ext   (ext_sram_bus_addr  ),
        .bus_we_ext     (ext_sram_bus_we    ),
        .bus_wdata_ext  (ext_sram_bus_wdata ),
        .bus_rdata_ext  (ext_sram_bus_rdata ),
        // SRAM-BUS Interface 1 (Peripheral)
        .bus_en1        (peri_bus_en   ),
        .bus_addr1      (peri_bus_addr ),
        .bus_we1        (peri_bus_we   ),
        .bus_wdata1     (peri_bus_wdata),
        .bus_rdata1     (peri_bus_rdata)
    );

endmodule
