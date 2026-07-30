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
    input  wire         dev_widle,      // write FIFO and bus completely idle
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
    localparam integer WORDS_PER_LINE  = `CACHE_BLK_LEN;
    localparam integer LINE_BITS       = `CACHE_BLK_SIZE;
    localparam integer STORE_FIFO_DEPTH = 4;
    localparam [2:0] STORE_FIFO_CAPACITY = 3'd4;
    localparam integer LOAD_REQ_FIFO_DEPTH = 2;
    localparam [1:0] LOAD_REQ_FIFO_CAPACITY = 2'd2;
    localparam integer ORD_DEPTH = 4;
    localparam [2:0] ORD_CAPACITY = 3'd4;

    // Load response ownership is explicit so adding a new response source
    // cannot silently change the architecturally visible priority.
    localparam [2:0] RESP_NONE                  = 3'd0;
    localparam [2:0] RESP_REFILL_CRITICAL       = 3'd1;
    localparam [2:0] RESP_HUR_SAME_IMMEDIATE    = 3'd2;
    localparam [2:0] RESP_HUR_SAME_TARGET_BEAT  = 3'd3;
    localparam [2:0] RESP_HUR_DIFFERENT_LINE    = 3'd4;
    localparam [2:0] RESP_NORMAL_HIT            = 3'd5;
    localparam [2:0] RESP_UNCACHED              = 3'd6;

    // Explicit owners document the split demand-read and Store/write ports.
    // The same encoding is used on both sides so assertions and diagnostics
    // remain stable as new bank clients are added.
    localparam [3:0] ARRAY_OWNER_IDLE            = 4'd0;
    localparam [3:0] ARRAY_OWNER_MAINT           = 4'd1;
    localparam [3:0] ARRAY_OWNER_UNCACHED_STORE  = 4'd2;
    localparam [3:0] ARRAY_OWNER_REFILL_COMMIT   = 4'd3;
    localparam [3:0] ARRAY_OWNER_STORE_UPDATE    = 4'd4;
    localparam [3:0] ARRAY_OWNER_STORE_TAG       = 4'd5;
    localparam [3:0] ARRAY_OWNER_REPLAY          = 4'd6;
    localparam [3:0] ARRAY_OWNER_LOAD_DIRECT     = 4'd7;
    localparam [3:0] ARRAY_OWNER_LOAD_SKID       = 4'd8;
    localparam [3:0] ARRAY_OWNER_CONTEXT_HOLD    = 4'd9;

