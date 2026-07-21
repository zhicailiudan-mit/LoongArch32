`timescale 1ns / 1ps
module MemoryOrderChecker #(parameter integer STORE_SLOTS = 8) (
    input logic load_valid, input logic [31:0] load_addr,
    input logic [3:0] load_ren,
    input logic [STORE_SLOTS-1:0] store_valid,
    input logic [STORE_SLOTS-1:0] store_addr_ready,
    input logic [STORE_SLOTS*32-1:0] store_addr_flat,
    input logic [STORE_SLOTS*4-1:0] store_wen_flat,
    output logic blocked
);
    integer i;
    always_comb begin
        blocked = 1'b0;
        for (i = 0; i < STORE_SLOTS; i = i + 1)
            if (load_valid && store_valid[i] &&
                // A reserved older Store with an unresolved address is a
                // conservative memory-order barrier.  It must not disappear
                // merely because it has not reached the execute stage yet.
                (!store_addr_ready[i] ||
                 (((load_addr & 32'hffff_fffc) ==
                   (store_addr_flat[i*32 +: 32] & 32'hffff_fffc)) &&
                  (|(load_ren & store_wen_flat[i*4 +: 4])))))
                blocked = 1'b1;
    end
endmodule
