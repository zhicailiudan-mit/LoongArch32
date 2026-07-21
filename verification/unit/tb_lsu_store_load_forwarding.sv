`timescale 1ns/1ps
`include "defines.vh"
import cpu_types_pkg::*;

// Regression for the two ordering cases that previously caused a permanent
// LSU wait: an older store held by write backpressure, and a younger store
// at the same address.  This test intentionally keeps wready low throughout.
module tb_lsu_store_load_forwarding;
    logic clk, rstn, flush, branch_flush;
    logic recover_valid, system_flush;
    uop_id_t recover_id;
    execute_result_t execute_result, execute_result1;
    commit_t commit0, commit1;
    logic ldst_suspend, ldst1_suspend;
    completion_t main_completion, lane1_completion;
    memory_request_t dcache_req;
    memory_response_t dcache_rsp;
    logic read_pending;
    integer failures, read_request_count, before_forward_reads;

    LoadStoreUnit dut (
        .cpu_rstn(rstn), .cpu_clk(clk), .flush(flush),
        .branch_flush(branch_flush), .recover_valid(recover_valid),
        .system_flush(system_flush), .recover_id(recover_id),
        .execute_result(execute_result), .execute_result1(execute_result1),
        .commit0(commit0), .commit1(commit1),
        .ldst_suspend(ldst_suspend), .ldst1_suspend(ldst1_suspend),
        .main_completion(main_completion), .lane1_completion(lane1_completion),
        .dcache_req(dcache_req), .dcache_rsp(dcache_rsp)
    );

    initial begin clk = 1'b0; forever #5 clk = ~clk; end

    always @(negedge clk) begin
        dcache_rsp.rready  = 1'b1;
        dcache_rsp.wready  = 1'b0;
        dcache_rsp.wposted = 1'b0;
        dcache_rsp.wresp   = 1'b0;
        dcache_rsp.valid   = read_pending;
        dcache_rsp.rdata   = 32'haabb_ccdd;
        if (dcache_req.ren != 4'b0)
            read_request_count = read_request_count + 1;
        read_pending       = (dcache_req.ren != 4'b0);
    end

    task automatic clear_inputs;
        begin
            execute_result = '0;
            execute_result1 = '0;
            commit0 = '0;
            commit1 = '0;
            flush = 1'b0;
            branch_flush = 1'b0;
            recover_valid = 1'b0;
            system_flush = 1'b0;
            recover_id = '0;
        end
    endtask

    task automatic issue_store(input logic [3:0] tag, input logic [31:0] addr,
                               input logic [31:0] data, input logic [3:0] mask);
        begin
            @(negedge clk);
            execute_result = '0;
            execute_result.valid = 1'b1;
            execute_result.uop_id.epoch = 2'd0;
            execute_result.uop_id.rob_tag = tag;
            execute_result.pc = 32'h1c000000 + {24'b0, tag, 2'b00};
            execute_result.src1_value = data;
            execute_result.alu_result = addr;
            execute_result.store_mask = mask;
            execute_result.is_ld_st = 1'b1;
            @(negedge clk);
            execute_result = '0;
        end
    endtask

    task automatic commit_store(input logic [3:0] tag);
        begin
            @(negedge clk);
            commit0 = '0;
            commit0.valid = 1'b1;
            commit0.uop_id.epoch = 2'd0;
            commit0.uop_id.rob_tag = tag;
            @(negedge clk);
            commit0 = '0;
        end
    endtask

    task automatic commit_two_stores(input logic [3:0] older_tag,
                                     input logic [3:0] younger_tag);
        begin
            @(negedge clk);
            commit0 = '0;
            commit1 = '0;
            commit0.valid = 1'b1;
            commit0.uop_id.epoch = 2'd0;
            commit0.uop_id.rob_tag = older_tag;
            commit1.valid = 1'b1;
            commit1.uop_id.epoch = 2'd0;
            commit1.uop_id.rob_tag = younger_tag;
            @(negedge clk);
            commit0 = '0;
            commit1 = '0;
        end
    endtask

    task automatic issue_load(input logic [3:0] tag, input logic [31:0] addr,
                              input logic [2:0] ext_op);
        begin
            @(negedge clk);
            execute_result = '0;
            execute_result.valid = 1'b1;
            execute_result.uop_id.epoch = 2'd0;
            execute_result.uop_id.rob_tag = tag;
            execute_result.pc = 32'h1c000100 + {24'b0, tag, 2'b00};
            execute_result.alu_result = addr;
            execute_result.store_mask = `RAM_WE_N;
            execute_result.load_ext_op = ext_op;
            execute_result.reg_write = 1'b1;
            execute_result.arch_rd = 5'd16;
            execute_result.is_ld_st = 1'b1;
            @(negedge clk);
            execute_result = '0;
        end
    endtask

    task automatic expect_completion(input logic [3:0] tag,
                                     input logic [31:0] value,
                                     input integer max_cycles);
        integer n;
        logic found;
        begin
            found = 1'b0;
            for (n = 0; n < max_cycles; n = n + 1) begin
                @(negedge clk);
                if (main_completion.valid &&
                    (main_completion.uop_id.rob_tag == tag)) begin
                    found = 1'b1;
                    if (main_completion.value !== value) begin
                        $display("[LSU-FWD-FAIL] tag=%0d got=%h expected=%h", tag,
                                 main_completion.value, value);
                        failures = failures + 1;
                    end
                end
            end
            if (!found) begin
                $display("[LSU-FWD-FAIL] no completion for tag=%0d", tag);
                failures = failures + 1;
            end
        end
    endtask

    initial begin
        failures = 0;
        read_request_count = 0;
        read_pending = 1'b0;
        dcache_rsp = '0;
        clear_inputs();
        rstn = 1'b0;
        repeat (3) @(posedge clk);
        rstn = 1'b1;

        // Store remains in StoreBuffer because wready stays low.  ld.b at
        // byte 1 must complete from 32'h11223344, returning 32'h33.
        issue_store(4'd1, 32'h00000100, 32'h11223344, `RAM_WE_W);
        commit_store(4'd1);
        repeat (3) @(negedge clk);
        if (dut.u_store_buffer.count != 1) begin
            $display("[LSU-FWD-FAIL] committed store did not reach StoreBuffer");
            failures = failures + 1;
        end
        before_forward_reads = read_request_count;
        issue_load(4'd2, 32'h00000101, `RAM_EXT_B_Z);
        expect_completion(4'd2, 32'h00000033, 6);
        if (read_request_count != before_forward_reads) begin
            $display("[LSU-FWD-FAIL] forwarded byte load issued DCache read");
            failures = failures + 1;
        end

        // A later byte store merges into the buffered word.  The byte-age
        // metadata must follow that merge, so tag 4 observes 8'haa rather
        // than the older 8'h33 in the same lane.
        issue_store(4'd3, 32'h00000101, 32'h000000aa, `RAM_WE_B);
        commit_store(4'd3);
        repeat (3) @(negedge clk);
        if (dut.u_store_buffer.count != 1) begin
            $display("[LSU-FWD-FAIL] same-word stores did not merge in StoreBuffer count=%0d tail=%h e0=%h e1=%h",
                     dut.u_store_buffer.count, dut.u_store_buffer.tail_address,
                     dut.u_store_buffer.entry_addr[0], dut.u_store_buffer.entry_addr[1]);
            failures = failures + 1;
        end
        issue_load(4'd4, 32'h00000101, `RAM_EXT_B_Z);
        expect_completion(4'd4, 32'h000000aa, 6);

        // The tag-6 store is younger than tag-5.  It must not create an
        // address dependency; tag-5 therefore reads the DCache response.
        issue_store(4'd6, 32'h00000200, 32'hdeadbeef, `RAM_WE_W);
        issue_load(4'd5, 32'h00000200, `RAM_EXT_N);
        expect_completion(4'd5, 32'haabbccdd, 8);
        commit_store(4'd6);
        repeat (3) @(negedge clk);

        // Execute the younger store first, then commit both stores in ROB
        // order.  StoreBuffer must receive tag 7 before tag 8 regardless of
        // their execution/StoreQueue insertion order.
        issue_store(4'd8, 32'h00000304, 32'h22222222, `RAM_WE_W);
        issue_store(4'd7, 32'h00000300, 32'h11111111, `RAM_WE_W);
        commit_two_stores(4'd7, 4'd8);
        repeat (4) @(negedge clk);
        if ((dut.u_store_buffer.count != 4) ||
            (dut.u_store_buffer.entries[2].uop_id.rob_tag != 4'd7) ||
            (dut.u_store_buffer.entries[3].uop_id.rob_tag != 4'd8)) begin
            $display("[LSU-FWD-FAIL] StoreQueue release order sb=%0d tags=%0d,%0d",
                     dut.u_store_buffer.count,
                     dut.u_store_buffer.entries[2].uop_id.rob_tag,
                     dut.u_store_buffer.entries[3].uop_id.rob_tag);
            failures = failures + 1;
        end

        if (failures == 0)
            $display("[LSU-FWD-PASS] store/load forwarding and age filtering passed");
        else
            $fatal(1, "[LSU-FWD] failures=%0d", failures);
        $finish;
    end
endmodule
