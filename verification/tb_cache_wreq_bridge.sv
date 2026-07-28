`timescale 1ns / 1ps

module tb_cache_wreq_bridge;

    reg rstn;
    reg cpu_clk;
    reg bus_uclk;

    wire dev_wrdy;
    wire dev_wdone;
    wire dev_widle;
    reg [3:0] cpu_wen;
    reg [31:0] cpu_waddr;
    reg [31:0] cpu_wdata;

    wire bus_en;
    wire [31:0] bus_waddr;
    wire [3:0] bus_we;
    wire [31:0] bus_wdata;

    cache_wreq_bridge dut (
        .rstn(rstn),
        .cpu_clk(cpu_clk),
        .dev_wrdy(dev_wrdy),
        .dev_wdone(dev_wdone),
        .dev_widle(dev_widle),
        .cpu_wen(cpu_wen),
        .cpu_waddr(cpu_waddr),
        .cpu_wdata(cpu_wdata),
        .bus_uclk(bus_uclk),
        .bus_en(bus_en),
        .bus_waddr(bus_waddr),
        .bus_we(bus_we),
        .bus_wdata(bus_wdata)
    );

    real cpu_period = 10.0;
    real bus_period = 12.0;

    initial begin
        cpu_clk = 0;
        forever #(cpu_period / 2.0) cpu_clk = ~cpu_clk;
    end

    initial begin
        bus_uclk = 0;
        forever #(bus_period / 2.0) bus_uclk = ~bus_uclk;
    end

    typedef struct {
        bit [3:0]  wen;
        bit [31:0] waddr;
        bit [31:0] wdata;
        int        seq_id;
    } req_t;

    req_t push_queue[$];

    int push_count = 0;
    int bus_write_count = 0;
    int payload_mismatch = 0;
    int duplicate_count = 0;
    int missing_count = 0;
    int reorder_count = 0;

    task push_item(input [3:0] wen, input [31:0] addr, input [31:0] data, input int seq);
        req_t item;
        item.wen = wen;
        item.waddr = addr;
        item.wdata = data;
        item.seq_id = seq;

        @(posedge cpu_clk);
        while (!dev_wrdy) @(posedge cpu_clk);

        cpu_wen   <= wen;
        cpu_waddr <= addr;
        cpu_wdata <= data;
        push_queue.push_back(item);
        push_count++;

        @(posedge cpu_clk);
        cpu_wen   <= 4'h0;
        cpu_waddr <= 32'h0;
        cpu_wdata <= 32'h0;
    endtask

    always @(posedge bus_uclk) begin
        if (rstn && bus_en && (|bus_we)) begin
            bus_write_count++;
            if (push_queue.size() == 0) begin
                $display("[ERROR] Extra unexpected write on bus!");
                duplicate_count++;
            end else begin
                req_t exp = push_queue.pop_front();
                bit [31:0] exp_word_addr = (exp.waddr[31:16] == 16'hBFAF || exp.waddr[31:16] == 16'hBFD0) ?
                                           exp.waddr : {2'h0, exp.waddr[31:2]};

                if (bus_we !== exp.wen || bus_waddr !== exp_word_addr || bus_wdata !== exp.wdata) begin
                    $display("[MISMATCH] Seq %0d: exp (we=%h, addr=%h, data=%h), got (we=%h, addr=%h, data=%h)",
                             exp.seq_id, exp.wen, exp_word_addr, exp.wdata, bus_we, bus_waddr, bus_wdata);
                    payload_mismatch++;
                end
            end
        end
    end

    initial begin
        rstn = 0;
        cpu_wen = 0;
        cpu_waddr = 0;
        cpu_wdata = 0;
        #100;
        rstn = 1;
        #50;

        $display("=== STARTING BRIDGE TEST (1000 ITEMS) ===");

        for (int i = 1; i <= 1000; i++) begin
            push_item(4'hF, 32'h1000_0000 + (i << 2), 32'hA5A5_0000 + i, i);
            if (i % 5 == 0) #(i % 7 * 3);
        end

        while (!dev_widle || push_queue.size() > 0) @(posedge cpu_clk);

        #200;
        missing_count = push_queue.size();

        $display("==================================================");
        $display("SUMMARY:");
        $display("push_count           = %0d", push_count);
        $display("bus_write_count      = %0d", bus_write_count);
        $display("payload_mismatch     = %0d", payload_mismatch);
        $display("duplicate_count      = %0d", duplicate_count);
        $display("missing_count        = %0d", missing_count);
        $display("reorder_count        = %0d", reorder_count);
        $display("dev_widle            = %0b", dev_widle);
        $display("==================================================");

        if (push_count == bus_write_count &&
            payload_mismatch == 0 &&
            duplicate_count == 0 &&
            missing_count == 0 &&
            reorder_count == 0 &&
            dev_widle == 1'b1) begin
            $display("[TEST SUCCESSFUL] All 1000 items matched exactly with zero mismatch!");
        end else begin
            $fatal(1, "[TEST FAILED] Bridge test verification failed!");
        end

        $finish;
    end

endmodule
