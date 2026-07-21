`timescale 1ns/1ps

`include "defines.vh"
import cpu_types_pkg::*;

module tb_lsu;
    logic clk;
    logic rstn;
    logic flush;
    logic branch_flush;
    execute_result_t execute_result;
    execute_result_t execute_result1;
    commit_t commit0;
    commit_t commit1;
    logic ldst_suspend;
    logic ldst1_suspend;
    completion_t main_completion;
    completion_t lane1_completion;
    memory_request_t dcache_req;
    memory_response_t dcache_rsp;
    integer load_delay;
    integer i;
    bit load_request_seen;
    bit store_request_seen;
    bit completion_seen;
    bit dual_load0_seen;
    bit dual_load1_seen;

    `include "tb_common.svh"

    LoadStoreUnit dut (
        .cpu_rstn       (rstn),
        .cpu_clk       (clk),
        .flush         (flush),
        .branch_flush  (branch_flush),
        .execute_result(execute_result),
        .execute_result1(execute_result1),
        .commit0       (commit0),
        .commit1       (commit1),
        .ldst_suspend  (ldst_suspend),
        .ldst1_suspend (ldst1_suspend),
        .main_completion(main_completion),
        .lane1_completion(lane1_completion),
        .dcache_req    (dcache_req),
        .dcache_rsp    (dcache_rsp)
    );

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    // Small deterministic DCache-side BFM.  A load response is delayed by
    // two cycles; stores are posted immediately once the request is visible.
    always @(negedge clk) begin
        dcache_rsp.rready = 1'b1;
        dcache_rsp.wready = 1'b1;
        dcache_rsp.wposted = (dcache_req.wen != `RAM_WE_N);
        dcache_rsp.wresp = 1'b0;
        dcache_rsp.valid = 1'b0;
        dcache_rsp.rdata = 32'h1234_5678;

        if (load_delay > 0) begin
            load_delay = load_delay - 1;
            if (load_delay == 0) begin
                dcache_rsp.valid = 1'b1;
                dcache_rsp.rdata = 32'h1234_5678;
            end
        end

        if ((dcache_req.ren != 4'h0) && (load_delay == 0)) begin
            load_delay = 2;
            load_request_seen = 1'b1;
        end
        if (dcache_req.wen != `RAM_WE_N)
            store_request_seen = 1'b1;
    end

    task automatic clear_transaction;
        begin
            execute_result = '0;
            execute_result1 = '0;
            commit0 = '0;
            commit1 = '0;
            flush = 1'b0;
            branch_flush = 1'b0;
        end
    endtask

    task automatic wait_for_completion(
        input logic [`ROB_TAG_W-1:0] expected_tag,
        output bit found
    );
        begin
            found = 1'b0;
            for (i = 0; i < 20; i = i + 1) begin
                @(negedge clk);
                #1;
                if (main_completion.valid &&
                    (main_completion.rob_tag == expected_tag)) begin
                    found = 1'b1;
                    tb_expect(main_completion.reg_write,
                              "LSU load completion reg_write");
                    tb_expect(main_completion.value == 32'h1234_5678,
                              "LSU load completion data");
                end
            end
        end
    endtask

    initial begin
        rstn = 1'b0;
        clear_transaction();
        dcache_rsp = '0;
        load_delay = 0;
        load_request_seen = 1'b0;
        store_request_seen = 1'b0;
        repeat (3) @(posedge clk);
        rstn = 1'b1;

        // Load enqueue, delayed response and completion.
        @(negedge clk);
        execute_result.valid = 1'b1;
        execute_result.rob_tag = 4'd1;
        execute_result.pc = 32'h4000;
        execute_result.is_ld_st = 1'b1;
        execute_result.store_mask = `RAM_WE_N;
        execute_result.load_ext_op = `RAM_EXT_N;
        execute_result.reg_write = 1'b1;
        execute_result.arch_rd = 5'd8;
        execute_result.alu_result = 32'h0000_1000;
        #1;
        tb_expect(!ldst_suspend, "LSU accepts first load");
        @(posedge clk);
        #1;
        execute_result = '0;
        wait_for_completion(4'd1, completion_seen);
        tb_expect(load_request_seen, "LSU issued load to DCache");
        tb_expect(completion_seen, "LSU returned load completion");

        // A flushed load may consume the cache response but must not complete.
        load_delay = 0;
        load_request_seen = 1'b0;
        completion_seen = 1'b0;
        @(negedge clk);
        execute_result.valid = 1'b1;
        execute_result.rob_tag = 4'd2;
        execute_result.pc = 32'h4010;
        execute_result.is_ld_st = 1'b1;
        execute_result.store_mask = `RAM_WE_N;
        execute_result.load_ext_op = `RAM_EXT_N;
        execute_result.reg_write = 1'b1;
        execute_result.arch_rd = 5'd9;
        execute_result.alu_result = 32'h0000_2000;
        @(posedge clk);
        #1;
        execute_result = '0;
        for (i = 0; i < 8; i = i + 1) begin
            @(negedge clk);
            if (load_request_seen && !flush)
                flush = 1'b1;
            @(posedge clk);
            #1;
            flush = 1'b0;
            if (main_completion.valid && main_completion.rob_tag == 4'd2)
                completion_seen = 1'b1;
        end
        tb_expect(load_request_seen, "LSU issued flushed load");
        tb_expect(!completion_seen, "LSU suppresses flushed load completion");

        // A store completes at execution but cannot reach DCache until its
        // matching ROB commit is presented.
        store_request_seen = 1'b0;
        @(negedge clk);
        execute_result.valid = 1'b1;
        execute_result.rob_tag = 4'd3;
        execute_result.pc = 32'h4020;
        execute_result.is_ld_st = 1'b1;
        execute_result.store_mask = `RAM_WE_W;
        execute_result.src1_value = 32'hdead_beef;
        execute_result.reg_write = 1'b0;
        execute_result.alu_result = 32'h0000_3000;
        @(posedge clk);
        #1;
        tb_expect(main_completion.valid && main_completion.rob_tag == 4'd3,
                  "LSU store execution completion");
        execute_result = '0;
        repeat (3) @(negedge clk);
        tb_expect(!store_request_seen, "LSU holds speculative store");

        @(negedge clk);
        commit0.valid = 1'b1;
        commit0.rob_tag = 4'd3;
        commit0.arch_rd = 5'd0;
        commit0.reg_write = 1'b0;
        @(posedge clk);
        #1;
        commit0 = '0;
        repeat (8) @(negedge clk);
        tb_expect(store_request_seen, "LSU releases committed store");

        // Both address-generation lanes may enqueue stores in one cycle and
        // each owns a distinct completion port.
        @(negedge clk);
        execute_result = '0;
        execute_result.valid = 1'b1;
        execute_result.rob_tag = 4'd4;
        execute_result.is_ld_st = 1'b1;
        execute_result.store_mask = `RAM_WE_W;
        execute_result.alu_result = 32'h0000_3100;
        execute_result.src1_value = 32'haaaa_5555;
        execute_result1 = execute_result;
        execute_result1.rob_tag = 4'd5;
        execute_result1.alu_result = 32'h0000_3200;
        execute_result1.src1_value = 32'h5555_aaaa;
        #1;
        tb_expect(!ldst_suspend && !ldst1_suspend,
                  "LSU accepts two stores in one cycle");
        @(posedge clk);
        #1;
        tb_expect(main_completion.valid && main_completion.rob_tag == 4'd4,
                  "lane0 dual-store completion");
        tb_expect(lane1_completion.valid && lane1_completion.rob_tag == 4'd5,
                  "lane1 dual-store completion");
        tb_expect(dut.sq_occupancy == 2,
                  "two stores occupy SQ after one acceptance edge");
        execute_result = '0;
        execute_result1 = '0;
        @(negedge clk);
        commit0.valid = 1'b1;
        commit0.rob_tag = 4'd4;
        commit1.valid = 1'b1;
        commit1.rob_tag = 4'd5;
        @(posedge clk);
        #1;
        commit0 = '0;
        commit1 = '0;
        repeat (8) @(posedge clk);

        // Two loads enter the shared age-ordered LQ together. The serialized
        // cache port drains them independently without losing either tag.
        @(negedge clk);
        execute_result = '0;
        execute_result.valid = 1'b1;
        execute_result.rob_tag = 4'd6;
        execute_result.is_ld_st = 1'b1;
        execute_result.store_mask = `RAM_WE_N;
        execute_result.load_ext_op = `RAM_EXT_N;
        execute_result.reg_write = 1'b1;
        execute_result.alu_result = 32'h0000_3300;
        execute_result1 = execute_result;
        execute_result1.rob_tag = 4'd7;
        execute_result1.alu_result = 32'h0000_3400;
        #1;
        tb_expect(!ldst_suspend && !ldst1_suspend,
                  "LSU accepts two loads in one cycle");
        @(posedge clk);
        #1;
        tb_expect(dut.lq_occupancy == 2,
                  "two loads occupy LQ after one acceptance edge");
        execute_result = '0;
        execute_result1 = '0;
        dual_load0_seen = 1'b0;
        dual_load1_seen = 1'b0;
        for (i = 0; i < 40; i = i + 1) begin
            @(negedge clk);
            #1;
            if (main_completion.valid && main_completion.rob_tag == 4'd6)
                dual_load0_seen = 1'b1;
            if (main_completion.valid && main_completion.rob_tag == 4'd7)
                dual_load1_seen = 1'b1;
        end
        tb_expect(dual_load0_seen && dual_load1_seen,
                  "serialized cache drains both same-cycle loads");

        tb_note("LSU baseline PASS");
        $finish;
    end
endmodule
