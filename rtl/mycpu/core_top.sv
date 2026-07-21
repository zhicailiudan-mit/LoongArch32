`timescale 1ns / 1ps
`include "defines.vh"

// Official la32r_soc CPU-IP boundary. The legacy mycpu_top remains available
// for the local ThinPad SRAM board; both tops share the same CPU/cache RTL.
module core_top #(
    parameter TLBNUM = 32
)(
    input           aclk,
    input           aresetn,
    input  [7:0]    intrpt,

    output [3:0]    arid,
    output [31:0]   araddr,
    output [7:0]    arlen,
    output [2:0]    arsize,
    output [1:0]    arburst,
    output [1:0]    arlock,
    output [3:0]    arcache,
    output [2:0]    arprot,
    output          arvalid,
    input           arready,
    input  [3:0]    rid,
    input  [31:0]   rdata,
    input  [1:0]    rresp,
    input           rlast,
    input           rvalid,
    output          rready,

    output [3:0]    awid,
    output [31:0]   awaddr,
    output [7:0]    awlen,
    output [2:0]    awsize,
    output [1:0]    awburst,
    output [1:0]    awlock,
    output [3:0]    awcache,
    output [2:0]    awprot,
    output          awvalid,
    input           awready,
    output [3:0]    wid,
    output [31:0]   wdata,
    output [3:0]    wstrb,
    output          wlast,
    output          wvalid,
    input           wready,
    input  [3:0]    bid,
    input  [1:0]    bresp,
    input           bvalid,
    output          bready,

    input           break_point,
    input           infor_flag,
    input  [4:0]    reg_num,
    output          ws_valid,
    output [31:0]   rf_rdata,

    output [31:0]   debug0_wb_pc,
    output [3:0]    debug0_wb_rf_wen,
    output [4:0]    debug0_wb_rf_wnum,
    output [31:0]   debug0_wb_rf_wdata,
    output [31:0]   debug0_wb_inst
);
    wire        cpu2ic_rreq;
    wire        ic2cpu_ready;
    wire [31:0] cpu2ic_addr;
    wire        cpu2ic_cacheable;
    wire        cpu2ic_dual;
    wire        ic2cpu_valid;
    wire [31:0] ic2cpu_inst;
    wire        ic2cpu_valid1;
    wire [31:0] ic2cpu_inst1;
    wire        cpu2ic_pderr;

    wire        dev2ic_rrdy;
    wire [3:0]  ic2dev_ren;
    wire [31:0] ic2dev_raddr;
    wire        dev2ic_rvalid;
    wire [31:0] dev2ic_rdata;

    wire [3:0]  cpu2dc_ren;
    wire [31:0] cpu2dc_addr;
    wire        cpu2dc_cacheable;
    wire        dc2cpu_rready;
    wire        dc2cpu_valid;
    wire [31:0] dc2cpu_rdata;
    wire [3:0]  cpu2dc_wen;
    wire [31:0] cpu2dc_wdata;
    wire        dc2cpu_wready;
    wire        dc2cpu_wposted;
    wire        dc2cpu_wresp;
    wire        dc_line_alloc_valid;
    wire [31:0] dc_line_alloc_addr;
    wire [`CACHE_BLK_SIZE-1:0] dc_line_alloc_data;
    wire [`CACHE_BLK_LEN-1:0] dc_line_alloc_word_mask;

    wire        dev2dc_wrdy;
    wire        dev2dc_wdone;
    wire [3:0]  dc2dev_wen;
    wire [31:0] dc2dev_waddr;
    wire [31:0] dc2dev_wdata;
    wire        dev2dc_rrdy;
    wire [3:0]  dc2dev_ren;
    wire [31:0] dc2dev_raddr;
    wire        dc2dev_rburst;
    wire        dev2dc_rvalid;
    wire [31:0] dev2dc_rdata;

    wire        ic_maint_valid;
    wire        ic_maint_ready;
    wire        ic_maint_done;
    wire        dc_maint_valid;
    wire        dc_maint_ready;
    wire        dc_maint_done;
    wire        cache_maint_all;
    wire [1:0]  cache_maint_mode;
    wire [31:0] cache_maint_addr;
    wire [31:0] cache_maint_ctag;

    MyCpu u_mycpu (
        .cpu_rstn(aresetn),
        .cpu_clk(aclk),
        .ifetch_rreq(cpu2ic_rreq),
        .ifetch_ready(ic2cpu_ready),
        .ifetch_addr(cpu2ic_addr),
        .ifetch_cacheable(cpu2ic_cacheable),
        .ifetch_dual(cpu2ic_dual),
        .ifetch_valid(ic2cpu_valid),
        .ifetch_inst(ic2cpu_inst),
        .ifetch1_valid(ic2cpu_valid1),
        .ifetch1_inst(ic2cpu_inst1),
        .pred_error(cpu2ic_pderr),
        .daccess_ren(cpu2dc_ren),
        .daccess_addr(cpu2dc_addr),
        .daccess_cacheable(cpu2dc_cacheable),
        .daccess_rready(dc2cpu_rready),
        .daccess_valid(dc2cpu_valid),
        .daccess_rdata(dc2cpu_rdata),
        .daccess_wen(cpu2dc_wen),
        .daccess_wdata(cpu2dc_wdata),
        .daccess_wready(dc2cpu_wready),
        .daccess_wposted(dc2cpu_wposted),
        .daccess_wresp(dc2cpu_wresp),
        .daccess_line_alloc_valid(dc_line_alloc_valid),
        .daccess_line_alloc_addr(dc_line_alloc_addr),
        .daccess_line_alloc_data(dc_line_alloc_data),
        .daccess_line_alloc_word_mask(dc_line_alloc_word_mask),
        .daccess_line_alloc_ready(1'b0),
        .icache_maint_valid(ic_maint_valid),
        .icache_maint_ready(ic_maint_ready),
        .icache_maint_done(ic_maint_done),
        .dcache_maint_valid(dc_maint_valid),
        .dcache_maint_ready(dc_maint_ready),
        .dcache_maint_done(dc_maint_done),
        .cache_maint_all(cache_maint_all),
        .cache_maint_mode(cache_maint_mode),
        .cache_maint_addr(cache_maint_addr),
        .cache_maint_ctag(cache_maint_ctag),
        .debug0_wb_pc(debug0_wb_pc),
        .debug0_wb_rf_wen(debug0_wb_rf_wen),
        .debug0_wb_rf_wnum(debug0_wb_rf_wnum),
        .debug0_wb_rf_wdata(debug0_wb_rf_wdata),
        .debug0_wb_inst(debug0_wb_inst)
    );

    ICache u_icache (
        .cpu_rstn(aresetn), .cpu_clk(aclk),
        .inst_rreq(cpu2ic_rreq), .inst_ready(ic2cpu_ready),
        .inst_addr(cpu2ic_addr), .inst_cacheable(cpu2ic_cacheable),
        .inst_dual(cpu2ic_dual), .inst_valid(ic2cpu_valid),
        .inst_out(ic2cpu_inst), .inst1_valid(ic2cpu_valid1),
        .inst1_out(ic2cpu_inst1), .pred_error(cpu2ic_pderr),
        .dev_rrdy(dev2ic_rrdy), .cpu_ren(ic2dev_ren),
        .cpu_raddr(ic2dev_raddr), .dev_rvalid(dev2ic_rvalid),
        .dev_rdata(dev2ic_rdata),
        .maint_valid(ic_maint_valid), .maint_ready(ic_maint_ready),
        .maint_done(ic_maint_done), .maint_all(cache_maint_all),
        .maint_mode(cache_maint_mode), .maint_addr(cache_maint_addr),
        .maint_ctag(cache_maint_ctag)
    );

    DCache u_dcache (
        .cpu_rstn(aresetn), .cpu_clk(aclk),
        .data_ren(cpu2dc_ren), .data_addr(cpu2dc_addr),
        .data_cacheable(cpu2dc_cacheable), .data_rready(dc2cpu_rready),
        .data_valid(dc2cpu_valid), .data_rdata(dc2cpu_rdata),
        .data_wen(cpu2dc_wen), .data_wdata(cpu2dc_wdata),
        .data_wready(dc2cpu_wready), .data_wposted(dc2cpu_wposted),
        .data_wresp(dc2cpu_wresp),
        .line_alloc_valid(1'b0),
        .line_alloc_addr(32'h0),
        .line_alloc_data(0),
        .line_alloc_word_mask(0),
        .line_alloc_ready(),
        .dev_wdone(dev2dc_wdone),
        .dev_wrdy(dev2dc_wrdy), .cpu_wen(dc2dev_wen),
        .cpu_waddr(dc2dev_waddr), .cpu_wdata(dc2dev_wdata),
        .dev_rrdy(dev2dc_rrdy), .cpu_ren(dc2dev_ren),
        .cpu_raddr(dc2dev_raddr), .cpu_rburst(dc2dev_rburst),
        .dev_rvalid(dev2dc_rvalid), .dev_rdata(dev2dc_rdata),
        .maint_valid(dc_maint_valid), .maint_ready(dc_maint_ready),
        .maint_done(dc_maint_done), .maint_all(cache_maint_all),
        .maint_mode(cache_maint_mode), .maint_addr(cache_maint_addr),
        .maint_ctag(cache_maint_ctag)
    );

    AxiCacheBridge u_axi_cache_bridge (
        .aclk(aclk), .aresetn(aresetn),
        .ic_dev_rrdy(dev2ic_rrdy), .ic_cpu_ren(|ic2dev_ren),
        .ic_cpu_raddr(ic2dev_raddr), .ic_dev_rvalid(dev2ic_rvalid),
        .ic_dev_rdata(dev2ic_rdata),
        .dc_dev_rrdy(dev2dc_rrdy), .dc_cpu_ren(dc2dev_ren),
        .dc_cpu_raddr(dc2dev_raddr), .dc_cpu_rburst(dc2dev_rburst),
        .dc_dev_rvalid(dev2dc_rvalid), .dc_dev_rdata(dev2dc_rdata),
        .dc_dev_wrdy(dev2dc_wrdy), .dc_dev_wdone(dev2dc_wdone),
        .dc_cpu_wen(dc2dev_wen),
        .dc_cpu_waddr(dc2dev_waddr), .dc_cpu_wdata(dc2dev_wdata),
        .arid(arid), .araddr(araddr), .arlen(arlen), .arsize(arsize),
        .arburst(arburst), .arlock(arlock), .arcache(arcache),
        .arprot(arprot), .arvalid(arvalid), .arready(arready),
        .rid(rid), .rdata(rdata), .rresp(rresp), .rlast(rlast),
        .rvalid(rvalid), .rready(rready),
        .awid(awid), .awaddr(awaddr), .awlen(awlen), .awsize(awsize),
        .awburst(awburst), .awlock(awlock), .awcache(awcache),
        .awprot(awprot), .awvalid(awvalid), .awready(awready),
        .wid(wid), .wdata(wdata), .wstrb(wstrb), .wlast(wlast),
        .wvalid(wvalid), .wready(wready), .bid(bid), .bresp(bresp),
        .bvalid(bvalid), .bready(bready)
    );

    assign ws_valid = 1'b0;
    assign rf_rdata = 32'h0000_0000;
    wire unused_official_inputs = ^{TLBNUM, intrpt, break_point,
                                    infor_flag, reg_num};
endmodule
