`timescale 1ns/1ps
`include "defines.vh"
import cpu_types_pkg::*;

module tb_store_queue_decoupled;
    logic clk = 1'b0;
    logic rstn = 1'b0;
    always #5 clk = ~clk;

    logic flush, recover_valid, system_flush;
    uop_id_t recover_id;
    logic accept_valid, accept1_valid;
    lsu_entry_t accept_entry, accept1_entry;
    logic accept_ready, accept1_ready;
    logic reserve0_valid, reserve0_ready;
    uop_id_t reserve0_uop_id, reserve0_src1_id;
    logic [31:0] reserve0_pc, reserve0_src1_value;
    logic [3:0] reserve0_store_mask;
    logic reserve0_src1_ready;
    logic reserve1_valid, reserve1_ready;
    uop_id_t reserve1_uop_id, reserve1_src1_id;
    logic [31:0] reserve1_pc, reserve1_src1_value;
    logic [3:0] reserve1_store_mask;
    logic reserve1_src1_ready;
    logic addr_update0_valid, addr_update0_ack, addr_update0_unalign;
    uop_id_t addr_update0_uop_id;
    logic [31:0] addr_update0_address;
    logic [3:0] addr_update0_store_wen;
    logic addr_update1_valid, addr_update1_ack, addr_update1_unalign;
    uop_id_t addr_update1_uop_id;
    logic [31:0] addr_update1_address;
    logic [3:0] addr_update1_store_wen;
    completion_t complete0, complete1;
    commit_t commit0, commit1;
    logic release_valid, release_fire;
    lsu_entry_t release_entry;
    logic [3:0] valid_vec, addr_ready_vec, store_data_ready_vec;
    logic [127:0] addr_flat, store_data_flat;
    logic [4*`UOP_ID_W-1:0] uop_id_flat;
    logic [15:0] store_wen_flat;
    logic [16*`UOP_ID_W-1:0] store_byte_uop_id_flat;
    logic [2:0] occupancy;
    integer failures = 0;
    integer i;
    logic found_id;

    function automatic uop_id_t uid(input integer tag);
        uop_id_t tmp;
        begin
            tmp = '0;
            tmp.rob_tag = tag[`ROB_TAG_W-1:0];
            uid = tmp;
        end
    endfunction

    function automatic uop_id_t uid_epoch(input integer tag, input integer epoch);
        uop_id_t tmp;
        begin
            tmp = '0;
            tmp.rob_tag = tag[`ROB_TAG_W-1:0];
            tmp.epoch = epoch[`UOP_EPOCH_W-1:0];
            uid_epoch = tmp;
        end
    endfunction

    task automatic tb_expect(input logic cond, input string msg);
        if (!cond) begin
            $display("[SQ-DECOUPLED-FAIL] %s", msg);
            failures = failures + 1;
        end
    endtask

    task automatic clear_inputs;
        begin
            flush = 0; recover_valid = 0; system_flush = 0; recover_id = '0;
            accept_valid = 0; accept1_valid = 0; accept_entry = '0; accept1_entry = '0;
            reserve0_valid = 0; reserve0_uop_id = '0; reserve0_pc = 0;
            reserve0_store_mask = 0; reserve0_src1_ready = 0;
            reserve0_src1_value = 0; reserve0_src1_id = '0;
            reserve1_valid = 0; reserve1_uop_id = '0; reserve1_pc = 0;
            reserve1_store_mask = 0; reserve1_src1_ready = 0;
            reserve1_src1_value = 0; reserve1_src1_id = '0;
            addr_update0_valid = 0; addr_update0_uop_id = '0;
            addr_update0_address = 0; addr_update0_store_wen = 0;
            addr_update0_unalign = 0;
            addr_update1_valid = 0; addr_update1_uop_id = '0;
            addr_update1_address = 0; addr_update1_store_wen = 0;
            addr_update1_unalign = 0;
            complete0 = '0; complete1 = '0; commit0 = '0; commit1 = '0;
            release_fire = 0;
        end
    endtask

    task automatic reset_dut;
        begin
            @(negedge clk); clear_inputs(); rstn = 0;
            repeat (2) @(posedge clk);
            @(negedge clk); rstn = 1;
        end
    endtask

    task automatic reserve_ready_store(
        input integer tag, input [3:0] mask, input [31:0] value,
        input [31:0] address, input logic commit_now
    );
        begin
            @(negedge clk);
            reserve0_valid = 1;
            reserve0_uop_id = uid(tag);
            reserve0_pc = 32'h1c00_0000 + tag*4;
            reserve0_store_mask = mask;
            reserve0_src1_ready = 1;
            reserve0_src1_value = value;
            addr_update0_valid = 1;
            addr_update0_uop_id = uid(tag);
            addr_update0_address = address;
            if (commit_now) begin
                commit0.valid = 1;
                commit0.uop_id = uid(tag);
            end
            #1 tb_expect(reserve0_ready && addr_update0_ack,
                      "same-cycle reservation/address update was not accepted");
            @(posedge clk);
            #1;
            reserve0_valid = 0; addr_update0_valid = 0; commit0 = '0;
        end
    endtask

    StoreQueue #(.DEPTH(4)) dut (
        .clk, .rstn, .flush, .recover_valid, .system_flush, .recover_id,
        .accept_valid, .accept_entry, .accept_ready,
        .accept1_valid, .accept1_entry, .accept1_ready,
        .reserve0_valid, .reserve0_ready, .reserve0_uop_id, .reserve0_pc,
        .reserve0_store_mask, .reserve0_src1_ready, .reserve0_src1_value,
        .reserve0_src1_id,
        .reserve1_valid, .reserve1_ready, .reserve1_uop_id, .reserve1_pc,
        .reserve1_store_mask, .reserve1_src1_ready, .reserve1_src1_value,
        .reserve1_src1_id,
        .addr_update0_valid, .addr_update0_ack, .addr_update0_uop_id,
        .addr_update0_address, .addr_update0_store_wen, .addr_update0_unalign,
        .addr_update1_valid, .addr_update1_ack, .addr_update1_uop_id,
        .addr_update1_address, .addr_update1_store_wen, .addr_update1_unalign,
        .complete0, .complete1, .commit0, .commit1,
        .release_valid, .release_entry, .release_fire,
        .valid_vec, .addr_ready_vec, .store_data_ready_vec,
        .addr_flat, .uop_id_flat, .store_wen_flat, .store_data_flat,
        .store_byte_uop_id_flat, .occupancy
    );

    initial begin
        clear_inputs();
        reset_dut();

        // Data is captured at reservation; address arrives later.  Byte
        // alignment must use the later address offset, not the initial mask.
        @(negedge clk);
        reserve0_valid = 1; reserve0_uop_id = uid(1); reserve0_pc = 32'h1c00_0004;
        reserve0_store_mask = `RAM_WE_B; reserve0_src1_ready = 1;
        reserve0_src1_value = 32'h0000_00aa;
        #1 tb_expect(reserve0_ready, "data-before-address reservation not ready");
        @(posedge clk); #1; reserve0_valid = 0;
        @(negedge clk);
        addr_update0_valid = 1; addr_update0_uop_id = uid(1);
        addr_update0_address = 32'h0000_1001;
        #1 tb_expect(addr_update0_ack, "data-before-address update not acknowledged");
        @(posedge clk); #1; addr_update0_valid = 0;
        @(negedge clk); commit0.valid = 1; commit0.uop_id = uid(1);
        @(posedge clk); #1; commit0 = '0;
        @(negedge clk); #1;
        tb_expect(release_valid, "data-before-address Store did not become releasable");
        tb_expect(release_entry.store_wen == 4'b0010, "byte enable was not address shifted");
        tb_expect(release_entry.store_data == 32'h0000_aa00, "byte data was not address shifted");
        release_fire = 1; @(posedge clk); #1; release_fire = 0;

        // Address arrives first; the producer completion supplies data later.
        @(negedge clk);
        reserve0_valid = 1; reserve0_uop_id = uid(2); reserve0_pc = 32'h1c00_0008;
        reserve0_store_mask = `RAM_WE_W; reserve0_src1_ready = 0;
        reserve0_src1_id = uid(9);
        addr_update0_valid = 1; addr_update0_uop_id = uid(2);
        addr_update0_address = 32'h0000_1004;
        #1 tb_expect(reserve0_ready && addr_update0_ack,
                  "address-before-data reservation/update failed");
        @(posedge clk); #1; reserve0_valid = 0; addr_update0_valid = 0;
        @(negedge clk); complete0.valid = 1; complete0.reg_write = 1;
        complete0.uop_id = uid(9); complete0.value = 32'h1234_5678;
        @(posedge clk); #1; complete0 = '0;
        @(negedge clk); commit0.valid = 1; commit0.uop_id = uid(2);
        @(posedge clk); #1; commit0 = '0;
        @(negedge clk); #1;
        tb_expect(release_valid, "address-before-data Store did not become releasable");
        tb_expect(release_entry.store_data == 32'h1234_5678,
               "late Store data completion was not retained");
        release_fire = 1; @(posedge clk); #1; release_fire = 0;

        // With one free slot and two candidates, exactly the older Store wins.
        reset_dut();
        reserve_ready_store(3, `RAM_WE_W, 32'h3, 32'h2000, 1'b1);
        reserve_ready_store(4, `RAM_WE_W, 32'h4, 32'h2004, 1'b1);
        reserve_ready_store(5, `RAM_WE_W, 32'h5, 32'h2008, 1'b1);
        @(negedge clk);
        reserve0_valid = 1; reserve0_uop_id = uid(7); reserve0_store_mask = `RAM_WE_W;
        reserve0_src1_ready = 1; reserve0_src1_value = 32'h7;
        reserve1_valid = 1; reserve1_uop_id = uid(6); reserve1_store_mask = `RAM_WE_W;
        reserve1_src1_ready = 1; reserve1_src1_value = 32'h6;
        #1;
        tb_expect(!reserve0_ready && reserve1_ready,
               "one-slot dual reservation did not grant the older Store");
        @(posedge clk); #1; reserve0_valid = 0; reserve1_valid = 0;
        tb_expect(occupancy == 4, "one-slot arbitration produced wrong occupancy");
        found_id = 0;
        for (i = 0; i < 4; i = i + 1)
            if (dut.entries[i].valid && uop_id_equal(dut.entries[i].uop_id, uid(6)))
                found_id = 1;
        tb_expect(found_id, "older Store was not inserted after one-slot grant");

        // A producer commit is a fallback for a Store that missed the
        // one-cycle completion broadcast.  The data-only commit copy is
        // deliberately registered, so it wakes the Store one cycle later.
        reset_dut();
        @(negedge clk);
        reserve0_valid = 1; reserve0_uop_id = uid(10); reserve0_pc = 32'h1c00_0028;
        reserve0_store_mask = `RAM_WE_W; reserve0_src1_ready = 0;
        reserve0_src1_id = uid(8);
        addr_update0_valid = 1; addr_update0_uop_id = uid(10);
        addr_update0_address = 32'h0000_3000;
        commit0.valid = 1; commit0.reg_write = 1;
        commit0.uop_id = uid(8); commit0.value = 32'h89ab_cdef;
        @(posedge clk); #1;
        tb_expect(!store_data_ready_vec[0],
                  "commit fallback bypassed the intended register boundary");
        @(negedge clk);
        reserve0_valid = 0; addr_update0_valid = 0; commit0 = '0;
        @(posedge clk); #1;
        tb_expect(store_data_ready_vec[0], "registered commit fallback did not wake Store");
        tb_expect(store_data_flat[31:0] == 32'h89ab_cdef,
                  "registered commit fallback captured wrong data");

        // Completion remains the immediate path for a same-cycle reservation.
        reset_dut();
        @(negedge clk);
        reserve0_valid = 1; reserve0_uop_id = uid(11); reserve0_pc = 32'h1c00_002c;
        reserve0_store_mask = `RAM_WE_W; reserve0_src1_ready = 0;
        reserve0_src1_id = uid(9);
        addr_update0_valid = 1; addr_update0_uop_id = uid(11);
        addr_update0_address = 32'h0000_3004;
        complete0.valid = 1; complete0.reg_write = 1;
        complete0.uop_id = uid(9); complete0.value = 32'h1020_3040;
        @(posedge clk); #1;
        tb_expect(store_data_ready_vec[0],
                  "same-cycle completion did not wake newly reserved Store");
        tb_expect(store_data_flat[31:0] == 32'h1020_3040,
                  "same-cycle completion captured wrong data");

        // A release shift and registered wakeup may update the same surviving
        // entry on one edge.  The shifted Store must retain the wakeup value.
        reset_dut();
        reserve_ready_store(12, `RAM_WE_W, 32'h1212_1212, 32'h4000, 1'b1);
        @(negedge clk);
        reserve0_valid = 1; reserve0_uop_id = uid(13); reserve0_pc = 32'h1c00_0034;
        reserve0_store_mask = `RAM_WE_W; reserve0_src1_ready = 0;
        reserve0_src1_id = uid(7);
        addr_update0_valid = 1; addr_update0_uop_id = uid(13);
        addr_update0_address = 32'h0000_4004;
        @(posedge clk); #1;
        @(negedge clk);
        reserve0_valid = 0; addr_update0_valid = 0;
        commit0.valid = 1; commit0.reg_write = 1;
        commit0.uop_id = uid(7); commit0.value = 32'h7777_7777;
        @(posedge clk); #1;
        @(negedge clk); commit0 = '0; release_fire = 1;
        @(posedge clk); #1; release_fire = 0;
        tb_expect(occupancy == 1, "release shift produced wrong occupancy");
        tb_expect(store_data_ready_vec[0],
                  "release shift lost registered Store-data wakeup");
        tb_expect(store_data_flat[31:0] == 32'h7777_7777,
                  "release shift retained wrong Store data");

        // Full uop_id matching: a recycled ROB tag from another epoch must not
        // wake the waiting Store.
        reset_dut();
        @(negedge clk);
        reserve0_valid = 1; reserve0_uop_id = uid_epoch(14, 1);
        reserve0_store_mask = `RAM_WE_W; reserve0_src1_ready = 0;
        reserve0_src1_id = uid_epoch(6, 1);
        addr_update0_valid = 1; addr_update0_uop_id = uid_epoch(14, 1);
        addr_update0_address = 32'h0000_5000;
        @(posedge clk); #1;
        @(negedge clk); reserve0_valid = 0; addr_update0_valid = 0;
        commit0.valid = 1; commit0.reg_write = 1;
        commit0.uop_id = uid_epoch(6, 0); commit0.value = 32'hdead_beef;
        @(posedge clk); #1;
        @(negedge clk); commit0 = '0;
        @(posedge clk); #1;
        tb_expect(!store_data_ready_vec[0],
                  "commit fallback matched ROB tag without matching epoch");

        // Branch recovery keeps the resolving/older Store.  A producer commit
        // on the flush edge must remain available after compaction.
        reset_dut();
        @(negedge clk);
        reserve0_valid = 1; reserve0_uop_id = uid(16);
        reserve0_store_mask = `RAM_WE_W; reserve0_src1_ready = 0;
        reserve0_src1_id = uid(15);
        addr_update0_valid = 1; addr_update0_uop_id = uid(16);
        addr_update0_address = 32'h0000_6000;
        @(posedge clk); #1;
        @(negedge clk); reserve0_valid = 0; addr_update0_valid = 0;
        flush = 1; recover_valid = 1; recover_id = uid(16);
        commit0.valid = 1; commit0.reg_write = 1;
        commit0.uop_id = uid(15); commit0.value = 32'h1515_1515;
        @(posedge clk); #1;
        tb_expect(occupancy == 1 && !store_data_ready_vec[0],
                  "branch flush did not preserve waiting Store exactly once");
        @(negedge clk); flush = 0; recover_valid = 0; commit0 = '0;
        @(posedge clk); #1;
        tb_expect(store_data_ready_vec[0] && store_data_flat[31:0] == 32'h1515_1515,
                  "branch flush lost same-cycle producer commit fallback");

        // System flush preserves only a Store retiring on that edge.  commit0
        // is the older producer and commit1 is the younger Store.
        reset_dut();
        @(negedge clk);
        reserve0_valid = 1; reserve0_uop_id = uid(18);
        reserve0_store_mask = `RAM_WE_W; reserve0_src1_ready = 0;
        reserve0_src1_id = uid(17);
        addr_update0_valid = 1; addr_update0_uop_id = uid(18);
        addr_update0_address = 32'h0000_7000;
        @(posedge clk); #1;
        @(negedge clk); reserve0_valid = 0; addr_update0_valid = 0;
        flush = 1; system_flush = 1;
        commit0.valid = 1; commit0.reg_write = 1;
        commit0.uop_id = uid(17); commit0.value = 32'h1717_1717;
        commit1.valid = 1; commit1.uop_id = uid(18);
        @(posedge clk); #1;
        tb_expect(occupancy == 1 && !store_data_ready_vec[0],
                  "system flush did not preserve same-cycle committed Store");
        @(negedge clk); flush = 0; system_flush = 0; commit0 = '0; commit1 = '0;
        @(posedge clk); #1;
        tb_expect(release_valid && release_entry.store_data == 32'h1717_1717,
                  "system flush lost delayed data for preserved committed Store");

        if (failures == 0)
            $display("[SQ-DECOUPLED-PASS] persistent address/data ownership passed");
        else
            $fatal(1, "[SQ-DECOUPLED] failures=%0d", failures);
        $finish;
    end
endmodule
