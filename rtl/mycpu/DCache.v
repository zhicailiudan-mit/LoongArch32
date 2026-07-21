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
    reg [2:0] recv_cnt;
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
    reg        line_alloc_pending;
    reg [31:0] line_alloc_addr_r;
    reg [`CACHE_BLK_SIZE-1:0] line_alloc_data_r;
    reg [`CACHE_BLK_LEN-1:0] line_alloc_word_mask_r;
    wire refill_commit = (r_state == R_REFILL) && dev_rvalid &&
                         (recv_cnt == 7) && req_cacheable_r;
    reg [`CACHE_BLK_NUM-1:0] line_enabled0;
    reg [`CACHE_BLK_NUM-1:0] line_enabled1;
    reg [`CACHE_BLK_NUM-1:0] replace_way;
    reg                      refill_way_r;
    reg                      refill_response_sent;
    reg                      hm_probe_valid;
    reg [31:0]               hm_probe_addr;
    reg                      hm_response_pending;
    reg [31:0]               hm_response_data;
    // Per-word validity for the line currently being refilled.  A secondary
    // request to that line waits for its own word instead of allocating a
    // second miss transaction.
    reg [7:0]                 refill_word_valid_mask;
    // One-entry victim buffer.  The current DCache is write-through, so the
    // victim is clean; it is used to avoid an SRAM refill when a recently
    // evicted line is requested again.
    reg                      victim_valid;
    reg [INDEX_WID-1:0]      victim_index;
    reg [TAG_WID-1:0]        victim_tag;
    reg [`CACHE_BLK_SIZE-1:0] victim_data;

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
    wire hm_window = (r_state == R_REFILL) && (w_state == W_IDLE) &&
                     !data_valid && !data_wresp && !hm_response_pending;

    wire victim_hit = (r_state == R_TAG_CHK) && !uncached &&
                      victim_valid && (victim_index == cache_index) &&
                      (victim_tag == tag_from_cpu);
    wire line_alloc_accept = line_alloc_valid && line_alloc_ready;
    wire line_alloc_commit = line_alloc_pending && is_idle &&
                             (maint_state == M_IDLE);
    assign line_alloc_ready = is_idle && !line_alloc_pending &&
                              (maint_state == M_IDLE);
    // A full-line allocation owns the DCache write port for this cycle.
    assign data_wready = is_idle && !line_alloc_valid && !line_alloc_pending;
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
            line_alloc_pending <= 1'b0;
            line_alloc_addr_r <= 32'h0;
            line_alloc_data_r <= 0;
            line_alloc_word_mask_r <= 0;
        end else if (is_idle && has_req) begin
            req_addr_r  <= data_addr;
            req_ren_r   <= data_ren;
            req_wen_r   <= data_wen;
            req_wdata_r <= data_wdata;
            req_cacheable_r <= data_cacheable;
        end else begin
            if (line_alloc_accept) begin
                line_alloc_pending <= 1'b1;
                line_alloc_addr_r <= line_alloc_addr;
                line_alloc_data_r <= line_alloc_data;
                line_alloc_word_mask_r <= line_alloc_word_mask;
            end else if (line_alloc_commit) begin
                line_alloc_pending <= 1'b0;
            end
        end
    end

    // 主存地址分解已在请求锁存区前置定义，保证第1拍即可驱动 BRAM。
    wire [INDEX_WID-1:0] alloc_index = line_alloc_pending ?
                                       line_alloc_addr_r[INDEX_WID+OFFSET_WID-1:OFFSET_WID] :
                                       cache_index;
    wire [TAG_WID-1:0] alloc_tag = line_alloc_pending ?
                                    line_alloc_addr_r[31:INDEX_WID+OFFSET_WID] :
                                    tag_from_cpu;

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
    wire alloc_hit0 = valid_bit0 && line_enabled0[alloc_index] &&
                      (tag_from_cache0 == alloc_tag);
    wire alloc_hit1 = valid_bit1 && line_enabled1[alloc_index] &&
                      (tag_from_cache1 == alloc_tag);
    wire alloc_way = alloc_hit0 ? 1'b0 :
                     alloc_hit1 ? 1'b1 :
                     ((!valid_bit0 || !line_enabled0[alloc_index]) ? 1'b0 :
                      ((!valid_bit1 || !line_enabled1[alloc_index]) ? 1'b1 :
                       replace_way[alloc_index]));
    wire alloc_source_valid = alloc_way ?
                              (valid_bit1 && line_enabled1[alloc_index]) :
                              (valid_bit0 && line_enabled0[alloc_index]);
    wire [TAG_WID-1:0] alloc_source_tag = alloc_way ? tag_from_cache1 : tag_from_cache0;
    wire [`CACHE_BLK_SIZE-1:0] alloc_source_data = alloc_way ?
                                                    cache_line_r1[`CACHE_BLK_SIZE-1:0] :
                                                    cache_line_r0[`CACHE_BLK_SIZE-1:0];
    wire [BLK_WID-1:0] cache_line_hm0;
    wire [BLK_WID-1:0] cache_line_hm1;
    wire cache_hm_valid0 = cache_line_hm0[BLK_WID-1];
    wire cache_hm_valid1 = cache_line_hm1[BLK_WID-1];
    wire [TAG_WID-1:0] cache_hm_tag0 = cache_line_hm0[BLK_WID-2 : `CACHE_BLK_SIZE];
    wire [TAG_WID-1:0] cache_hm_tag1 = cache_line_hm1[BLK_WID-2 : `CACHE_BLK_SIZE];
    wire [INDEX_WID-1:0] hm_index = data_addr[INDEX_WID+OFFSET_WID-1:OFFSET_WID];
    wire [TAG_WID-1:0] hm_tag = data_addr[31:INDEX_WID+OFFSET_WID];
    wire hm_probe_match = hm_window && hm_probe_valid && (|data_ren) &&
                          (data_addr == hm_probe_addr);
    wire hm_hit0 = hm_probe_match && cache_hm_valid0 &&
                   line_enabled0[hm_index] && (cache_hm_tag0 == hm_tag);
    wire hm_hit1 = hm_probe_match && cache_hm_valid1 &&
                   line_enabled1[hm_index] && (cache_hm_tag1 == hm_tag);
    wire hm_refill_line_match = hm_probe_match &&
                                 (hm_probe_addr[31:5] == req_addr_r[31:5]);
    wire hm_refill_hit = hm_refill_line_match &&
                         refill_word_valid_mask[hm_probe_addr[4:2]];
    wire hm_hit = hm_hit0 || hm_hit1 || hm_refill_hit;
    assign data_rready = is_idle || hm_hit || victim_hit;
    always @(posedge cpu_clk or negedge cpu_rstn) begin
        if (!cpu_rstn) begin
            hm_probe_valid <= 1'b0;
            hm_probe_addr <= 32'h0;
        end else if (hm_window && (|data_ren) && !hm_hit) begin
            hm_probe_valid <= 1'b1;
            hm_probe_addr <= data_addr;
        end else if (!hm_window || hm_hit) begin
            hm_probe_valid <= 1'b0;
        end
    end
    wire [BLK_WID-1:0] hm_selected_line = hm_hit0 ? cache_line_hm0 : cache_line_hm1;
    reg [31:0] hm_hit_rdata;
    always @(*) begin
        if (hm_refill_hit) begin
            case (hm_probe_addr[4:2])
                3'd0: hm_hit_rdata = cache_line_data[31:0];
                3'd1: hm_hit_rdata = cache_line_data[63:32];
                3'd2: hm_hit_rdata = cache_line_data[95:64];
                3'd3: hm_hit_rdata = cache_line_data[127:96];
                3'd4: hm_hit_rdata = cache_line_data[159:128];
                3'd5: hm_hit_rdata = cache_line_data[191:160];
                3'd6: hm_hit_rdata = cache_line_data[223:192];
                default: hm_hit_rdata = cache_line_data[255:224];
            endcase
        end else begin
            case (data_addr[4:2])
                3'd0: hm_hit_rdata = hm_selected_line[31:0];
                3'd1: hm_hit_rdata = hm_selected_line[63:32];
                3'd2: hm_hit_rdata = hm_selected_line[95:64];
                3'd3: hm_hit_rdata = hm_selected_line[127:96];
                3'd4: hm_hit_rdata = hm_selected_line[159:128];
                3'd5: hm_hit_rdata = hm_selected_line[191:160];
                3'd6: hm_hit_rdata = hm_selected_line[223:192];
                default: hm_hit_rdata = hm_selected_line[255:224];
            endcase
        end
    end
    reg [31:0] victim_rdata;
    always @(*) begin
        case (offset[4:2])
            3'd0: victim_rdata = victim_data[31:0];
            3'd1: victim_rdata = victim_data[63:32];
            3'd2: victim_rdata = victim_data[95:64];
            3'd3: victim_rdata = victim_data[127:96];
            3'd4: victim_rdata = victim_data[159:128];
            3'd5: victim_rdata = victim_data[191:160];
            3'd6: victim_rdata = victim_data[223:192];
            default: victim_rdata = victim_data[255:224];
        endcase
    end
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
            
            R_TAG_CHK:  r_nstat = (hit_r || victim_hit) ? R_IDLE : R_RD_MEM;
            R_RD_MEM:   r_nstat = dev_rrdy ? R_REFILL : R_RD_MEM;
            // The requested word is returned as soon as its refill beat
            // arrives; the remaining beats continue filling the selected way.
            R_REFILL:   r_nstat = (dev_rvalid && recv_cnt == 7) ? R_IDLE : R_REFILL;
            
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
    wire [2:0] refill_word_sel = req_addr_r[4:2] + recv_cnt;

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

    always @(posedge cpu_clk or negedge cpu_rstn) begin
        if (!cpu_rstn) begin
            refill_word_valid_mask <= 8'h00;
        end else if ((r_state == R_TAG_CHK) && !hit) begin
            refill_word_valid_mask <= 8'h00;
        end else if ((r_state == R_REFILL) && dev_rvalid) begin
            refill_word_valid_mask[refill_word_sel] <= 1'b1;
        end else if (refill_commit) begin
            refill_word_valid_mask <= 8'h00;
        end
    end

    // === 写命中 (Write Hit) 时，利用写掩码更新指定字节 ===
    reg [255:0] updated_data_blk;
    integer i;
    always @(*) begin
        updated_data_blk = selected_cache_line[255:0]; // 默认保留命中路数据
        for (i=0; i<8; i=i+1) begin
            if (offset[4:2] == i) begin
                // 利用动态切片语法精确修改特定字节
                if (req_wen_r[0]) updated_data_blk[i*32 + 0  +: 8] = req_wdata_r[7:0];
                if (req_wen_r[1]) updated_data_blk[i*32 + 8  +: 8] = req_wdata_r[15:8];
                if (req_wen_r[2]) updated_data_blk[i*32 + 16 +: 8] = req_wdata_r[23:16];
                if (req_wen_r[3]) updated_data_blk[i*32 + 24 +: 8] = req_wdata_r[31:24];
            end
        end
    end

    // Cache 写使能：读重填结束，或写命中时触发
    wire cache_we = refill_commit || hit_w || victim_hit || line_alloc_commit;
    wire cache_we0 = cache_we &&
                     ((refill_commit ? refill_way_r :
                       (line_alloc_commit ? alloc_way :
                        (victim_hit ? miss_way : hit_way))) == 1'b0);
    wire cache_we1 = cache_we &&
                     ((refill_commit ? refill_way_r :
                       (line_alloc_commit ? alloc_way :
                        (victim_hit ? miss_way : hit_way))) == 1'b1);
    wire refill_word_valid = (r_state == R_REFILL) && dev_rvalid &&
                             !refill_response_sent &&
                             (recv_cnt == 3'd0);
`ifndef SYNTHESIS
    // Phase-0/2 observation points. These counters are simulation-only and
    // intentionally do not feed any functional control signal.
    (* keep = "true", mark_debug = "true" *) reg [63:0] perf_dcache_hits;
    (* keep = "true", mark_debug = "true" *) reg [63:0] perf_dcache_misses;
    (* keep = "true", mark_debug = "true" *) reg [63:0] perf_secondary_miss_hits;
    (* keep = "true", mark_debug = "true" *) reg [63:0] perf_hit_under_miss;
    (* keep = "true", mark_debug = "true" *) reg [63:0] perf_critical_word_returns;
    (* keep = "true", mark_debug = "true" *) reg [63:0] perf_refill_cycles;
    (* keep = "true", mark_debug = "true" *) reg [63:0] perf_bus_read_beats;
    always @(posedge cpu_clk or negedge cpu_rstn) begin
        if (!cpu_rstn) begin
            perf_dcache_hits <= 0;
            perf_dcache_misses <= 0;
            perf_secondary_miss_hits <= 0;
            perf_hit_under_miss <= 0;
            perf_critical_word_returns <= 0;
            perf_refill_cycles <= 0;
            perf_bus_read_beats <= 0;
        end else begin
            if (hit_r) perf_dcache_hits <= perf_dcache_hits + 1;
            if ((r_state == R_TAG_CHK) && !hit)
                perf_dcache_misses <= perf_dcache_misses + 1;
            if (hm_window && hm_refill_hit)
                perf_secondary_miss_hits <= perf_secondary_miss_hits + 1;
            if (hm_window && (hm_hit0 || hm_hit1))
                perf_hit_under_miss <= perf_hit_under_miss + 1;
            if (refill_word_valid)
                perf_critical_word_returns <= perf_critical_word_returns + 1;
            if (r_state == R_REFILL)
                perf_refill_cycles <= perf_refill_cycles + 1;
            if ((r_state == R_REFILL) && dev_rvalid)
                perf_bus_read_beats <= perf_bus_read_beats + 1;
        end
    end
`endif

    always @(posedge cpu_clk or negedge cpu_rstn) begin
        if (!cpu_rstn) begin
            refill_way_r <= 1'b0;
            refill_response_sent <= 1'b0;
        end else begin
            if ((r_state == R_TAG_CHK) && !hit) begin
                refill_way_r <= miss_way;
                refill_response_sent <= 1'b0;
            end else if (refill_word_valid) begin
                refill_response_sent <= 1'b1;
            end else if (refill_commit) begin
                refill_response_sent <= 1'b0;
            end
        end
    end

    // Capture the line that is about to be replaced.  A victim hit swaps the
    // cached line into this slot; a direct full-line Store allocation also
    // preserves the evicted clean line for a possible immediate reuse.
    always @(posedge cpu_clk or negedge cpu_rstn) begin
        if (!cpu_rstn) begin
            victim_valid <= 1'b0;
            victim_index <= 0;
            victim_tag <= 0;
            victim_data <= 0;
        end else if (victim_hit) begin
            victim_valid <= (miss_way ?
                             (valid_bit1 && line_enabled1[cache_index]) :
                             (valid_bit0 && line_enabled0[cache_index]));
            victim_index <= cache_index;
            victim_tag <= miss_way ? tag_from_cache1 : tag_from_cache0;
            victim_data <= miss_way ? cache_line_r1[`CACHE_BLK_SIZE-1:0] :
                                      cache_line_r0[`CACHE_BLK_SIZE-1:0];
        end else if (line_alloc_commit) begin
            victim_valid <= alloc_source_valid && !alloc_hit0 && !alloc_hit1;
            victim_index <= alloc_index;
            victim_tag <= alloc_source_tag;
            victim_data <= alloc_source_data;
        end else if ((r_state == R_TAG_CHK) && !hit && !victim_hit) begin
            victim_valid <= (miss_way ?
                             (valid_bit1 && line_enabled1[cache_index]) :
                             (valid_bit0 && line_enabled0[cache_index]));
            victim_index <= cache_index;
            victim_tag <= miss_way ? tag_from_cache1 : tag_from_cache0;
            victim_data <= miss_way ? cache_line_r1[`CACHE_BLK_SIZE-1:0] :
                                      cache_line_r0[`CACHE_BLK_SIZE-1:0];
        end
    end
    
    // 待写入的 Cache 块拼接
    wire [BLK_WID-1:0] cache_line_w = line_alloc_commit ?
                                      {1'b1, alloc_tag, line_alloc_data_r} :
                                      victim_hit ?
                                      {1'b1, victim_tag, victim_data} :
                                      ((w_state == W_TAG_CHK) ?
                                      {1'b1, selected_cache_tag, updated_data_blk} : // Hit: 写回修改后的整块
                                       {1'b1, tag_from_cpu, refill_commit_data}); // Miss: 拼装主存数据

    // =========================================================
    // 6. 输出信号生成 (规避 concurrent assignment 报错)
    // =========================================================
    
    // 6.1 面向 CPU 的读返回信号。命中数据和外设数据都先寄存，避免
    // BRAM/tag/word-select 组合路径直接进入流水线全局暂停与写回网络。
    reg [31:0] hit_rdata;
    always @(*) begin
        case (offset[4:2])
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
            hm_response_pending <= 1'b0;
            hm_response_data <= 32'h0;
        end else begin
            data_valid <= 1'b0;

            if (hm_response_pending) begin
                data_valid <= 1'b1;
                data_rdata <= hm_response_data;
                hm_response_pending <= 1'b0;
            end else if (refill_word_valid) begin
                data_valid <= 1'b1;
                data_rdata <= dev_rdata;
                if (hm_hit) begin
                    hm_response_pending <= 1'b1;
                    hm_response_data <= hm_hit_rdata;
                end
            end else if (hm_hit) begin
                data_valid <= 1'b1;
                data_rdata <= hm_hit_rdata;
            end else if (victim_hit) begin
                data_valid <= 1'b1;
                data_rdata <= victim_rdata;
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
    wire maint_store_we = 1'b0;
    wire bram_we = cache_we | maint_store_we;
    wire [BLK_WID-1:0] maint_line_w = {
        maint_ctag_r[0],
        maint_ctag_r[TAG_WID:1],
        selected_cache_line[`CACHE_BLK_SIZE-1:0]
    };
    wire [BLK_WID-1:0] bram_line_w = maint_store_we ?
                                       maint_line_w : cache_line_w;
    wire [INDEX_WID-1:0] bram_index = maint_active ?
                                         maint_index_r :
                                         (line_alloc_pending ? alloc_index : cache_index);
    wire [INDEX_WID-1:0] hm_bram_index = hm_window ? hm_index : bram_index;
    assign maint_ready = (maint_state == M_IDLE) && is_idle && !has_req &&
                         !line_alloc_pending;

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
            if (line_alloc_commit) begin
                if (alloc_way == 1'b0)
                    line_enabled0[alloc_index] <= 1'b1;
                else
                    line_enabled1[alloc_index] <= 1'b1;
                replace_way[alloc_index] <= ~alloc_way;
            end
            if (victim_hit) begin
                if (miss_way == 1'b0)
                    line_enabled0[cache_index] <= 1'b1;
                else
                    line_enabled1[cache_index] <= 1'b1;
                replace_way[cache_index] <= ~miss_way;
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
    blk_mem_gen_0 U_dsram_hm_way0 (
        .clka   (cpu_clk),
        .wea    (cache_we0),
        .addra  (hm_bram_index),
        .dina   (cache_line_w),
        .douta  (cache_line_hm0)
    );
    blk_mem_gen_0 U_dsram_hm_way1 (
        .clka   (cpu_clk),
        .wea    (cache_we1),
        .addra  (hm_bram_index),
        .dina   (cache_line_w),
        .douta  (cache_line_hm1)
    );

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
