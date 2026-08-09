`timescale 1ns / 1ps

// Minimal LA32 direct/DMW address translator.  Page-table translation is
// deliberately reported as a miss because this core has no TLB yet.
module AddressTranslate (
    input  logic [31:0] vaddr,
    input  logic        is_fetch,
    input  logic [31:0] crmd,
    input  logic [31:0] dmw0,
    input  logic [31:0] dmw1,
    output logic [31:0] paddr,
    output logic [1:0]  mat,
    output logic        cacheable,
    output logic        dmw_hit,
    output logic        page_miss
);

    wire [1:0] plv = crmd[1:0];
    wire direct_mode = crmd[3] && !crmd[4];
    wire mapped_mode = !crmd[3] && crmd[4];
    wire dmw0_plv_en = dmw0[plv];
    wire dmw1_plv_en = dmw1[plv];
    wire dmw0_hit = mapped_mode && dmw0_plv_en &&
                    (vaddr[31:29] == dmw0[31:29]);
    wire dmw1_hit = mapped_mode && dmw1_plv_en &&
                    (vaddr[31:29] == dmw1[31:29]);

    always_comb begin
        paddr     = vaddr;
        mat       = is_fetch ? crmd[6:5] : crmd[8:7];
        dmw_hit   = 1'b0;
        page_miss = 1'b0;

        if (direct_mode) begin
            paddr = vaddr;
        end else if (dmw0_hit) begin
            paddr   = {dmw0[27:25], vaddr[28:0]};
            mat     = dmw0[5:4];
            dmw_hit = 1'b1;
        end else if (dmw1_hit) begin
            paddr   = {dmw1[27:25], vaddr[28:0]};
            mat     = dmw1[5:4];
            dmw_hit = 1'b1;
        end else if (mapped_mode) begin
            // A future TLB owns this case.  Keep the untranslated address on
            // the pins for observability, but force it uncached and flag it.
            paddr     = vaddr;
            mat       = 2'b00;
            page_miss = 1'b1;
        end

        // The official SoC maps normal cacheable memory only in BaseRAM and
        // ExtRAM (0x1c00_0000..0x1c7f_ffff). UART and the remaining 0x1fxx
        // MMIO space must stay single-beat/strongly ordered even when CRMD.MAT
        // selects cached memory globally.
        cacheable = (mat == 2'b01) && !page_miss &&
                    (paddr >= 32'h1c00_0000) &&
                    (paddr <  32'h1c80_0000);
    end

endmodule
