//*************************************************************************
//   > File Name   : soc_lite_top.v
//   > Description : SoC, include CPU, BUS, SRAM, confreg
//   > Architecture: 
//           ------------------------
//           |         myCPU        |
//           ------------------------
//              |                 | 
//        ------------      ------------
//        |  ICache  |      |  DCache  |
//        ------------      ------------
//              | read            | read/write
//              |                 | 
//        ------------------------------
//        |           SRAM BUS         |
//        ------------------------------
//           | interface0           | interface1
//           |                      | 
//   ----------------------    -------------
//   | SRAM (inst & data) |    |  confreg  |
//   ----------------------    -------------
//
//*************************************************************************

// This file owns the simulation-only clocks below.  Give their delay
// expressions an explicit file-local scale; Vivado accepts this Verilog
// directive in both .v and .sv sources, whereas a compilation-unit timeunit
// declaration is rejected for this top-level source.
`timescale 1ns / 1ps
`include "mycpu_inst.vh"
`include "C:/Users/wanlinc/Desktop/Me/Loogn cpu v1/func_test/soc_verify/test_profile.vh"
`default_nettype none

//for simulation:
//1. if define SIMU_USE_PLL = 1, will use clk_pll to generate cpu_clk/timer_clk,
//   and simulation will be very slow.
//2. usually, please define SIMU_USE_PLL=0 to speed up simulation by assign
//   cpu_clk/timer_clk = clk.
//   at this time, cpu_clk/timer_clk frequency are both 100MHz, same as clk.
`define SIMU_USE_PLL 0 //set 0 to speed up simulation


module soc_lite_top #(parameter SIMULATION=1'b0)
(
    input  wire        resetn, 
    input  wire        clk,

    //------BaseRAM / ExtRAM-------
    output wire [19:0]  base_sram_addr,
    inout  wire [31:0]  base_sram_data,
    output wire         base_sram_oen,
    output wire         base_sram_cen,
    output wire         base_sram_wen,
    output wire [ 3:0]  base_sram_ben,
    output wire [19:0]  ext_sram_addr,
    inout  wire [31:0]  ext_sram_data,
    output wire         ext_sram_oen,
    output wire         ext_sram_cen,
    output wire         ext_sram_wen,
    output wire [ 3:0]  ext_sram_ben,

    //------gpio-------
    output wire [15:0] led,
    output wire [1 :0] led_rg0,
    output wire [1 :0] led_rg1,
    output wire [7 :0] num_csn,
    output wire [6 :0] num_a_g,
    output wire [31:0] num_data,
    input  wire [7 :0] switch, 
    output wire [3 :0] btn_key_col,
    input  wire [3 :0] btn_key_row,
    input  wire [1 :0] btn_step
);

    //clk and resetn
    wire cpu_clk;
    wire timer_clk;
    wire sram_uclk, sram_wclk;
    generate
        if (SIMULATION && `SIMU_USE_PLL==0) begin: speedup_simulation
            // 200 MHz CPU: 5 ns period; 70 MHz SRAM: 14.286 ns period.
            // Express these in ps so they stay non-zero for every supported
            // compile-unit time scale and remain independent of `real`
            // rounding rules in XSim.
            localparam time DUT_CPU_HALF_CYCLE  = 2500ps;
            localparam time DUT_SRAM_HALF_CYCLE = 7143ps;
            localparam time SRAM_WRITE_PHASE    = 3571ps;

            reg sim_cpu_clk = 0, sim_sram_uclk = 0, sim_sram_wclk = 0;
            always #DUT_CPU_HALF_CYCLE  sim_cpu_clk   = !sim_cpu_clk;
            always #DUT_SRAM_HALF_CYCLE sim_sram_uclk = !sim_sram_uclk;
            initial #SRAM_WRITE_PHASE forever #DUT_SRAM_HALF_CYCLE
                sim_sram_wclk = !sim_sram_wclk;
            // assign cpu_clk   = clk;
            assign timer_clk = clk;
            assign cpu_clk   = sim_cpu_clk;
            assign sram_uclk = sim_sram_uclk;
            assign sram_wclk = sim_sram_wclk;
        end else begin: pll
            clk_pll clk_pll(
                .clk_in1    (clk),
                .cpu_clk    (cpu_clk),
                .timer_clk  (timer_clk),
                .clk_out3   (sram_uclk),
                .clk_out4   (sram_wclk)
            );
        end
    endgenerate

    // SRAM
    wire        base_sram_bus_en;
    wire [31:0] base_sram_bus_addr;
    wire [ 3:0] base_sram_bus_we;
    wire [31:0] base_sram_bus_wdata;
    wire [31:0] base_sram_bus_rdata;
    wire        ext_sram_bus_en;
    wire [31:0] ext_sram_bus_addr;
    wire [ 3:0] ext_sram_bus_we;
    wire [31:0] ext_sram_bus_wdata;
    wire [31:0] ext_sram_bus_rdata;
    // Peripheral
    wire        peri_bus_en;
    wire [31:0] peri_bus_addr;
    wire [ 3:0] peri_bus_we;
    wire [31:0] peri_bus_wdata;
    wire [31:0] peri_bus_rdata;
    wire [31:0] confreg_bus_rdata;
    wire        cpu_rstn;
    wire        sram_rstn;

    // The simulation top has no physical UART pins.  Keep the original
    // confreg-based monitor path, but translate the required physical UART
    // DATA write to the confreg virtual-UART register and answer STATUS reads
    // with TX_READY.  This preserves the original mycpu_tb monitor while the
    // submitted/board top uses the real UART implementation.
    function automatic is_sim_uart_data_addr;
        input [31:0] addr;
        begin
            is_sim_uart_data_addr = (addr == 32'h1f00_0000) ||
                                    (addr == 32'hbf00_0000) ||
                                    (addr == 32'hbfd0_03f8);
        end
    endfunction

    function automatic is_sim_uart_status_addr;
        input [31:0] addr;
        begin
            is_sim_uart_status_addr = (addr == 32'h1f00_0005) ||
                                      (addr == 32'hbf00_0005) ||
                                      (addr == 32'hbfd0_03fc);
        end
    endfunction

    function automatic is_sim_uart_window_addr;
        input [31:0] addr;
        begin
            is_sim_uart_window_addr =
                ((addr >= 32'h1f00_0000) && (addr <= 32'h1f00_0005)) ||
                ((addr >= 32'hbf00_0000) && (addr <= 32'hbf00_0005)) ||
                ((addr >= 32'hbfd0_03f8) && (addr <= 32'hbfd0_03fc));
        end
    endfunction

    wire sim_uart_data_read = peri_bus_en && (peri_bus_we == 4'h0) &&
                               is_sim_uart_data_addr(peri_bus_addr);
    wire sim_uart_data_write = peri_bus_en && (peri_bus_we != 4'h0) &&
                                is_sim_uart_data_addr(peri_bus_addr);
    wire sim_uart_status_read = peri_bus_en && (peri_bus_we == 4'h0) &&
                                 is_sim_uart_status_addr(peri_bus_addr);
    wire confreg_bus_en = peri_bus_en &&
                          !is_sim_uart_window_addr(peri_bus_addr);
    wire [31:0] confreg_bus_addr = sim_uart_data_write ?
                                   32'hbfaf_ff10 : peri_bus_addr;
    reg        sim_uart_read_r;
    reg [31:0] sim_uart_rdata_r;
    always @(posedge cpu_clk or negedge cpu_rstn) begin
        if (!cpu_rstn) begin
            sim_uart_read_r  <= 1'b0;
            sim_uart_rdata_r <= 32'h0000_0000;
        end else begin
            sim_uart_read_r <= sim_uart_data_read || sim_uart_status_read;
            if (sim_uart_status_read)
                sim_uart_rdata_r <= 32'h0000_0020;
            else if (sim_uart_data_read)
                sim_uart_rdata_r <= 32'h0000_0000;
        end
    end

    // Reset assertion is asynchronous, while release is synchronized in
    // each destination clock domain.
    ResetDomainSync u_cpu_reset_sync (
        .clk        (cpu_clk),
        .async_rstn (resetn),
        .sync_rstn  (cpu_rstn)
    );
    ResetDomainSync u_sram_reset_sync (
        .clk        (sram_uclk),
        .async_rstn (resetn),
        .sync_rstn  (sram_rstn)
    );

    wire [4 :0] ram_random_mask;

    // Your CPU
    mycpu_top u_cpu(
        .cpu_rstn       (cpu_rstn      ),   //low active
        .cpu_clk        (cpu_clk       ),
        .sram_rstn      (sram_rstn     ),
        .sram_uclk      (sram_uclk     ),

        // BaseRAM bus
        .base_sram_bus_en    (base_sram_bus_en   ),
        .base_sram_bus_addr  (base_sram_bus_addr ),
        .base_sram_bus_we    (base_sram_bus_we   ),
        .base_sram_bus_wdata (base_sram_bus_wdata),
        .base_sram_bus_rdata (base_sram_bus_rdata),
        // ExtRAM bus
        .ext_sram_bus_en     (ext_sram_bus_en    ),
        .ext_sram_bus_addr   (ext_sram_bus_addr  ),
        .ext_sram_bus_we     (ext_sram_bus_we    ),
        .ext_sram_bus_wdata  (ext_sram_bus_wdata ),
        .ext_sram_bus_rdata  (ext_sram_bus_rdata ),
        
        // BUS Interface 1 (Peripheral)
        .peri_bus_en    (peri_bus_en   ),
        .peri_bus_addr  (peri_bus_addr ),
        .peri_bus_we    (peri_bus_we   ),
        .peri_bus_wdata (peri_bus_wdata),
        .peri_bus_rdata (peri_bus_rdata)
    );

    // BaseRAM and ExtRAM are separate simulation devices, matching the board.
    sram_ctrl #(20) u_base_sram_ctrl (
        .rstn           (sram_rstn     ),
        .usr_clk        (sram_uclk     ),
        .wen_clk        (sram_wclk     ),
        // User Interface
        .usr_en         (base_sram_bus_en   ),
        .usr_addr       (base_sram_bus_addr ),
        .usr_we         (base_sram_bus_we   ),
        .usr_wdata      (base_sram_bus_wdata),
        .usr_rdata      (base_sram_bus_rdata),
        // SRAM Interface
        .sram_addr      (base_sram_addr),
        .sram_data      (base_sram_data),
        .sram_oen       (base_sram_oen ),
        .sram_cen       (base_sram_cen ),
        .sram_wen       (base_sram_wen ),
        .sram_ben       (base_sram_ben )
    );

    sram_ctrl #(20) u_ext_sram_ctrl (
        .rstn           (sram_rstn     ),
        .usr_clk        (sram_uclk     ),
        .wen_clk        (sram_wclk     ),
        .usr_en         (ext_sram_bus_en   ),
        .usr_addr       (ext_sram_bus_addr ),
        .usr_we         (ext_sram_bus_we   ),
        .usr_wdata      (ext_sram_bus_wdata),
        .usr_rdata      (ext_sram_bus_rdata),
        .sram_addr      (ext_sram_addr),
        .sram_data      (ext_sram_data),
        .sram_oen       (ext_sram_oen ),
        .sram_cen       (ext_sram_cen ),
        .sram_wen       (ext_sram_wen ),
        .sram_ben       (ext_sram_ben )
    );

    // Peripheral
    confreg #(.SIMULATION(SIMULATION)) u_confreg (
        .timer_clk   ( timer_clk  ),  // i, 1   
        .aclk        ( cpu_clk    ),  // i, 1   
        .aresetn     ( resetn     ),  // i, 1    

        // SRAM-BUS Interface
        .bus_en      (confreg_bus_en),
        .bus_addr    (confreg_bus_addr),
        .bus_we      (peri_bus_we   ),
        .bus_wdata   (peri_bus_wdata),
        .bus_rdata   (confreg_bus_rdata),

        .ram_random_mask ( ram_random_mask ),
        .led         ( led        ),  // o, 16   
        .led_rg0     ( led_rg0    ),  // o, 2      
        .led_rg1     ( led_rg1    ),  // o, 2      
        .num_csn     ( num_csn    ),  // o, 8      
        .num_a_g     ( num_a_g    ),  // o, 7      
        .num_data    ( num_data   ),  // o, 32
        .switch      ( switch     ),  // i, 8     
        .btn_key_col ( btn_key_col),  // o, 4          
        .btn_key_row ( btn_key_row),  // i, 4           
        .btn_step    ( btn_step   )   // i, 2   
    );

    assign peri_bus_rdata = sim_uart_read_r ? sim_uart_rdata_r : confreg_bus_rdata;

endmodule

