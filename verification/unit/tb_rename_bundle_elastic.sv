`timescale 1ns / 1ps

`include "defines.vh"
import cpu_types_pkg::*;

module tb_rename_bundle_elastic;
    logic clk = 0;
    logic rstn = 0;
    logic flush = 0;
    logic in_valid0, in_valid1, in_ready;
    logic out_valid0, out_valid1;
    logic [1:0] out_pop_count, occupancy;
    decoded_uop_t in_uop0, in_uop1, out_uop0, out_uop1;
    commit_t commit0, commit1;

    always #5 clk = ~clk;

    RenameBundle dut (
        .clk, .rstn, .flush,
        .in_valid0, .in_valid1, .in_ready, .in_uop0, .in_uop1,
        .out_valid0, .out_valid1, .out_pop_count,
        .out_uop0, .out_uop1, .occupancy, .commit0, .commit1
    );

    function automatic decoded_uop_t make_uop(input logic [31:0] pc);
        decoded_uop_t u;
        begin
            u = '0;
            u.pc = pc;
            u.src0.used = 1'b1;
            u.src0.arch_reg = pc[4:0];
            u.src0.value = pc ^ 32'h55aa_55aa;
            make_uop = u;
        end
    endfunction

    task automatic drive_input(input logic v0, input logic v1,
                               input logic [31:0] pc0,
                               input logic [31:0] pc1,
                               input logic [1:0] pops);
        begin
            @(negedge clk);
            in_valid0 = v0;
            in_valid1 = v1;
            in_uop0 = make_uop(pc0);
            in_uop1 = make_uop(pc1);
            out_pop_count = pops;
            @(posedge clk); #1;
            in_valid0 = 0;
            in_valid1 = 0;
            out_pop_count = 0;
        end
    endtask

    task automatic check_state(input logic [1:0] expected_count,
                               input logic [31:0] expected_pc0,
                               input logic [31:0] expected_pc1);
        begin
            if (occupancy !== expected_count)
                $fatal(1, "occupancy expected=%0d actual=%0d",
                       expected_count, occupancy);
            if ((expected_count != 0) && (out_uop0.pc !== expected_pc0))
                $fatal(1, "oldest PC expected=%h actual=%h",
                       expected_pc0, out_uop0.pc);
            if ((expected_count == 2) && (out_uop1.pc !== expected_pc1))
                $fatal(1, "youngest PC expected=%h actual=%h",
                       expected_pc1, out_uop1.pc);
            if (out_valid0 !== (expected_count != 0) ||
                out_valid1 !== (expected_count == 2))
                $fatal(1, "valid vector does not match occupancy");
        end
    endtask

    initial begin
        in_valid0 = 0;
        in_valid1 = 0;
        in_uop0 = '0;
        in_uop1 = '0;
        out_pop_count = 0;
        commit0 = '0;
        commit1 = '0;
        repeat (3) @(posedge clk);
        rstn = 1;

        // Fill both slots in program order.
        drive_input(1, 1, 32'h1000, 32'h1004, 0);
        check_state(2, 32'h1000, 32'h1004);

        // Partial dispatch plus one-uop refill: B survives before C.
        drive_input(1, 0, 32'h1008, 0, 1);
        check_state(2, 32'h1004, 32'h1008);

        // Full stall must preserve both payloads.
        repeat (3) begin
            drive_input(0, 0, 0, 0, 0);
            check_state(2, 32'h1004, 32'h1008);
        end

        // Pop both and refill both on the same edge.
        drive_input(1, 1, 32'h100c, 32'h1010, 2);
        check_state(2, 32'h100c, 32'h1010);

        // Leave one survivor, then fill the single free slot.
        drive_input(0, 0, 0, 0, 1);
        check_state(1, 32'h1010, 0);
        if (!in_ready) $fatal(1, "one free slot did not accept one uop");
        drive_input(1, 0, 32'h1014, 0, 0);
        check_state(2, 32'h1010, 32'h1014);

        // Flush discards both unallocated entries.
        @(negedge clk); flush = 1;
        @(posedge clk); #1; flush = 0;
        check_state(0, 0, 0);

        $display("[UNIT-PASS] RenameBundle elastic partial-dispatch transitions passed");
        $finish;
    end
endmodule
