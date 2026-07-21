`timescale 1ns / 1ps

module async_fifo #(
    parameter DATA_WIDTH = 32,
    parameter FIFO_DEPTH = 4    // 2^n
) (
    input  wire         rstn,
    // Write Port
    input  wire         wr_clk,
    input  wire         wr_en,
    input  wire [DATA_WIDTH-1:0] din,
    output wire         full,
    // Read Port
    input  wire         rd_clk,
    input  wire         rd_en,
    output wire [DATA_WIDTH-1:0] dout,
    output wire         empty
);

    localparam ADDR_WIDTH = $clog2(FIFO_DEPTH);

    reg [DATA_WIDTH-1:0] mem [0:FIFO_DEPTH-1];
    reg [DATA_WIDTH-1:0] dout_fwft, dout_hold;

    // 鍐欐寚閽堝拰璇绘寚閽堬紙浜岃繘鍒跺拰Gray鐮侊級
    reg [ADDR_WIDTH:0] wr_ptr_bin, wr_ptr_gray;
    reg [ADDR_WIDTH:0] rd_ptr_bin, rd_ptr_gray;

    // 鍚屾鍒板鏂规椂閽熷煙鐨凣ray鎸囬拡
    reg [ADDR_WIDTH:0] wr_ptr_gray_rdclk1, wr_ptr_gray_rdclk2;
    reg [ADDR_WIDTH:0] rd_ptr_gray_wrclk1, rd_ptr_gray_wrclk2;

    wire [ADDR_WIDTH:0] wr_ptr_bin_next  = wr_ptr_bin + 1;
    wire [ADDR_WIDTH:0] wr_ptr_gray_next = (wr_ptr_bin_next >> 1) ^ wr_ptr_bin_next;

    // ==================== 鍐欐椂閽熷煙閫昏緫 ====================
    integer i;
    always @(posedge wr_clk or negedge rstn) begin
        if (!rstn) begin
            wr_ptr_bin  <= 0;
            wr_ptr_gray <= 0;
            for (i = 0; i < FIFO_DEPTH; i = i + 1)
                mem[i] <= {DATA_WIDTH{1'b0}};
        end else begin
            if (wr_en & !full) begin
                mem[wr_ptr_bin[ADDR_WIDTH-1:0]] <= din;
                wr_ptr_bin  <= wr_ptr_bin_next;
                wr_ptr_gray <= wr_ptr_gray_next;
            end
        end
    end

    // 褰� wr_en 鏈夋晥涓斿嵆灏嗗彉婊℃椂锛宖ull 绔嬪嵆鍙橀珮锛岄樆姝� wr_ptr_bin_next 缁х画澧為暱
    assign full = (wr_ptr_gray_next == {~rd_ptr_gray_wrclk2[ADDR_WIDTH:ADDR_WIDTH-1], rd_ptr_gray_wrclk2[ADDR_WIDTH-2:0]});

    // ==================== 璇绘椂閽熷煙閫昏緫 ====================
    always @(posedge rd_clk or negedge rstn)
        dout_fwft <= !rstn ? {DATA_WIDTH{1'b0}} : mem[rd_ptr_bin[ADDR_WIDTH-1:0]];   // 濮嬬粓鍔犺浇褰撳墠澶撮儴鏁版嵁
    always @(posedge rd_clk)
        if (rd_en & !empty) dout_hold <= dout_fwft;     // 涓嬩竴娆¤鎿嶄綔涔嬪墠锛屼繚鎸佽緭鍑轰笉鍙�
        
    assign dout = (rd_en & !empty) ? dout_fwft : dout_hold;

    always @(posedge rd_clk or negedge rstn) begin
        if (!rstn) begin
            rd_ptr_bin  <= 0;
            rd_ptr_gray <= 0;
        end else if (rd_en && !empty) begin
            rd_ptr_bin  <= rd_ptr_bin + 1'b1;
            rd_ptr_gray <= (rd_ptr_bin + 1'b1) ^ ((rd_ptr_bin + 1'b1) >> 1);
        end
    end

    // empty鏍囧織锛氬綋璇绘寚閽堢瓑浜庡悓姝ュ悗鐨勫啓鎸囬拡鏃朵负绌�
    assign empty = (rd_ptr_gray == wr_ptr_gray_rdclk2);

    // ==================== 璺ㄦ椂閽熷煙鍚屾锛堜袱绾у悓姝ュ櫒锛�===================
    // 鍐欐寚閽圙ray鐮佸悓姝ュ埌璇绘椂閽熷煙
    always @(posedge rd_clk or negedge rstn) begin
        if (!rstn) begin
            wr_ptr_gray_rdclk1 <= 0;
            wr_ptr_gray_rdclk2 <= 0;
        end else begin
            wr_ptr_gray_rdclk1 <= wr_ptr_gray;
            wr_ptr_gray_rdclk2 <= wr_ptr_gray_rdclk1;
        end
    end

    // 璇绘寚閽圙ray鐮佸悓姝ュ埌鍐欐椂閽熷煙
    always @(posedge wr_clk or negedge rstn) begin
        if (!rstn) begin
            rd_ptr_gray_wrclk1 <= 0;
            rd_ptr_gray_wrclk2 <= 0;
        end else begin
            rd_ptr_gray_wrclk1 <= rd_ptr_gray;
            rd_ptr_gray_wrclk2 <= rd_ptr_gray_wrclk1;
        end
    end

endmodule