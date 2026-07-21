`timescale 1ns/1ps

import cpu_types_pkg::*;

module tb_privilege_supervisor;
    logic clk = 1'b0;
    logic rstn = 1'b0;
    privilege_req_t req;
    logic req_ready;
    privilege_rsp_t rsp;
    privilege_state_t state;
    logic busy;
    logic icache_maint_valid, icache_maint_ready, icache_maint_done;
    logic dcache_maint_valid, dcache_maint_ready, dcache_maint_done;
    logic cache_maint_all;
    logic [1:0] cache_maint_mode;
    logic [31:0] cache_maint_addr, cache_maint_ctag;
    integer errors = 0;

    always #5 clk = ~clk;

    PrivilegeSystem dut (
        .cpu_clk(clk), .cpu_rstn(rstn), .req(req), .req_ready(req_ready),
        .rsp(rsp), .state(state), .busy(busy),
        .icache_maint_valid(icache_maint_valid),
        .icache_maint_ready(icache_maint_ready),
        .icache_maint_done(icache_maint_done),
        .dcache_maint_valid(dcache_maint_valid),
        .dcache_maint_ready(dcache_maint_ready),
        .dcache_maint_done(dcache_maint_done),
        .cache_maint_all(cache_maint_all),
        .cache_maint_mode(cache_maint_mode),
        .cache_maint_addr(cache_maint_addr),
        .cache_maint_ctag(cache_maint_ctag)
    );

    task automatic fail(input string msg);
        begin
            errors = errors + 1;
            $display("[UNIT-FAIL] cycle=%0t %s", $time, msg);
        end
    endtask

    task automatic check_cpucfg(input logic [31:0] index,
                                 input logic [31:0] expected);
        begin
            @(negedge clk);
            req = '0;
            req.valid = 1'b1;
            req.system_op = SYS_CPUCFG;
            req.source_value = index;
            req.rob_tag = index[`ROB_TAG_W-1:0];
            req.pc = 32'h1c00_1000 + (index << 2);
            @(posedge clk); #1;
            if (!rsp.valid || rsp.result !== expected || !rsp.reg_write)
                fail($sformatf("CPUCFG[%08x] expected=%08x actual valid=%0b data=%08x reg_write=%0b",
                               index, expected, rsp.valid, rsp.result, rsp.reg_write));
            req.valid = 1'b0;
        end
    endtask

    task automatic check_cacop(input logic [4:0] op,
                               input logic expect_i,
                               input logic expect_d,
                               input logic [1:0] expected_mode);
        logic [`ROB_TAG_W-1:0] tag;
        logic [31:0] pc;
        begin
            tag = op[`ROB_TAG_W-1:0];
            pc = 32'h1c00_2000 + {25'd0, op, 2'b00};
            @(negedge clk);
            req = '0;
            req.valid = 1'b1;
            req.system_op = SYS_CACOP;
            req.cacop_op = op;
            req.address = 32'h8000_0364;
            req.rob_tag = tag;
            req.pc = pc;
            @(posedge clk); #1;
            req.valid = 1'b0;
            if (icache_maint_valid !== expect_i || dcache_maint_valid !== expect_d)
                fail($sformatf("CACOP %02x wrong target: I=%0b D=%0b", op,
                               icache_maint_valid, dcache_maint_valid));
            if (cache_maint_mode !== expected_mode || cache_maint_all !== 1'b0 ||
                cache_maint_addr !== 32'h8000_0364)
                fail($sformatf("CACOP %02x wrong payload: mode=%0d all=%0b addr=%08x",
                               op, cache_maint_mode, cache_maint_all, cache_maint_addr));

            @(posedge clk); #1;
            icache_maint_done = expect_i;
            dcache_maint_done = expect_d;
            @(posedge clk); #1;
            icache_maint_done = 1'b0;
            dcache_maint_done = 1'b0;
            if (!rsp.valid || rsp.rob_tag !== tag || rsp.reg_write ||
                !rsp.redirect_valid || rsp.redirect_target !== pc + 32'd4)
                fail($sformatf("CACOP %02x completion mismatch", op));
        end
    endtask

    task automatic check_mapping_csr(input logic [13:0] csr_num,
                                     input logic [31:0] value);
        begin
            @(negedge clk);
            req = '0;
            req.valid = 1'b1;
            req.system_op = SYS_CSRWR;
            req.csr_num = csr_num;
            req.source_value = value;
            req.rob_tag = 4'he;
            req.pc = 32'h1c00_3000;
            @(posedge clk); #1;
            req.valid = 1'b0;
            if (!icache_maint_valid || !dcache_maint_valid || !cache_maint_all ||
                cache_maint_mode !== 2'b01)
                fail($sformatf("mapping CSR %04x did not request all-cache invalidate", csr_num));
            @(posedge clk); #1;
            icache_maint_done = 1'b1;
            dcache_maint_done = 1'b1;
            @(posedge clk); #1;
            icache_maint_done = 1'b0;
            dcache_maint_done = 1'b0;
            if (!rsp.valid)
                fail($sformatf("mapping CSR %04x did not complete", csr_num));
        end
    endtask

    initial begin
        req = '0;
        icache_maint_ready = 1'b1;
        dcache_maint_ready = 1'b1;
        icache_maint_done = 1'b0;
        dcache_maint_done = 1'b0;
        repeat (3) @(posedge clk);
        rstn = 1'b1;
        @(posedge clk); #1;

        if (state.crmd !== 32'h0000_0088 || state.dmw0 !== 32'd0 || state.dmw1 !== 32'd0)
            fail("reset privilege state mismatch");

        check_cpucfg(32'h10, 32'h0000_0005);
        check_cpucfg(32'h11, 32'h0505_0000);
        check_cpucfg(32'h12, 32'h0505_0000);
        check_cpucfg(32'd10, 32'h0000_0000);

        check_cacop(5'h00, 1'b1, 1'b0, 2'b00);
        check_cacop(5'h01, 1'b0, 1'b1, 2'b00);
        check_cacop(5'h09, 1'b0, 1'b1, 2'b01);

        check_mapping_csr(14'h0000, 32'h0000_0088);
        if (state.crmd !== 32'h0000_0088) fail("CRMD was not retained");
        check_mapping_csr(14'h0180, 32'hee00_0039);
        if (state.dmw0 !== 32'hee00_0039) fail("DMW0 write/read state mismatch");
        check_mapping_csr(14'h0181, 32'ha600_0019);
        if (state.dmw1 !== (32'ha600_0019 & 32'hee00_0039)) fail("DMW1 write mask mismatch");

        if (errors != 0)
            $fatal(1, "[UNIT-FAIL] privilege supervisor errors=%0d", errors);
        $display("[UNIT-PASS] CPUCFG/CACOP/CRMD/DMW supervisor contract passed");
        $finish;
    end

    initial begin
        #10000;
        $fatal(1, "[UNIT-FAIL] privilege supervisor timeout");
    end
endmodule
