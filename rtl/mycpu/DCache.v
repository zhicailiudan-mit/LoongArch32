`timescale 1ns / 1ps

`include "defines.vh"

module DCache (
    input  wire         cpu_rstn,       // low active
    input  wire         cpu_clk,
    // Interface to CPU
    input  wire [ 3:0]  data_ren,
    input  wire [31:0]  data_addr,
    input  wire         data_cacheable,
    output wire         data_rready,
    output reg          data_valid,
    output reg  [31:0]  data_rdata,
    input  wire [ 3:0]  data_wen,
    input  wire [31:0]  data_wdata,
    output wire         data_wready,
    output wire         data_wposted,
`ifdef ENABLE_DCACHE
    output wire         data_wresp,
`else
    output reg          data_wresp,
`endif
    // Full cache-line StoreBuffer allocation.  This sideband is optional;
    // the scalar write-through protocol remains unchanged.
    input  wire         line_alloc_valid,
    input  wire [31:0]  line_alloc_addr,
    input  wire [`CACHE_BLK_SIZE-1:0] line_alloc_data,
    input  wire [`CACHE_BLK_LEN-1:0] line_alloc_word_mask,
    output wire         line_alloc_ready,
    // Interface to Write Bus
    input  wire         dev_wrdy,       // device ready to accept a write
    input  wire         dev_wdone,      // write has actually reached the bus
    output reg  [ 3:0]  cpu_wen,        // cpu write enable
    output reg  [31:0]  cpu_waddr,      // cpu write data address
    output reg  [31:0]  cpu_wdata,      // cpu write data
    // Interface to Read Bus
    input  wire         dev_rrdy,       // device ready to be read
    output reg  [ 3:0]  cpu_ren,        // cpu read mask
    output reg  [31:0]  cpu_raddr,      // cpu read data address
    output reg          cpu_rburst,     // 1: eight-beat cache-line refill
    input  wire         dev_rvalid,     // device data valid
    input  wire [31:0]  dev_rdata,      // data to be read

    input  wire         maint_valid,
    output wire         maint_ready,
    output reg          maint_done,
    input  wire         maint_all,
    input  wire [1:0]   maint_mode,
    input  wire [31:0]  maint_addr,
    input  wire [31:0]  maint_ctag
);

`ifdef ENABLE_DCACHE
    localparam INDEX_WID  = $clog2(`CACHE_BLK_NUM);         // 5 bit
    localparam OFFSET_WID = $clog2(`CACHE_BLK_LEN) + 2;     // 5 bit
    localparam TAG_WID    = 32 - INDEX_WID - OFFSET_WID;    // 22 bit
    localparam BLK_WID    = `CACHE_BLK_SIZE + TAG_WID + 1;  // 279 bit
    localparam LINE_WORD_IW = $clog2(`CACHE_BLK_LEN);
    localparam LINE_LAST_WORD = `CACHE_BLK_LEN - 1;

`ifndef SYNTHESIS
    initial begin
        if ((`CACHE_BLK_LEN != 8) || (`CACHE_BLK_SIZE != 256))
            $error("DCache correctness implementation requires an 8-word/32-byte line");
    end
