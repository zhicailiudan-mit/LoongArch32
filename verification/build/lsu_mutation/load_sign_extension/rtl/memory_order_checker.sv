`timescale 1ns / 1ps
module MemoryOrderChecker #(parameter integer STORE_SLOTS = 8) (
    input logic load_valid, input logic [31:0] load_addr,
    input logic [STORE_SLOTS-1:0] store_valid,
    input logic [STORE_SLOTS*32-1:0] store_addr_flat,
    output logic blocked
);
    integer i;
    always_comb begin
        blocked = 1'b0;
        for (i = 0; i < STORE_SLOTS; i = i + 1)
            if (load_valid && store_valid[i] &&
                ((load_addr & 32'hffff_fffc) ==
                 (store_addr_flat[i*32 +: 32] & 32'hffff_fffc)))
                blocked = 1'b1;
    end
endmodule