`ifndef SYNTHESIS
    initial begin
        if ((`CACHE_BLK_LEN != 8) || (`CACHE_BLK_SIZE != 256))
            $error("DCache correctness implementation requires an 8-word/32-byte line");
    end
`endif

    // Full-line StoreBuffer allocation is intentionally disabled in the
    // current write-through/no-write-allocate design.  Keep the interface
    // tied off explicitly until a future cache architecture owns it.
    assign line_alloc_ready = 1'b0;

    function automatic is_uncached_request;
        input [31:0] addr;
        input        cacheable;
        begin
            is_uncached_request = !cacheable ||
                                  (addr[31:16] == 16'hBFAF) ||
                                  (addr[31:16] == 16'hBFD0);
        end
    endfunction

    function automatic [31:0] select_line_word;
        input [LINE_BITS-1:0] line;
        input [LINE_WORD_IW-1:0] word_index;
        begin
            select_line_word = line[word_index*32 +: 32];
        end
    endfunction

    function automatic [31:0] merge_store_bytes;
        input [31:0] base_word;
        input [3:0]  byte_enable;
        input [31:0] store_data;
        reg   [31:0] merged_word;
        integer byte_idx;
        begin
            merged_word = base_word;
            for (byte_idx = 0; byte_idx < 4; byte_idx = byte_idx + 1)
                if (byte_enable[byte_idx])
                    merged_word[byte_idx*8 +: 8] = store_data[byte_idx*8 +: 8];
            merge_store_bytes = merged_word;
        end
    endfunction

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

    // 写状态机 (Write FSM) - 仅用于 uncached Store 串行控制
    localparam W_IDLE     = 3'd0;
    localparam W_TAG_CHK  = 3'd1;
    localparam W_WR_MEM   = 3'd2;
    localparam W_WR_WAIT  = 3'd3; 

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
    // Explicit MSHR: valid flag living alongside refill context
    // =========================================================
    reg        mshr_valid;
    reg [ 1:0] mshr_slot_id;
    reg        mshr_critical_done;

    // =========================================================
    // Response Order Buffer (4-deep, strictly ordered release)
    // =========================================================
    reg [ 1:0] ord_head;
    reg [ 2:0] ord_count;
    reg [ORD_DEPTH-1:0] ord_valid;
    reg [ORD_DEPTH-1:0] ord_ready;
    reg [31:0] ord_data [0:ORD_DEPTH-1];
    reg [ 1:0] ord_slot_alloc;         // next free slot at read_accept

    // =========================================================
    // Request and miss-context registers
    // =========================================================
    reg [31:0] req_raddr_r;
    reg [ 3:0] req_ren_r;
    reg        req_rcacheable_r;
    reg [ 1:0] req_slot_r;             // ord slot allocated at accept

    // =========================================================
    // 独立 Miss/Refill 上下文与 HUR Replay/Probe 寄存器
    // =========================================================
    reg [31:0] refill_raddr_r;
    reg [ 3:0] refill_ren_r;
    reg        refill_rcacheable_r;

    wire [INDEX_WID-1:0]  refill_index_r  = refill_raddr_r[INDEX_WID+OFFSET_WID-1 : OFFSET_WID];
    wire [TAG_WID-1:0]    refill_tag_r    = refill_raddr_r[31 : INDEX_WID+OFFSET_WID];
    wire [OFFSET_WID-1:0] refill_offset_r = refill_raddr_r[OFFSET_WID-1 : 0];

    reg        replay_pending;
    reg [31:0] replay_raddr_r;
    reg [ 3:0] replay_ren_r;
    reg        replay_rcacheable_r;
    reg [ 1:0] replay_slot_r;
    reg        probe_checking_r;
    reg [7:0]  refill_word_valid_mask;
    // A same-refill-line Load owns its ORD slot while waiting for the target
    // beat.  Track that wait per slot so one future beat does not globally
    // freeze all younger probes and queued requests.
    reg [ORD_DEPTH-1:0] same_wait_valid;
    reg [ 2:0] same_wait_word [0:ORD_DEPTH-1];
    reg [31:0] same_wait_addr [0:ORD_DEPTH-1];
    wire                  same_wait_any = |same_wait_valid;

`ifndef SYNTHESIS
    reg [1:0]  req_fifo_max_occ;
    reg [63:0] engine_busy_enqueue;
    reg [63:0] fifo_full_block;
    reg [63:0] hur_cycle_count;
    reg [63:0] hur_probe_launch_cnt;
    reg [63:0] hur_probe_hit_cnt;
    reg [63:0] hur_probe_replay_cnt;
    reg [63:0] hur_same_line_block_cnt;
    reg [63:0] hur_same_line_probe_cnt;
    reg [63:0] hur_same_line_buffer_hit_cnt;
    reg [63:0] hur_same_line_buffer_wait_cnt;
    reg [63:0] hur_same_line_wait_cycles_cnt;
    reg [63:0] hur_same_line_replay_cnt;
    reg [63:0] mshr_alloc_cnt;
    reg [63:0] mshr_complete_cnt;
    reg [63:0] mshr_active_cycles_cnt;
    reg [63:0] mshr_critical_wait_cycles_cnt;
    reg [63:0] hum_precritical_probe_cnt;
    reg [63:0] hum_precritical_hit_cnt;
    reg [63:0] hum_secondary_miss_cnt;
    reg [63:0] hum_same_set_conflict_cnt;
    reg [63:0] ord_buffered_completion_cnt;
    reg [63:0] ord_release_cnt;
    reg [63:0] ord_full_block_cnt;
    reg [ 2:0] ord_max_occupancy;
`endif

`ifdef ENABLE_DCACHE_NEXTLINE_PREFETCH
    reg [1:0]  pf_confidence;         // 2-bit saturating stream confidence counter (0..3), threshold >= 2
    reg        pf_last_demand_valid;
    reg [26:0] pf_last_demand_line;

    reg        pf_pending_valid;
    reg [26:0] pf_pending_line;
`else
    wire [1:0]  pf_confidence = 2'd0;
    wire        pf_last_demand_valid = 1'b0;
    wire [26:0] pf_last_demand_line = 27'd0;
    wire        pf_pending_valid = 1'b0;
    wire [26:0] pf_pending_line = 27'd0;
`endif

    reg        req_is_prefetch_r;
    reg        mshr_is_prefetch;

`ifndef SYNTHESIS
    reg [63:0] pf_candidate_cnt;
    reg [63:0] pf_pending_overwrite_cnt;
    reg [63:0] pf_tag_launch_cnt;
    reg [63:0] pf_tag_hit_redundant_cnt;
    reg [63:0] pf_tag_miss_cnt;
    reg [63:0] pf_bus_launch_cnt;
    reg [63:0] pf_cancel_cnt;
    reg [63:0] pf_fill_complete_cnt;
    reg [63:0] pf_useful_hit_cnt;
    reg [63:0] pf_useless_evict_cnt;
    reg [63:0] pf_demand_merge_imm_cnt;
    reg [63:0] pf_demand_merge_wait_cnt;
    reg [63:0] pf_blocked_demand_cnt;
    reg [63:0] pf_blocked_req_fifo_cnt;
    reg [63:0] pf_blocked_mshr_cnt;
    reg [63:0] pf_blocked_store_array_cnt;
    reg [63:0] pf_blocked_write_bus_cnt;
    reg [63:0] pf_blocked_maint_cnt;
    reg [63:0] pf_active_cycles_cnt;

    reg [`CACHE_BLK_NUM-1:0] pf_line_way0;
    reg [`CACHE_BLK_NUM-1:0] pf_line_way1;

    // Phase A2: 2-bit Confidence Stream Detector Observational Model
    reg [1:0]  stream_conf;           // 2-bit saturating counter (0..3), threshold >= 2
    reg [26:0] last_miss_line;
    reg        last_miss_valid;

    reg        pf_a2_active;
    reg [26:0] pf_a2_line;
    reg [31:0] pf_a2_timestamp;

    // Per-100k-Cycle Interval Counters
    reg [63:0] interval_demand_miss_cnt;
    reg [63:0] interval_would_launch_cnt;
    reg [63:0] interval_would_useful_cnt;
    reg [63:0] interval_would_wrong_line_cnt;
    reg [63:0] interval_would_cross_4k_cnt;
    reg [63:0] interval_would_uncached_cnt;
    reg [63:0] interval_useful_cycles_sum;
    reg [63:0] interval_wrong_cycles_sum;
    reg [63:0] interval_word_offset_cnt [0:7];

    wire [31:0] a2_curr_addr = {req_raddr_r[31:5], 5'b0};
    wire [31:0] a2_next_addr = a2_curr_addr + 32'd32;
    wire        a2_same_4k   = (a2_curr_addr[31:12] == a2_next_addr[31:12]);
    wire        a2_uncached  = is_uncached_request(a2_next_addr, 1'b1);
    wire        a2_cand_pass = a2_same_4k && !a2_uncached;
`endif

    reg [31:0] req_waddr_r;
    reg [ 3:0] req_wen_r;
    reg [31:0] req_wdata_r;
    reg        req_wcacheable_r;

    // Uncached Store request ownership is kept outside the posted FIFO.
    reg        uncached_store_valid;

    // 4-Entry Parameterized Posted Store FIFO
    reg [31:0]  store_fifo_addr         [0:STORE_FIFO_DEPTH-1];
    reg [ 3:0]  store_fifo_wen          [0:STORE_FIFO_DEPTH-1];
    reg [31:0]  store_fifo_wdata        [0:STORE_FIFO_DEPTH-1];
    reg         store_fifo_cacheable    [0:STORE_FIFO_DEPTH-1];

    reg        store_fifo_tag_checked  [0:STORE_FIFO_DEPTH-1];
    reg        store_fifo_hit          [0:STORE_FIFO_DEPTH-1];
    reg        store_fifo_hit_way      [0:STORE_FIFO_DEPTH-1];
    reg        store_fifo_cache_updated[0:STORE_FIFO_DEPTH-1];
    reg        store_fifo_ext_written  [0:STORE_FIFO_DEPTH-1];

    reg [1:0]  store_fifo_head;
    reg [1:0]  store_fifo_tail;
    reg [2:0]  store_fifo_count;

    reg        store_tag_pending;

    wire refill_commit = (r_state == R_REFILL) && dev_rvalid &&
                         (recv_cnt == LINE_LAST_WORD) && refill_rcacheable_r;
    reg [`CACHE_BLK_NUM-1:0] line_enabled0;
    reg [`CACHE_BLK_NUM-1:0] line_enabled1;
    reg [`CACHE_BLK_NUM-1:0] replace_way;
    reg                      refill_way_r;
    wire maint_active = (maint_state != M_IDLE);
    wire has_req = (|data_ren) || (|data_wen);

    wire incoming_r_uncached = is_uncached_request(data_addr, data_cacheable);
    wire incoming_w_uncached = is_uncached_request(data_addr, data_cacheable);
    wire r_uncached = is_uncached_request(req_raddr_r, req_rcacheable_r);
    wire w_uncached = is_uncached_request(req_waddr_r, req_wcacheable_r);

    // 地址与 Tag/Offset 分解
    wire [INDEX_WID-1:0] r_cache_index = req_raddr_r[INDEX_WID+OFFSET_WID-1 : OFFSET_WID];
    wire [INDEX_WID-1:0] w_cache_index = req_waddr_r[INDEX_WID+OFFSET_WID-1 : OFFSET_WID];

    wire [TAG_WID-1:0]   r_tag_from_cpu = req_raddr_r[31 : INDEX_WID+OFFSET_WID];
    wire [TAG_WID-1:0]   w_tag_from_cpu = req_waddr_r[31 : INDEX_WID+OFFSET_WID];

    wire [OFFSET_WID-1:0] r_offset = req_raddr_r[OFFSET_WID-1 : 0];
    wire [OFFSET_WID-1:0] w_offset = req_waddr_r[OFFSET_WID-1 : 0];

    // =========================================================
    // 2. Cache 块数据解析与 2 项 Store FIFO 逻辑
    // =========================================================
    // Demand/maintenance lookup output (port A of the banked backend).
    reg [TAG_WID:0] cache_meta_r0;
    reg [TAG_WID:0] cache_meta_r1;
    reg [31:0]      cache_word_r0;
    reg [31:0]      cache_word_r1;

    // Posted-Store lookup output (port B when it is not writing).
    reg [TAG_WID:0] store_meta_r0;
    reg [TAG_WID:0] store_meta_r1;

    wire               valid_bit0 = cache_meta_r0[TAG_WID];
    wire               valid_bit1 = cache_meta_r1[TAG_WID];
    wire [TAG_WID-1:0] tag_from_cache0 = cache_meta_r0[TAG_WID-1:0];
    wire [TAG_WID-1:0] tag_from_cache1 = cache_meta_r1[TAG_WID-1:0];

    // 读 Hit 判定
    wire r_hit0 = valid_bit0 && line_enabled0[r_cache_index] &&
                  (tag_from_cache0 == r_tag_from_cpu) && !r_uncached;
    wire r_hit1 = valid_bit1 && line_enabled1[r_cache_index] &&
                  (tag_from_cache1 == r_tag_from_cpu) && !r_uncached;
    wire r_hit  = r_hit0 || r_hit1;
    wire r_hit_way = r_hit0 ? 1'b0 : 1'b1;
    wire [31:0] r_selected_cache_word = r_hit0 ? cache_word_r0 : cache_word_r1;

    // 写 Hit 判定 (uncached 写专用)
    wire w_hit0 = valid_bit0 && line_enabled0[w_cache_index] &&
                  (tag_from_cache0 == w_tag_from_cpu) && !w_uncached;
    wire w_hit1 = valid_bit1 && line_enabled1[w_cache_index] &&
                  (tag_from_cache1 == w_tag_from_cpu) && !w_uncached;
    wire w_hit  = w_hit0 || w_hit1;
    wire w_hit_way = w_hit0 ? 1'b0 : 1'b1;
    wire [31:0] w_selected_cache_word = w_hit0 ? cache_word_r0 : cache_word_r1;

    wire miss_way = (!valid_bit0 || !line_enabled0[r_cache_index]) ? 1'b0 :
                    ((!valid_bit1 || !line_enabled1[r_cache_index]) ? 1'b1 :
                     replace_way[r_cache_index]);
    wire hit_r = (r_state == R_TAG_CHK) && r_hit && !req_is_prefetch_r;
    wire hit_w = (w_state == W_TAG_CHK) && w_hit;

    // Parameterized ordered Load Request FIFO.  Depth 1 is the measured
    // optimum for the current blocking refill engine; deeper buffering is
    // reserved for a future non-blocking miss architecture.
    reg [31:0] req_fifo_addr      [0:LOAD_REQ_FIFO_DEPTH-1];
    reg [ 3:0] req_fifo_ren       [0:LOAD_REQ_FIFO_DEPTH-1];
    reg        req_fifo_cacheable [0:LOAD_REQ_FIFO_DEPTH-1];
    reg [ 1:0] req_fifo_slot     [0:LOAD_REQ_FIFO_DEPTH-1];

    reg        req_fifo_head;
    reg        req_fifo_tail;
    reg [1:0]  req_fifo_count;

    wire req_fifo_head_uncached = (req_fifo_count > 0) &&
                                  is_uncached_request(req_fifo_addr[req_fifo_head], req_fifo_cacheable[req_fifo_head]);

    // Store FIFO 指针与状态控制
    wire [1:0] head_ptr = store_fifo_head;
    wire [1:0] tail_ptr = store_fifo_tail;

    wire store_fifo_will_pop = (store_fifo_count > 0) &&
                               store_fifo_cache_updated[head_ptr] &&
                               store_fifo_ext_written[head_ptr];

    wire store_fifo_can_accept = (store_fifo_count < STORE_FIFO_CAPACITY) ||
                                 ((store_fifo_count == STORE_FIFO_CAPACITY) &&
                                  store_fifo_will_pop);

    wire cacheable_write_ready = !incoming_w_uncached && store_fifo_can_accept && !maint_active;
    wire uncached_write_ready = incoming_w_uncached && !uncached_store_valid && (store_fifo_count == 0) &&
                                (r_state == R_IDLE) && (w_state == W_IDLE) &&
                                !data_valid && !data_wresp && !maint_active &&
                                dev_widle;
    assign data_wready = cacheable_write_ready || uncached_write_ready;
    wire write_accept = data_wready && (|data_wen);
    assign data_wposted = write_accept && !incoming_w_uncached;
    assign data_wresp = (w_state == W_WR_WAIT) && dev_wdone;

    wire store_fifo_push = write_accept && !incoming_w_uncached;
    wire store_fifo_pop  = store_fifo_will_pop;

    // External write completion is recorded only on a real ready/valid fire.
    wire store_ext_write_valid = (store_fifo_count > 0) &&
                                 !store_fifo_ext_written[head_ptr] &&
                                 (w_state == W_IDLE);

    wire external_write_fire = store_ext_write_valid && dev_wrdy;


    // Store Tag 检查读 Array 命中计算
    wire [INDEX_WID-1:0] store_head_index  = store_fifo_addr[head_ptr][INDEX_WID+OFFSET_WID-1 : OFFSET_WID];
    wire [TAG_WID-1:0]   store_head_tag    = store_fifo_addr[head_ptr][31 : INDEX_WID+OFFSET_WID];
    wire [OFFSET_WID-1:0] store_head_offset = store_fifo_addr[head_ptr][OFFSET_WID-1 : 0];
    wire store_w_hit0 = store_meta_r0[TAG_WID] && line_enabled0[store_head_index] &&
                        (store_meta_r0[TAG_WID-1:0] == store_head_tag);
    wire store_w_hit1 = store_meta_r1[TAG_WID] && line_enabled1[store_head_index] &&
                        (store_meta_r1[TAG_WID-1:0] == store_head_tag);
    wire store_w_hit  = store_w_hit0 || store_w_hit1;
    wire store_w_hit_way = store_w_hit0 ? 1'b0 : 1'b1;

    // 内部 Store Tag 检查与 Cache 更新启动信号
    wire store_same_refill_line = (r_state == R_REFILL) &&
                                  (store_fifo_addr[head_ptr][31:OFFSET_WID] == refill_raddr_r[31:OFFSET_WID]);

    wire store_same_refill_set = (r_state == R_REFILL) &&
                                 (store_head_index == refill_index_r);

    wire store_refill_tail_allow = (r_state == R_REFILL) &&
                                   (recv_cnt > 0) &&
                                   (req_fifo_count == 0) &&
                                   !(|data_ren) &&
                                   !probe_checking_r &&
                                   !same_wait_any &&
                                   !store_same_refill_set;


    wire store_service_r_state_ok = (r_state == R_IDLE) ||
                                    ((r_state == R_TAG_CHK) && r_hit) ||
                                    store_refill_tail_allow;

    wire store_fifo_has_unbound_head = (store_fifo_count > 3'd0) &&
                                       !store_fifo_tag_checked[head_ptr] &&
                                       !(store_fifo_count == 3'd1 && store_fifo_will_pop);

    wire store_tag_launch = store_fifo_has_unbound_head &&
                            !store_tag_pending &&
                            store_service_r_state_ok &&
                            (w_state == W_IDLE) &&
                            !replay_pending &&
                            !refill_commit && !maint_active;

    wire store_update_launch = (store_fifo_count > 3'd0) &&
                               (store_tag_pending || store_fifo_tag_checked[head_ptr]) &&
                               (store_tag_pending ? store_w_hit : store_fifo_hit[head_ptr]) &&
                               !store_fifo_cache_updated[head_ptr] &&
                               store_service_r_state_ok &&
                               (w_state == W_IDLE) &&
                               !replay_pending &&
                               !refill_commit && !maint_active;

    wire [INDEX_WID-1:0] store_launch_index  = store_head_index;
    wire [OFFSET_WID-1:0] store_launch_offset = store_head_offset;

    wire same_refill_line = mshr_valid &&
                            (req_raddr_r[31:OFFSET_WID] == refill_raddr_r[31:OFFSET_WID]);

    wire incoming_r_cacheable = (req_fifo_count > 0) ? !req_fifo_head_uncached : !incoming_r_uncached;

    wire [2:0] arriving_word_index = refill_offset_r[4:2] + recv_cnt;
    wire [2:0] probe_word_index    = req_raddr_r[OFFSET_WID-1:2];

    wire [ORD_DEPTH-1:0] same_wait_beat_match;
    assign same_wait_beat_match[0] = (r_state == R_REFILL) && dev_rvalid &&
                                     same_wait_valid[0] && (arriving_word_index == same_wait_word[0]);
    assign same_wait_beat_match[1] = (r_state == R_REFILL) && dev_rvalid &&
                                     same_wait_valid[1] && (arriving_word_index == same_wait_word[1]);
    assign same_wait_beat_match[2] = (r_state == R_REFILL) && dev_rvalid &&
                                     same_wait_valid[2] && (arriving_word_index == same_wait_word[2]);
    assign same_wait_beat_match[3] = (r_state == R_REFILL) && dev_rvalid &&
                                     same_wait_valid[3] && (arriving_word_index == same_wait_word[3]);

    wire word_available_now = refill_word_valid_mask[probe_word_index] ||
                              (dev_rvalid && (arriving_word_index == probe_word_index));

    // A single MSHR owns the external miss.  While it is waiting for the bus
    // or receiving refill beats, an otherwise-idle array read port may probe
    // one younger request.  The ordered response buffer prevents that probe
    // from returning ahead of the older miss.
    wire hur_probe_window = mshr_valid &&
                            ((r_state == R_RD_MEM) || (r_state == R_REFILL));

    wire hur_probe_can_launch = hur_probe_window &&
                                incoming_r_cacheable &&
                                !refill_commit &&
                                !replay_pending &&
                                !probe_checking_r &&
                                (w_state == W_IDLE) &&
                                !maint_active;

    wire hur_probe_result       = mshr_valid && probe_checking_r &&
                                  ((r_state == R_RD_MEM) || (r_state == R_REFILL));
    wire hur_probe_hit          = hur_probe_result && r_hit && !same_refill_line;
    wire hur_same_line_imm_hit  = hur_probe_result && same_refill_line && word_available_now;

    integer f_idx;
    always @(posedge cpu_clk or negedge cpu_rstn) begin
        if (!cpu_rstn) begin
            store_fifo_head   <= 2'd0;
            store_fifo_tail   <= 2'd0;
            store_fifo_count  <= 3'd0;
            store_tag_pending <= 1'b0;

            for (f_idx = 0; f_idx < STORE_FIFO_DEPTH; f_idx = f_idx + 1) begin
                store_fifo_tag_checked[f_idx]   <= 1'b0;
                store_fifo_hit[f_idx]           <= 1'b0;
                store_fifo_hit_way[f_idx]       <= 1'b0;
                store_fifo_cache_updated[f_idx] <= 1'b0;
                store_fifo_ext_written[f_idx]   <= 1'b0;
                store_fifo_addr[f_idx]          <= 32'h0;
                store_fifo_wen[f_idx]           <= 4'h0;
                store_fifo_wdata[f_idx]         <= 32'h0;
                store_fifo_cacheable[f_idx]     <= 1'b0;
            end
        end else begin
            if (store_fifo_push) begin
                store_fifo_addr[tail_ptr]          <= data_addr;
                store_fifo_wen[tail_ptr]           <= data_wen;
                store_fifo_wdata[tail_ptr]         <= data_wdata;
                store_fifo_cacheable[tail_ptr]     <= data_cacheable;

                store_fifo_tag_checked[tail_ptr]   <= 1'b0;
                store_fifo_hit[tail_ptr]           <= 1'b0;
                store_fifo_hit_way[tail_ptr]       <= 1'b0;
                store_fifo_cache_updated[tail_ptr] <= 1'b0;
                store_fifo_ext_written[tail_ptr]   <= 1'b0;

                store_fifo_tail <= store_fifo_tail + 2'd1;
            end

            if (store_fifo_pop) begin
                store_fifo_head <= store_fifo_head + 2'd1;
            end

            store_fifo_count <= store_fifo_count + {2'b0, store_fifo_push} - {2'b0, store_fifo_pop};

            // Port B returns the metadata match one cycle after launch.
            if (store_tag_launch) begin
                store_tag_pending <= 1'b1;
            end else if (store_tag_pending) begin
                store_tag_pending <= 1'b0;
                store_fifo_tag_checked[head_ptr] <= 1'b1;
                store_fifo_hit[head_ptr]         <= store_w_hit;
                store_fifo_hit_way[head_ptr]     <= store_w_hit_way;
                if (!store_w_hit || store_update_launch) begin
                    store_fifo_cache_updated[head_ptr] <= 1'b1;
                end
            end

            // 内部 Store Cache Data Array 更新标记
            if (store_update_launch && !store_tag_pending) begin
                store_fifo_cache_updated[head_ptr] <= 1'b1;
            end

            // Track completion of the independent external write obligation.
            if (external_write_fire) begin
                store_fifo_ext_written[head_ptr] <= 1'b1;
            end
        end
    end

    // 主 Load 流水线就绪条件
    wire load_can_start_cond = (((r_state == R_IDLE) || (r_state == R_TAG_CHK && r_hit)) && !replay_pending) &&
                               (w_state == W_IDLE) &&
                               !refill_commit && !maint_active;

    wire load_accept_ready = load_can_start_cond || hur_probe_can_launch;

    wire ord_ready_release = (ord_count > 3'd0) &&
                             ord_valid[ord_head] && ord_ready[ord_head];

    // Load Request FIFO 出队 / 启动定义
    wire req_fifo_can_dequeue = (req_fifo_count > 0) && load_accept_ready &&
                                !replay_pending && !probe_checking_r;
    wire req_fifo_pop   = req_fifo_can_dequeue;
    wire req_fifo_start = req_fifo_can_dequeue;

    wire req_fifo_will_pop   = req_fifo_pop;
    wire req_fifo_can_accept = (req_fifo_count < LOAD_REQ_FIFO_CAPACITY) ||
                               ((req_fifo_count == LOAD_REQ_FIFO_CAPACITY) && req_fifo_will_pop);

    // Load 读就绪逻辑 (只要 FIFO 有空间且非 maint 即可 accept，不被 engine 忙状态阻塞，消除与 Store 写就绪的死锁/组合环)
    assign data_rready = req_fifo_can_accept &&
                         !maint_active &&
                         ((ord_count < ORD_CAPACITY) || ord_ready_release);

    wire read_accept = data_rready && (|data_ren);

    // Load Req FIFO 入队：所有 accepted 读请求均存入 req_fifo 建立 registered ownership boundary
    wire req_fifo_push = read_accept;

    wire cache_idle = (r_state == R_IDLE) &&
                      (w_state == W_IDLE) &&
                      (req_fifo_count == 2'd0) &&
                      !read_accept &&
                      !(|data_ren) &&
                      (ord_count == 3'd0) &&
                      (store_fifo_count == 3'd0) &&
                      !replay_pending &&
                      !same_wait_any &&
                      !probe_checking_r &&
                      !mshr_valid &&
                      !maint_active &&
                      !maint_valid;

    wire demand_observe = read_accept && !incoming_r_uncached;
    wire [26:0] curr_demand_line = data_addr[31:5];
    wire [26:0] next_demand_line = curr_demand_line + 27'd1;
    wire [31:0] next_line_addr   = {next_demand_line, 5'b0};
    wire [31:0] curr_line_addr   = {curr_demand_line, 5'b0};
    wire        cand_same_4k     = (curr_line_addr[31:12] == next_line_addr[31:12]);
    wire        cand_uncached    = is_uncached_request(next_line_addr, 1'b1);
    wire        cand_pass        = cand_same_4k && !cand_uncached;

    wire demand_line_changed = demand_observe && (!pf_last_demand_valid || (curr_demand_line != pf_last_demand_line));

    reg [1:0] pf_confidence_next;
    always @(*) begin
        pf_confidence_next = pf_confidence;
        if (demand_observe) begin
            if (pf_last_demand_valid) begin
                if (curr_demand_line == pf_last_demand_line + 27'd1) begin
                    pf_confidence_next = (pf_confidence == 2'd3) ? 2'd3 : (pf_confidence + 2'd1);
                end else if (curr_demand_line != pf_last_demand_line) begin
                    pf_confidence_next = (pf_confidence == 2'd0) ? 2'd0 : (pf_confidence - 2'd1);
                end
            end else begin
                pf_confidence_next = 2'd0;
            end
        end
    end

    wire pf_pending_create = demand_observe && demand_line_changed && cand_pass && (pf_confidence_next >= 2'd2);

    wire pf_tag_launch_safe =
        pf_pending_valid &&
        (r_state == R_IDLE) &&
        (w_state == W_IDLE) &&
        (req_fifo_count == 0) &&
        !read_accept &&
        !(|data_ren) &&
        !replay_pending &&
        !same_wait_any &&
        !probe_checking_r &&
        !mshr_valid &&
        !maint_active &&
        !maint_valid &&
        !refill_commit &&
        !store_tag_launch &&
        !store_update_launch &&
        !store_tag_pending;

`ifdef ENABLE_DCACHE_NEXTLINE_PREFETCH
    wire pf_launch = pf_tag_launch_safe;
`else
    wire pf_launch = 1'b0;
`endif

    wire pf_tag_launch = pf_launch;

`ifdef ENABLE_DCACHE_NEXTLINE_PREFETCH
    always @(posedge cpu_clk or negedge cpu_rstn) begin
        if (!cpu_rstn) begin
            pf_confidence        <= 2'd0;
            pf_last_demand_valid <= 1'b0;
            pf_last_demand_line  <= 27'd0;
            pf_pending_valid     <= 1'b0;
            pf_pending_line      <= 27'd0;
        end else begin
            if (demand_observe) begin
                if (demand_line_changed) begin
                    pf_confidence        <= pf_confidence_next;
                    pf_last_demand_valid <= 1'b1;
                    pf_last_demand_line  <= curr_demand_line;
                end

                if (pf_pending_create) begin
`ifndef SYNTHESIS
                    if (pf_pending_valid && (pf_pending_line != next_demand_line))
                        pf_pending_overwrite_cnt <= pf_pending_overwrite_cnt + 64'd1;
                    pf_candidate_cnt <= pf_candidate_cnt + 64'd1;
`endif
                    pf_pending_valid <= 1'b1;
                    pf_pending_line  <= next_demand_line;
                end else if (curr_demand_line == pf_pending_line) begin
                    pf_pending_valid <= 1'b0;
                end
            end

            if (pf_tag_launch) begin
`ifndef SYNTHESIS
                pf_tag_launch_cnt <= pf_tag_launch_cnt + 64'd1;
`endif
                pf_pending_valid <= 1'b0;
            end else if ((r_state == R_TAG_CHK) && r_hit && req_is_prefetch_r) begin
                pf_pending_valid <= 1'b0;
            end
        end
    end
`endif

    wire [INDEX_WID-1:0] incoming_index =
        data_addr[INDEX_WID+OFFSET_WID-1:OFFSET_WID];

    // Load req_r* 寄存器更新 (including ord slot propagation)
    always @(posedge cpu_clk or negedge cpu_rstn) begin
        if (!cpu_rstn) begin
            req_raddr_r       <= 32'h0;
            req_ren_r         <= 4'h0;
            req_rcacheable_r  <= 1'b0;
            req_slot_r        <= 2'd0;
            req_is_prefetch_r <= 1'b0;
        end else if (pf_launch) begin
            req_raddr_r       <= {pf_pending_line, 5'b0};
            req_ren_r         <= 4'hf;
            req_rcacheable_r  <= 1'b1;
            req_slot_r        <= 2'd0;
            req_is_prefetch_r <= 1'b1;
        end else if (replay_pending && (r_state == R_REFILL || r_state == R_IDLE)) begin
            req_raddr_r       <= replay_raddr_r;
            req_ren_r         <= replay_ren_r;
            req_rcacheable_r  <= replay_rcacheable_r;
            req_slot_r        <= replay_slot_r;
            req_is_prefetch_r <= 1'b0;
        end else if (req_fifo_start) begin
            req_raddr_r       <= req_fifo_addr[req_fifo_head];
            req_ren_r         <= req_fifo_ren[req_fifo_head];
            req_rcacheable_r  <= req_fifo_cacheable[req_fifo_head];
            req_slot_r        <= req_fifo_slot[req_fifo_head];
            req_is_prefetch_r <= 1'b0;
        end else if ((r_state == R_TAG_CHK) && r_hit && req_is_prefetch_r) begin
            req_is_prefetch_r <= 1'b0;
        end
    end

    // Ord slot allocation: when read_accept fires, allocate the next free slot.
    wire [1:0] next_ord_slot = ord_slot_alloc + 1'b1;
    always @(posedge cpu_clk or negedge cpu_rstn) begin
        if (!cpu_rstn) begin
            ord_slot_alloc <= 2'd0;
        end else if (read_accept) begin
            ord_slot_alloc <= next_ord_slot;
        end
    end

    // Ordered Load Request FIFO control
    integer rf_idx;
    always @(posedge cpu_clk or negedge cpu_rstn) begin
        if (!cpu_rstn) begin
            req_fifo_head  <= 1'b0;
            req_fifo_tail  <= 1'b0;
            req_fifo_count <= 2'd0;
            for (rf_idx = 0; rf_idx < LOAD_REQ_FIFO_DEPTH; rf_idx = rf_idx + 1) begin
                req_fifo_addr[rf_idx]      <= 32'h0;
                req_fifo_ren[rf_idx]       <= 4'h0;
                req_fifo_cacheable[rf_idx] <= 1'b0;
                req_fifo_slot[rf_idx]      <= 2'd0;
            end
        end else begin
            if (req_fifo_push) begin
                req_fifo_addr[req_fifo_tail]      <= data_addr;
                req_fifo_ren[req_fifo_tail]       <= data_ren;
                req_fifo_cacheable[req_fifo_tail] <= data_cacheable;
                req_fifo_slot[req_fifo_tail]      <= ord_slot_alloc;
                req_fifo_tail                     <= req_fifo_tail + 1'b1;
            end
            if (req_fifo_pop) begin
                req_fifo_head <= req_fifo_head + 1'b1;
            end
            req_fifo_count <= req_fifo_count + {1'b0, req_fifo_push} - {1'b0, req_fifo_pop};
        end
    end

    // Uncached Store request register and owner lifetime.
    always @(posedge cpu_clk or negedge cpu_rstn) begin
        if (!cpu_rstn) begin
            req_waddr_r          <= 0;
            req_wen_r            <= 0;
            req_wdata_r          <= 0;
            req_wcacheable_r     <= 1'b0;
            uncached_store_valid <= 1'b0;
        end else begin
            if (write_accept && incoming_w_uncached) begin
                req_waddr_r          <= data_addr;
                req_wen_r            <= data_wen;
                req_wdata_r          <= data_wdata;
                req_wcacheable_r     <= data_cacheable;
                uncached_store_valid <= 1'b1;
            end else if (w_state == W_WR_MEM && dev_wrdy && w_uncached) begin
                uncached_store_valid <= 1'b0;
            end
        end
    end

    wire pf_demand_pending = (req_fifo_count != 0) || read_accept || (|data_ren) || replay_pending || maint_valid;
    wire external_read_fire = (r_state == R_RD_MEM) && dev_rrdy && dev_widle && (!mshr_is_prefetch || !pf_demand_pending);
    wire pf_waiting_for_bus = mshr_valid && mshr_is_prefetch && (r_state == R_RD_MEM);
    wire pf_cancel_before_bus = pf_waiting_for_bus && pf_demand_pending && !external_read_fire;
    wire pf_bus_launch_fire = (r_state == R_RD_MEM) && mshr_is_prefetch && external_read_fire;

    // =========================================================
    // 3. DCache 读状态机 (Read FSM) - 流水化响应
    // =========================================================
    always @(posedge cpu_clk or negedge cpu_rstn) begin
        if (!cpu_rstn) r_state <= R_IDLE;
        else           r_state <= r_nstat;
    end

    wire replay_r_uncached = is_uncached_request(replay_raddr_r,
                                                  replay_rcacheable_r);

    always @(*) begin
        case(r_state)
            R_IDLE: begin
                if (replay_pending) begin
                    if (replay_r_uncached) r_nstat = R_UNC_REQ;
                    else                   r_nstat = R_TAG_CHK;
                end else if (req_fifo_start) begin
                    if (req_fifo_head_uncached) r_nstat = R_UNC_REQ;
                    else                        r_nstat = R_TAG_CHK;
                end else if (pf_launch) begin
                    r_nstat = R_TAG_CHK;
                end else r_nstat = R_IDLE;
            end
            
            R_TAG_CHK: begin
                if (r_hit) begin
                    if (req_is_prefetch_r) begin
                        r_nstat = R_IDLE;
                    end else if (replay_pending) begin
                        if (replay_r_uncached) r_nstat = R_UNC_REQ;
                        else                   r_nstat = R_TAG_CHK;
                    end else if (req_fifo_start) begin
                        if (req_fifo_head_uncached) r_nstat = R_UNC_REQ;
                        else                        r_nstat = R_TAG_CHK;
                    end else begin
                        r_nstat = R_IDLE;
                    end
                end else begin
                    r_nstat = R_RD_MEM;
                end
            end

            R_RD_MEM: begin
                if (mshr_is_prefetch && pf_demand_pending && !external_read_fire)
                    r_nstat = R_IDLE;
                else if (dev_rrdy && dev_widle)
                    r_nstat = R_REFILL;
                else
                    r_nstat = R_RD_MEM;
            end
            R_REFILL:   r_nstat = (dev_rvalid && recv_cnt == LINE_LAST_WORD) ?
                                  (req_fifo_start ? R_TAG_CHK : R_IDLE) : R_REFILL;
            
            R_UNC_REQ:  r_nstat = dev_rvalid ? (replay_pending ? R_TAG_CHK : R_IDLE) :
                                   ((dev_rrdy && dev_widle) ? R_UNC_WAIT : R_UNC_REQ);
            R_UNC_WAIT: r_nstat = dev_rvalid ? (replay_pending ? R_TAG_CHK : R_IDLE) : R_UNC_WAIT;
            default:    r_nstat = R_IDLE;
        endcase
    end

    // =========================================================
    // 4. DCache 写状态机 (Write FSM) - Uncached Store 专用
    // =========================================================
    always @(posedge cpu_clk or negedge cpu_rstn) begin
        if (!cpu_rstn) w_state <= W_IDLE;
        else           w_state <= w_nstat;
    end

    always @(*) begin
        case(w_state)
            W_IDLE:     w_nstat = (uncached_store_valid && w_uncached) ? W_WR_MEM : W_IDLE;
            W_TAG_CHK:  w_nstat = W_WR_MEM; 
            W_WR_MEM:   w_nstat = dev_wrdy ? (!w_uncached ? W_IDLE : W_WR_WAIT) : W_WR_MEM;
            W_WR_WAIT:  w_nstat = dev_wdone ? W_IDLE : W_WR_WAIT;
            default:    w_nstat = W_IDLE;
        endcase
    end

    // =========================================================
    // 5. 数据重填 (REFILL) 与 Cache 更新逻辑
    // =========================================================
    wire [LINE_WORD_IW-1:0] refill_word_sel =
        refill_offset_r[OFFSET_WID-1:2] + recv_cnt;

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

    wire refill_word_valid = (r_state == R_REFILL) && dev_rvalid &&
                              (recv_cnt == {LINE_WORD_IW{1'b0}});

    reg [2:0]  response_owner;
    always @(posedge cpu_clk or negedge cpu_rstn) begin
        if (!cpu_rstn) begin
            refill_way_r            <= 1'b0;
            refill_raddr_r          <= 32'h0;
            refill_ren_r            <= 4'h0;
            refill_rcacheable_r     <= 1'b0;
            mshr_valid              <= 1'b0;
            mshr_slot_id            <= 2'd0;
            mshr_critical_done      <= 1'b0;
            mshr_is_prefetch        <= 1'b0;
            probe_checking_r        <= 1'b0;
            replay_pending          <= 1'b0;
            replay_raddr_r          <= 32'h0;
            replay_ren_r            <= 4'h0;
            replay_rcacheable_r     <= 1'b0;
            replay_slot_r           <= 2'd0;
            refill_word_valid_mask  <= 8'h0;
            same_wait_valid         <= {ORD_DEPTH{1'b0}};
            same_wait_word[0]       <= 3'b0;
            same_wait_word[1]       <= 3'b0;
            same_wait_word[2]       <= 3'b0;
            same_wait_word[3]       <= 3'b0;
            same_wait_addr[0]       <= 32'h0;
            same_wait_addr[1]       <= 32'h0;
            same_wait_addr[2]       <= 32'h0;
            same_wait_addr[3]       <= 32'h0;
        end else begin
            if (pf_cancel_before_bus) begin
                mshr_valid              <= 1'b0;
                mshr_is_prefetch        <= 1'b0;
                mshr_critical_done      <= 1'b0;
                refill_word_valid_mask  <= 8'h0;
                req_is_prefetch_r       <= 1'b0;
`ifndef SYNTHESIS
                pf_cancel_cnt           <= pf_cancel_cnt + 64'd1;
`endif
            end else if ((r_state == R_TAG_CHK) && !r_hit && !mshr_valid) begin
                refill_way_r           <= miss_way;
                refill_raddr_r         <= req_raddr_r;
                refill_ren_r           <= req_ren_r;
                refill_rcacheable_r    <= req_rcacheable_r;
                refill_word_valid_mask <= 8'h0;
                mshr_valid             <= 1'b1;
                mshr_slot_id           <= req_slot_r;
                mshr_critical_done     <= 1'b0;
                mshr_is_prefetch       <= req_is_prefetch_r;
`ifndef SYNTHESIS
                if (!req_is_prefetch_r)
                    mshr_alloc_cnt     <= mshr_alloc_cnt + 64'd1;
                else
                    pf_tag_miss_cnt    <= pf_tag_miss_cnt + 64'd1;
`endif
            end

            if (refill_commit) begin
                mshr_valid         <= 1'b0;
                mshr_critical_done <= 1'b0;
                mshr_is_prefetch   <= 1'b0;
                req_is_prefetch_r  <= 1'b0;
`ifndef SYNTHESIS
                if (!mshr_is_prefetch)
                    mshr_complete_cnt <= mshr_complete_cnt + 64'd1;
                else
                    pf_fill_complete_cnt <= pf_fill_complete_cnt + 64'd1;
`endif
            end

            if (refill_word_valid) begin
                mshr_critical_done <= 1'b1;
            end

            if (r_state == R_REFILL && dev_rvalid) begin
                refill_word_valid_mask[arriving_word_index] <= 1'b1;
            end

            if (hur_probe_can_launch && req_fifo_start) begin
                probe_checking_r <= 1'b1;
            end else begin
                probe_checking_r <= 1'b0;
            end

            if (hur_probe_result) begin
                if (same_refill_line) begin
                    if (word_available_now) begin
`ifndef SYNTHESIS
                        if (mshr_is_prefetch) pf_demand_merge_imm_cnt <= pf_demand_merge_imm_cnt + 64'd1;
`endif
                    end else begin
                        same_wait_valid[req_slot_r] <= 1'b1;
                        same_wait_word[req_slot_r]  <= probe_word_index;
                        same_wait_addr[req_slot_r]  <= req_raddr_r;
`ifndef SYNTHESIS
                        if (mshr_is_prefetch) pf_demand_merge_wait_cnt <= pf_demand_merge_wait_cnt + 64'd1;
`endif
                    end
                end else if (!r_hit) begin
                    replay_pending      <= 1'b1;
                    replay_raddr_r      <= req_raddr_r;
                    replay_ren_r        <= req_ren_r;
                    replay_rcacheable_r <= req_rcacheable_r;
                    replay_slot_r       <= req_slot_r;
                end else begin
                end
            end

            if (same_wait_beat_match[0]) same_wait_valid[0] <= 1'b0;
            if (same_wait_beat_match[1]) same_wait_valid[1] <= 1'b0;
            if (same_wait_beat_match[2]) same_wait_valid[2] <= 1'b0;
            if (same_wait_beat_match[3]) same_wait_valid[3] <= 1'b0;

            // A physical ORD slot may be released and reallocated in one
            // cycle.  Clear stale waiter ownership before a new request uses
            // that slot; a later probe result will establish fresh metadata.
            if (read_accept)
                same_wait_valid[ord_slot_alloc] <= 1'b0;

            if (replay_pending && (r_state == R_IDLE)) begin
                replay_pending <= 1'b0;
            end
        end
    end

    wire [31:0] hit_rdata = r_selected_cache_word;

    // Apply forwarding in FIFO age order (oldest to youngest).
    // Younger entries are merged last so they win overlapping byte writes.
    function automatic [31:0] forward_from_store_fifo;
        input [31:0] base_data;
        input [31:0] load_addr;
        input [1:0]  fifo_head;
        input [2:0]  fifo_count;
        reg   [31:0] result;
        reg   [1:0]  slot;
        integer k;
        begin
            result = base_data;
            for (k = 0; k < 4; k = k + 1) begin
                if ({1'b0, fifo_count} > k) begin
                    slot = fifo_head + k[1:0];
                    if (store_fifo_addr[slot][31:2] == load_addr[31:2])
                        result = merge_store_bytes(result, store_fifo_wen[slot], store_fifo_wdata[slot]);
                end
            end
            forward_from_store_fifo = result;
        end
    endfunction

    reg [31:0] final_rdata;
    always @(*) begin
        final_rdata = forward_from_store_fifo(hit_rdata, req_raddr_r, head_ptr, store_fifo_count);
    end

    reg [31:0] same_line_imm_rdata;
    always @(*) begin
        if (dev_rvalid && (arriving_word_index == probe_word_index)) begin
            same_line_imm_rdata = dev_rdata;
        end else begin
            same_line_imm_rdata = select_line_word(refill_commit_data,
                                                    probe_word_index);
        end
    end

    reg [31:0] same_line_imm_final_rdata;
    always @(*) begin
        same_line_imm_final_rdata = forward_from_store_fifo(same_line_imm_rdata, req_raddr_r, head_ptr, store_fifo_count);
    end

    reg [31:0] same_wait_final_rdata [0:ORD_DEPTH-1];
    integer same_wait_data_idx;
    always @(*) begin
        for (same_wait_data_idx = 0; same_wait_data_idx < ORD_DEPTH;
             same_wait_data_idx = same_wait_data_idx + 1) begin
            same_wait_final_rdata[same_wait_data_idx] =
                forward_from_store_fifo(dev_rdata,
                                        same_wait_addr[same_wait_data_idx],
                                        head_ptr, store_fifo_count);
        end
    end

    // =========================================================
    // 6b. Response Order Buffer — strictly ordered release
    // =========================================================
    // A slot is reserved at the input handshake, not at completion.  A
    // younger hit may therefore become ready while the head miss is waiting,
    // but only the ready head is exposed to the untagged LSU response port.
    wire ord_aux_event = hur_same_line_imm_hit || hur_probe_hit ||
                         hit_r ||
                         (((r_state == R_UNC_REQ) || (r_state == R_UNC_WAIT)) &&
                          dev_rvalid);
    reg [1:0]  ord_aux_slot;
    reg [31:0] ord_aux_data;

    always @(*) begin
        ord_aux_slot = req_slot_r;
        ord_aux_data = final_rdata;
        if (hur_same_line_imm_hit) begin
            ord_aux_slot = req_slot_r;
            ord_aux_data = same_line_imm_final_rdata;
        end else if (hur_probe_hit || hit_r) begin
            ord_aux_slot = req_slot_r;
            ord_aux_data = final_rdata;
        end else if (((r_state == R_UNC_REQ) || (r_state == R_UNC_WAIT)) &&
                     dev_rvalid) begin
            ord_aux_slot = req_slot_r;
            ord_aux_data = dev_rdata;
        end
    end

    wire ord_write_event = (refill_word_valid && !mshr_is_prefetch) || ord_aux_event ||
                           (|same_wait_beat_match);
    wire ord_refill_completes_head = refill_word_valid && !mshr_is_prefetch &&
                                     (mshr_slot_id == ord_head);
    wire ord_aux_completes_head = ord_aux_event &&
                                  (ord_aux_slot == ord_head);
    wire ord_waiter_completes_head = same_wait_beat_match[ord_head];
    wire ord_complete_head_now = (ord_count > 3'd0) &&
                                 ord_valid[ord_head] &&
                                 !ord_ready[ord_head] &&
                                 (ord_refill_completes_head ||
                                  ord_waiter_completes_head ||
                                  ord_aux_completes_head);
    wire ord_emit = ord_ready_release || ord_complete_head_now;

    always @(posedge cpu_clk or negedge cpu_rstn) begin
        if (!cpu_rstn) begin
            ord_head       <= 2'd0;
            ord_count      <= 3'd0;
            ord_valid      <= {ORD_DEPTH{1'b0}};
            ord_ready      <= {ORD_DEPTH{1'b0}};
            ord_data[0]    <= 32'h0;
            ord_data[1]    <= 32'h0;
            ord_data[2]    <= 32'h0;
            ord_data[3]    <= 32'h0;
            data_valid     <= 1'b0;
            data_rdata     <= 32'h0;
        end else begin
            data_valid <= 1'b0;
            data_rdata <= 32'h0;

            // Release the old head first.  If the full ring turns around in
            // this cycle, the following allocation deliberately wins the
            // nonblocking assignments to that same physical slot.
            if (ord_emit) begin
                data_valid          <= 1'b1;
                if (ord_ready_release)
                    data_rdata <= ord_data[ord_head];
                else if (ord_refill_completes_head)
                    data_rdata <= dev_rdata;
                else if (ord_waiter_completes_head)
                    data_rdata <= same_wait_final_rdata[ord_head];
                else
                    data_rdata <= ord_aux_data;
                ord_valid[ord_head] <= 1'b0;
                ord_ready[ord_head] <= 1'b0;
                ord_head            <= ord_head + 2'd1;
            end

            if (read_accept) begin
                ord_valid[ord_slot_alloc] <= 1'b1;
                ord_ready[ord_slot_alloc] <= 1'b0;
                ord_data[ord_slot_alloc]  <= 32'h0;
            end

            // Refill critical data and one independent completion may land
            // together.  They belong to distinct accepted requests and are
            // written into distinct slots; an assertion below enforces this.
            if (refill_word_valid && !mshr_is_prefetch) begin
                if (!(ord_complete_head_now &&
                      (mshr_slot_id == ord_head))) begin
                    ord_ready[mshr_slot_id] <= 1'b1;
                    ord_data[mshr_slot_id]  <= dev_rdata;
                end
            end
            if (ord_aux_event) begin
                if (!(ord_complete_head_now &&
                      (ord_aux_slot == ord_head))) begin
                    ord_ready[ord_aux_slot] <= 1'b1;
                    ord_data[ord_aux_slot]  <= ord_aux_data;
                end
            end
            if (same_wait_beat_match[0] &&
                !(ord_complete_head_now && (ord_head == 2'd0))) begin
                ord_ready[0] <= 1'b1;
                ord_data[0]  <= same_wait_final_rdata[0];
            end
            if (same_wait_beat_match[1] &&
                !(ord_complete_head_now && (ord_head == 2'd1))) begin
                ord_ready[1] <= 1'b1;
                ord_data[1]  <= same_wait_final_rdata[1];
            end
            if (same_wait_beat_match[2] &&
                !(ord_complete_head_now && (ord_head == 2'd2))) begin
                ord_ready[2] <= 1'b1;
                ord_data[2]  <= same_wait_final_rdata[2];
            end
            if (same_wait_beat_match[3] &&
                !(ord_complete_head_now && (ord_head == 2'd3))) begin
                ord_ready[3] <= 1'b1;
                ord_data[3]  <= same_wait_final_rdata[3];
            end

            ord_count <= ord_count + {2'b0, read_accept} -
                         {2'b0, ord_emit};
        end
    end
    // =========================================================
    // 6a. Response event detection (only used for ord write arbitration)
    // =========================================================
    always @(*) begin
        response_owner = RESP_NONE;

        if (refill_word_valid && !mshr_is_prefetch) response_owner = RESP_REFILL_CRITICAL;
        else if (|same_wait_beat_match)             response_owner = RESP_HUR_SAME_TARGET_BEAT;
        else if (hur_same_line_imm_hit)            response_owner = RESP_HUR_SAME_IMMEDIATE;
        else if (hur_probe_hit)                    response_owner = RESP_HUR_DIFFERENT_LINE;
        else if (hit_r)                            response_owner = RESP_NORMAL_HIT;
        else if ((r_state == R_UNC_REQ || r_state == R_UNC_WAIT) && dev_rvalid)
                                                   response_owner = RESP_UNCACHED;
    end

    always @(*) begin
        cpu_ren   = 4'h0;
        cpu_raddr = 32'h0;
        cpu_rburst = 1'b0;
        if (r_state == R_RD_MEM && dev_rrdy && dev_widle && (!mshr_is_prefetch || !pf_demand_pending)) begin
            cpu_ren   = 4'b1111;
            cpu_raddr = {refill_raddr_r[31:2], 2'b00};
            cpu_rburst = 1'b1;
        end else if (r_state == R_UNC_REQ && dev_rrdy && dev_widle) begin
            cpu_ren   = req_ren_r;
            cpu_raddr = req_raddr_r;
        end
    end

    // External writes use a stable ready/valid payload until accepted.
    always @(*) begin
        if (w_state == W_WR_MEM) begin
            cpu_wen   = req_wen_r;
            cpu_waddr = req_waddr_r;
            cpu_wdata = req_wdata_r;
        end else if (store_ext_write_valid) begin
            cpu_wen   = store_fifo_wen[head_ptr];
            cpu_waddr = store_fifo_addr[head_ptr];
            cpu_wdata = store_fifo_wdata[head_ptr];
        end else begin
            cpu_wen   = 4'h0;
            cpu_waddr = 32'h0;
            cpu_wdata = 32'h0;
        end
    end

    // =========================================================
    // 7. External bus generation and central cache-array arbitration
    // =========================================================
    reg [INDEX_WID-1:0] maint_index_r;
    reg [INDEX_WID-1:0] maint_count;
    reg [TAG_WID-1:0] maint_tag_r;
    reg [1:0] maint_mode_r;
    reg [31:0] maint_ctag_r;

    wire replay_lookup_launch = (r_state == R_IDLE) && replay_pending;

    reg [3:0] array_read_owner;
    reg [INDEX_WID-1:0] array_read_index;
    reg [LINE_WORD_IW-1:0] array_read_word;
    reg [3:0] array_write_owner;
    reg [INDEX_WID-1:0] array_write_index;
    reg array_write_enable;
    reg array_write_way;
    reg array_write_meta_enable;
    reg [TAG_WID:0] array_write_meta;
    reg [31:0] array_write_byte_mask;
    reg [LINE_BITS-1:0] array_write_line;

    // Port A is reserved for demand/maintenance reads.
    always @(*) begin
        array_read_owner = ARRAY_OWNER_CONTEXT_HOLD;
        array_read_index = r_cache_index;
        array_read_word  = r_offset[OFFSET_WID-1:2];

        if (maint_active) begin
            array_read_owner = ARRAY_OWNER_MAINT;
            array_read_index = maint_index_r;
            array_read_word  = {LINE_WORD_IW{1'b0}};
        end else if (replay_lookup_launch) begin
            array_read_owner = ARRAY_OWNER_REPLAY;
            array_read_index = replay_raddr_r[INDEX_WID+OFFSET_WID-1 : OFFSET_WID];
            array_read_word  = replay_raddr_r[OFFSET_WID-1:2];
        end else if (req_fifo_start) begin
            array_read_owner = ARRAY_OWNER_LOAD_SKID;
            array_read_index = req_fifo_addr[req_fifo_head][INDEX_WID+OFFSET_WID-1 : OFFSET_WID];
            array_read_word  = req_fifo_addr[req_fifo_head][OFFSET_WID-1:2];
        end else if (w_state != W_IDLE) begin
            array_read_owner = ARRAY_OWNER_CONTEXT_HOLD;
            array_read_index = w_cache_index;
            array_read_word  = w_offset[OFFSET_WID-1:2];
        end
    end

    always @(*) begin
        array_write_owner       = ARRAY_OWNER_IDLE;
        array_write_index       = r_cache_index;
        array_write_enable      = 1'b0;
        array_write_way         = 1'b0;
        array_write_meta_enable = 1'b0;
        array_write_meta        = {(TAG_WID+1){1'b0}};
        array_write_byte_mask   = 32'h0;
        array_write_line        = {LINE_BITS{1'b0}};

        if (w_state == W_TAG_CHK) begin
            array_write_owner = ARRAY_OWNER_UNCACHED_STORE;
            array_write_index = w_cache_index;
            if (hit_w) begin
                array_write_enable = 1'b1;
                array_write_way    = w_hit_way;
                array_write_byte_mask[w_offset[OFFSET_WID-1:2]*4 +: 4] = req_wen_r;
                array_write_line[w_offset[OFFSET_WID-1:2]*32 +: 32]    = req_wdata_r;
            end
        end else if (refill_commit) begin
            array_write_owner       = ARRAY_OWNER_REFILL_COMMIT;
            array_write_index       = refill_index_r;
            array_write_enable      = 1'b1;
            array_write_way         = refill_way_r;
            array_write_meta_enable = 1'b1;
            array_write_meta        = {1'b1, refill_tag_r};
            array_write_byte_mask   = 32'hFFFFFFFF;
            array_write_line        = refill_commit_data;
        end else if (store_update_launch) begin
            array_write_owner  = ARRAY_OWNER_STORE_UPDATE;
            array_write_index  = store_head_index;
            array_write_enable = 1'b1;
            array_write_way    = store_tag_pending ? store_w_hit_way : store_fifo_hit_way[head_ptr];
            array_write_byte_mask[store_fifo_addr[head_ptr][OFFSET_WID-1:2]*4 +: 4] = store_fifo_wen[head_ptr];
            array_write_line[store_fifo_addr[head_ptr][OFFSET_WID-1:2]*32 +: 32]    = store_fifo_wdata[head_ptr];
        end
    end

    // =========================================================
    // 8. Two-port, word-banked cache-array backend
    // =========================================================
    reg [TAG_WID:0] cache_meta_way0 [0:`CACHE_BLK_NUM-1];
    reg [TAG_WID:0] cache_meta_way1 [0:`CACHE_BLK_NUM-1];

    reg [31:0] cache_data_way0_bank0 [0:`CACHE_BLK_NUM-1];
    reg [31:0] cache_data_way0_bank1 [0:`CACHE_BLK_NUM-1];
    reg [31:0] cache_data_way0_bank2 [0:`CACHE_BLK_NUM-1];
    reg [31:0] cache_data_way0_bank3 [0:`CACHE_BLK_NUM-1];
    reg [31:0] cache_data_way0_bank4 [0:`CACHE_BLK_NUM-1];
    reg [31:0] cache_data_way0_bank5 [0:`CACHE_BLK_NUM-1];
    reg [31:0] cache_data_way0_bank6 [0:`CACHE_BLK_NUM-1];
    reg [31:0] cache_data_way0_bank7 [0:`CACHE_BLK_NUM-1];
    reg [31:0] cache_data_way1_bank0 [0:`CACHE_BLK_NUM-1];
    reg [31:0] cache_data_way1_bank1 [0:`CACHE_BLK_NUM-1];
    reg [31:0] cache_data_way1_bank2 [0:`CACHE_BLK_NUM-1];
    reg [31:0] cache_data_way1_bank3 [0:`CACHE_BLK_NUM-1];
    reg [31:0] cache_data_way1_bank4 [0:`CACHE_BLK_NUM-1];
    reg [31:0] cache_data_way1_bank5 [0:`CACHE_BLK_NUM-1];
    reg [31:0] cache_data_way1_bank6 [0:`CACHE_BLK_NUM-1];
    reg [31:0] cache_data_way1_bank7 [0:`CACHE_BLK_NUM-1];

    always @(posedge cpu_clk or negedge cpu_rstn) begin
        if (!cpu_rstn) begin
            cache_meta_r0 <= {(TAG_WID+1){1'b0}};
            cache_meta_r1 <= {(TAG_WID+1){1'b0}};
            cache_word_r0 <= 32'h0;
            cache_word_r1 <= 32'h0;
        end else begin
            cache_meta_r0 <= cache_meta_way0[array_read_index];
            cache_meta_r1 <= cache_meta_way1[array_read_index];
            case (array_read_word)
                3'd0: begin cache_word_r0 <= cache_data_way0_bank0[array_read_index]; cache_word_r1 <= cache_data_way1_bank0[array_read_index]; end
                3'd1: begin cache_word_r0 <= cache_data_way0_bank1[array_read_index]; cache_word_r1 <= cache_data_way1_bank1[array_read_index]; end
                3'd2: begin cache_word_r0 <= cache_data_way0_bank2[array_read_index]; cache_word_r1 <= cache_data_way1_bank2[array_read_index]; end
                3'd3: begin cache_word_r0 <= cache_data_way0_bank3[array_read_index]; cache_word_r1 <= cache_data_way1_bank3[array_read_index]; end
                3'd4: begin cache_word_r0 <= cache_data_way0_bank4[array_read_index]; cache_word_r1 <= cache_data_way1_bank4[array_read_index]; end
                3'd5: begin cache_word_r0 <= cache_data_way0_bank5[array_read_index]; cache_word_r1 <= cache_data_way1_bank5[array_read_index]; end
                3'd6: begin cache_word_r0 <= cache_data_way0_bank6[array_read_index]; cache_word_r1 <= cache_data_way1_bank6[array_read_index]; end
                default: begin cache_word_r0 <= cache_data_way0_bank7[array_read_index]; cache_word_r1 <= cache_data_way1_bank7[array_read_index]; end
            endcase
        end
    end

    // Port B lookup only reads Tag/Valid metadata.
    always @(posedge cpu_clk or negedge cpu_rstn) begin
        if (!cpu_rstn) begin
            store_meta_r0 <= {(TAG_WID+1){1'b0}};
            store_meta_r1 <= {(TAG_WID+1){1'b0}};
        end else if (store_tag_launch) begin
            store_meta_r0 <= cache_meta_way0[store_launch_index];
            store_meta_r1 <= cache_meta_way1[store_launch_index];
        end
    end

    // Port B write side.  Nonblocking assignments preserve read-first
    // behavior for a same-address demand read; Store forwarding supplies the
    // architecturally newer bytes to that demand response.
    always @(posedge cpu_clk) begin
        if (array_write_enable && (array_write_way == 1'b0)) begin
            if (array_write_meta_enable)
                cache_meta_way0[array_write_index] <= array_write_meta;
            if (array_write_byte_mask[ 0]) cache_data_way0_bank0[array_write_index][ 7: 0] <= array_write_line[ 7: 0];
            if (array_write_byte_mask[ 1]) cache_data_way0_bank0[array_write_index][15: 8] <= array_write_line[15: 8];
            if (array_write_byte_mask[ 2]) cache_data_way0_bank0[array_write_index][23:16] <= array_write_line[23:16];
            if (array_write_byte_mask[ 3]) cache_data_way0_bank0[array_write_index][31:24] <= array_write_line[31:24];

            if (array_write_byte_mask[ 4]) cache_data_way0_bank1[array_write_index][ 7: 0] <= array_write_line[39:32];
            if (array_write_byte_mask[ 5]) cache_data_way0_bank1[array_write_index][15: 8] <= array_write_line[47:40];
            if (array_write_byte_mask[ 6]) cache_data_way0_bank1[array_write_index][23:16] <= array_write_line[55:48];
            if (array_write_byte_mask[ 7]) cache_data_way0_bank1[array_write_index][31:24] <= array_write_line[63:56];

            if (array_write_byte_mask[ 8]) cache_data_way0_bank2[array_write_index][ 7: 0] <= array_write_line[71:64];
            if (array_write_byte_mask[ 9]) cache_data_way0_bank2[array_write_index][15: 8] <= array_write_line[79:72];
            if (array_write_byte_mask[10]) cache_data_way0_bank2[array_write_index][23:16] <= array_write_line[87:80];
            if (array_write_byte_mask[11]) cache_data_way0_bank2[array_write_index][31:24] <= array_write_line[95:88];

            if (array_write_byte_mask[12]) cache_data_way0_bank3[array_write_index][ 7: 0] <= array_write_line[103:96];
            if (array_write_byte_mask[13]) cache_data_way0_bank3[array_write_index][15: 8] <= array_write_line[111:104];
            if (array_write_byte_mask[14]) cache_data_way0_bank3[array_write_index][23:16] <= array_write_line[119:112];
            if (array_write_byte_mask[15]) cache_data_way0_bank3[array_write_index][31:24] <= array_write_line[127:120];

            if (array_write_byte_mask[16]) cache_data_way0_bank4[array_write_index][ 7: 0] <= array_write_line[135:128];
            if (array_write_byte_mask[17]) cache_data_way0_bank4[array_write_index][15: 8] <= array_write_line[143:136];
            if (array_write_byte_mask[18]) cache_data_way0_bank4[array_write_index][23:16] <= array_write_line[151:144];
            if (array_write_byte_mask[19]) cache_data_way0_bank4[array_write_index][31:24] <= array_write_line[159:152];

            if (array_write_byte_mask[20]) cache_data_way0_bank5[array_write_index][ 7: 0] <= array_write_line[167:160];
            if (array_write_byte_mask[21]) cache_data_way0_bank5[array_write_index][15: 8] <= array_write_line[175:168];
            if (array_write_byte_mask[22]) cache_data_way0_bank5[array_write_index][23:16] <= array_write_line[183:176];
            if (array_write_byte_mask[23]) cache_data_way0_bank5[array_write_index][31:24] <= array_write_line[191:184];

            if (array_write_byte_mask[24]) cache_data_way0_bank6[array_write_index][ 7: 0] <= array_write_line[199:192];
            if (array_write_byte_mask[25]) cache_data_way0_bank6[array_write_index][15: 8] <= array_write_line[207:200];
            if (array_write_byte_mask[26]) cache_data_way0_bank6[array_write_index][23:16] <= array_write_line[215:208];
            if (array_write_byte_mask[27]) cache_data_way0_bank6[array_write_index][31:24] <= array_write_line[223:216];

            if (array_write_byte_mask[28]) cache_data_way0_bank7[array_write_index][ 7: 0] <= array_write_line[231:224];
            if (array_write_byte_mask[29]) cache_data_way0_bank7[array_write_index][15: 8] <= array_write_line[239:232];
            if (array_write_byte_mask[30]) cache_data_way0_bank7[array_write_index][23:16] <= array_write_line[247:240];
            if (array_write_byte_mask[31]) cache_data_way0_bank7[array_write_index][31:24] <= array_write_line[255:248];
        end else if (array_write_enable && (array_write_way == 1'b1)) begin
            if (array_write_meta_enable)
                cache_meta_way1[array_write_index] <= array_write_meta;
            if (array_write_byte_mask[ 0]) cache_data_way1_bank0[array_write_index][ 7: 0] <= array_write_line[ 7: 0];
            if (array_write_byte_mask[ 1]) cache_data_way1_bank0[array_write_index][15: 8] <= array_write_line[15: 8];
            if (array_write_byte_mask[ 2]) cache_data_way1_bank0[array_write_index][23:16] <= array_write_line[23:16];
            if (array_write_byte_mask[ 3]) cache_data_way1_bank0[array_write_index][31:24] <= array_write_line[31:24];

            if (array_write_byte_mask[ 4]) cache_data_way1_bank1[array_write_index][ 7: 0] <= array_write_line[39:32];
            if (array_write_byte_mask[ 5]) cache_data_way1_bank1[array_write_index][15: 8] <= array_write_line[47:40];
            if (array_write_byte_mask[ 6]) cache_data_way1_bank1[array_write_index][23:16] <= array_write_line[55:48];
            if (array_write_byte_mask[ 7]) cache_data_way1_bank1[array_write_index][31:24] <= array_write_line[63:56];

            if (array_write_byte_mask[ 8]) cache_data_way1_bank2[array_write_index][ 7: 0] <= array_write_line[71:64];
            if (array_write_byte_mask[ 9]) cache_data_way1_bank2[array_write_index][15: 8] <= array_write_line[79:72];
            if (array_write_byte_mask[10]) cache_data_way1_bank2[array_write_index][23:16] <= array_write_line[87:80];
            if (array_write_byte_mask[11]) cache_data_way1_bank2[array_write_index][31:24] <= array_write_line[95:88];

            if (array_write_byte_mask[12]) cache_data_way1_bank3[array_write_index][ 7: 0] <= array_write_line[103:96];
            if (array_write_byte_mask[13]) cache_data_way1_bank3[array_write_index][15: 8] <= array_write_line[111:104];
            if (array_write_byte_mask[14]) cache_data_way1_bank3[array_write_index][23:16] <= array_write_line[119:112];
            if (array_write_byte_mask[15]) cache_data_way1_bank3[array_write_index][31:24] <= array_write_line[127:120];

            if (array_write_byte_mask[16]) cache_data_way1_bank4[array_write_index][ 7: 0] <= array_write_line[135:128];
            if (array_write_byte_mask[17]) cache_data_way1_bank4[array_write_index][15: 8] <= array_write_line[143:136];
            if (array_write_byte_mask[18]) cache_data_way1_bank4[array_write_index][23:16] <= array_write_line[151:144];
            if (array_write_byte_mask[19]) cache_data_way1_bank4[array_write_index][31:24] <= array_write_line[159:152];

            if (array_write_byte_mask[20]) cache_data_way1_bank5[array_write_index][ 7: 0] <= array_write_line[167:160];
            if (array_write_byte_mask[21]) cache_data_way1_bank5[array_write_index][15: 8] <= array_write_line[175:168];
            if (array_write_byte_mask[22]) cache_data_way1_bank5[array_write_index][23:16] <= array_write_line[183:176];
            if (array_write_byte_mask[23]) cache_data_way1_bank5[array_write_index][31:24] <= array_write_line[191:184];

            if (array_write_byte_mask[24]) cache_data_way1_bank6[array_write_index][ 7: 0] <= array_write_line[199:192];
            if (array_write_byte_mask[25]) cache_data_way1_bank6[array_write_index][15: 8] <= array_write_line[207:200];
            if (array_write_byte_mask[26]) cache_data_way1_bank6[array_write_index][23:16] <= array_write_line[215:208];
            if (array_write_byte_mask[27]) cache_data_way1_bank6[array_write_index][31:24] <= array_write_line[223:216];

            if (array_write_byte_mask[28]) cache_data_way1_bank7[array_write_index][ 7: 0] <= array_write_line[231:224];
            if (array_write_byte_mask[29]) cache_data_way1_bank7[array_write_index][15: 8] <= array_write_line[239:232];
            if (array_write_byte_mask[30]) cache_data_way1_bank7[array_write_index][23:16] <= array_write_line[247:240];
            if (array_write_byte_mask[31]) cache_data_way1_bank7[array_write_index][31:24] <= array_write_line[255:248];
        end
    end

`ifndef SYNTHESIS
    reg [31:0] w_wait_cnt;
    always @(posedge cpu_clk or negedge cpu_rstn) begin
        if (!cpu_rstn) w_wait_cnt <= 0;
        else if (w_state == W_WR_WAIT) w_wait_cnt <= w_wait_cnt + 1;
        else w_wait_cnt <= 0;
    end
    always @(posedge cpu_clk) begin
        if (cpu_rstn && w_wait_cnt > 100) begin
            $display("[T=%0t] DCache watchdog timeout! w_state=%d, req_waddr_r=%h, dev_wdone=%b", $time, w_state, req_waddr_r, dev_wdone);
            $fatal(1, "W_WR_WAIT watchdog");
        end
    end

    reg [63:0] store_fifo_push_count;
    reg [63:0] store_fifo_pop_count;
    reg [63:0] store_fifo_ext_written_count;
    reg [63:0] store_fifo_cache_updated_count;

    reg [31:0] head_payload_addr_q;
    reg [ 3:0] head_payload_wen_q;
    reg [31:0] head_payload_wdata_q;
    reg [ 1:0] store_fifo_head_q;
    reg [ 2:0] store_fifo_count_q;
    reg        store_fifo_pop_q;

    reg [ 3:0] ext_req_wen_q;
    reg [31:0] ext_req_waddr_q;
    reg [31:0] ext_req_wdata_q;
    reg        ext_req_stalled_q;

    reg [3:0] prev_ext_written;
    reg       prev_ext_fire;
    reg [1:0] prev_ext_fire_head;

    always @(posedge cpu_clk or negedge cpu_rstn) begin
        if (!cpu_rstn) begin
            store_fifo_push_count          <= 64'd0;
            store_fifo_pop_count           <= 64'd0;
            store_fifo_ext_written_count   <= 64'd0;
            store_fifo_cache_updated_count <= 64'd0;
            head_payload_addr_q            <= 32'd0;
            head_payload_wen_q             <= 4'd0;
            head_payload_wdata_q           <= 32'd0;
            store_fifo_head_q              <= 2'b0;
            store_fifo_count_q             <= 3'd0;
            store_fifo_pop_q               <= 1'b0;
            ext_req_wen_q                  <= 4'd0;
            ext_req_waddr_q                <= 32'd0;
            ext_req_wdata_q                <= 32'd0;
            ext_req_stalled_q              <= 1'b0;
            prev_ext_written               <= 4'b0000;
            prev_ext_fire                  <= 1'b0;
            prev_ext_fire_head             <= 2'b0;
        end else begin
            store_fifo_head_q  <= store_fifo_head;
            store_fifo_count_q <= store_fifo_count;
            store_fifo_pop_q   <= store_fifo_pop;

            ext_req_stalled_q  <= (cpu_wen != 4'h0) && !dev_wrdy;
            if (cpu_wen != 4'h0) begin
                ext_req_wen_q   <= cpu_wen;
                ext_req_waddr_q <= cpu_waddr;
                ext_req_wdata_q <= cpu_wdata;
            end

            prev_ext_written[0] <= store_fifo_ext_written[0];
            prev_ext_written[1] <= store_fifo_ext_written[1];
            prev_ext_written[2] <= store_fifo_ext_written[2];
            prev_ext_written[3] <= store_fifo_ext_written[3];
            prev_ext_fire      <= external_write_fire;
            prev_ext_fire_head <= head_ptr;

            if (store_fifo_push)
                store_fifo_push_count <= store_fifo_push_count + 64'd1;
            if (store_fifo_pop)
                store_fifo_pop_count <= store_fifo_pop_count + 64'd1;
            if (external_write_fire)
                store_fifo_ext_written_count <= store_fifo_ext_written_count + 64'd1;
            if (store_update_launch || (store_tag_pending && !store_w_hit))
                store_fifo_cache_updated_count <= store_fifo_cache_updated_count + 64'd1;

            if (store_fifo_count > 0) begin
                head_payload_addr_q  <= store_fifo_addr[head_ptr];
                head_payload_wen_q   <= store_fifo_wen[head_ptr];
                head_payload_wdata_q <= store_fifo_wdata[head_ptr];
            end
        end
    end

    integer assert_idx;
    always @(posedge cpu_clk) begin
        if (cpu_rstn) begin
            // 1. FIFO occupancy 永远不超过 STORE_FIFO_CAPACITY
            if (store_fifo_count > STORE_FIFO_CAPACITY)
                $fatal(1, "[DCACHE-ASSERT] Store FIFO occupancy exceeded STORE_FIFO_CAPACITY!");

            // 2. FIFO push/pop conservation
            if ((store_fifo_push_count - store_fifo_pop_count) != {61'd0, store_fifo_count})
                $fatal(1, "[DCACHE-ASSERT] Store FIFO push/pop conservation failed!");

            // 3. FIFO 满且无 pop 时不能 accept
            if (store_fifo_count == STORE_FIFO_CAPACITY &&
                !store_fifo_will_pop && write_accept && !incoming_w_uncached)
                $fatal(1, "[DCACHE-ASSERT] Store FIFO accepted new write while full without pop!");

            // 4. stalled 时 FIFO payload 稳定
            if ((store_fifo_count_q > 3'd0) && (store_fifo_count > 3'd0) &&
                (store_fifo_head_q === store_fifo_head) && !store_fifo_pop_q) begin
                if (store_fifo_addr[head_ptr] !== head_payload_addr_q ||
                    store_fifo_wen[head_ptr]  !== head_payload_wen_q ||
                    store_fifo_wdata[head_ptr] !== head_payload_wdata_q)
                    $fatal(1, "[DCACHE-ASSERT] Store FIFO head payload changed while stalled!");
            end

            // 5. The head cannot retire until both local and external work finish
            if (store_fifo_pop && (!store_fifo_cache_updated[head_ptr] || !store_fifo_ext_written[head_ptr]))
                $fatal(1, "[DCACHE-ASSERT] Store FIFO popped head before cache update and external write completed!");

            // 6. uncached Store 不能产生 data_wposted
            if (data_wposted && incoming_w_uncached)
                $fatal(1, "[DCACHE-ASSERT] uncached Store produced data_wposted!");

            // 7. 外部写 stall 协议与握手事件守恒检查
            if (ext_req_stalled_q && (cpu_wen != 4'h0)) begin
                if (cpu_wen !== ext_req_wen_q || cpu_waddr !== ext_req_waddr_q || cpu_wdata !== ext_req_wdata_q)
                    $fatal(1, "[DCACHE-ASSERT] External write request payload changed while stalled!");
            end

            if (external_write_fire && !((cpu_wen != 4'h0) && dev_wrdy))
                $fatal(1, "[DCACHE-ASSERT] external_write_fire occurred without valid cpu_wen and dev_wrdy!");

            for (assert_idx = 0; assert_idx < 4; assert_idx = assert_idx + 1) begin
                if ((store_fifo_ext_written[assert_idx] && !prev_ext_written[assert_idx]) &&
                    !(prev_ext_fire && prev_ext_fire_head == assert_idx[1:0]))
                    $fatal(1, "[DCACHE-ASSERT] store_fifo_ext_written set without external_write_fire!");
            end

            // 8. Array write owner & byte mask check
            if (array_write_enable &&
                (array_write_owner != ARRAY_OWNER_UNCACHED_STORE) &&
                (array_write_owner != ARRAY_OWNER_REFILL_COMMIT) &&
                (array_write_owner != ARRAY_OWNER_STORE_UPDATE))
                $fatal(1, "[DCACHE-ASSERT] Array write issued by a read-only owner!");

            if (array_write_enable && (array_write_byte_mask == 32'h0))
                $fatal(1, "[DCACHE-ASSERT] Array write has no selected byte mask!");

            // 9. 不允许 X/Z 进入指针与计数
            if (store_fifo_count !== 3'd0 && store_fifo_count !== 3'd1 &&
                store_fifo_count !== 3'd2 && store_fifo_count !== 3'd3 &&
                store_fifo_count !== STORE_FIFO_CAPACITY)
                $fatal(1, "[DCACHE-ASSERT] store_fifo_count is X/Z!");
        end
    end
`endif

    wire maint_hit0 = valid_bit0 && (tag_from_cache0 == maint_tag_r);
    wire maint_hit1 = valid_bit1 && (tag_from_cache1 == maint_tag_r);

    // Maintenance FSM and cache-line valid / replacement tracking
    always @(posedge cpu_clk or negedge cpu_rstn) begin
        if (!cpu_rstn) begin
            maint_state   <= M_IDLE;
            line_enabled0 <= {`CACHE_BLK_NUM{1'b0}};
            line_enabled1 <= {`CACHE_BLK_NUM{1'b0}};
            replace_way   <= {`CACHE_BLK_NUM{1'b0}};
            maint_count   <= {INDEX_WID{1'b0}};
            maint_done    <= 1'b0;
            maint_index_r <= {INDEX_WID{1'b0}};
            maint_tag_r   <= {TAG_WID{1'b0}};
            maint_mode_r  <= 2'b0;
            maint_ctag_r  <= 32'h0;
        end else begin
            maint_done <= 1'b0;
            case (maint_state)
                M_IDLE: begin
                    if (maint_valid && maint_ready) begin
                        maint_state   <= maint_all ? M_ALL : M_LOOKUP;
                        maint_count   <= {INDEX_WID{1'b0}};
                        maint_index_r <= maint_addr[INDEX_WID+OFFSET_WID-1 : OFFSET_WID];
                        maint_tag_r   <= maint_addr[31 : INDEX_WID+OFFSET_WID];
                        maint_mode_r  <= maint_mode;
                        maint_ctag_r  <= maint_ctag;
                    end
                end
                M_LOOKUP: begin
                    maint_state <= M_APPLY;
                end
                M_APPLY: begin
                    maint_state <= M_DONE;
                    case (maint_mode_r)
                        2'b00: begin
                            line_enabled0[maint_index_r] <= 1'b0;
                            line_enabled1[maint_index_r] <= 1'b0;
`ifndef SYNTHESIS
                            pf_line_way0[maint_index_r] <= 1'b0;
                            pf_line_way1[maint_index_r] <= 1'b0;
`endif
                        end
                        2'b01: begin
                            line_enabled0[maint_index_r] <= 1'b0;
                            line_enabled1[maint_index_r] <= 1'b0;
`ifndef SYNTHESIS
                            pf_line_way0[maint_index_r] <= 1'b0;
                            pf_line_way1[maint_index_r] <= 1'b0;
`endif
                        end
                        2'b10: begin
                            if (maint_hit0) begin
                                line_enabled0[maint_index_r] <= 1'b0;
`ifndef SYNTHESIS
                                pf_line_way0[maint_index_r] <= 1'b0;
`endif
                            end
                            if (maint_hit1) begin
                                line_enabled1[maint_index_r] <= 1'b0;
`ifndef SYNTHESIS
                                pf_line_way1[maint_index_r] <= 1'b0;
`endif
                            end
                        end
                        2'b11: begin
                            line_enabled0 <= {`CACHE_BLK_NUM{1'b0}};
                            line_enabled1 <= {`CACHE_BLK_NUM{1'b0}};
`ifndef SYNTHESIS
                            pf_line_way0  <= {`CACHE_BLK_NUM{1'b0}};
                            pf_line_way1  <= {`CACHE_BLK_NUM{1'b0}};
`endif
                        end
                    endcase
                end
                M_ALL: begin
                    line_enabled0[maint_count] <= 1'b0;
                    line_enabled1[maint_count] <= 1'b0;
`ifndef SYNTHESIS
                    pf_line_way0[maint_count] <= 1'b0;
                    pf_line_way1[maint_count] <= 1'b0;
`endif
                    if (maint_count == `CACHE_BLK_NUM - 1) begin
                        maint_state <= M_DONE;
                    end else begin
                        maint_count <= maint_count + 1'b1;
                    end
                end
                M_DONE: begin
                    maint_done  <= 1'b1;
                    maint_state <= M_IDLE;
                end
                default: maint_state <= M_IDLE;
            endcase

            if (refill_commit) begin
                if (refill_way_r == 1'b0) begin
                    line_enabled0[refill_index_r] <= 1'b1;
                    replace_way[refill_index_r]   <= 1'b1;
                end else begin
                    line_enabled1[refill_index_r] <= 1'b1;
                    replace_way[refill_index_r]   <= 1'b0;
                end
            end else if (hit_r) begin
                replace_way[r_cache_index] <= ~r_hit_way;
            end
        end
    end

    // Maintenance must not overtake a Load that has already been accepted at
    // data_rready but is still queued or held by the HUR replay machinery.
    assign maint_ready = (maint_state == M_IDLE) &&
                         (r_state == R_IDLE) &&
                         (w_state == W_IDLE) &&
                         !has_req &&
                         (store_fifo_count == 0) &&
                         (req_fifo_count == 0) &&
                         (ord_count == 0) &&
                         !replay_pending &&
                         !same_wait_any &&
                         !probe_checking_r &&
                         !mshr_valid;

`ifndef SYNTHESIS
    initial begin
`ifdef ENABLE_DCACHE_NEXTLINE_PREFETCH
        $display("[DCACHE-PF-A3-CONFIG] enabled=1");
`else
        $display("[DCACHE-PF-A3-CONFIG] enabled=0");
`endif
    end

    always @(posedge cpu_clk or negedge cpu_rstn) begin
        if (!cpu_rstn) begin
            req_fifo_max_occ             <= 2'd0;
            engine_busy_enqueue          <= 64'd0;
            fifo_full_block              <= 64'd0;
            hur_cycle_count              <= 64'd0;
            hur_probe_launch_cnt         <= 64'd0;
            hur_probe_hit_cnt            <= 64'd0;
            hur_probe_replay_cnt         <= 64'd0;
            hur_same_line_block_cnt      <= 64'd0;
            hur_same_line_probe_cnt      <= 64'd0;
            hur_same_line_buffer_hit_cnt <= 64'd0;
            hur_same_line_buffer_wait_cnt<= 64'd0;
            hur_same_line_wait_cycles_cnt<= 64'd0;
            hur_same_line_replay_cnt     <= 64'd0;
            mshr_alloc_cnt               <= 64'd0;
            mshr_complete_cnt            <= 64'd0;
            mshr_active_cycles_cnt       <= 64'd0;
            mshr_critical_wait_cycles_cnt<= 64'd0;
            hum_precritical_probe_cnt    <= 64'd0;
            hum_precritical_hit_cnt      <= 64'd0;
            hum_secondary_miss_cnt       <= 64'd0;
            hum_same_set_conflict_cnt    <= 64'd0;
            ord_buffered_completion_cnt  <= 64'd0;
            ord_release_cnt              <= 64'd0;
            ord_full_block_cnt           <= 64'd0;
            ord_max_occupancy            <= 3'd0;
            stream_conf                  <= 2'd0;
            last_miss_line               <= 27'd0;
            last_miss_valid              <= 1'b0;
            pf_a2_active                 <= 1'b0;
            pf_a2_line                   <= 27'd0;
            pf_a2_timestamp              <= 32'd0;
            interval_demand_miss_cnt     <= 64'd0;
            interval_would_launch_cnt    <= 64'd0;
            interval_would_useful_cnt    <= 64'd0;
            interval_would_wrong_line_cnt<= 64'd0;
            interval_would_cross_4k_cnt   <= 64'd0;
            interval_would_uncached_cnt   <= 64'd0;
            interval_useful_cycles_sum   <= 64'd0;
            interval_wrong_cycles_sum    <= 64'd0;
            interval_word_offset_cnt[0]  <= 64'd0;
            interval_word_offset_cnt[1]  <= 64'd0;
            interval_word_offset_cnt[2]  <= 64'd0;
            interval_word_offset_cnt[3]  <= 64'd0;
            interval_word_offset_cnt[4]  <= 64'd0;
            interval_word_offset_cnt[5]  <= 64'd0;
            interval_word_offset_cnt[6]  <= 64'd0;
            interval_word_offset_cnt[7]  <= 64'd0;
            pf_candidate_cnt             <= 64'd0;
            pf_pending_overwrite_cnt     <= 64'd0;
            pf_tag_launch_cnt            <= 64'd0;
            pf_tag_hit_redundant_cnt     <= 64'd0;
            pf_tag_miss_cnt              <= 64'd0;
            pf_bus_launch_cnt            <= 64'd0;
            pf_cancel_cnt                <= 64'd0;
            pf_fill_complete_cnt         <= 64'd0;
            pf_useful_hit_cnt            <= 64'd0;
            pf_useless_evict_cnt         <= 64'd0;
            pf_demand_merge_imm_cnt      <= 64'd0;
            pf_demand_merge_wait_cnt     <= 64'd0;
            pf_blocked_demand_cnt        <= 64'd0;
            pf_blocked_req_fifo_cnt      <= 64'd0;
            pf_blocked_mshr_cnt          <= 64'd0;
            pf_blocked_store_array_cnt   <= 64'd0;
            pf_blocked_write_bus_cnt     <= 64'd0;
            pf_blocked_maint_cnt         <= 64'd0;
            pf_active_cycles_cnt         <= 64'd0;
            pf_line_way0                 <= {`CACHE_BLK_NUM{1'b0}};
            pf_line_way1                 <= {`CACHE_BLK_NUM{1'b0}};
        end else begin
            hur_cycle_count <= hur_cycle_count + 64'd1;

            if (req_fifo_count > req_fifo_max_occ)
                req_fifo_max_occ <= req_fifo_count;

            if (req_fifo_push && (!load_accept_ready || replay_pending || probe_checking_r))
                engine_busy_enqueue <= engine_busy_enqueue + 64'd1;

            if ((|data_ren) && !req_fifo_can_accept && !maint_active)
                fifo_full_block <= fifo_full_block + 64'd1;

            if (hur_cycle_count > 64'd0 && (hur_cycle_count % 64'd100000 == 64'd0)) begin
                $display("[DCACHE-HUR-STATS] cycles=%0d probe=%0d hit=%0d replay=%0d same_line_probe=%0d buf_hit=%0d buf_wait=%0d wait_cycles=%0d buf_replay=%0d",
                         hur_cycle_count, hur_probe_launch_cnt, hur_probe_hit_cnt, hur_probe_replay_cnt,
                         hur_same_line_probe_cnt, hur_same_line_buffer_hit_cnt, hur_same_line_buffer_wait_cnt,
                         hur_same_line_wait_cycles_cnt, hur_same_line_replay_cnt);
                $display("[DCACHE-REQ-FIFO-STATS] cycles=%0d max_occ=%0d busy_enqueue=%0d full_block=%0d",
                         hur_cycle_count, req_fifo_max_occ, engine_busy_enqueue, fifo_full_block);
                $display("[DCACHE-MSHR-STATS] cycles=%0d alloc=%0d complete=%0d active_cycles=%0d critical_wait=%0d precrit_probe=%0d precrit_hit=%0d secondary_miss=%0d same_set_conflict=%0d buffered_completion=%0d release=%0d ord_full_block=%0d max_ord_occ=%0d",
                         hur_cycle_count, mshr_alloc_cnt, mshr_complete_cnt,
                         mshr_active_cycles_cnt, mshr_critical_wait_cycles_cnt,
                         hum_precritical_probe_cnt, hum_precritical_hit_cnt,
                         hum_secondary_miss_cnt, hum_same_set_conflict_cnt,
                         ord_buffered_completion_cnt, ord_release_cnt,
                         ord_full_block_cnt, ord_max_occupancy);
                $display("[DCACHE-PF-A2-INTERVAL] cycles=%0d-%0d misses=%0d launches=%0d useful=%0d wrong_line=%0d cross_4k=%0d uncached=%0d useful_rate=%0d%% avg_useful_lat=%0d avg_wrong_lat=%0d word_offsets=[%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d]",
                         hur_cycle_count - 64'd100000, hur_cycle_count,
                         interval_demand_miss_cnt,
                         interval_would_launch_cnt,
                         interval_would_useful_cnt,
                         interval_would_wrong_line_cnt,
                         interval_would_cross_4k_cnt,
                         interval_would_uncached_cnt,
                         (interval_would_launch_cnt > 0) ? (interval_would_useful_cnt * 64'd100 / interval_would_launch_cnt) : 64'd0,
                         (interval_would_useful_cnt > 0) ? (interval_useful_cycles_sum / interval_would_useful_cnt) : 64'd0,
                         (interval_would_wrong_line_cnt > 0) ? (interval_wrong_cycles_sum / interval_would_wrong_line_cnt) : 64'd0,
                         interval_word_offset_cnt[0], interval_word_offset_cnt[1], interval_word_offset_cnt[2], interval_word_offset_cnt[3],
                         interval_word_offset_cnt[4], interval_word_offset_cnt[5], interval_word_offset_cnt[6], interval_word_offset_cnt[7]);
                $display("[DCACHE-PF-A3-STATS] cycles=%0d candidate=%0d overwrite=%0d tag_probe=%0d tag_hit=%0d tag_miss=%0d bus_launch=%0d cancel=%0d fill=%0d useful_hit=%0d merge_imm=%0d merge_wait=%0d useless_evict=%0d blocked_demand=%0d blocked_fifo=%0d blocked_mshr=%0d blocked_store=%0d blocked_bus=%0d blocked_maint=%0d active_cycles=%0d confidence=%0d pending=%0d",
                         hur_cycle_count, pf_candidate_cnt, pf_pending_overwrite_cnt, pf_tag_launch_cnt, pf_tag_hit_redundant_cnt, pf_tag_miss_cnt, pf_bus_launch_cnt, pf_cancel_cnt, pf_fill_complete_cnt, pf_useful_hit_cnt, pf_demand_merge_imm_cnt, pf_demand_merge_wait_cnt, pf_useless_evict_cnt, pf_blocked_demand_cnt, pf_blocked_req_fifo_cnt, pf_blocked_mshr_cnt, pf_blocked_store_array_cnt, pf_blocked_write_bus_cnt, pf_blocked_maint_cnt, pf_active_cycles_cnt, pf_confidence, pf_pending_valid);

                // Reset interval counters per 100k cycles
                interval_demand_miss_cnt     <= 64'd0;
                interval_would_launch_cnt    <= 64'd0;
                interval_would_useful_cnt    <= 64'd0;
                interval_would_wrong_line_cnt<= 64'd0;
                interval_would_cross_4k_cnt   <= 64'd0;
                interval_would_uncached_cnt   <= 64'd0;
                interval_useful_cycles_sum   <= 64'd0;
                interval_wrong_cycles_sum    <= 64'd0;
                interval_word_offset_cnt[0]  <= 64'd0;
                interval_word_offset_cnt[1]  <= 64'd0;
                interval_word_offset_cnt[2]  <= 64'd0;
                interval_word_offset_cnt[3]  <= 64'd0;
                interval_word_offset_cnt[4]  <= 64'd0;
                interval_word_offset_cnt[5]  <= 64'd0;
                interval_word_offset_cnt[6]  <= 64'd0;
                interval_word_offset_cnt[7]  <= 64'd0;
            end

            // Phase A2 Observational Model Tracking Logic
            if ((r_state == R_TAG_CHK) && !r_hit && !r_uncached && !mshr_valid && !req_is_prefetch_r) begin
                interval_demand_miss_cnt <= interval_demand_miss_cnt + 64'd1;

                // Track demand word offset distribution
                interval_word_offset_cnt[req_raddr_r[4:2]] <= interval_word_offset_cnt[req_raddr_r[4:2]] + 64'd1;

                // Evaluate sequential miss stream
                if (last_miss_valid && (req_raddr_r[31:5] == last_miss_line + 27'd1)) begin
                    if (stream_conf < 2'd3)
                        stream_conf <= stream_conf + 2'd1;
                end else begin
                    if (stream_conf > 2'd0)
                        stream_conf <= stream_conf - 2'd1;
                end
                last_miss_line  <= req_raddr_r[31:5];
                last_miss_valid <= 1'b1;

                // Evaluate previous would_launch candidate against current demand miss
                if (pf_a2_active) begin
                    if (req_raddr_r[31:5] == pf_a2_line) begin
                        interval_would_useful_cnt <= interval_would_useful_cnt + 64'd1;
                        interval_useful_cycles_sum <= interval_useful_cycles_sum + (hur_cycle_count[31:0] - pf_a2_timestamp);
                    end else begin
                        interval_would_wrong_line_cnt <= interval_would_wrong_line_cnt + 64'd1;
                        interval_wrong_cycles_sum <= interval_wrong_cycles_sum + (hur_cycle_count[31:0] - pf_a2_timestamp);
                    end
                    pf_a2_active <= 1'b0;
                end

                // Evaluate candidate for current miss
                if (!a2_same_4k)
                    interval_would_cross_4k_cnt <= interval_would_cross_4k_cnt + 64'd1;
                if (a2_uncached)
                    interval_would_uncached_cnt <= interval_would_uncached_cnt + 64'd1;

                // Would Launch only if confidence counter >= 2 and candidate passes filters
                if (a2_cand_pass && (stream_conf >= 2'd2)) begin
                    interval_would_launch_cnt <= interval_would_launch_cnt + 64'd1;
                    pf_a2_active    <= 1'b1;
                    pf_a2_line      <= a2_next_addr[31:5];
                    pf_a2_timestamp <= hur_cycle_count[31:0];
                end
            end

            if (hur_probe_can_launch && req_fifo_start)
                hur_probe_launch_cnt <= hur_probe_launch_cnt + 64'd1;
            if (hur_probe_hit)
                hur_probe_hit_cnt <= hur_probe_hit_cnt + 64'd1;
            if (hur_probe_result && !same_refill_line && !r_hit)
                hur_probe_replay_cnt <= hur_probe_replay_cnt + 64'd1;
            if (same_refill_line && req_fifo_start)
                hur_same_line_block_cnt <= hur_same_line_block_cnt + 64'd1;
            if (hur_probe_result && same_refill_line)
                hur_same_line_probe_cnt <= hur_same_line_probe_cnt + 64'd1;
            if (hur_same_line_imm_hit)
                hur_same_line_buffer_hit_cnt <= hur_same_line_buffer_hit_cnt + 64'd1;
            if (same_wait_any) begin
                hur_same_line_wait_cycles_cnt <= hur_same_line_wait_cycles_cnt + 64'd1;
                if (r_state != R_REFILL)
                    hur_same_line_replay_cnt <= hur_same_line_replay_cnt + 64'd1;
            end
            if (|same_wait_beat_match)
                hur_same_line_buffer_wait_cnt <= hur_same_line_buffer_wait_cnt +
                    {63'd0, same_wait_beat_match[0]} +
                    {63'd0, same_wait_beat_match[1]} +
                    {63'd0, same_wait_beat_match[2]} +
                    {63'd0, same_wait_beat_match[3]};

            if ((r_state == R_TAG_CHK) && !r_hit && !mshr_valid && !req_is_prefetch_r)
                mshr_alloc_cnt <= mshr_alloc_cnt + 64'd1;
            if (refill_commit && !mshr_is_prefetch)
                mshr_complete_cnt <= mshr_complete_cnt + 64'd1;
            if (mshr_valid && !mshr_is_prefetch)
                mshr_active_cycles_cnt <= mshr_active_cycles_cnt + 64'd1;
            if (mshr_valid && !mshr_is_prefetch && !mshr_critical_done)
                mshr_critical_wait_cycles_cnt <= mshr_critical_wait_cycles_cnt + 64'd1;

            if (pf_bus_launch_fire)
                pf_bus_launch_cnt <= pf_bus_launch_cnt + 64'd1;

            if (refill_commit) begin
                if (mshr_is_prefetch) begin
                    if (refill_way_r == 1'b0) pf_line_way0[refill_index_r] <= 1'b1;
                    else                      pf_line_way1[refill_index_r] <= 1'b1;
                end else begin
                    if (refill_way_r == 1'b0) begin
                        if (pf_line_way0[refill_index_r]) pf_useless_evict_cnt <= pf_useless_evict_cnt + 64'd1;
                        pf_line_way0[refill_index_r] <= 1'b0;
                    end else begin
                        if (pf_line_way1[refill_index_r]) pf_useless_evict_cnt <= pf_useless_evict_cnt + 64'd1;
                        pf_line_way1[refill_index_r] <= 1'b0;
                    end
                end
            end

            if (hit_r) begin
                if (r_hit0 && pf_line_way0[r_cache_index]) begin
                    pf_useful_hit_cnt <= pf_useful_hit_cnt + 64'd1;
                    pf_line_way0[r_cache_index] <= 1'b0;
                end else if (r_hit1 && pf_line_way1[r_cache_index]) begin
                    pf_useful_hit_cnt <= pf_useful_hit_cnt + 64'd1;
                    pf_line_way1[r_cache_index] <= 1'b0;
                end
            end

            if (pf_pending_valid && !pf_tag_launch) begin
                if (read_accept || (|data_ren)) begin
                    pf_blocked_demand_cnt <= pf_blocked_demand_cnt + 64'd1;
                end else if ((req_fifo_count != 0) || replay_pending || same_wait_any || probe_checking_r) begin
                    pf_blocked_req_fifo_cnt <= pf_blocked_req_fifo_cnt + 64'd1;
                end else if (mshr_valid || (r_state != R_IDLE)) begin
                    pf_blocked_mshr_cnt <= pf_blocked_mshr_cnt + 64'd1;
                end else if (maint_active || maint_valid) begin
                    pf_blocked_maint_cnt <= pf_blocked_maint_cnt + 64'd1;
                end else if (store_tag_launch || store_update_launch || store_tag_pending || (w_state != W_IDLE)) begin
                    pf_blocked_store_array_cnt <= pf_blocked_store_array_cnt + 64'd1;
                end else if (!dev_widle) begin
                    pf_blocked_write_bus_cnt <= pf_blocked_write_bus_cnt + 64'd1;
                end
            end

            if (mshr_valid && mshr_is_prefetch) begin
                pf_active_cycles_cnt <= pf_active_cycles_cnt + 64'd1;
            end

            if (hur_probe_can_launch && req_fifo_start &&
                !mshr_critical_done)
                hum_precritical_probe_cnt <= hum_precritical_probe_cnt + 64'd1;
            if ((hur_probe_hit || hur_same_line_imm_hit) &&
                !mshr_critical_done)
                hum_precritical_hit_cnt <= hum_precritical_hit_cnt + 64'd1;
            if (hur_probe_result && !same_refill_line && !r_hit)
                hum_secondary_miss_cnt <= hum_secondary_miss_cnt + 64'd1;
            if (hur_probe_result && !same_refill_line && !r_hit &&
                (r_cache_index == refill_index_r))
                hum_same_set_conflict_cnt <= hum_same_set_conflict_cnt + 64'd1;
            if ((refill_word_valid && !ord_refill_completes_head) ||
                (ord_aux_event && !ord_aux_completes_head))
                ord_buffered_completion_cnt <= ord_buffered_completion_cnt +
                    {63'd0, (refill_word_valid && !ord_refill_completes_head)} +
                    {63'd0, (ord_aux_event && !ord_aux_completes_head)};
            if (ord_emit)
                ord_release_cnt <= ord_release_cnt + 64'd1;
            if ((|data_ren) && (ord_count == ORD_CAPACITY) &&
                !ord_ready_release && !maint_active)
                ord_full_block_cnt <= ord_full_block_cnt + 64'd1;
            if (ord_count > ord_max_occupancy)
                ord_max_occupancy <= ord_count;
        end
    end

    always @(posedge cpu_clk) begin
        if (cpu_rstn) begin
            if (req_fifo_count > LOAD_REQ_FIFO_CAPACITY)
                $fatal(1, "[DCACHE-ASSERT] Load req FIFO occupancy exceeded LOAD_REQ_FIFO_CAPACITY!");

            if (req_fifo_push && (req_fifo_count == LOAD_REQ_FIFO_CAPACITY) && !req_fifo_pop)
                $fatal(1, "[DCACHE-ASSERT] Load req FIFO accepted push while full without pop!");

            if (ord_count > ORD_CAPACITY)
                $fatal(1, "[DCACHE-ASSERT] Response order occupancy exceeded capacity!");

            if (ord_count != ({2'b0, ord_valid[0]} +
                              {2'b0, ord_valid[1]} +
                              {2'b0, ord_valid[2]} +
                              {2'b0, ord_valid[3]}))
                $fatal(1, "[DCACHE-ASSERT] Response-order count/valid conservation failure!");

            if (read_accept && (ord_count == ORD_CAPACITY) &&
                !ord_ready_release)
                $fatal(1, "[DCACHE-ASSERT] Load accepted without a response-order slot!");

            if (read_accept && ord_valid[ord_slot_alloc] &&
                !(ord_ready_release && (ord_slot_alloc == ord_head)))
                $fatal(1, "[DCACHE-ASSERT] Allocated an occupied response-order slot!");

            if (refill_word_valid && !mshr_is_prefetch && !ord_valid[mshr_slot_id])
                $fatal(1, "[DCACHE-ASSERT] Refill critical response targets an unallocated slot!");

            if (ord_aux_event && !ord_valid[ord_aux_slot])
                $fatal(1, "[DCACHE-ASSERT] Load completion targets an unallocated slot!");

            if (refill_word_valid && !mshr_is_prefetch && ord_ready[mshr_slot_id])
                $fatal(1, "[DCACHE-ASSERT] Refill response filled a slot twice!");

            if (ord_aux_event && ord_ready[ord_aux_slot])
                $fatal(1, "[DCACHE-ASSERT] Load response filled a slot twice!");

            if (refill_word_valid && !mshr_is_prefetch && ord_aux_event &&
                (mshr_slot_id == ord_aux_slot))
                $fatal(1, "[DCACHE-ASSERT] Two completion sources target the same slot!");

            if ((r_state == R_TAG_CHK) && !r_hit && mshr_valid)
                $fatal(1, "[DCACHE-ASSERT] Attempted to overwrite the active MSHR!");

            if ((r_state == R_TAG_CHK) && !r_hit && !mshr_valid &&
                !ord_valid[req_slot_r] && !req_is_prefetch_r)
                $fatal(1, "[DCACHE-ASSERT] MSHR allocation has no response-order owner!");

            if (mshr_valid && !mshr_critical_done &&
                !ord_valid[mshr_slot_id] && !mshr_is_prefetch)
                $fatal(1, "[DCACHE-ASSERT] Pending critical word lost its response-order owner!");

            if (refill_word_valid && !mshr_valid)
                $fatal(1, "[DCACHE-ASSERT] Critical refill beat arrived without an MSHR!");

            if (refill_commit && !mshr_valid)
                $fatal(1, "[DCACHE-ASSERT] Refill committed without an active MSHR!");

            if (maint_valid && maint_ready &&
                ((ord_count != 0) || mshr_valid || (req_fifo_count != 0) ||
                 replay_pending || same_wait_any || probe_checking_r))
                $fatal(1, "[DCACHE-ASSERT] Maintenance overtook an accepted Load!");

            if (hur_probe_result && same_refill_line && !word_available_now &&
                (!ord_valid[req_slot_r] || ord_ready[req_slot_r]))
                $fatal(1, "[DCACHE-ASSERT] Same-line waiter targets an invalid ORD slot!");

            if (hur_probe_result && same_refill_line && !word_available_now &&
                same_wait_valid[req_slot_r])
                $fatal(1, "[DCACHE-ASSERT] Same-line request allocated a waiter twice!");

            if ((same_wait_valid[0] && (!ord_valid[0] || ord_ready[0])) ||
                (same_wait_valid[1] && (!ord_valid[1] || ord_ready[1])) ||
                (same_wait_valid[2] && (!ord_valid[2] || ord_ready[2])) ||
                (same_wait_valid[3] && (!ord_valid[3] || ord_ready[3])))
                $fatal(1, "[DCACHE-ASSERT] Same-line waiter lost ORD ownership!");

            if (refill_commit && (|(same_wait_valid & ~same_wait_beat_match)))
                $fatal(1, "[DCACHE-ASSERT] Refill completed with unresolved same-line waiters!");

            if (ord_aux_event && same_wait_beat_match[ord_aux_slot])
                $fatal(1, "[DCACHE-ASSERT] Two completion sources target one ORD slot!");

            // Structural boundary assertions: array_read_owner must NEVER be LOAD_DIRECT
            if (array_read_owner == ARRAY_OWNER_LOAD_DIRECT)
                $fatal(1, "[DCACHE-ASSERT] Critical path boundary violation: array_read_owner is ARRAY_OWNER_LOAD_DIRECT!");
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
    reg [1:0] w_state_no_cache;
`endif

endmodule