`endif

    // =========================================================
    // 读写状态机参数定义
    // =========================================================
    // 读状态机 (Read FSM)
    localparam R_IDLE     = 3'd0;
    localparam R_TAG_CHK  = 3'd1;
    localparam R_RD_MEM   = 3'd2;
    localparam R_REFILL   = 3'd3;
    localparam R_UNC_REQ  = 3'd4; // Uncached 读请求
    localparam R_UNC_WAIT = 3'd5; // Uncached 读等待

    // 写状态机 (Write FSM)
    localparam W_IDLE     = 3'd0;
    localparam W_TAG_CHK  = 3'd1;
    localparam W_WR_MEM   = 3'd2; // Write-Through 直接写主存/外设
    localparam W_WR_WAIT  = 3'd3; 

    // Maintenance state values must be declared before any combinational
    // ready/accept logic references them.
    localparam M_IDLE     = 3'd0;
    localparam M_LOOKUP   = 3'd1;
    localparam M_APPLY    = 3'd2;
    localparam M_ALL      = 3'd3;
    localparam M_DONE     = 3'd4;

    reg [2:0] r_state, r_nstat;
    reg [2:0] w_state, w_nstat;
    reg [2:0] maint_state;
    reg [LINE_WORD_IW-1:0] recv_cnt;
    reg [255:0] cache_line_data;
    reg [255:0] refill_commit_data;

    // =========================================================
    // 1. 请求锁存与地址分解
    // =========================================================
    // 为了防止流水线信号在等待总线时丢失，第一时间锁存所有请求
    reg [31:0] req_addr_r;
    reg [ 3:0] req_ren_r;
    reg [ 3:0] req_wen_r;
    reg [31:0] req_wdata_r;
    reg        req_cacheable_r;
    wire refill_commit = (r_state == R_REFILL) && dev_rvalid &&
                         (recv_cnt == LINE_LAST_WORD) && req_cacheable_r;
    reg [`CACHE_BLK_NUM-1:0] line_enabled0;
    reg [`CACHE_BLK_NUM-1:0] line_enabled1;
    reg [`CACHE_BLK_NUM-1:0] replace_way;
    reg                      refill_way_r;

    wire is_idle = (r_state == R_IDLE && w_state == W_IDLE) &&
                   !data_valid && !data_wresp;
    wire has_req = (|data_ren) || (|data_wen);
    wire incoming_uncached = !data_cacheable ||
                             (data_addr[31:16] == 16'hBFAF) ||
                             (data_addr[31:16] == 16'hBFD0);

    // Address decomposition is placed before victim/allocation probes so
    // Vivado does not treat these nets as implicit undeclared identifiers.
    wire [INDEX_WID-1:0] cache_index = is_idle ? data_addr[INDEX_WID+OFFSET_WID-1 : OFFSET_WID]
                                                : req_addr_r[INDEX_WID+OFFSET_WID-1 : OFFSET_WID];
    wire [TAG_WID-1:0]   tag_from_cpu = req_addr_r[31 : INDEX_WID+OFFSET_WID];
    wire [OFFSET_WID-1:0] offset = req_addr_r[OFFSET_WID-1 : 0];
    wire uncached = !req_cacheable_r ||
                    (req_addr_r[31:16] == 16'hBFAF) ||
                    (req_addr_r[31:16] == 16'hBFD0);
    // Full-line allocation is intentionally disabled in this correctness
    // phase.  Keep the wrapper sideband quiescent.
    assign line_alloc_ready = 1'b0;
    assign data_wready = is_idle;
    // A cacheable store is owned by this request slot once accepted. MMIO
    // remains strongly ordered and reports completion only after the bus ACK.
    assign data_wposted = is_idle && (|data_wen) && !incoming_uncached;
    // The LSU samples the response on the same clock edge that the write
    // state machine leaves W_WR_WAIT.  A registered pulse would only become
    // visible after that edge and would therefore be missed by the LSU.
    assign data_wresp = (w_state == W_WR_WAIT) && dev_wdone;

    always @(posedge cpu_clk or negedge cpu_rstn) begin
        if (!cpu_rstn) begin
            req_addr_r <= 0; req_ren_r <= 0; req_wen_r <= 0; req_wdata_r <= 0;
            req_cacheable_r <= 1'b0;
        end else if (is_idle && has_req) begin
            req_addr_r  <= data_addr;
            req_ren_r   <= data_ren;
            req_wen_r   <= data_wen;
            req_wdata_r <= data_wdata;
            req_cacheable_r <= data_cacheable;
        end
    end

    // =========================================================
    // 2. Cache 块数据解析与命中判定
    // =========================================================
    wire [BLK_WID-1:0] cache_line_r0;
    wire [BLK_WID-1:0] cache_line_r1;
    wire               valid_bit0 = cache_line_r0[BLK_WID-1];
    wire               valid_bit1 = cache_line_r1[BLK_WID-1];
    wire [TAG_WID-1:0] tag_from_cache0 = cache_line_r0[BLK_WID-2 : `CACHE_BLK_SIZE];
    wire [TAG_WID-1:0] tag_from_cache1 = cache_line_r1[BLK_WID-2 : `CACHE_BLK_SIZE];

    // Uncached 请求强制按 Miss 处理，保护 BRAM 数据不被污染
    wire hit0 = valid_bit0 && line_enabled0[cache_index] &&
                (tag_from_cache0 == tag_from_cpu) && !uncached;
    wire hit1 = valid_bit1 && line_enabled1[cache_index] &&
                (tag_from_cache1 == tag_from_cpu) && !uncached;
    wire hit = hit0 || hit1;
    wire hit_way = hit0 ? 1'b0 : 1'b1;
    wire [BLK_WID-1:0] selected_cache_line = hit0 ? cache_line_r0 : cache_line_r1;
    wire [TAG_WID-1:0] selected_cache_tag = selected_cache_line[BLK_WID-2 : `CACHE_BLK_SIZE];
    wire miss_way = (!valid_bit0 || !line_enabled0[cache_index]) ? 1'b0 :
                    ((!valid_bit1 || !line_enabled1[cache_index]) ? 1'b1 :
                     replace_way[cache_index]);
    assign data_rready = is_idle;
    wire hit_r = (r_state == R_TAG_CHK) && hit;
    wire hit_w = (w_state == W_TAG_CHK) && hit;

    // =========================================================
    // 3. DCache 读状态机 (Read FSM)
    // =========================================================
    always @(posedge cpu_clk or negedge cpu_rstn) begin
        if (!cpu_rstn) r_state <= R_IDLE;
        else           r_state <= r_nstat;
    end

    always @(*) begin
        case(r_state)
            R_IDLE: begin
                if (|data_ren && is_idle) begin
                    // 第一时间检测是否为 Uncached 地址
                    if (!data_cacheable ||
                        (data_addr[31:16] == 16'hBFAF) ||
                        (data_addr[31:16] == 16'hBFD0)) r_nstat = R_UNC_REQ;
                    else                                r_nstat = R_TAG_CHK;
                end else r_nstat = R_IDLE;
            end
            
            R_TAG_CHK:  r_nstat = hit_r ? R_IDLE : R_RD_MEM;
            R_RD_MEM:   r_nstat = dev_rrdy ? R_REFILL : R_RD_MEM;
            // The requested word is returned as soon as its refill beat
            // arrives; the remaining beats continue filling the selected way.
            R_REFILL:   r_nstat = (dev_rvalid && recv_cnt == LINE_LAST_WORD) ? R_IDLE : R_REFILL;
            
            // The read bridge response is transferred with a synchronized
            // event and may arrive on the same cpu_clk edge that accepts the
            // request.  Consume it in R_UNC_REQ as well as R_UNC_WAIT;
            // otherwise the FSM enters WAIT after the only response pulse
            // and can remain there forever.
            R_UNC_REQ:  r_nstat = dev_rvalid ? R_IDLE :
                                   (dev_rrdy ? R_UNC_WAIT : R_UNC_REQ);
            R_UNC_WAIT: r_nstat = dev_rvalid ? R_IDLE : R_UNC_WAIT;
            default:    r_nstat = R_IDLE;
        endcase
    end

    // =========================================================
    // 4. DCache 写状态机 (Write FSM)
    // =========================================================
    always @(posedge cpu_clk or negedge cpu_rstn) begin
        if (!cpu_rstn) w_state <= W_IDLE;
        else           w_state <= w_nstat;
    end

    always @(*) begin
        case(w_state)
            W_IDLE:     w_nstat = (|data_wen && is_idle) ? W_TAG_CHK : W_IDLE;
            // Write-Through策略：无论Hit/Miss，接下来都必须写主存 (Uncached也会安全走到这里)
            W_TAG_CHK:  w_nstat = W_WR_MEM; 
            W_WR_MEM:   w_nstat = dev_wrdy ? W_WR_WAIT : W_WR_MEM;
            W_WR_WAIT:  w_nstat = dev_wdone ? W_IDLE : W_WR_WAIT; // 等待总线真正完成
            default:    w_nstat = W_IDLE;
        endcase
    end

    // =========================================================
    // 5. 数据重填 (REFILL) 与 Cache 更新逻辑
    // =========================================================
    // The refill bus may return the requested word first.  The three-bit
    // addition naturally wraps within the eight-word cache line.
    wire [LINE_WORD_IW-1:0] refill_word_sel =
        req_addr_r[OFFSET_WID-1:2] + recv_cnt;

    always @(posedge cpu_clk or negedge cpu_rstn) begin
        if (!cpu_rstn) recv_cnt <= 0;
        else if (r_state == R_REFILL && dev_rvalid) recv_cnt <= recv_cnt + 1;
    end

    always @(posedge cpu_clk or negedge cpu_rstn) begin
        if (!cpu_rstn) cache_line_data <= 0;
        else if (r_state == R_REFILL && dev_rvalid) begin
            case (refill_word_sel)
                3'd0: cache_line_data[31:0]   <= dev_rdata;
                3'd1: cache_line_data[63:32]  <= dev_rdata;
                3'd2: cache_line_data[95:64]  <= dev_rdata;
                3'd3: cache_line_data[127:96] <= dev_rdata;
                3'd4: cache_line_data[159:128]<= dev_rdata;
                3'd5: cache_line_data[191:160]<= dev_rdata;
                3'd6: cache_line_data[223:192]<= dev_rdata;
                3'd7: cache_line_data[255:224]<= dev_rdata;
            endcase
        end
    end

    always @(*) begin
        refill_commit_data = cache_line_data;
        if ((r_state == R_REFILL) && dev_rvalid) begin
            case (refill_word_sel)
                3'd0: refill_commit_data[31:0]    = dev_rdata;
                3'd1: refill_commit_data[63:32]   = dev_rdata;
                3'd2: refill_commit_data[95:64]   = dev_rdata;
                3'd3: refill_commit_data[127:96]  = dev_rdata;
                3'd4: refill_commit_data[159:128] = dev_rdata;
                3'd5: refill_commit_data[191:160] = dev_rdata;
                3'd6: refill_commit_data[223:192] = dev_rdata;
                default: refill_commit_data[255:224] = dev_rdata;
            endcase
        end
    end

    // === 写命中 (Write Hit) 时，利用写掩码更新指定字节 ===
    reg [255:0] updated_data_blk;
    integer i;
    always @(*) begin
        updated_data_blk = selected_cache_line[255:0]; // 默认保留命中路数据
        for (i=0; i<8; i=i+1) begin
            if (offset[OFFSET_WID-1:2] == i) begin
                // 利用动态切片语法精确修改特定字节
                if (req_wen_r[0]) updated_data_blk[i*32 + 0  +: 8] = req_wdata_r[7:0];
                if (req_wen_r[1]) updated_data_blk[i*32 + 8  +: 8] = req_wdata_r[15:8];
                if (req_wen_r[2]) updated_data_blk[i*32 + 16 +: 8] = req_wdata_r[23:16];
                if (req_wen_r[3]) updated_data_blk[i*32 + 24 +: 8] = req_wdata_r[31:24];
            end
        end
    end

    // Cache 写使能：读重填结束，或写命中时触发
    wire cache_we = refill_commit || hit_w;
    wire cache_we0 = cache_we &&
                     ((refill_commit ? refill_way_r : hit_way) == 1'b0);
    wire cache_we1 = cache_we &&
                     ((refill_commit ? refill_way_r : hit_way) == 1'b1);
    wire refill_word_valid = (r_state == R_REFILL) && dev_rvalid &&
                              (recv_cnt == {LINE_WORD_IW{1'b0}});

    always @(posedge cpu_clk or negedge cpu_rstn) begin
        if (!cpu_rstn) begin
            refill_way_r <= 1'b0;
        end else begin
            if ((r_state == R_TAG_CHK) && !hit) begin
                refill_way_r <= miss_way;
            end
        end
    end

    // 待写入的 Cache 块拼接
    wire [BLK_WID-1:0] cache_line_w = (w_state == W_TAG_CHK) ?
                                      {1'b1, selected_cache_tag, updated_data_blk} : // Hit: 写回修改后的整块
                                       {1'b1, tag_from_cpu, refill_commit_data}; // Miss: 拼装主存数据

    // =========================================================
    // 6. 输出信号生成 (规避 concurrent assignment 报错)
    // =========================================================
    
    // 6.1 面向 CPU 的读返回信号。命中数据和外设数据都先寄存，避免
    // BRAM/tag/word-select 组合路径直接进入流水线全局暂停与写回网络。
    reg [31:0] hit_rdata;
    always @(*) begin
        case (offset[OFFSET_WID-1:2])
            3'd0: hit_rdata = selected_cache_line[31:0];
            3'd1: hit_rdata = selected_cache_line[63:32];
            3'd2: hit_rdata = selected_cache_line[95:64];
            3'd3: hit_rdata = selected_cache_line[127:96];
            3'd4: hit_rdata = selected_cache_line[159:128];
            3'd5: hit_rdata = selected_cache_line[191:160];
            3'd6: hit_rdata = selected_cache_line[223:192];
            default: hit_rdata = selected_cache_line[255:224];
        endcase
    end

    always @(posedge cpu_clk or negedge cpu_rstn) begin
        if (!cpu_rstn) begin
            data_valid <= 1'b0;
            data_rdata <= 32'h0;
        end else begin
            data_valid <= 1'b0;

            if (refill_word_valid) begin
                data_valid <= 1'b1;
                data_rdata <= dev_rdata;
            end else if (hit_r) begin
                data_valid <= 1'b1;
                data_rdata <= hit_rdata;
            end else if ((r_state == R_UNC_REQ || r_state == R_UNC_WAIT) &&
                         dev_rvalid) begin
                data_valid <= 1'b1;
                data_rdata <= dev_rdata;
            end
        end
    end

    // 6.2 面向 读总线 的信号
    always @(*) begin
        cpu_ren   = 4'h0;
        cpu_raddr = 32'h0;
        cpu_rburst = 1'b0;
        if (r_state == R_RD_MEM && dev_rrdy) begin
            cpu_ren   = 4'b1111;
            // Send the demanded word address.  The read bridge performs a
            // line-wrapped burst so the critical word is returned first.
            cpu_raddr = {req_addr_r[31:2], 2'b00};
            cpu_rburst = 1'b1;
        end else if (r_state == R_UNC_REQ && dev_rrdy) begin
            cpu_ren   = req_ren_r;
            cpu_raddr = req_addr_r; // 保持原精确地址
        end
    end

    // 6.3 面向 CPU 和 写总线 的写出信号 
    // =========================================================
    // 【核心修复2】：摒弃组合逻辑，恢复成寄存器打拍输出，严格对齐时钟沿
    always @(posedge cpu_clk or negedge cpu_rstn) begin
        if (!cpu_rstn) begin
            cpu_wen    <= 4'h0;
            cpu_waddr  <= 32'h0;
            cpu_wdata  <= 32'h0;
        end else begin
            // 严格遵循图2-13：在进入 W_WR_MEM 且总线就绪的下一拍，打出写使能
            if (w_state == W_WR_MEM && dev_wrdy) begin
                cpu_wen   <= req_wen_r;
                cpu_waddr <= req_addr_r;
                cpu_wdata <= req_wdata_r;
            end else begin
                cpu_wen   <= 4'h0;
            end
            
        end
    end

`ifndef SYNTHESIS
    // The bus write address must remain the address captured when this Store
    // entered the DCache request slot.  This catches accidental line/index
    // reconstruction and stale-request reuse.
    always @(posedge cpu_clk) begin
        if (cpu_rstn && (cpu_wen != 4'h0) &&
            (cpu_waddr !== req_addr_r))
            $error("DCache cpu_waddr differs from latched Store address");
        // Older unit benches omit the optional sideband port, leaving it
        // floating.  Treat only an asserted 1 as a protocol violation.
        if (cpu_rstn && (line_alloc_valid === 1'b1))
            $error("DCache line allocation must remain disabled");
    end
`endif
    // =========================================================
    // 7. CACOP maintenance and BRAM port arbitration
    // =========================================================
    reg [INDEX_WID-1:0] maint_index_r;
    reg [INDEX_WID-1:0] maint_count;
    reg [TAG_WID-1:0] maint_tag_r;
    reg [1:0] maint_mode_r;
    reg [31:0] maint_ctag_r;

    wire maint_active = (maint_state != M_IDLE);
    // CACOP 0x01 is index invalidate.  CACOP 0x09 selects mode01 below;
    // because this D-cache is write-through and has no dirty state, clearing
    // valid is architecturally sufficient for writeback-invalidate.
    wire [INDEX_WID-1:0] bram_index = maint_active ?
                                         maint_index_r : cache_index;
    assign maint_ready = (maint_state == M_IDLE) && is_idle && !has_req &&
                         1'b1;

    always @(posedge cpu_clk or negedge cpu_rstn) begin
        if (!cpu_rstn) begin
            maint_state <= M_IDLE;
            maint_index_r <= {INDEX_WID{1'b0}};
            maint_count <= {INDEX_WID{1'b0}};
            maint_tag_r <= {TAG_WID{1'b0}};
            maint_mode_r <= 2'b00;
            maint_ctag_r <= 32'h0;
            line_enabled0 <= {`CACHE_BLK_NUM{1'b0}};
            line_enabled1 <= {`CACHE_BLK_NUM{1'b0}};
            replace_way <= {`CACHE_BLK_NUM{1'b0}};
            maint_done <= 1'b0;
        end else begin
            maint_done <= 1'b0;
            if (refill_commit) begin
                if (refill_way_r == 1'b0)
                    line_enabled0[cache_index] <= 1'b1;
                else
                    line_enabled1[cache_index] <= 1'b1;
                replace_way[cache_index] <= ~refill_way_r;
            end
            if (hit_r || hit_w)
                replace_way[cache_index] <= ~hit_way;

            case (maint_state)
                M_IDLE: begin
                    if (maint_valid && maint_ready) begin
                        maint_index_r <= maint_addr[INDEX_WID+OFFSET_WID-1:OFFSET_WID];
                        maint_tag_r <= maint_addr[31:INDEX_WID+OFFSET_WID];
                        maint_mode_r <= maint_mode;
                        maint_ctag_r <= maint_ctag;
                        maint_count <= {INDEX_WID{1'b0}};
                        if (maint_all)
                            maint_state <= M_ALL;
                        else if ((maint_mode == 2'b10) || (maint_mode == 2'b00))
                            maint_state <= M_LOOKUP;
                        else
                            maint_state <= M_APPLY;
                    end
                end
                M_LOOKUP: maint_state <= M_APPLY;
                M_APPLY: begin
                    case (maint_mode_r)
                        2'b00: begin
                            line_enabled0[maint_index_r] <= 1'b0;
                            line_enabled1[maint_index_r] <= 1'b0;
                        end
                        2'b01: begin
                            line_enabled0[maint_index_r] <= 1'b0;
                            line_enabled1[maint_index_r] <= 1'b0;
                        end
                        2'b10: begin
                            if (valid_bit0 && line_enabled0[maint_index_r] &&
                                (tag_from_cache0 == maint_tag_r))
                                line_enabled0[maint_index_r] <= 1'b0;
                            if (valid_bit1 && line_enabled1[maint_index_r] &&
                                (tag_from_cache1 == maint_tag_r))
                                line_enabled1[maint_index_r] <= 1'b0;
                        end
                        default: begin end
                    endcase
                    maint_state <= M_DONE;
                end
                M_ALL: begin
                    line_enabled0[maint_count] <= 1'b0;
                    line_enabled1[maint_count] <= 1'b0;
                    if (maint_count == `CACHE_BLK_NUM-1)
                        maint_state <= M_DONE;
                    else
                        maint_count <= maint_count + 1'b1;
                end
                M_DONE: begin
                    maint_done <= 1'b1;
                    maint_state <= M_IDLE;
                end
                default: maint_state <= M_IDLE;
            endcase
        end
    end

    // =========================================================
    // 8. BRAM instance (single-port read/write sharing)
    // =========================================================
    blk_mem_gen_0 U_dsram_way0 (
        .clka   (cpu_clk),
        .wea    (cache_we0),
        .addra  (bram_index),
        .dina   (cache_line_w),
        .douta  (cache_line_r0)
    );
    blk_mem_gen_0 U_dsram_way1 (
        .clka   (cpu_clk),
        .wea    (cache_we1),
        .addra  (bram_index),
        .dina   (cache_line_w),
        .douta  (cache_line_r1)
    );

`ifndef SYNTHESIS
    reg [31:0] w_wait_cnt;
    always @(posedge cpu_clk or negedge cpu_rstn) begin
        if (!cpu_rstn) w_wait_cnt <= 0;
        else if (w_state == W_WR_WAIT) w_wait_cnt <= w_wait_cnt + 1;
        else w_wait_cnt <= 0;
    end
    always @(posedge cpu_clk) begin
        if (cpu_rstn && w_wait_cnt > 100) begin
            $display("[T=%0t] DCache watchdog timeout! w_state=%d, req_addr_r=%h, dev_wdone=%b", $time, w_state, req_addr_r, dev_wdone);
            $fatal(1, "W_WR_WAIT watchdog");
        end
    end
`endif

`else

    assign line_alloc_ready = 1'b0;
    assign maint_ready = 1'b1;
    always @(*) maint_done = maint_valid;

    localparam SB_DEPTH = 4;
    localparam SB_PTR_W = 2;

    reg [ 3:0] sb_wen   [SB_DEPTH-1:0];
    reg [31:0] sb_addr  [SB_DEPTH-1:0];
    reg [31:0] sb_wdata [SB_DEPTH-1:0];
    reg [SB_PTR_W-1:0] sb_rptr;
    reg [SB_PTR_W-1:0] sb_wptr;
    reg [SB_PTR_W:0]   sb_count;
    reg                sb_drain_busy;

    wire sb_empty = (sb_count == 0);
    wire sb_full  = (sb_count == SB_DEPTH);

    function is_peripheral;
        input [31:0] addr;
        begin
            is_peripheral = (addr[31:16] == 16'hBFAF) ||
                            (addr[31:16] == 16'hBFD0);
        end
    endfunction

    reg        store_pending;
    reg [ 3:0] store_wen_r;
    reg [31:0] store_addr_r;
    reg [31:0] store_wdata_r;

    wire        store_src_valid = store_pending | (|data_wen);
    wire [ 3:0] store_src_wen   = store_pending ? store_wen_r   : data_wen;
    wire [31:0] store_src_addr  = store_pending ? store_addr_r  : data_addr;
    wire [31:0] store_src_data  = store_pending ? store_wdata_r : data_wdata;
    wire        store_src_peri  = is_peripheral(store_src_addr);

    wire enqueue_store = store_src_valid & !store_src_peri & !sb_full;

    reg [3:0]  sb_forward_mask;
    reg [31:0] sb_forward_data;
    integer sb_i;
    integer sb_b;
    reg [SB_PTR_W-1:0] sb_idx;

    always @(*) begin
        sb_forward_mask = 4'h0;
        sb_forward_data = 32'h0;
        sb_idx = {SB_PTR_W{1'b0}};

        for (sb_i = 0; sb_i < SB_DEPTH; sb_i = sb_i + 1) begin
            if (sb_i < sb_count) begin
                sb_idx = sb_rptr + sb_i;

                if (sb_addr[sb_idx][31:2] == data_addr[31:2]) begin
                    for (sb_b = 0; sb_b < 4; sb_b = sb_b + 1) begin
                        if (sb_wen[sb_idx][sb_b]) begin
                            sb_forward_mask[sb_b] = 1'b1;
                            sb_forward_data[8*sb_b +: 8] = sb_wdata[sb_idx][8*sb_b +: 8];
                        end
                    end
                end
            end
        end
    end

    localparam R_IDLE  = 2'b00;
    localparam R_STAT0 = 2'b01;
    localparam R_STAT1 = 2'b11;
    reg [1:0] r_state, r_nstat;
    reg [3:0] ren_r;
    reg [3:0] read_fwd_mask_r;
    reg [31:0] read_fwd_data_r;

    assign data_rready = (r_state == R_IDLE);
    assign data_wready = !store_pending;
    assign data_wposted = !store_pending && !sb_full &&
                          !is_peripheral(data_addr);

    wire read_forward_full = (sb_forward_mask == 4'hF) & (|data_ren);
    wire [31:0] read_merged_data = {
        read_fwd_mask_r[3] ? read_fwd_data_r[31:24] : dev_rdata[31:24],
        read_fwd_mask_r[2] ? read_fwd_data_r[23:16] : dev_rdata[23:16],
        read_fwd_mask_r[1] ? read_fwd_data_r[15: 8] : dev_rdata[15: 8],
        read_fwd_mask_r[0] ? read_fwd_data_r[ 7: 0] : dev_rdata[ 7: 0]
    };

    always @(posedge cpu_clk or negedge cpu_rstn) begin
        r_state <= !cpu_rstn ? R_IDLE : r_nstat;
    end

    always @(*) begin
        case (r_state)
            R_IDLE:  r_nstat = (|data_ren) ? (read_forward_full ? R_IDLE :
                                               (dev_rrdy ? R_STAT1 : R_STAT0)) : R_IDLE;
            R_STAT0: r_nstat = dev_rrdy ? R_STAT1 : R_STAT0;
            R_STAT1: r_nstat = dev_rvalid ? R_IDLE : R_STAT1;
            default: r_nstat = R_IDLE;
        endcase
    end

    always @(posedge cpu_clk or negedge cpu_rstn) begin
        if (!cpu_rstn) begin
            data_valid <= 1'b0;
            cpu_ren    <= 4'h0;
            cpu_raddr  <= 32'h0;
            cpu_rburst <= 1'b0;
            read_fwd_mask_r <= 4'h0;
            read_fwd_data_r <= 32'h0;
        end else begin
            cpu_rburst <= 1'b0;
            case (r_state)
                R_IDLE: begin
                    data_valid <= 1'b0;

                    if (|data_ren) begin
                        read_fwd_mask_r <= sb_forward_mask;
                        read_fwd_data_r <= sb_forward_data;

                        if (read_forward_full) begin
                            data_valid <= 1'b1;
                            data_rdata <= sb_forward_data;
                            cpu_ren    <= 4'h0;
                        end
                        else if (dev_rrdy) begin
                            cpu_ren <= data_ren;
                        end
                        else begin
                            ren_r   <= data_ren;
                        end

                        cpu_raddr <= data_addr;
                    end else
                        cpu_ren   <= 4'h0;
                end
                R_STAT0: begin
                    cpu_ren    <= dev_rrdy ? ren_r : 4'h0;
                end   
                R_STAT1: begin
                    cpu_ren    <= 4'h0;
                    data_valid <= dev_rvalid ? 1'b1 : 1'b0;
                    data_rdata <= dev_rvalid ? read_merged_data : 32'h0;
                end
                default: begin
                    data_valid <= 1'b0;
                    cpu_ren    <= 4'h0;
                end 
            endcase
        end
    end

    localparam W_IDLE  = 2'b00;
    localparam W_STAT0 = 2'b01;
    localparam W_STAT1 = 2'b11;
    reg  [1:0] w_state, w_nstat;
    reg  [3:0] mmio_wen_r;
    reg [31:0] mmio_addr_r;
    reg [31:0] mmio_wdata_r;
    wire       wr_resp = dev_wrdy & (cpu_wen == 4'h0) ? 1'b1 : 1'b0;
    wire       start_mmio_store = (w_state == W_IDLE) &
                                  store_src_valid &
                                  store_src_peri &
                                  sb_empty;

    always @(posedge cpu_clk or negedge cpu_rstn) begin
        w_state <= !cpu_rstn ? W_IDLE : w_nstat;
    end

    always @(*) begin
        case (w_state)
            W_IDLE:  w_nstat = start_mmio_store ? (dev_wrdy ? W_STAT1 : W_STAT0) : W_IDLE;
            W_STAT0: w_nstat = dev_wrdy ? W_STAT1 : W_STAT0;
            W_STAT1: w_nstat = wr_resp ? W_IDLE : W_STAT1;
            default: w_nstat = W_IDLE;
        endcase
    end

    wire drain_start = !sb_empty &
                       !sb_drain_busy &
                       dev_wrdy &
                       (w_state == W_IDLE) &
                       !store_src_peri;
    wire drain_done  = sb_drain_busy & dev_wrdy & (cpu_wen == 4'h0);
    wire [SB_PTR_W:0] sb_count_next =
        sb_count + { {SB_PTR_W{1'b0}}, enqueue_store } -
                   { {SB_PTR_W{1'b0}}, drain_done    };

    always @(posedge cpu_clk or negedge cpu_rstn) begin
        if (!cpu_rstn) begin
            data_wresp <= 1'b0;
            cpu_wen    <= 4'h0;
            cpu_waddr  <= 32'h0;
            cpu_wdata  <= 32'h0;
            sb_rptr    <= {SB_PTR_W{1'b0}};
            sb_wptr    <= {SB_PTR_W{1'b0}};
            sb_count   <= {(SB_PTR_W+1){1'b0}};
            sb_drain_busy <= 1'b0;
            store_pending <= 1'b0;
            store_wen_r   <= 4'h0;
            store_addr_r  <= 32'h0;
            store_wdata_r <= 32'h0;
            mmio_wen_r    <= 4'h0;
            mmio_addr_r   <= 32'h0;
            mmio_wdata_r  <= 32'h0;
        end else begin
            data_wresp <= 1'b0;
            cpu_wen    <= 4'h0;

            if (enqueue_store) begin
                sb_wen  [sb_wptr] <= store_src_wen;
                sb_addr [sb_wptr] <= store_src_addr;
                sb_wdata[sb_wptr] <= store_src_data;
                sb_wptr <= sb_wptr + 1'b1;
                data_wresp <= 1'b1;

                if (store_pending)
                    store_pending <= 1'b0;
            end
            else if ((|data_wen) && !store_pending && !start_mmio_store) begin
                store_pending <= 1'b1;
                store_wen_r   <= data_wen;
                store_addr_r  <= data_addr;
                store_wdata_r <= data_wdata;
            end

            if (drain_start) begin
                cpu_wen   <= sb_wen[sb_rptr];
                cpu_waddr <= sb_addr[sb_rptr];
                cpu_wdata <= sb_wdata[sb_rptr];
                sb_drain_busy <= 1'b1;
            end

            if (drain_done) begin
                sb_rptr   <= sb_rptr + 1'b1;
                sb_drain_busy <= 1'b0;
            end

            sb_count <= sb_count_next;

            case (w_state)
                W_IDLE: begin
                    if (start_mmio_store) begin
                        mmio_wen_r   <= store_src_wen;
                        mmio_addr_r  <= store_src_addr;
                        mmio_wdata_r <= store_src_data;

                        if (dev_wrdy) begin
                            cpu_wen   <= store_src_wen;
                            cpu_waddr <= store_src_addr;
                            cpu_wdata <= store_src_data;
                        end

                        if (store_pending)
                            store_pending <= 1'b0;
                    end
                end
                W_STAT0: begin
                    if (dev_wrdy) begin
                        cpu_wen   <= mmio_wen_r;
                        cpu_waddr <= mmio_addr_r;
                        cpu_wdata <= mmio_wdata_r;
                    end
                end
                W_STAT1: begin
                    data_wresp <= wr_resp ? 1'b1 : 1'b0;
                end
                default: begin
                    data_wresp <= 1'b0;
                end
            endcase
        end
    end

`endif

endmodule
