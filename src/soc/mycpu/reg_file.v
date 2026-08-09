`timescale 1ns / 1ps

// Architectural register file shared by both decode lanes.
// There are four combinational read ports and two commit write ports.
module RegFile (
    input  wire        cpu_clk,
    input  wire [4:0]  rR1,
    input  wire [4:0]  rR2,
    input  wire [4:0]  rR3,
    input  wire [4:0]  rR4,
    input  wire        we,
    input  wire [4:0]  wR,
    input  wire [31:0] wD,
    input  wire        we1,
    input  wire [4:0]  wR1,
    input  wire [31:0] wD1,
    output wire [31:0] rD1,
    output wire [31:0] rD2,
    output wire [31:0] rD3,
    output wire [31:0] rD4
);

    reg [31:0] r [1:31];

    always @(posedge cpu_clk) begin
        if (we  && (wR  != 5'h0)) r[wR]  <= wD;
        if (we1 && (wR1 != 5'h0)) r[wR1] <= wD1;
    end

    assign rD1 = (rR1 == 5'h0) ? 32'h0 : r[rR1];
    assign rD2 = (rR2 == 5'h0) ? 32'h0 : r[rR2];
    assign rD3 = (rR3 == 5'h0) ? 32'h0 : r[rR3];
    assign rD4 = (rR4 == 5'h0) ? 32'h0 : r[rR4];

endmodule
