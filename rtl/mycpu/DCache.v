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
    localparam integer WCB_DEPTH = 4;
    localparam [2:0] WCB_CAPACITY = 3'd4;
    localparam [2:0] WCB_HIGH_WATERMARK = 3'd3;
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
    localparam [3:0] ARRAY_OWNER_PREFETCH_TAG    = 4'd10;

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
                                  ((addr >= 32'h1f00_0000) &&
                                   (addr <  32'h1f60_0000)) ||
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

    reg [INDEX_WID-1:0] maint_index_r;
    reg [INDEX_WID-1:0] maint_count;
    reg [TAG_WID-1:0] maint_tag_r;
    reg [1:0] maint_mode_r;
    reg [31:0] maint_ctag_r;

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

    // Stage 3: an early prefetch Tag probe may overlap the active Demand
    // refill, but it must never borrow the Demand request/response context.
    // Keep the probe result and its mutation epoch in a separate context so
    // a later direct prefetch start can be proven safe without a second MSHR.
    reg        pf_early_probe_valid;
    reg        pf_early_miss_valid;
    reg [26:0] pf_early_line_r;
    reg [INDEX_WID-1:0] pf_early_index_r;
    reg [TAG_WID:0] pf_early_meta_r0;
    reg [TAG_WID:0] pf_early_meta_r1;
    reg [15:0] pf_early_epoch_r;
    reg        pf_early_miss_way_r;

    // A set epoch changes whenever metadata validity, data, or replacement
    // state can change.  It is a compact proof that an early Tag result is
    // still current before it is allowed to allocate the single MSHR.
    reg [15:0] cache_set_epoch [0:`CACHE_BLK_NUM-1];
`else
    wire [1:0]  pf_confidence = 2'd0;
    wire        pf_last_demand_valid = 1'b0;
    wire [26:0] pf_last_demand_line = 27'd0;
    wire        pf_pending_valid = 1'b0;
    wire [26:0] pf_pending_line = 27'd0;
    wire        pf_early_probe_valid = 1'b0;
    wire        pf_early_miss_valid = 1'b0;
    wire [26:0] pf_early_line_r = 27'd0;
    wire [INDEX_WID-1:0] pf_early_index_r = {INDEX_WID{1'b0}};
    wire        pf_early_miss_way_r = 1'b0;
`endif

    reg        req_is_prefetch_r;
    reg        mshr_is_prefetch;

`ifndef SYNTHESIS
    reg [63:0] pf_candidate_cnt;
    reg [63:0] pf_pending_overwrite_cnt;
    reg [63:0] pf_tag_launch_cnt;
    reg [63:0] pf_tag_hit_redundant_cnt;
    reg [63:0] pf_tag_miss_cnt;
    reg [63:0] pf_tag_abort_cnt;
    reg [63:0] pf_early_tag_launch_cnt;
    reg [63:0] pf_early_start_cnt;
    reg [63:0] pf_bus_launch_cnt;
    reg [63:0] pf_cancel_cnt;
    reg [63:0] pf_fill_complete_cnt;
    reg [63:0] pf_useful_hit_cnt;
    reg [63:0] pf_useless_evict_cnt;
    reg [63:0] pf_demand_merge_imm_cnt;
    reg [63:0] pf_demand_merge_wait_cnt;
    reg [63:0] pf_suppressed_by_demand_cnt;
    reg [63:0] pf_suppressed_by_fifo_cnt;
    reg [63:0] pf_suppressed_by_mshr_cnt;
    reg [63:0] pf_suppressed_by_store_cnt;
    reg [63:0] pf_suppressed_by_bus_cnt;
    reg [63:0] pf_suppressed_by_maint_cnt;
    reg [63:0] pf_active_cycles_cnt;

    // One-cycle metadata-read provenance used to check the synchronous
    // Port-A lookup boundary.  These are observation-only registers.
    reg [3:0] pf_array_read_owner_q;
    reg [INDEX_WID-1:0] pf_array_read_index_q;

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

    // Line-based write-combining buffer.  A WCB entry owns the memory-side
    // write obligation after the scalar Store FIFO has posted the store to
    // the LSU.  Byte validity is kept independently from the data so a
    // partial store never exposes an uninitialized byte to a younger Load.
    reg [26:0] wcb_line        [0:WCB_DEPTH-1];
    reg [255:0] wcb_data       [0:WCB_DEPTH-1];
    reg [31:0]  wcb_byte_valid [0:WCB_DEPTH-1];
    reg         wcb_valid      [0:WCB_DEPTH-1];
    reg         wcb_draining   [0:WCB_DEPTH-1];

    reg         wcb_drain_active;
    reg [1:0]   wcb_drain_idx;
    reg [7:0]   wcb_drain_sent_mask;
    reg [3:0]   wcb_drain_pending_count;
    reg [1:0]   wcb_order       [0:WCB_DEPTH-1];
    reg [1:0]   wcb_order_head;
    reg [1:0]   wcb_order_tail;
    reg [2:0]   wcb_order_count;

    reg [1:0]  store_fifo_head;
    reg [1:0]  store_fifo_tail;
    reg [2:0]  store_fifo_count;

    function automatic [255:0] merge_wcb_line;
        input [255:0] base_line;
        input [4:0]   store_offset;
        input [3:0]   byte_enable;
        input [31:0]  store_data;
        reg [255:0] result;
        integer byte_idx;
        begin
            result = base_line;
            for (byte_idx = 0; byte_idx < 4; byte_idx = byte_idx + 1)
                if (byte_enable[byte_idx])
                    result[store_offset[4:2]*32 + byte_idx*8 +: 8] =
                        store_data[byte_idx*8 +: 8];
            merge_wcb_line = result;
        end
    endfunction

    function automatic [31:0] merge_wcb_byte_valid;
        input [31:0] base_mask;
        input [4:0]  store_offset;
        input [3:0]  byte_enable;
        reg [31:0] result;
        integer byte_idx;
        begin
            result = base_mask;
            for (byte_idx = 0; byte_idx < 4; byte_idx = byte_idx + 1)
                if (byte_enable[byte_idx])
                    result[store_offset[4:2]*4 + byte_idx] = 1'b1;
            merge_wcb_byte_valid = result;
        end
    endfunction

    function automatic [3:0] select_wcb_word_mask;
        input [31:0] mask;
        input [2:0]  word_index;
        begin
            case (word_index)
                3'd0: select_wcb_word_mask = mask[3:0];
                3'd1: select_wcb_word_mask = mask[7:4];
                3'd2: select_wcb_word_mask = mask[11:8];
                3'd3: select_wcb_word_mask = mask[15:12];
                3'd4: select_wcb_word_mask = mask[19:16];
                3'd5: select_wcb_word_mask = mask[23:20];
                3'd6: select_wcb_word_mask = mask[27:24];
                default: select_wcb_word_mask = mask[31:28];
            endcase
        end
    endfunction

    function automatic [31:0] select_wcb_word_data;
        input [255:0] line_data;
        input [2:0]   word_index;
        begin
            select_wcb_word_data = line_data[word_index*32 +: 32];
        end
    endfunction

    // Overlay every valid byte from the WCB.  This is used both by the
    // critical-word response and by a line refill commit, so a demand read
    // may safely proceed while an older line is still draining.
    function automatic [31:0] forward_from_wcb_word;
        input [31:0] base_data;
        input [31:0] load_addr;
        reg [31:0] result;
        integer wcb_idx;
        begin
            result = base_data;
            for (wcb_idx = 0; wcb_idx < WCB_DEPTH; wcb_idx = wcb_idx + 1)
                if (wcb_valid[wcb_idx] &&
                    (wcb_line[wcb_idx] == load_addr[31:5]))
                    result = merge_store_bytes(
                        result,
                        select_wcb_word_mask(wcb_byte_valid[wcb_idx], load_addr[4:2]),
                        select_wcb_word_data(wcb_data[wcb_idx], load_addr[4:2]));
            forward_from_wcb_word = result;
        end
    endfunction

    function automatic [255:0] forward_from_wcb_line;
        input [255:0] base_line;
        input [26:0]  line_addr;
        reg [255:0] result;
        integer wcb_idx;
        integer byte_idx;
        begin
            result = base_line;
            for (wcb_idx = 0; wcb_idx < WCB_DEPTH; wcb_idx = wcb_idx + 1)
                if (wcb_valid[wcb_idx] && (wcb_line[wcb_idx] == line_addr))
                    for (byte_idx = 0; byte_idx < 32; byte_idx = byte_idx + 1)
                        if (wcb_byte_valid[wcb_idx][byte_idx])
                            result[byte_idx*8 +: 8] =
                                wcb_data[wcb_idx][byte_idx*8 +: 8];
            forward_from_wcb_line = result;
        end
    endfunction

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

    // A prefetch Tag probe has one registered metadata-read latency.  The
    // result is accounted for only in R_TAG_CHK; it cannot allocate an ORD
    // owner or emit a load completion.
    wire pf_tag_lookup_active = (r_state == R_TAG_CHK) && req_is_prefetch_r;
    wire pf_tag_hit_event    = pf_tag_lookup_active && r_hit;
    wire pf_tag_miss_event   = pf_tag_lookup_active && !r_hit && !mshr_valid;

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

    wire [2:0] wcb_valid_count = {2'b0, wcb_valid[0]} +
                                  {2'b0, wcb_valid[1]} +
                                  {2'b0, wcb_valid[2]} +
                                  {2'b0, wcb_valid[3]};
    wire wcb_empty = (wcb_valid_count == 3'd0);

    reg       wcb_merge_found;
    reg       wcb_blocked_same_line;
    reg       wcb_free_found;
    reg       wcb_drain_candidate_found;
    reg [1:0] wcb_merge_idx;
    reg [1:0] wcb_free_idx;
    reg [1:0] wcb_drain_candidate_idx;
    integer wcb_search_idx;

    // The same line is never merged into an entry that has started its
    // physical drain.  If that happens, the scalar FIFO simply waits for
    // the old entry to complete, which is the intended true-conflict rule.
    always @(*) begin
        wcb_merge_found          = 1'b0;
        wcb_blocked_same_line    = 1'b0;
        wcb_free_found           = 1'b0;
        wcb_drain_candidate_found= (wcb_order_count != 3'd0) &&
                                   wcb_valid[wcb_order_head] &&
                                   !wcb_draining[wcb_order_head];
        wcb_merge_idx            = 2'd0;
        wcb_free_idx             = 2'd0;
        wcb_drain_candidate_idx  = wcb_order_head;
        for (wcb_search_idx = 0; wcb_search_idx < WCB_DEPTH; wcb_search_idx = wcb_search_idx + 1) begin
            if (wcb_valid[wcb_search_idx] &&
                (wcb_line[wcb_search_idx] == store_fifo_addr[head_ptr][31:5])) begin
                if (wcb_draining[wcb_search_idx]) begin
                    wcb_blocked_same_line = 1'b1;
                end else if (!wcb_merge_found) begin
                    wcb_merge_found = 1'b1;
                    wcb_merge_idx   = wcb_search_idx[1:0];
                end
            end
            if (!wcb_valid[wcb_search_idx] && !wcb_free_found) begin
                wcb_free_found = 1'b1;
                wcb_free_idx   = wcb_search_idx[1:0];
            end
        end
    end

    wire wcb_merge_ok = !wcb_blocked_same_line &&
                        (wcb_merge_found || wcb_free_found);

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
                                wcb_empty && !wcb_drain_active && dev_widle;
    assign data_wready = cacheable_write_ready || uncached_write_ready;
    wire write_accept = data_wready && (|data_wen);
    assign data_wposted = write_accept && !incoming_w_uncached;
    assign data_wresp = (w_state == W_WR_WAIT) && dev_wdone;

    wire store_fifo_push = write_accept && !incoming_w_uncached;
    wire store_fifo_pop  = store_fifo_will_pop;

    // Once the cache-side update is complete, ownership moves from the
    // scalar Store FIFO into one line-based WCB entry.  This is the posted
    // completion seen by the LSU; physical completion is tracked separately.
    wire wcb_store_merge_fire = (store_fifo_count > 0) &&
                                 store_fifo_cache_updated[head_ptr] &&
                                 !store_fifo_ext_written[head_ptr] &&
                                 wcb_merge_ok &&
                                 (w_state == W_IDLE) && !maint_active;

    reg [2:0] wcb_drain_word_idx;
    reg [3:0] wcb_drain_word_wen;
    reg [31:0] wcb_drain_word_data;
    reg [7:0] wcb_drain_valid_word_mask;
    reg       wcb_drain_word_found;
    integer   wcb_word_idx;

    // Pick the oldest available line, then the first unsent valid word in
    // that line.  The payload is held stable while dev_wrdy is low.
    always @(*) begin
        wcb_drain_valid_word_mask = 8'h00;
        wcb_drain_word_idx        = 3'd0;
        wcb_drain_word_wen        = 4'h0;
        wcb_drain_word_data       = 32'h0;
        wcb_drain_word_found      = 1'b0;
        if (wcb_drain_active) begin
            for (wcb_word_idx = 0; wcb_word_idx < WORDS_PER_LINE; wcb_word_idx = wcb_word_idx + 1)
                if (select_wcb_word_mask(wcb_byte_valid[wcb_drain_idx], wcb_word_idx[2:0]) != 4'h0)
                    wcb_drain_valid_word_mask[wcb_word_idx] = 1'b1;

            if (!wcb_drain_sent_mask[0] && wcb_drain_valid_word_mask[0]) begin
                wcb_drain_word_idx = 3'd0;
                wcb_drain_word_found = 1'b1;
            end else if (!wcb_drain_sent_mask[1] && wcb_drain_valid_word_mask[1]) begin
                wcb_drain_word_idx = 3'd1;
                wcb_drain_word_found = 1'b1;
            end else if (!wcb_drain_sent_mask[2] && wcb_drain_valid_word_mask[2]) begin
                wcb_drain_word_idx = 3'd2;
                wcb_drain_word_found = 1'b1;
            end else if (!wcb_drain_sent_mask[3] && wcb_drain_valid_word_mask[3]) begin
                wcb_drain_word_idx = 3'd3;
                wcb_drain_word_found = 1'b1;
            end else if (!wcb_drain_sent_mask[4] && wcb_drain_valid_word_mask[4]) begin
                wcb_drain_word_idx = 3'd4;
                wcb_drain_word_found = 1'b1;
            end else if (!wcb_drain_sent_mask[5] && wcb_drain_valid_word_mask[5]) begin
                wcb_drain_word_idx = 3'd5;
                wcb_drain_word_found = 1'b1;
            end else if (!wcb_drain_sent_mask[6] && wcb_drain_valid_word_mask[6]) begin
                wcb_drain_word_idx = 3'd6;
                wcb_drain_word_found = 1'b1;
            end else if (!wcb_drain_sent_mask[7] && wcb_drain_valid_word_mask[7]) begin
                wcb_drain_word_idx = 3'd7;
                wcb_drain_word_found = 1'b1;
            end

            if (wcb_drain_word_found) begin
                wcb_drain_word_wen  = select_wcb_word_mask(
                    wcb_byte_valid[wcb_drain_idx], wcb_drain_word_idx);
                wcb_drain_word_data = select_wcb_word_data(
                    wcb_data[wcb_drain_idx], wcb_drain_word_idx);
            end
        end
    end

    wire wcb_cacheable_read_pending =
        ((r_state == R_TAG_CHK) || (r_state == R_RD_MEM) ||
         (r_state == R_REFILL)) ||
        ((req_fifo_count != 0) && !req_fifo_head_uncached) ||
        ((|data_ren) && !incoming_r_uncached) ||
        (replay_pending && !is_uncached_request(replay_raddr_r, replay_rcacheable_r));
    wire wcb_drain_start = !wcb_drain_active &&
                           wcb_drain_candidate_found &&
                           (wcb_valid_count != 0) &&
                           (w_state == W_IDLE) &&
                           !uncached_store_valid && !maint_active &&
                           !wcb_store_merge_fire &&
                           ((wcb_valid_count >= WCB_HIGH_WATERMARK) ||
                            !wcb_cacheable_read_pending);

    wire wcb_drain_write_valid = wcb_drain_active &&
                                  (wcb_drain_word_wen != 4'h0);
    wire wcb_drain_fire = wcb_drain_write_valid && dev_wrdy;
    wire wcb_done_for_count = wcb_drain_active && dev_wdone &&
                              (wcb_drain_pending_count != 4'd0);
    wire [7:0] wcb_drain_sent_after =
        wcb_drain_sent_mask |
        (wcb_drain_fire ? (8'b1 << wcb_drain_word_idx) : 8'h00);
    wire [3:0] wcb_drain_pending_after =
        wcb_drain_pending_count + (wcb_drain_fire ? 4'd1 : 4'd0) -
        (wcb_done_for_count ? 4'd1 : 4'd0);
    wire wcb_drain_all_sent_after =
        (wcb_drain_sent_after & wcb_drain_valid_word_mask) ==
        wcb_drain_valid_word_mask;
    wire wcb_drain_complete = wcb_drain_active &&
                               wcb_drain_all_sent_after &&
                               (wcb_drain_pending_after == 4'd0);
    wire wcb_order_push = wcb_store_merge_fire && !wcb_merge_found;
    wire wcb_order_pop  = wcb_drain_complete;

    // Existing instrumentation uses this name for a physical write fire.
    // It now denotes a WCB word accepted by the write bridge.
    wire external_write_fire = wcb_drain_fire;


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
                            ((r_state == R_REFILL) ||
                             ((r_state == R_RD_MEM) && !mshr_is_prefetch));

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

            // Track transfer of the independent memory-side obligation into
            // the line-based WCB.  Physical completion is intentionally not
            // required before the scalar Store FIFO entry is released.
            if (wcb_store_merge_fire) begin
                store_fifo_ext_written[head_ptr] <= 1'b1;
            end
        end
    end

    integer wcb_init_idx;
    always @(posedge cpu_clk or negedge cpu_rstn) begin
        if (!cpu_rstn) begin
            wcb_drain_active        <= 1'b0;
            wcb_drain_idx           <= 2'd0;
            wcb_drain_sent_mask     <= 8'h00;
            wcb_drain_pending_count <= 4'd0;
            wcb_order_head          <= 2'd0;
            wcb_order_tail          <= 2'd0;
            wcb_order_count         <= 3'd0;
            for (wcb_init_idx = 0; wcb_init_idx < WCB_DEPTH; wcb_init_idx = wcb_init_idx + 1) begin
                wcb_line[wcb_init_idx]        <= 27'h0;
                wcb_data[wcb_init_idx]        <= 256'h0;
                wcb_byte_valid[wcb_init_idx]  <= 32'h0;
                wcb_valid[wcb_init_idx]       <= 1'b0;
                wcb_draining[wcb_init_idx]    <= 1'b0;
                wcb_order[wcb_init_idx]       <= 2'd0;
            end
        end else begin
            if (wcb_store_merge_fire) begin
                if (wcb_merge_found) begin
                    wcb_data[wcb_merge_idx] <= merge_wcb_line(
                        wcb_data[wcb_merge_idx],
                        store_fifo_addr[head_ptr][4:0],
                        store_fifo_wen[head_ptr],
                        store_fifo_wdata[head_ptr]);
                    wcb_byte_valid[wcb_merge_idx] <= merge_wcb_byte_valid(
                        wcb_byte_valid[wcb_merge_idx],
                        store_fifo_addr[head_ptr][4:0],
                        store_fifo_wen[head_ptr]);
                end else begin
                    wcb_line[wcb_free_idx]       <= store_fifo_addr[head_ptr][31:5];
                    wcb_data[wcb_free_idx]       <= merge_wcb_line(
                        256'h0,
                        store_fifo_addr[head_ptr][4:0],
                        store_fifo_wen[head_ptr],
                        store_fifo_wdata[head_ptr]);
                    wcb_byte_valid[wcb_free_idx] <= merge_wcb_byte_valid(
                        32'h0,
                        store_fifo_addr[head_ptr][4:0],
                        store_fifo_wen[head_ptr]);
                    wcb_valid[wcb_free_idx]      <= 1'b1;
                    wcb_draining[wcb_free_idx]   <= 1'b0;
                end
            end

            if (wcb_order_push) begin
                wcb_order[wcb_order_tail] <= wcb_free_idx;
                wcb_order_tail            <= wcb_order_tail + 2'd1;
            end
            if (wcb_order_pop)
                wcb_order_head <= wcb_order_head + 2'd1;
            case ({wcb_order_push, wcb_order_pop})
                2'b10: wcb_order_count <= wcb_order_count + 3'd1;
                2'b01: wcb_order_count <= wcb_order_count - 3'd1;
                default: wcb_order_count <= wcb_order_count;
            endcase

            if (!wcb_drain_active) begin
                if (wcb_drain_start) begin
                    wcb_drain_active                         <= 1'b1;
                    wcb_drain_idx                            <= wcb_drain_candidate_idx;
                    wcb_drain_sent_mask                      <= 8'h00;
                    wcb_drain_pending_count                  <= 4'd0;
                    wcb_draining[wcb_drain_candidate_idx]    <= 1'b1;
                end
            end else begin
                if (wcb_drain_fire)
                    wcb_drain_sent_mask[wcb_drain_word_idx] <= 1'b1;

                case ({wcb_drain_fire, wcb_done_for_count})
                    2'b10: wcb_drain_pending_count <= wcb_drain_pending_count + 4'd1;
                    2'b01: wcb_drain_pending_count <= wcb_drain_pending_count - 4'd1;
                    default: wcb_drain_pending_count <= wcb_drain_pending_count;
                endcase

                // Do not release an entry on request acceptance.  It stays
                // valid until every accepted word has produced dev_wdone.
                if (wcb_drain_complete) begin
                    wcb_valid[wcb_drain_idx]       <= 1'b0;
                    wcb_draining[wcb_drain_idx]    <= 1'b0;
                    wcb_drain_active                <= 1'b0;
                    wcb_drain_sent_mask            <= 8'h00;
                    wcb_drain_pending_count        <= 4'd0;
                end
            end
        end
    end

    // 主 Load 流水线就绪条件
    wire load_can_start_cond = (((r_state == R_IDLE) || (r_state == R_TAG_CHK && r_hit)) && !replay_pending) &&
                               (w_state == W_IDLE) &&
                               !refill_commit && !maint_active &&
                               !((req_fifo_count != 0) && req_fifo_head_uncached &&
                                 (!wcb_empty || !dev_widle));

    wire load_accept_ready = load_can_start_cond || hur_probe_can_launch;

    wire ord_ready_release = (ord_count > 3'd0) &&
                             ord_valid[ord_head] && ord_ready[ord_head];

    wire prefetch_waiting_bus = mshr_valid && mshr_is_prefetch && (r_state == R_RD_MEM);

    // Load Request FIFO 出队 / 启动定义
    wire req_fifo_can_dequeue = (req_fifo_count > 0) && load_accept_ready &&
                                !replay_pending && !probe_checking_r &&
                                !prefetch_waiting_bus;
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

    // A2 and the functional predictor observe exactly one architectural
    // event: a cacheable Demand that reaches Tag Check and allocates the
    // single Demand MSHR.  Hits, repeated accesses to an already resident
    // line, uncached/MMIO accesses, and prefetch misses are excluded.
    wire demand_miss_alloc =
        (r_state == R_TAG_CHK) &&
        !r_hit &&
        !r_uncached &&
        !mshr_valid &&
        !req_is_prefetch_r;

    // A cacheable accepted request may still consume a pending candidate;
    // this cancellation does not update predictor history or confidence.
    wire demand_cacheable_accept = read_accept && !incoming_r_uncached;
    wire [26:0] accepted_demand_line = data_addr[31:5];

    wire cache_idle = (r_state == R_IDLE) &&
                      (w_state == W_IDLE) &&
                      (req_fifo_count == 2'd0) &&
                      !read_accept &&
                      !(|data_ren) &&
                      (ord_count == 3'd0) &&
                      (store_fifo_count == 3'd0) &&
                      wcb_empty && !wcb_drain_active &&
                      !replay_pending &&
                      !same_wait_any &&
                      !probe_checking_r &&
                      !mshr_valid &&
                      !maint_active &&
                      !maint_valid;

    wire [26:0] curr_demand_line = req_raddr_r[31:5];
    wire [26:0] next_demand_line = curr_demand_line + 27'd1;
    wire [31:0] next_line_addr   = {next_demand_line, 5'b0};
    wire [31:0] curr_line_addr   = {curr_demand_line, 5'b0};
    wire        cand_same_4k     = (curr_line_addr[31:12] == next_line_addr[31:12]);
    wire        cand_uncached    = is_uncached_request(next_line_addr, 1'b1);
    wire        cand_pass        = cand_same_4k && !cand_uncached;

    wire demand_line_changed = demand_miss_alloc &&
                                (!pf_last_demand_valid ||
                                 (curr_demand_line != pf_last_demand_line));

    reg [1:0] pf_confidence_next;
    always @(*) begin
        pf_confidence_next = pf_confidence;
        if (demand_miss_alloc) begin
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

    wire pf_pending_create = demand_miss_alloc && demand_line_changed &&
                             cand_pass && (pf_confidence_next >= 2'd2);

`ifndef SYNTHESIS
    wire a2_miss_line_changed = demand_miss_alloc &&
                                 (!last_miss_valid ||
                                  (req_raddr_r[31:5] != last_miss_line));
`endif

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

`ifdef ENABLE_DCACHE_NEXTLINE_PREFETCH
    // The early probe is deliberately narrower than the normal late probe:
    // it only uses an active Demand MSHR's otherwise-idle Array read window.
    // It never changes req_raddr_r, cache_meta_r*, probe_checking_r, or ORD.
    wire pf_early_candidate_consumed =
        demand_cacheable_accept &&
        (accepted_demand_line == pf_early_line_r);

    wire pf_early_miss_consumed =
        pf_early_miss_valid && pf_early_candidate_consumed;

    wire pf_early_target_mutation_now =
        (array_write_enable && (array_write_index == pf_early_index_r)) ||
        (hit_r && (r_cache_index == pf_early_index_r)) ||
        ((maint_state == M_APPLY) &&
         ((maint_mode_r == 2'b11) ||
          (maint_index_r == pf_early_index_r))) ||
        ((maint_state == M_ALL) &&
         (maint_count == pf_early_index_r));

    wire pf_early_epoch_ok =
        (cache_set_epoch[pf_early_index_r] == pf_early_epoch_r) &&
        !pf_early_target_mutation_now;

    wire pf_early_hit0 = pf_early_meta_r0[TAG_WID] &&
                         line_enabled0[pf_early_index_r] &&
                         (pf_early_meta_r0[TAG_WID-1:0] ==
                          pf_early_line_r[26:INDEX_WID]);
    wire pf_early_hit1 = pf_early_meta_r1[TAG_WID] &&
                         line_enabled1[pf_early_index_r] &&
                         (pf_early_meta_r1[TAG_WID-1:0] ==
                          pf_early_line_r[26:INDEX_WID]);
    wire pf_early_hit = pf_early_hit0 || pf_early_hit1;
    wire pf_early_miss_way_calc =
        (!pf_early_meta_r0[TAG_WID] || !line_enabled0[pf_early_index_r]) ? 1'b0 :
        ((!pf_early_meta_r1[TAG_WID] || !line_enabled1[pf_early_index_r]) ? 1'b1 :
         replace_way[pf_early_index_r]);

    wire pf_early_tag_hit_event = pf_early_probe_valid &&
                                   pf_early_epoch_ok &&
                                   !pf_early_candidate_consumed &&
                                   pf_early_hit;
    wire pf_early_tag_miss_event = pf_early_probe_valid &&
                                   pf_early_epoch_ok &&
                                   !pf_early_candidate_consumed &&
                                   !pf_early_hit;
    // A consumed candidate or a stale metadata snapshot is an explicit
    // abort.  It is never allowed to become an unvalidated direct MSHR.
    wire pf_early_tag_abort_event = pf_early_probe_valid &&
                                    (!pf_early_epoch_ok ||
                                     pf_early_candidate_consumed);

    wire pf_early_tag_launch_safe =
        pf_pending_valid &&
        mshr_valid && !mshr_is_prefetch &&
        ((r_state == R_RD_MEM) || (r_state == R_REFILL)) &&
        !pf_early_probe_valid &&
        !pf_early_miss_valid &&
        (req_fifo_count == 0) &&
        !read_accept && !(|data_ren) &&
        !replay_pending && !same_wait_any && !probe_checking_r &&
        (w_state == W_IDLE) &&
        !store_tag_launch && !store_update_launch && !store_tag_pending &&
        !maint_active && !maint_valid &&
        !refill_commit && !dev_rvalid &&
        !data_valid && !data_wresp &&
        (store_fifo_count == 0);

    wire pf_early_tag_launch = pf_early_tag_launch_safe;

    wire pf_early_start_safe =
        pf_early_miss_valid &&
        (r_state == R_IDLE) && !mshr_valid &&
        (req_fifo_count == 0) &&
        !read_accept && !(|data_ren) &&
        !replay_pending && !same_wait_any && !probe_checking_r &&
        (w_state == W_IDLE) &&
        !store_tag_launch && !store_update_launch && !store_tag_pending &&
        !maint_active && !maint_valid && !refill_commit &&
        (ord_count == 0) && !data_valid && !data_wresp &&
        (store_fifo_count == 0) && !external_write_fire &&
        pf_early_epoch_ok;

    wire pf_early_start = pf_early_start_safe;

    // If the captured miss way becomes stale before the direct start, let
    // the normal serialized Tag path revalidate it instead of trusting it.
    wire pf_early_requeue_event =
        pf_early_miss_valid && !pf_early_epoch_ok &&
        !pf_early_miss_consumed && !pf_pending_create;
`else
    wire pf_early_tag_launch = 1'b0;
    wire pf_early_start = 1'b0;
    wire pf_early_tag_hit_event = 1'b0;
    wire pf_early_tag_miss_event = 1'b0;
    wire pf_early_tag_abort_event = 1'b0;
    wire pf_early_requeue_event = 1'b0;
`endif

    wire pf_tag_launch = pf_launch || pf_early_tag_launch;
    wire pf_tag_lookup_active_total = pf_tag_lookup_active || pf_early_probe_valid;

`ifdef ENABLE_DCACHE_NEXTLINE_PREFETCH
    always @(posedge cpu_clk or negedge cpu_rstn) begin
        if (!cpu_rstn) begin
            pf_confidence        <= 2'd0;
            pf_last_demand_valid <= 1'b0;
            pf_last_demand_line  <= 27'd0;
            pf_pending_valid     <= 1'b0;
            pf_pending_line      <= 27'd0;
        end else begin
            if (demand_miss_alloc) begin
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
                end
            end

            // A demand hit can consume a candidate before its Tag probe is
            // launched.  It must not perturb the miss-only history above.
            if (demand_cacheable_accept && pf_pending_valid &&
                (accepted_demand_line == pf_pending_line) && !pf_pending_create)
                pf_pending_valid <= 1'b0;

            if (pf_tag_launch) begin
`ifndef SYNTHESIS
                pf_tag_launch_cnt <= pf_tag_launch_cnt + 64'd1;
`endif
                pf_pending_valid <= 1'b0;
            end else if ((r_state == R_TAG_CHK) && r_hit && req_is_prefetch_r) begin
                pf_pending_valid <= 1'b0;
            end else if (pf_early_tag_abort_event &&
                         !pf_early_candidate_consumed &&
                         !pf_pending_create) begin
                // Re-run a stale/contended early probe through the normal
                // serialized lookup path.  A demand that consumed the
                // candidate takes the other branch and drops it.
                pf_pending_valid <= 1'b1;
                pf_pending_line  <= pf_early_line_r;
            end else if (pf_early_requeue_event) begin
                pf_pending_valid <= 1'b1;
                pf_pending_line  <= pf_early_line_r;
            end
        end
    end
`endif

    wire pf_fifo_valid = (req_fifo_count != 0);

    wire pf_fifo_same_line =
        pf_fifo_valid &&
        !req_fifo_head_uncached &&
        (req_fifo_addr[req_fifo_head][31:5] == refill_raddr_r[31:5]);

    wire pf_input_valid = |data_ren;

    wire pf_input_same_line =
        pf_input_valid &&
        !incoming_r_uncached &&
        (data_addr[31:5] == refill_raddr_r[31:5]);

    wire pf_conflicting_demand =
        replay_pending ||
        maint_valid ||
        (pf_fifo_valid && !pf_fifo_same_line) ||
        (pf_input_valid && !pf_input_same_line);

    wire external_read_fire =
        (r_state == R_RD_MEM) &&
        dev_rrdy &&
        (
            !mshr_is_prefetch ||
            !pf_conflicting_demand
        );

    // A demand Tag miss already has a stable request context and a selected
    // refill way.  If the read bridge can accept the burst now, launch it in
    // the Tag-check cycle instead of spending one extra cycle in R_RD_MEM.
    // The MSHR/refill registers are still captured on this same clock edge;
    // the asynchronous read bridge cannot return a beat before that context
    // exists, so the existing R_REFILL response/ORD path remains unchanged.
    wire demand_tag_read_fire =
        (r_state == R_TAG_CHK) &&
        !r_hit &&
        !r_uncached &&
        !req_is_prefetch_r &&
        !mshr_valid &&
        !maint_active &&
        dev_rrdy;

    wire pf_waiting_for_bus =
        mshr_valid &&
        mshr_is_prefetch &&
        (r_state == R_RD_MEM);

    wire pf_cancel_before_bus =
        pf_waiting_for_bus &&
        pf_conflicting_demand &&
        !external_read_fire;

    wire pf_bus_launch_fire =
        pf_waiting_for_bus &&
        external_read_fire;

    wire [INDEX_WID-1:0] incoming_index =
        data_addr[INDEX_WID+OFFSET_WID-1:OFFSET_WID];
    wire [INDEX_WID-1:0] pf_pending_index = pf_pending_line[INDEX_WID-1:0];

    // Load req_r* 寄存器更新 (including ord slot propagation)
    always @(posedge cpu_clk or negedge cpu_rstn) begin
        if (!cpu_rstn) begin
            req_raddr_r       <= 32'h0;
            req_ren_r         <= 4'h0;
            req_rcacheable_r  <= 1'b0;
            req_slot_r        <= 2'd0;
            req_is_prefetch_r <= 1'b0;
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
        end else if (pf_early_start) begin
            req_raddr_r       <= {pf_early_line_r, 5'b0};
            req_ren_r         <= 4'hf;
            req_rcacheable_r  <= 1'b1;
            req_slot_r        <= 2'd0;
            req_is_prefetch_r <= 1'b1;
        end else if (pf_launch) begin
            req_raddr_r       <= {pf_pending_line, 5'b0};
            req_ren_r         <= 4'hf;
            req_rcacheable_r  <= 1'b1;
            req_slot_r        <= 2'd0;
            req_is_prefetch_r <= 1'b1;
        end else if (pf_cancel_before_bus ||
                     ((r_state == R_TAG_CHK) && r_hit && req_is_prefetch_r) ||
                     (refill_commit && mshr_is_prefetch)) begin
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
                end else if (pf_early_start) begin
                    r_nstat = R_RD_MEM;
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
                end else if (demand_tag_read_fire) begin
                    r_nstat = R_REFILL;
                end else begin
                    r_nstat = R_RD_MEM;
                end
            end

            R_RD_MEM: begin
                if (mshr_is_prefetch && pf_cancel_before_bus)
                    r_nstat = R_IDLE;
                else if (external_read_fire)
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
        refill_commit_data = forward_from_wcb_line(
            refill_commit_data, refill_raddr_r[31:5]);
    end

    // CWF_EN makes the bridge launch at the requested word.  Identify the
    // critical beat by its line index instead of assuming it is always the
    // first word of the line.
    wire refill_word_valid = (r_state == R_REFILL) && dev_rvalid &&
                              (arriving_word_index ==
                               refill_offset_r[OFFSET_WID-1:2]);

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
            end else if (pf_early_start) begin
                // Direct start is legal only after the independent early
                // Tag result has passed its epoch check.  It allocates the
                // same single prefetch MSHR as the late path and no ORD slot.
                refill_way_r           <= pf_early_miss_way_r;
                refill_raddr_r         <= {pf_early_line_r, 5'b0};
                refill_ren_r            <= 4'hf;
                refill_rcacheable_r    <= 1'b1;
                refill_word_valid_mask <= 8'h0;
                mshr_valid              <= 1'b1;
                mshr_slot_id            <= 2'd0;
                mshr_critical_done     <= 1'b0;
                mshr_is_prefetch       <= 1'b1;
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
                else if (pf_tag_miss_event)
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
        final_rdata = forward_from_store_fifo(
            forward_from_wcb_word(hit_rdata, req_raddr_r),
            req_raddr_r, head_ptr, store_fifo_count);
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
        same_line_imm_final_rdata = forward_from_store_fifo(
            forward_from_wcb_word(same_line_imm_rdata, req_raddr_r),
            req_raddr_r, head_ptr, store_fifo_count);
    end

    // The critical refill beat can race an older posted store.  Apply the
    // same WCB/Store-FIFO forwarding used by cache hits before exposing the
    // early-restart response to the LSU.
    wire [31:0] refill_critical_rdata = forward_from_store_fifo(
        forward_from_wcb_word(dev_rdata, refill_raddr_r),
        refill_raddr_r, head_ptr, store_fifo_count);

    reg [31:0] same_wait_final_rdata [0:ORD_DEPTH-1];
    integer same_wait_data_idx;
    always @(*) begin
        for (same_wait_data_idx = 0; same_wait_data_idx < ORD_DEPTH;
             same_wait_data_idx = same_wait_data_idx + 1) begin
            same_wait_final_rdata[same_wait_data_idx] =
                forward_from_store_fifo(
                    forward_from_wcb_word(
                        dev_rdata, same_wait_addr[same_wait_data_idx]),
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
                    data_rdata <= refill_critical_rdata;
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
                    ord_data[mshr_slot_id]  <= refill_critical_rdata;
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
        if (demand_tag_read_fire) begin
            cpu_ren   = 4'b1111;
            cpu_raddr = {req_raddr_r[31:2], 2'b00};
            cpu_rburst = 1'b1;
        end else if (r_state == R_RD_MEM && dev_rrdy &&
                     (!mshr_is_prefetch || !pf_conflicting_demand)) begin
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
        end else if (wcb_drain_write_valid) begin
            cpu_wen   = wcb_drain_word_wen;
            cpu_waddr = {wcb_line[wcb_drain_idx], 5'b0} +
                        (wcb_drain_word_idx * 32'd4);
            cpu_wdata = wcb_drain_word_data;
        end else begin
            cpu_wen   = 4'h0;
            cpu_waddr = 32'h0;
            cpu_wdata = 32'h0;
        end
    end

    // =========================================================
    // 7. External bus generation and central cache-array arbitration
    // =========================================================
    wire replay_lookup_launch = (r_state == R_IDLE) && replay_pending;

    // Port-A read priority is explicit.  A prefetch Tag lookup is the
    // lowest-priority functional lookup and uses the candidate line's set
    // index, not the previous request context's index.
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
        end else if (pf_early_tag_launch) begin
            array_read_owner = ARRAY_OWNER_PREFETCH_TAG;
            array_read_index = pf_pending_index;
            array_read_word  = {LINE_WORD_IW{1'b0}};
        end else if (pf_tag_launch) begin
            array_read_owner = ARRAY_OWNER_PREFETCH_TAG;
            array_read_index = pf_pending_index;
            array_read_word  = {LINE_WORD_IW{1'b0}};
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

`ifdef ENABLE_DCACHE_NEXTLINE_PREFETCH
    integer cache_epoch_idx;

    // Keep the mutation proof in one sequential owner.  A single increment
    // is sufficient when two conservative mutation causes coincide in one
    // cycle; the early snapshot only needs to observe that the set changed.
    always @(posedge cpu_clk or negedge cpu_rstn) begin
        if (!cpu_rstn) begin
            for (cache_epoch_idx = 0;
                 cache_epoch_idx < `CACHE_BLK_NUM;
                 cache_epoch_idx = cache_epoch_idx + 1)
                cache_set_epoch[cache_epoch_idx] <= 16'd0;
        end else if ((maint_state == M_APPLY) && (maint_mode_r == 2'b11)) begin
            for (cache_epoch_idx = 0;
                 cache_epoch_idx < `CACHE_BLK_NUM;
                 cache_epoch_idx = cache_epoch_idx + 1)
                cache_set_epoch[cache_epoch_idx] <=
                    cache_set_epoch[cache_epoch_idx] + 16'd1;
        end else if (maint_state == M_ALL) begin
            cache_set_epoch[maint_count] <= cache_set_epoch[maint_count] + 16'd1;
        end else if (array_write_enable) begin
            cache_set_epoch[array_write_index] <=
                cache_set_epoch[array_write_index] + 16'd1;
        end else if (hit_r) begin
            cache_set_epoch[r_cache_index] <=
                cache_set_epoch[r_cache_index] + 16'd1;
        end else if (maint_state == M_APPLY) begin
            cache_set_epoch[maint_index_r] <=
                cache_set_epoch[maint_index_r] + 16'd1;
        end
    end

    // The early Tag context has no architectural response side effects.  It
    // either records a validated miss for a later direct prefetch start or
    // disappears so the normal late lookup can revalidate the candidate.
    always @(posedge cpu_clk or negedge cpu_rstn) begin
        if (!cpu_rstn) begin
            pf_early_probe_valid <= 1'b0;
            pf_early_miss_valid  <= 1'b0;
            pf_early_line_r      <= 27'd0;
            pf_early_index_r     <= {INDEX_WID{1'b0}};
            pf_early_meta_r0     <= {(TAG_WID+1){1'b0}};
            pf_early_meta_r1     <= {(TAG_WID+1){1'b0}};
            pf_early_epoch_r     <= 16'd0;
            pf_early_miss_way_r  <= 1'b0;
        end else if (pf_early_tag_launch) begin
            pf_early_probe_valid <= 1'b1;
            pf_early_miss_valid  <= 1'b0;
            pf_early_line_r      <= pf_pending_line;
            pf_early_index_r     <= pf_pending_index;
            pf_early_meta_r0     <= cache_meta_way0[pf_pending_index];
            pf_early_meta_r1     <= cache_meta_way1[pf_pending_index];
            pf_early_epoch_r     <= cache_set_epoch[pf_pending_index];
        end else if (pf_early_probe_valid) begin
            pf_early_probe_valid <= 1'b0;
            if (pf_early_tag_miss_event) begin
                pf_early_miss_valid <= 1'b1;
                pf_early_miss_way_r <= pf_early_miss_way_calc;
            end else begin
                pf_early_miss_valid <= 1'b0;
            end
        end else if (pf_pending_create || pf_early_miss_consumed ||
                     pf_early_requeue_event || pf_early_start) begin
            pf_early_miss_valid <= 1'b0;
        end
    end
`endif

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
            // The Store FIFO completion bit is the WCB merge event, not the
            // later physical bus completion.
            prev_ext_fire      <= wcb_store_merge_fire;
            prev_ext_fire_head <= head_ptr;

            if (store_fifo_push)
                store_fifo_push_count <= store_fifo_push_count + 64'd1;
            if (store_fifo_pop)
                store_fifo_pop_count <= store_fifo_pop_count + 64'd1;
            if (wcb_store_merge_fire)
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

            // 5. The head cannot retire until local cache update and WCB
            // ownership transfer both finish.
            if (store_fifo_pop && (!store_fifo_cache_updated[head_ptr] || !store_fifo_ext_written[head_ptr]))
                $fatal(1, "[DCACHE-ASSERT] Store FIFO popped head before cache update and WCB merge completed!");

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
                    $fatal(1, "[DCACHE-ASSERT] store_fifo_ext_written set without WCB merge event!");
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
                         wcb_empty && !wcb_drain_active && dev_widle &&
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
            pf_tag_abort_cnt             <= 64'd0;
            pf_early_tag_launch_cnt      <= 64'd0;
            pf_early_start_cnt           <= 64'd0;
            pf_bus_launch_cnt            <= 64'd0;
            pf_cancel_cnt                <= 64'd0;
            pf_fill_complete_cnt         <= 64'd0;
            pf_useful_hit_cnt            <= 64'd0;
            pf_useless_evict_cnt         <= 64'd0;
            pf_demand_merge_imm_cnt      <= 64'd0;
            pf_demand_merge_wait_cnt     <= 64'd0;
            pf_suppressed_by_demand_cnt  <= 64'd0;
            pf_suppressed_by_fifo_cnt    <= 64'd0;
            pf_suppressed_by_mshr_cnt    <= 64'd0;
            pf_suppressed_by_store_cnt   <= 64'd0;
            pf_suppressed_by_bus_cnt     <= 64'd0;
            pf_suppressed_by_maint_cnt   <= 64'd0;
            pf_active_cycles_cnt         <= 64'd0;
            pf_line_way0                 <= {`CACHE_BLK_NUM{1'b0}};
            pf_line_way1                 <= {`CACHE_BLK_NUM{1'b0}};
            pf_array_read_owner_q        <= ARRAY_OWNER_CONTEXT_HOLD;
            pf_array_read_index_q        <= {INDEX_WID{1'b0}};
        end else begin
            pf_array_read_owner_q <= array_read_owner;
            pf_array_read_index_q <= array_read_index;
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
                $display("[DCACHE-PF-A3-STATS] cycles=%0d candidate=%0d overwrite=%0d tag_probe=%0d tag_hit_redundant=%0d tag_miss=%0d tag_abort=%0d tag_inflight=%0d early_probe=%0d early_start=%0d bus_launch=%0d cancel=%0d fill=%0d useful_hit=%0d merge_imm=%0d merge_wait=%0d useless_evict=%0d suppressed_by_demand=%0d suppressed_by_fifo=%0d suppressed_by_mshr=%0d suppressed_by_store=%0d suppressed_by_bus=%0d suppressed_by_maint=%0d active_cycles=%0d confidence=%0d pending=%0d",
                         hur_cycle_count, pf_candidate_cnt, pf_pending_overwrite_cnt, pf_tag_launch_cnt, pf_tag_hit_redundant_cnt, pf_tag_miss_cnt, pf_tag_abort_cnt, pf_tag_lookup_active_total, pf_early_tag_launch_cnt, pf_early_start_cnt, pf_bus_launch_cnt, pf_cancel_cnt, pf_fill_complete_cnt, pf_useful_hit_cnt, pf_demand_merge_imm_cnt, pf_demand_merge_wait_cnt, pf_useless_evict_cnt, pf_suppressed_by_demand_cnt, pf_suppressed_by_fifo_cnt, pf_suppressed_by_mshr_cnt, pf_suppressed_by_store_cnt, pf_suppressed_by_bus_cnt, pf_suppressed_by_maint_cnt, pf_active_cycles_cnt, pf_confidence, pf_pending_valid);

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
            if (demand_miss_alloc) begin
                interval_demand_miss_cnt <= interval_demand_miss_cnt + 64'd1;

                // Track demand word offset distribution
                interval_word_offset_cnt[req_raddr_r[4:2]] <= interval_word_offset_cnt[req_raddr_r[4:2]] + 64'd1;

                // Evaluate sequential miss stream.  A repeated miss to the
                // same line is still counted above, but it does not alter
                // the sequence history or confidence state.
                if (a2_miss_line_changed) begin
                    if (last_miss_valid &&
                        (req_raddr_r[31:5] == last_miss_line + 27'd1)) begin
                        if (stream_conf < 2'd3)
                            stream_conf <= stream_conf + 2'd1;
                    end else if (last_miss_valid) begin
                        if (stream_conf > 2'd0)
                            stream_conf <= stream_conf - 2'd1;
                    end
                    last_miss_line  <= req_raddr_r[31:5];
                    last_miss_valid <= 1'b1;
                end

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

                // Candidate accounting follows the same changed-line rule
                // as the functional predictor.
                if (a2_miss_line_changed) begin
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
            if (pf_early_tag_launch)
                pf_early_tag_launch_cnt <= pf_early_tag_launch_cnt + 64'd1;
            if (pf_early_start)
                pf_early_start_cnt <= pf_early_start_cnt + 64'd1;
            if (pf_tag_hit_event || pf_early_tag_hit_event)
                pf_tag_hit_redundant_cnt <= pf_tag_hit_redundant_cnt + 64'd1;
            if (pf_early_tag_miss_event)
                pf_tag_miss_cnt <= pf_tag_miss_cnt + 64'd1;
            if (pf_early_tag_abort_event)
                pf_tag_abort_cnt <= pf_tag_abort_cnt + 64'd1;

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
                    pf_suppressed_by_demand_cnt <= pf_suppressed_by_demand_cnt + 64'd1;
                end else if ((req_fifo_count != 0) || replay_pending || same_wait_any || probe_checking_r) begin
                    pf_suppressed_by_fifo_cnt <= pf_suppressed_by_fifo_cnt + 64'd1;
                end else if (mshr_valid || (r_state != R_IDLE)) begin
                    pf_suppressed_by_mshr_cnt <= pf_suppressed_by_mshr_cnt + 64'd1;
                end else if (maint_active || maint_valid) begin
                    pf_suppressed_by_maint_cnt <= pf_suppressed_by_maint_cnt + 64'd1;
                end else if (store_tag_launch || store_update_launch || store_tag_pending || (w_state != W_IDLE)) begin
                    pf_suppressed_by_store_cnt <= pf_suppressed_by_store_cnt + 64'd1;
                end else if (!dev_widle) begin
                    pf_suppressed_by_bus_cnt <= pf_suppressed_by_bus_cnt + 64'd1;
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

            if (mshr_valid && mshr_is_prefetch && (r_state == R_RD_MEM) && req_fifo_pop)
                $fatal(1, "[DCACHE-ASSERT] Prefetch in R_RD_MEM popped req_fifo!");
            if (pf_cancel_before_bus && req_fifo_pop)
                $fatal(1, "[DCACHE-ASSERT] Prefetch cancel popped req_fifo!");
            if (pf_bus_launch_fire && !dev_rrdy)
                $fatal(1, "[DCACHE-ASSERT] Prefetch bus launch without dev_rrdy!");
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

            if (pf_tag_launch_cnt !=
                (pf_tag_hit_redundant_cnt + pf_tag_miss_cnt +
                 pf_tag_abort_cnt +
                 {63'd0, pf_tag_lookup_active_total}))
                $fatal(1, "[DCACHE-ASSERT] Prefetch Tag accounting conservation failure!");

            if (pf_tag_lookup_active &&
                ((pf_array_read_owner_q != ARRAY_OWNER_PREFETCH_TAG) ||
                 (pf_array_read_index_q != r_cache_index)))
                $fatal(1, "[DCACHE-ASSERT] Prefetch Tag result used the wrong Array read context!");

            if (pf_tag_lookup_active && ord_aux_event)
                $fatal(1, "[DCACHE-ASSERT] Prefetch Tag lookup generated a Load completion!");

            if (pf_early_probe_valid &&
                ((pf_array_read_owner_q != ARRAY_OWNER_PREFETCH_TAG) ||
                 (pf_array_read_index_q != pf_early_index_r)))
                $fatal(1, "[DCACHE-ASSERT] Early prefetch Tag used the wrong Array read context!");

            if (pf_early_probe_valid &&
                (!mshr_valid || mshr_is_prefetch))
                $fatal(1, "[DCACHE-ASSERT] Early prefetch Tag was not owned by a Demand MSHR!");

            if (pf_early_start && mshr_valid)
                $fatal(1, "[DCACHE-ASSERT] Early prefetch start attempted to overwrite the active MSHR!");

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
            is_peripheral =
                ((addr >= 32'h1f00_0000) && (addr < 32'h1f60_0000)) ||
                (addr[31:16] == 16'hBFAF) ||
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

// -----------------------------------------------------------------------------
// TaggedDCache: first true non-blocking demand path
// -----------------------------------------------------------------------------
// This implementation deliberately keeps the external SRAM protocol simple:
// one refill burst may be active at a time and the two-entry refill-order FIFO
// identifies which internal MSHR owns that burst.  Internally, however, two
// distinct cache lines may be represented at once and up to eight Load TIDs
// may wait for hits, refill beats, or a merged MSHR line.
module TaggedDCache #(
    // A newly allocated MSHR is guarded by mshr_word_valid before any
    // consumer can read its data.  Keeping this knob allows a quick timing
    // A/B without changing the default behavior; the optimized setting can
    // omit the 256-bit allocation clear and leave only the validity clear.
    parameter CLEAR_MSHR_DATA_ON_ALLOC = 1'b0
) (
    input  wire         cpu_rstn,
    input  wire         cpu_clk,
    input  wire [3:0]   data_ren,
    input  wire [31:0]  data_addr,
    input  wire         data_cacheable,
    input  wire [2:0]   data_rtid,
    output wire         data_rready,
    output reg          data_valid,
    output reg  [31:0]  data_rdata,
    output reg  [2:0]   data_rtid_out,
    input  wire [3:0]   data_wen,
    input  wire [31:0]  data_wdata,
    output wire         data_wready,
    output wire         data_wposted,
    output wire         data_wresp,
    input  wire         line_alloc_valid,
    input  wire [31:0]  line_alloc_addr,
    input  wire [`CACHE_BLK_SIZE-1:0] line_alloc_data,
    input  wire [`CACHE_BLK_LEN-1:0] line_alloc_word_mask,
    output wire         line_alloc_ready,
    input  wire         dev_wrdy,
    input  wire         dev_wdone,
    input  wire         dev_widle,
    output reg  [3:0]   cpu_wen,
    output reg  [31:0]  cpu_waddr,
    output reg  [31:0]  cpu_wdata,
    output reg          cpu_wcacheable,
    input  wire         dev_rrdy,
    output reg  [3:0]   cpu_ren,
    output reg  [31:0]  cpu_raddr,
    output reg          cpu_rburst,
    input  wire         dev_rvalid,
    input  wire [31:0]  dev_rdata,
    input  wire         dev_rrdy1,
    output reg  [3:0]   cpu_ren1,
    output reg  [31:0]  cpu_raddr1,
    output reg          cpu_rburst1,
    input  wire         dev_rvalid1,
    input  wire [31:0]  dev_rdata1,
    input  wire         maint_valid,
    output wire         maint_ready,
    output reg          maint_done,
    input  wire         maint_all,
    input  wire [1:0]   maint_mode,
    input  wire [31:0]  maint_addr,
    input  wire [31:0]  maint_ctag
);
    localparam integer INDEX_WID = 5;
    localparam integer OFFSET_WID = 5;
    localparam integer TAG_WID = 22;
    localparam integer LINE_WORDS = 8;
    localparam integer LINE_BITS = 256;
    localparam integer CACHE_LINES = 32;
    localparam integer MSHR_COUNT = 2;
    localparam integer TID_COUNT = 8;
    localparam integer REQ_DEPTH = 2;
    localparam integer WCB_DEPTH = 4;
    localparam integer HIGH_WATERMARK = 3;
    // Give a partially filled line a bounded grace period to absorb the
    // next Store.  The old policy drained whenever no Load was pending;
    // that made a short gap in a store loop turn every line into a
    // one-word transaction and blocked same-line merging while it drained.
    localparam [5:0] WCB_IDLE_DRAIN_LIMIT = 6'd31;
    function automatic is_uncached_request;
        input [31:0] addr;
        input        cacheable;
        begin
            is_uncached_request = !cacheable ||
                                  ((addr >= 32'h1f00_0000) &&
                                   (addr <  32'h1f60_0000)) ||
                                  (addr[31:16] == 16'hBFAF) ||
                                  (addr[31:16] == 16'hBFD0);
        end
    endfunction

    function automatic is_ext_addr;
        input [31:0] addr;
        begin
            is_ext_addr = (addr >= 32'h1c40_0000) &&
                          (addr <  32'h1c80_0000);
        end
    endfunction

    function automatic [31:0] merge_bytes;
        input [31:0] base_data;
        input [3:0]  byte_enable;
        input [31:0] write_data;
        reg [31:0] result;
        integer bi;
        begin
            result = base_data;
            for (bi = 0; bi < 4; bi = bi + 1)
                if (byte_enable[bi])
                    result[bi*8 +: 8] = write_data[bi*8 +: 8];
            merge_bytes = result;
        end
    endfunction

    function automatic [255:0] merge_line_store;
        input [255:0] base_line;
        input [4:0]   byte_offset;
        input [3:0]   byte_enable;
        input [31:0]  write_data;
        reg [255:0] result;
        integer bi;
        begin
            result = base_line;
            for (bi = 0; bi < 4; bi = bi + 1)
                if (byte_enable[bi])
                    result[byte_offset[4:2]*32 + bi*8 +: 8] =
                        write_data[bi*8 +: 8];
            merge_line_store = result;
        end
    endfunction

    function automatic [255:0] merge_refill_word;
        input [255:0] base_line;
        input [2:0]   word_index;
        input [31:0]  word_data;
        reg [255:0] result;
        begin
            result = base_line;
            result[word_index*32 +: 32] = word_data;
            merge_refill_word = result;
        end
    endfunction

    function automatic [31:0] select_word;
        input [255:0] line_data;
        input [2:0]   word_index;
        begin
            select_word = line_data[word_index*32 +: 32];
        end
    endfunction

    reg [26:0] wcb_line [0:WCB_DEPTH-1];
    reg [255:0] wcb_data [0:WCB_DEPTH-1];
    reg [31:0] wcb_byte_valid [0:WCB_DEPTH-1];
    reg wcb_valid [0:WCB_DEPTH-1];
    reg wcb_draining [0:WCB_DEPTH-1];
    reg [1:0] wcb_order [0:WCB_DEPTH-1];
    reg [1:0] wcb_order_head, wcb_order_tail;
    reg [2:0] wcb_order_count;
    reg wcb_drain_active;
    reg [1:0] wcb_drain_idx;
    reg [7:0] wcb_drain_sent_mask;
    reg [3:0] wcb_drain_pending_count;
    // Per-word drain mask snapshot (replaces 32-bit byte mask)
    reg [7:0] wcb_drain_word_valid_q;
    reg [3:0] wcb_drain_word_wen_q [0:7];
    reg [5:0] wcb_idle_count;

    function automatic [255:0] wcb_merge_line;
        input [255:0] base_line;
        input [4:0] byte_offset;
        input [3:0] byte_enable;
        input [31:0] write_data;
        begin
            wcb_merge_line = merge_line_store(base_line, byte_offset,
                                              byte_enable, write_data);
        end
    endfunction

    function automatic [31:0] wcb_merge_mask;
        input [31:0] base_mask;
        input [4:0] byte_offset;
        input [3:0] byte_enable;
        reg [31:0] result;
        integer mi;
        begin
            result = base_mask;
            for (mi = 0; mi < 4; mi = mi + 1)
                if (byte_enable[mi])
                    result[byte_offset[4:2]*4 + mi] = 1'b1;
            wcb_merge_mask = result;
        end
    endfunction

    function automatic [3:0] wcb_word_mask;
        input [31:0] byte_mask;
        input [2:0] word_index;
        begin
            wcb_word_mask = byte_mask[word_index*4 +: 4];
        end
    endfunction

    function automatic [31:0] forward_wcb_word;
        input [31:0] base_data;
        input [31:0] load_addr;
        reg [31:0] result;
        integer wi;
        begin
            result = base_data;
            for (wi = 0; wi < WCB_DEPTH; wi = wi + 1)
                if (wcb_valid[wi] && (wcb_line[wi] == load_addr[31:5]))
                    result = merge_bytes(result,
                        wcb_word_mask(wcb_byte_valid[wi], load_addr[4:2]),
                        select_word(wcb_data[wi], load_addr[4:2]));
            forward_wcb_word = result;
        end
    endfunction

    function automatic [255:0] forward_wcb_line;
        input [255:0] base_line;
        input [26:0] line_addr;
        reg [255:0] result;
        integer li;
        integer bj;
        begin
            result = base_line;
            for (li = 0; li < WCB_DEPTH; li = li + 1)
                if (wcb_valid[li] && (wcb_line[li] == line_addr))
                    for (bj = 0; bj < 32; bj = bj + 1)
                        if (wcb_byte_valid[li][bj])
                            result[bj*8 +: 8] = wcb_data[li][bj*8 +: 8];
            forward_wcb_line = result;
        end
    endfunction

    reg [TAG_WID-1:0] cache_tag0 [0:CACHE_LINES-1];
    reg [TAG_WID-1:0] cache_tag1 [0:CACHE_LINES-1];
    // Banked 32-bit word data arrays (8 banks per way)
    reg [31:0] cache_data0_b0 [0:CACHE_LINES-1];
    reg [31:0] cache_data0_b1 [0:CACHE_LINES-1];
    reg [31:0] cache_data0_b2 [0:CACHE_LINES-1];
    reg [31:0] cache_data0_b3 [0:CACHE_LINES-1];
    reg [31:0] cache_data0_b4 [0:CACHE_LINES-1];
    reg [31:0] cache_data0_b5 [0:CACHE_LINES-1];
    reg [31:0] cache_data0_b6 [0:CACHE_LINES-1];
    reg [31:0] cache_data0_b7 [0:CACHE_LINES-1];

    reg [31:0] cache_data1_b0 [0:CACHE_LINES-1];
    reg [31:0] cache_data1_b1 [0:CACHE_LINES-1];
    reg [31:0] cache_data1_b2 [0:CACHE_LINES-1];
    reg [31:0] cache_data1_b3 [0:CACHE_LINES-1];
    reg [31:0] cache_data1_b4 [0:CACHE_LINES-1];
    reg [31:0] cache_data1_b5 [0:CACHE_LINES-1];
    reg [31:0] cache_data1_b6 [0:CACHE_LINES-1];
    reg [31:0] cache_data1_b7 [0:CACHE_LINES-1];

    function automatic [31:0] read_cache_word0;
        input [4:0] idx;
        input [2:0] w;
        begin
            case (w)
                3'd0: read_cache_word0 = cache_data0_b0[idx];
                3'd1: read_cache_word0 = cache_data0_b1[idx];
                3'd2: read_cache_word0 = cache_data0_b2[idx];
                3'd3: read_cache_word0 = cache_data0_b3[idx];
                3'd4: read_cache_word0 = cache_data0_b4[idx];
                3'd5: read_cache_word0 = cache_data0_b5[idx];
                3'd6: read_cache_word0 = cache_data0_b6[idx];
                3'd7: read_cache_word0 = cache_data0_b7[idx];
            endcase
        end
    endfunction

    function automatic [31:0] read_cache_word1;
        input [4:0] idx;
        input [2:0] w;
        begin
            case (w)
                3'd0: read_cache_word1 = cache_data1_b0[idx];
                3'd1: read_cache_word1 = cache_data1_b1[idx];
                3'd2: read_cache_word1 = cache_data1_b2[idx];
                3'd3: read_cache_word1 = cache_data1_b3[idx];
                3'd4: read_cache_word1 = cache_data1_b4[idx];
                3'd5: read_cache_word1 = cache_data1_b5[idx];
                3'd6: read_cache_word1 = cache_data1_b6[idx];
                3'd7: read_cache_word1 = cache_data1_b7[idx];
            endcase
        end
    endfunction

    // Refill commit pipeline register
    reg        refill_commit_valid_q;
    reg        refill_commit_way_q;
    reg [4:0]  refill_commit_index_q;
    reg [TAG_WID-1:0] refill_commit_tag_q;
    reg [255:0] refill_commit_line_q;

    // Store update pipeline register
    reg        store_update_valid_q;
    reg [4:0]  store_update_index_q;
    reg        store_update_way_q;
    reg [2:0]  store_update_word_q;
    reg [3:0]  store_update_wen_q;
    reg [31:0] store_update_data_q;

    reg cache_valid0 [0:CACHE_LINES-1];
    reg cache_valid1 [0:CACHE_LINES-1];
    reg replace_way [0:CACHE_LINES-1];

    wire [4:0] input_index = data_addr[9:5];
    wire [TAG_WID-1:0] input_tag = data_addr[31:10];
    wire input_uncached = is_uncached_request(data_addr, data_cacheable);
    wire input_hit0 = cache_valid0[input_index] &&
                      (cache_tag0[input_index] == input_tag);
    wire input_hit1 = cache_valid1[input_index] &&
                      (cache_tag1[input_index] == input_tag);

    reg wcb_store_match;
    reg wcb_same_line_draining;
    reg wcb_free_found;
    reg [1:0] wcb_match_idx, wcb_free_idx;
    integer wcb_search_i;
    always @(*) begin
        wcb_store_match = 1'b0;
        wcb_same_line_draining = 1'b0;
        wcb_free_found = 1'b0;
        wcb_match_idx = 2'd0;
        wcb_free_idx = 2'd0;
        for (wcb_search_i = 0; wcb_search_i < WCB_DEPTH; wcb_search_i = wcb_search_i + 1) begin
            if (wcb_valid[wcb_search_i] &&
                (wcb_line[wcb_search_i] == data_addr[31:5])) begin
                if (wcb_draining[wcb_search_i])
                    wcb_same_line_draining = 1'b1;
                else if (!wcb_store_match) begin
                    wcb_store_match = 1'b1;
                    wcb_match_idx = wcb_search_i[1:0];
                end
            end
            if (!wcb_valid[wcb_search_i] && !wcb_free_found) begin
                wcb_free_found = 1'b1;
                wcb_free_idx = wcb_search_i[1:0];
            end
        end
    end

    wire [2:0] wcb_valid_count = {2'b0,wcb_valid[0]} +
                                  {2'b0,wcb_valid[1]} +
                                  {2'b0,wcb_valid[2]} +
                                  {2'b0,wcb_valid[3]};
    wire wcb_empty = (wcb_valid_count == 3'd0);
    wire wcb_store_ready = !input_uncached && !wcb_same_line_draining &&
                           (wcb_store_match || wcb_free_found);
    wire cacheable_store_accept = data_wready && !input_uncached &&
                                  (|data_wen);

    // Two internal MSHRs.  The external bus only sees the head of the
    // refill-order FIFO, so no SRAM-side transaction ID is required.
    reg mshr_valid0, mshr_valid1;
    reg [26:0] mshr_line0, mshr_line1;
    reg [4:0] mshr_index0, mshr_index1;
    reg       mshr_way0, mshr_way1;
    reg [255:0] mshr_data0, mshr_data1;
    reg [7:0] mshr_word_valid0, mshr_word_valid1;
    reg [7:0] mshr_wait_mask0, mshr_wait_mask1;
    // The SRAM bridge returns the requested word first when CWF_EN is set.
    // Keep that first-word offset with each MSHR so the refill-order FIFO can
    // map returned beats back to their real line positions.
    reg [2:0] mshr_critical_word0, mshr_critical_word1;
    reg       mshr_bank0, mshr_bank1;
    reg [1:0] refill_order [0:1];
    reg       refill_order_head, refill_order_tail;
    reg [1:0] refill_order_count;
    reg       refill_started;
    reg [2:0] refill_recv_count;
    reg       refill_started0, refill_started1;
    reg [2:0] refill_recv_count0, refill_recv_count1;

    wire [1:0] active_mshr_idx = mshr_valid0 ? 2'd0 : 2'd1;
    wire active_refill = mshr_valid0 || mshr_valid1;
    // Compatibility visibility for the existing testbench refill counter.
    localparam [2:0] R_IDLE = 3'd0;
    localparam [2:0] R_REFILL = 3'd1;
    wire [2:0] r_state;
    assign r_state = active_refill ? R_REFILL : R_IDLE;
    wire [26:0] active_line = (active_mshr_idx == 2'd0) ? mshr_line0 : mshr_line1;
    wire [4:0] active_index = (active_mshr_idx == 2'd0) ? mshr_index0 : mshr_index1;
    wire active_way = (active_mshr_idx == 2'd0) ? mshr_way0 : mshr_way1;
    wire [255:0] active_data = (active_mshr_idx == 2'd0) ? mshr_data0 : mshr_data1;
    wire [7:0] active_word_valid = (active_mshr_idx == 2'd0) ? mshr_word_valid0 : mshr_word_valid1;
    wire [7:0] active_wait_mask = (active_mshr_idx == 2'd0) ? mshr_wait_mask0 : mshr_wait_mask1;
    wire [2:0] active_critical_word = (active_mshr_idx == 2'd0) ?
                                      mshr_critical_word0 : mshr_critical_word1;
    // Three-bit addition intentionally wraps at eight words: after the
    // critical word, the bridge returns the tail of the line and then wraps
    // to word zero.
    wire [2:0] active_word_index = active_critical_word + refill_recv_count;
    wire refill_last = active_refill && refill_started && dev_rvalid &&
                       (refill_recv_count == 3'd7);

    wire ch0_active0 = mshr_valid0 && !mshr_bank0;
    wire ch0_active1 = mshr_valid1 && !mshr_bank1;
    wire ch1_active0 = mshr_valid0 &&  mshr_bank0;
    wire ch1_active1 = mshr_valid1 &&  mshr_bank1;
    wire ch0_active = ch0_active0 || ch0_active1;
    wire ch1_active = ch1_active0 || ch1_active1;
    wire [1:0] ch0_mshr_idx = ch0_active0 ? 2'd0 : 2'd1;
    wire [1:0] ch1_mshr_idx = ch1_active0 ? 2'd0 : 2'd1;
    wire [26:0] ch0_line = (ch0_mshr_idx == 2'd0) ? mshr_line0 : mshr_line1;
    wire [26:0] ch1_line = (ch1_mshr_idx == 2'd0) ? mshr_line0 : mshr_line1;
    wire [4:0] ch0_index = (ch0_mshr_idx == 2'd0) ? mshr_index0 : mshr_index1;
    wire [4:0] ch1_index = (ch1_mshr_idx == 2'd0) ? mshr_index0 : mshr_index1;
    wire ch0_way = (ch0_mshr_idx == 2'd0) ? mshr_way0 : mshr_way1;
    wire ch1_way = (ch1_mshr_idx == 2'd0) ? mshr_way0 : mshr_way1;
    wire [255:0] ch0_data = (ch0_mshr_idx == 2'd0) ? mshr_data0 : mshr_data1;
    wire [255:0] ch1_data = (ch1_mshr_idx == 2'd0) ? mshr_data0 : mshr_data1;
    wire [7:0] ch0_wait_mask = (ch0_mshr_idx == 2'd0) ? mshr_wait_mask0 : mshr_wait_mask1;
    wire [7:0] ch1_wait_mask = (ch1_mshr_idx == 2'd0) ? mshr_wait_mask0 : mshr_wait_mask1;
    wire [2:0] ch0_critical_word = (ch0_mshr_idx == 2'd0) ? mshr_critical_word0 : mshr_critical_word1;
    wire [2:0] ch1_critical_word = (ch1_mshr_idx == 2'd0) ? mshr_critical_word0 : mshr_critical_word1;
    wire [2:0] ch0_word_index = ch0_critical_word + refill_recv_count0;
    wire [2:0] ch1_word_index = ch1_critical_word + refill_recv_count1;
    wire ch0_last = ch0_active && refill_started0 && dev_rvalid &&
                    (refill_recv_count0 == 3'd7);
    wire ch1_last = ch1_active && refill_started1 && dev_rvalid1 &&
                    (refill_recv_count1 == 3'd7);
    wire any_refill_last = ch0_last || ch1_last;

    reg [31:0] tid_req_addr [0:TID_COUNT-1];
    reg [3:0]  tid_req_ren  [0:TID_COUNT-1];
    reg [31:0] tid_resp_data[0:TID_COUNT-1];
    reg [TID_COUNT-1:0] tid_busy;
    reg [TID_COUNT-1:0] tid_resp_pending;

    reg [31:0] req_addr [0:REQ_DEPTH-1];
    reg [3:0]  req_ren [0:REQ_DEPTH-1];
    reg        req_cacheable [0:REQ_DEPTH-1];
    reg [2:0]  req_tid [0:REQ_DEPTH-1];
    reg        req_head, req_tail;
    reg [1:0]  req_count;

    wire req_head_valid = (req_count != 2'd0);
    wire [31:0] req_head_addr = req_addr[req_head];
    wire [3:0] req_head_ren = req_ren[req_head];
    wire        req_head_cacheable = req_cacheable[req_head];
    wire [2:0]  req_head_tid = req_tid[req_head];
    wire        req_head_uncached = is_uncached_request(req_head_addr,
                                                         req_head_cacheable);
    wire [4:0]  req_head_index = req_head_addr[9:5];
    wire [TAG_WID-1:0] req_head_tag = req_head_addr[31:10];
    wire [2:0]  req_head_word = req_head_addr[4:2];
    wire        req_hit0 = cache_valid0[req_head_index] &&
                           (cache_tag0[req_head_index] == req_head_tag);
    wire        req_hit1 = cache_valid1[req_head_index] &&
                           (cache_tag1[req_head_index] == req_head_tag);
    wire [31:0] req_hit_data_raw = req_hit0 ?
        read_cache_word0(req_head_index, req_head_word) :
        read_cache_word1(req_head_index, req_head_word);

    wire req_refill_commit_hit = refill_commit_valid_q &&
                                 (refill_commit_index_q == req_head_index) &&
                                 (refill_commit_tag_q == req_head_tag) &&
                                 (refill_commit_way_q == (req_hit1 ? 1'b1 : 1'b0));

    wire req_store_update_hit = store_update_valid_q &&
                                (store_update_index_q == req_head_index) &&
                                (store_update_way_q == (req_hit1 ? 1'b1 : 1'b0)) &&
                                (store_update_word_q == req_head_word);

    wire [31:0] req_hit_data_base = req_refill_commit_hit ?
        select_word(refill_commit_line_q, req_head_word) :
        (req_store_update_hit ?
            merge_bytes(req_hit_data_raw, store_update_wen_q, store_update_data_q) :
            req_hit_data_raw);

    wire [31:0] req_hit_data = forward_wcb_word(req_hit_data_base, req_head_addr);
    wire req_mshr_match0 = mshr_valid0 && (mshr_line0 == req_head_addr[31:5]);
    wire req_mshr_match1 = mshr_valid1 && (mshr_line1 == req_head_addr[31:5]);
    wire req_mshr_match = req_mshr_match0 || req_mshr_match1;
    wire [1:0] req_mshr_idx = req_mshr_match0 ? 2'd0 : 2'd1;
    wire req_mshr_word_available = req_mshr_match0 ?
        mshr_word_valid0[req_head_word] : mshr_word_valid1[req_head_word];
    wire [255:0] req_mshr_data = req_mshr_match0 ? mshr_data0 : mshr_data1;
    wire [31:0] req_mshr_data_word = forward_wcb_word(
        select_word(req_mshr_data, req_head_word), req_head_addr);
    wire mshr_free_found = !mshr_valid0 || !mshr_valid1;
    wire [1:0] mshr_free_idx = !mshr_valid0 ? 2'd0 : 2'd1;
    wire mshr_set_conflict = (mshr_valid0 && (mshr_index0 == req_head_index)) ||
                             (mshr_valid1 && (mshr_index1 == req_head_index));
    wire req_new_miss_possible = !req_head_uncached && !req_mshr_match &&
                                  !req_hit0 && !req_hit1 && mshr_free_found &&
                                  !mshr_set_conflict;

    reg uncached_read_pending, uncached_read_started;
    reg [2:0] uncached_read_tid;
    reg [31:0] uncached_read_addr;
    reg [3:0] uncached_read_ren;
    reg uncached_write_pending, uncached_write_sent;
    reg [31:0] uncached_write_addr, uncached_write_data;
    reg [3:0] uncached_write_wen;

    // An uncached alias is allowed to pass older WCB traffic when it targets a
    // different physical line.  The old implementation used wcb_empty and
    // dev_widle here, turning every uncached Load into a global Store-buffer
    // drain.  Keep only the true same-line ordering dependency at this level;
    // L2 overlays its pending SBUF/WBB bytes on an uncached response below.
    reg uncached_wcb_conflict;
    integer uncached_wcb_scan_i;
    always @(*) begin
        uncached_wcb_conflict = 1'b0;
        for (uncached_wcb_scan_i = 0;
             uncached_wcb_scan_i < WCB_DEPTH;
             uncached_wcb_scan_i = uncached_wcb_scan_i + 1) begin
            if (wcb_valid[uncached_wcb_scan_i] &&
                (wcb_line[uncached_wcb_scan_i] == req_head_addr[31:5]))
                uncached_wcb_conflict = 1'b1;
        end
    end

    wire req_uncached_can_process = req_head_uncached &&
                                     !uncached_read_pending &&
                                     !uncached_write_pending &&
                                     !active_refill &&
                                     !uncached_wcb_conflict;
    // A refill beat belongs to the current MSHR and may be the final beat.
    // Do not let a same-line waiter or a hit consume that cycle: doing so can
    // add a wait bit after the last beat has already decided to retire the
    // MSHR.  A genuinely different-line miss is safe, however, because it
    // allocates the other MSHR and remains ordered by refill_order.  This is
    // the admission point that was missing from the original two-MSHR path;
    // it lets the next Stream line be reserved while the current line is
    // still returning, without creating a second SRAM return stream.
    wire req_process = req_head_valid && !maint_valid &&
                       !uncached_read_pending &&
                       (req_head_uncached ?
                        (!dev_rvalid && !dev_rvalid1 &&
                         req_uncached_can_process) :
                        ((dev_rvalid || dev_rvalid1) ?
                         req_new_miss_possible :
                         (req_mshr_match || req_hit0 || req_hit1 ||
                          req_new_miss_possible)));
    wire req_pop = req_process;
    wire req_mshr_wait_fire = req_process && !req_head_uncached &&
                               req_mshr_match && !req_mshr_word_available;
    wire req_mshr_ready_fire = req_process && !req_head_uncached &&
                               req_mshr_match && req_mshr_word_available;
    wire req_hit_fire = req_process && !req_head_uncached &&
                        !req_mshr_match && (req_hit0 || req_hit1);
    wire req_new_miss_fire = req_process && req_new_miss_possible;

    wire req_fifo_can_accept = (req_count < REQ_DEPTH) || req_pop;
    wire input_tid_available = !tid_busy[data_rtid];
    assign data_rready = !maint_valid && !uncached_write_pending &&
                         req_fifo_can_accept && input_tid_available;
    wire req_push = data_rready && (|data_ren);

    reg resp_emit_found;
    reg [2:0] resp_emit_tid;
    integer resp_scan_i;
    always @(*) begin
        resp_emit_found = 1'b0;
        resp_emit_tid = 3'd0;
        for (resp_scan_i = 0; resp_scan_i < TID_COUNT; resp_scan_i = resp_scan_i + 1)
            if (tid_resp_pending[resp_scan_i] && !resp_emit_found) begin
                resp_emit_found = 1'b1;
                resp_emit_tid = resp_scan_i[2:0];
            end
    end

    reg [7:0] active_wait_match;
    reg [7:0] ch0_wait_match;
    reg [7:0] ch1_wait_match;
    integer wait_scan_i;
    always @(*) begin
        active_wait_match = 8'h00;
        ch0_wait_match = 8'h00;
        ch1_wait_match = 8'h00;
        if (ch0_active && refill_started0 && dev_rvalid)
            for (wait_scan_i = 0; wait_scan_i < TID_COUNT; wait_scan_i = wait_scan_i + 1)
                if (ch0_wait_mask[wait_scan_i] &&
                    (tid_req_addr[wait_scan_i][4:2] == ch0_word_index))
                    ch0_wait_match[wait_scan_i] = 1'b1;
        if (ch1_active && refill_started1 && dev_rvalid1)
            for (wait_scan_i = 0; wait_scan_i < TID_COUNT; wait_scan_i = wait_scan_i + 1)
                if (ch1_wait_mask[wait_scan_i] &&
                    (tid_req_addr[wait_scan_i][4:2] == ch1_word_index))
                    ch1_wait_match[wait_scan_i] = 1'b1;
        active_wait_match = ch0_wait_match;
    end

    wire [7:0] active_wait_after = active_wait_mask & ~active_wait_match;
    reg [255:0] active_line_after_beat;
    reg [255:0] ch0_line_after_beat;
    reg [255:0] ch1_line_after_beat;
    always @(*) begin
        active_line_after_beat = active_data;
        if (dev_rvalid && active_refill && refill_started)
            active_line_after_beat = merge_refill_word(active_data,
                                                        active_word_index,
                                                        dev_rdata);
        active_line_after_beat = forward_wcb_line(active_line_after_beat,
                                                  active_line);
        if (cacheable_store_accept &&
            (data_addr[31:5] == active_line))
            active_line_after_beat = merge_line_store(active_line_after_beat,
                                                      data_addr[4:0],
                                                      data_wen, data_wdata);

        ch0_line_after_beat = ch0_data;
        if (ch0_active && refill_started0 && dev_rvalid)
            ch0_line_after_beat = merge_refill_word(ch0_data, ch0_word_index, dev_rdata);
        ch0_line_after_beat = forward_wcb_line(ch0_line_after_beat, ch0_line);
        if (cacheable_store_accept && ch0_active && (data_addr[31:5] == ch0_line))
            ch0_line_after_beat = merge_line_store(ch0_line_after_beat,
                                                   data_addr[4:0], data_wen, data_wdata);

        ch1_line_after_beat = ch1_data;
        if (ch1_active && refill_started1 && dev_rvalid1)
            ch1_line_after_beat = merge_refill_word(ch1_data, ch1_word_index, dev_rdata1);
        ch1_line_after_beat = forward_wcb_line(ch1_line_after_beat, ch1_line);
        if (cacheable_store_accept && ch1_active && (data_addr[31:5] == ch1_line))
            ch1_line_after_beat = merge_line_store(ch1_line_after_beat,
                                                   data_addr[4:0], data_wen, data_wdata);
    end

    wire refill_start_fire0 = ch0_active && !refill_started0 &&
                              !uncached_read_pending && dev_rrdy;
    wire refill_start_fire1 = ch1_active && !refill_started1 &&
                              !uncached_read_pending && dev_rrdy1;
    wire refill_start_fire = refill_start_fire0 || refill_start_fire1;
    wire uncached_read_start_fire = uncached_read_pending &&
                                    !uncached_read_started &&
                                    !active_refill && dev_rrdy;
    wire uncached_write_fire = uncached_write_pending &&
                               !uncached_write_sent && dev_wrdy;
    wire cache_store_hit0 = cache_valid0[input_index] &&
                             (cache_tag0[input_index] == input_tag);
    wire cache_store_hit1 = cache_valid1[input_index] &&
                             (cache_tag1[input_index] == input_tag);
    // A refill only conflicts with the Store update when its final beat writes
    // the exact cache slot that currently contains the Store line.  Suppressing
    // every Store on any refill-last cycle leaves an unrelated hit line stale
    // after its WCB forwarding entry is eventually released.
    wire ch0_overwrites_store_slot = ch0_last && (ch0_index == input_index) &&
        ((!ch0_way && cache_store_hit0) || (ch0_way && cache_store_hit1));
    wire ch1_overwrites_store_slot = ch1_last && (ch1_index == input_index) &&
        ((!ch1_way && cache_store_hit0) || (ch1_way && cache_store_hit1));
    wire store_cache_update_fire = cacheable_store_accept &&
                                   !ch0_overwrites_store_slot &&
                                   !ch1_overwrites_store_slot &&
                                   (cache_store_hit0 || cache_store_hit1);

    wire [7:0] wcb_drain_valid_words = wcb_drain_word_valid_q;
    wire [7:0] remaining_words = wcb_drain_word_valid_q & ~wcb_drain_sent_mask;
    reg [2:0] wcb_drain_word_idx;
    reg [3:0] wcb_drain_word_wen;
    reg [31:0] wcb_drain_word_data;
    reg wcb_drain_word_found;
    always @(*) begin
        wcb_drain_word_idx = 3'd0;
        wcb_drain_word_wen = 4'h0;
        wcb_drain_word_data = 32'h0;
        wcb_drain_word_found = 1'b0;
        if (wcb_drain_active) begin
            if (remaining_words[0]) begin wcb_drain_word_idx = 3'd0; wcb_drain_word_found = 1'b1; end
            else if (remaining_words[1]) begin wcb_drain_word_idx = 3'd1; wcb_drain_word_found = 1'b1; end
            else if (remaining_words[2]) begin wcb_drain_word_idx = 3'd2; wcb_drain_word_found = 1'b1; end
            else if (remaining_words[3]) begin wcb_drain_word_idx = 3'd3; wcb_drain_word_found = 1'b1; end
            else if (remaining_words[4]) begin wcb_drain_word_idx = 3'd4; wcb_drain_word_found = 1'b1; end
            else if (remaining_words[5]) begin wcb_drain_word_idx = 3'd5; wcb_drain_word_found = 1'b1; end
            else if (remaining_words[6]) begin wcb_drain_word_idx = 3'd6; wcb_drain_word_found = 1'b1; end
            else if (remaining_words[7]) begin wcb_drain_word_idx = 3'd7; wcb_drain_word_found = 1'b1; end

            if (wcb_drain_word_found) begin
                wcb_drain_word_wen = wcb_drain_word_wen_q[wcb_drain_word_idx];
                wcb_drain_word_data = select_word(wcb_data[wcb_drain_idx], wcb_drain_word_idx);
            end
        end
    end

    wire wcb_drain_write_valid = wcb_drain_active && wcb_drain_word_found;
    wire wcb_drain_fire = wcb_drain_write_valid && dev_wrdy;
    wire wcb_done_for_count = wcb_drain_active && dev_wdone &&
                              (wcb_drain_pending_count != 4'd0);
    wire [7:0] wcb_sent_after = wcb_drain_sent_mask |
                                (wcb_drain_fire ?
                                 (8'b1 << wcb_drain_word_idx) : 8'h00);
    wire [3:0] wcb_pending_after = wcb_drain_pending_count +
                                   (wcb_drain_fire ? 4'd1 : 4'd0) -
                                   (wcb_done_for_count ? 4'd1 : 4'd0);
    wire wcb_all_sent_after =
        (wcb_sent_after & wcb_drain_valid_words) == wcb_drain_valid_words;
    wire wcb_drain_complete = wcb_drain_active && wcb_all_sent_after &&
                              (wcb_pending_after == 4'd0);
    wire wcb_idle_drain = (wcb_idle_count >= WCB_IDLE_DRAIN_LIMIT);
    wire wcb_drain_start = !wcb_drain_active &&
                           (wcb_order_count != 3'd0) &&
                           (wcb_valid_count != 3'd0) &&
                           !uncached_write_pending && !maint_valid &&
                           !cacheable_store_accept &&
                           ((wcb_valid_count >= HIGH_WATERMARK) ||
                            wcb_idle_drain);
    wire wcb_order_push = cacheable_store_accept && !wcb_store_match;
    wire wcb_order_pop = wcb_drain_complete;

    assign data_wready = !maint_valid &&
                         (input_uncached ?
                          (!uncached_write_pending && !uncached_read_pending &&
                           (req_count == 2'd0) && !active_refill &&
                           wcb_empty && !wcb_drain_active && dev_widle) :
                          (!uncached_write_pending && !uncached_read_pending &&
                           wcb_store_ready));
    assign data_wposted = data_wready && !input_uncached && (|data_wen);
    assign data_wresp = uncached_write_pending && dev_wdone;
    assign line_alloc_ready = 1'b0;

    always @(*) begin
        cpu_ren = 4'h0;
        cpu_raddr = 32'h0;
        cpu_rburst = 1'b0;
        cpu_ren1 = 4'h0;
        cpu_raddr1 = 32'h0;
        cpu_rburst1 = 1'b0;
        if (refill_start_fire0) begin
            cpu_ren = 4'hf;
            // Pass the original demand word, not the line base.  This is the
            // point at which critical-word-first is selected on the tagged
            // path; the bridge performs the wrapped eight-word sequence.
            cpu_raddr = {ch0_line, 5'b0} +
                        {27'd0, ch0_critical_word, 2'b0};
            cpu_rburst = 1'b1;
        end else if (uncached_read_start_fire) begin
            cpu_ren = uncached_read_ren;
            cpu_raddr = uncached_read_addr;
        end
        if (refill_start_fire1) begin
            cpu_ren1 = 4'hf;
            cpu_raddr1 = {ch1_line, 5'b0} +
                         {27'd0, ch1_critical_word, 2'b0};
            cpu_rburst1 = 1'b1;
        end
    end

    always @(*) begin
        cpu_wen = 4'h0;
        cpu_waddr = 32'h0;
        cpu_wdata = 32'h0;
        cpu_wcacheable = 1'b0;
        if (uncached_write_pending && !uncached_write_sent) begin
            cpu_wen = uncached_write_wen;
            cpu_waddr = uncached_write_addr;
            cpu_wdata = uncached_write_data;
        end else if (wcb_drain_write_valid) begin
            cpu_wen = wcb_drain_word_wen;
            cpu_waddr = {wcb_line[wcb_drain_idx], 5'b0} +
                        (wcb_drain_word_idx * 32'd4);
            cpu_wdata = wcb_drain_word_data;
            cpu_wcacheable = 1'b1;
        end
    end

    // WCB state and physical completion lifetime.
    integer wcb_state_i;
    always @(posedge cpu_clk or negedge cpu_rstn) begin
        if (!cpu_rstn) begin
            wcb_drain_active <= 1'b0;
            wcb_drain_idx <= 2'd0;
            wcb_drain_sent_mask <= 8'h0;
            wcb_drain_pending_count <= 4'd0;
            wcb_drain_word_valid_q <= 8'h0;
            for (wcb_state_i = 0; wcb_state_i < 8; wcb_state_i = wcb_state_i + 1)
                wcb_drain_word_wen_q[wcb_state_i] <= 4'h0;
            wcb_idle_count <= 6'd0;
            wcb_order_head <= 2'd0;
            wcb_order_tail <= 2'd0;
            wcb_order_count <= 3'd0;
            for (wcb_state_i = 0; wcb_state_i < WCB_DEPTH; wcb_state_i = wcb_state_i + 1) begin
                wcb_line[wcb_state_i] <= 27'd0;
                wcb_data[wcb_state_i] <= 256'd0;
                wcb_byte_valid[wcb_state_i] <= 32'd0;
                wcb_valid[wcb_state_i] <= 1'b0;
                wcb_draining[wcb_state_i] <= 1'b0;
                wcb_order[wcb_state_i] <= 2'd0;
            end
        end else begin
            // Do not start the drain merely because the current cycle has no
            // Load.  Keep the line merge window open across normal pipeline
            // gaps, but force progress after a bounded idle interval.
            if (cacheable_store_accept || wcb_drain_active ||
                wcb_drain_complete || (wcb_valid_count == 3'd0)) begin
                wcb_idle_count <= 6'd0;
            end else if (wcb_idle_count < WCB_IDLE_DRAIN_LIMIT) begin
                wcb_idle_count <= wcb_idle_count + 6'd1;
            end

            if (cacheable_store_accept) begin
                if (wcb_store_match) begin
                    wcb_data[wcb_match_idx] <= wcb_merge_line(
                        wcb_data[wcb_match_idx], data_addr[4:0], data_wen, data_wdata);
                    wcb_byte_valid[wcb_match_idx] <= wcb_merge_mask(
                        wcb_byte_valid[wcb_match_idx], data_addr[4:0], data_wen);
                end else begin
                    wcb_line[wcb_free_idx] <= data_addr[31:5];
                    wcb_data[wcb_free_idx] <= wcb_merge_line(
                        256'd0, data_addr[4:0], data_wen, data_wdata);
                    wcb_byte_valid[wcb_free_idx] <= wcb_merge_mask(
                        32'd0, data_addr[4:0], data_wen);
                    wcb_valid[wcb_free_idx] <= 1'b1;
                    wcb_draining[wcb_free_idx] <= 1'b0;
                end
            end
            if (wcb_order_push) begin
                wcb_order[wcb_order_tail] <= wcb_free_idx;
                wcb_order_tail <= wcb_order_tail + 2'd1;
            end
            if (wcb_order_pop)
                wcb_order_head <= wcb_order_head + 2'd1;
            case ({wcb_order_push, wcb_order_pop})
                2'b10: wcb_order_count <= wcb_order_count + 3'd1;
                2'b01: wcb_order_count <= wcb_order_count - 3'd1;
                default: wcb_order_count <= wcb_order_count;
            endcase

            if (!wcb_drain_active) begin
                if (wcb_drain_start) begin
                    wcb_drain_active <= 1'b1;
                    wcb_drain_idx <= wcb_order[wcb_order_head];
                    for (wcb_state_i = 0; wcb_state_i < 8; wcb_state_i = wcb_state_i + 1) begin
                        wcb_drain_word_wen_q[wcb_state_i] <=
                            wcb_byte_valid[wcb_order[wcb_order_head]][wcb_state_i*4 +: 4];
                        wcb_drain_word_valid_q[wcb_state_i] <=
                            |wcb_byte_valid[wcb_order[wcb_order_head]][wcb_state_i*4 +: 4];
                    end
                    wcb_drain_sent_mask <= 8'h0;
                    wcb_drain_pending_count <= 4'd0;
                    wcb_draining[wcb_order[wcb_order_head]] <= 1'b1;
                end
            end else begin
                if (wcb_drain_fire)
                    wcb_drain_sent_mask[wcb_drain_word_idx] <= 1'b1;
                case ({wcb_drain_fire, wcb_done_for_count})
                    2'b10: wcb_drain_pending_count <= wcb_drain_pending_count + 4'd1;
                    2'b01: wcb_drain_pending_count <= wcb_drain_pending_count - 4'd1;
                    default: wcb_drain_pending_count <= wcb_drain_pending_count;
                endcase
                if (wcb_drain_complete) begin
                    wcb_valid[wcb_drain_idx] <= 1'b0;
                    wcb_draining[wcb_drain_idx] <= 1'b0;
                    wcb_drain_active <= 1'b0;
                    wcb_drain_sent_mask <= 8'h0;
                    wcb_drain_pending_count <= 4'd0;
                end
            end
        end
    end

    // Uncached write protocol.  It is deliberately serialized behind the WCB
    // and any refill, while cacheable stores remain posted into the WCB.
    wire uncached_store_accept = data_wready && input_uncached && (|data_wen);
    always @(posedge cpu_clk or negedge cpu_rstn) begin
        if (!cpu_rstn) begin
            uncached_write_pending <= 1'b0;
            uncached_write_sent <= 1'b0;
            uncached_write_addr <= 32'd0;
            uncached_write_data <= 32'd0;
            uncached_write_wen <= 4'd0;
        end else begin
            if (uncached_store_accept) begin
                uncached_write_pending <= 1'b1;
                uncached_write_sent <= 1'b0;
                uncached_write_addr <= data_addr;
                uncached_write_data <= data_wdata;
                uncached_write_wen <= data_wen;
            end
            if (uncached_write_fire)
                uncached_write_sent <= 1'b1;
            if (uncached_write_pending && uncached_write_sent && dev_wdone) begin
                uncached_write_pending <= 1'b0;
                uncached_write_sent <= 1'b0;
            end
        end
    end

    // Request queue, TID response table, MSHR allocation, and refill order.
    integer core_i;
    integer core_j;
    always @(posedge cpu_clk or negedge cpu_rstn) begin
        if (!cpu_rstn) begin
            req_head <= 1'b0;
            req_tail <= 1'b0;
            req_count <= 2'd0;
            mshr_valid0 <= 1'b0;
            mshr_valid1 <= 1'b0;
            mshr_line0 <= 27'd0;
            mshr_line1 <= 27'd0;
            mshr_index0 <= 5'd0;
            mshr_index1 <= 5'd0;
            mshr_way0 <= 1'b0;
            mshr_way1 <= 1'b0;
            mshr_data0 <= 256'd0;
            mshr_data1 <= 256'd0;
            mshr_word_valid0 <= 8'd0;
            mshr_word_valid1 <= 8'd0;
            mshr_wait_mask0 <= 8'd0;
            mshr_wait_mask1 <= 8'd0;
            mshr_critical_word0 <= 3'd0;
            mshr_critical_word1 <= 3'd0;
            mshr_bank0 <= 1'b0;
            mshr_bank1 <= 1'b0;
            refill_order[0] <= 2'd0;
            refill_order[1] <= 2'd0;
            refill_order_head <= 1'b0;
            refill_order_tail <= 1'b0;
            refill_order_count <= 2'd0;
            refill_started <= 1'b0;
            refill_recv_count <= 3'd0;
            refill_started0 <= 1'b0;
            refill_started1 <= 1'b0;
            refill_recv_count0 <= 3'd0;
            refill_recv_count1 <= 3'd0;
            uncached_read_pending <= 1'b0;
            uncached_read_started <= 1'b0;
            uncached_read_tid <= 3'd0;
            uncached_read_addr <= 32'd0;
            uncached_read_ren <= 4'd0;
            tid_busy <= 8'd0;
            tid_resp_pending <= 8'd0;
            data_valid <= 1'b0;
            data_rdata <= 32'd0;
            data_rtid_out <= 3'd0;
            for (core_i = 0; core_i < TID_COUNT; core_i = core_i + 1) begin
                tid_req_addr[core_i] <= 32'd0;
                tid_req_ren[core_i] <= 4'd0;
                tid_resp_data[core_i] <= 32'd0;
            end
            for (core_j = 0; core_j < REQ_DEPTH; core_j = core_j + 1) begin
                req_addr[core_j] <= 32'd0;
                req_ren[core_j] <= 4'd0;
                req_cacheable[core_j] <= 1'b0;
                req_tid[core_j] <= 3'd0;
            end
        end else begin
            data_valid <= 1'b0;

            if (resp_emit_found) begin
                data_valid <= 1'b1;
                data_rdata <= tid_resp_data[resp_emit_tid];
                data_rtid_out <= resp_emit_tid;
                tid_resp_pending[resp_emit_tid] <= 1'b0;
                tid_busy[resp_emit_tid] <= 1'b0;
            end

            if (req_push) begin
                req_addr[req_tail] <= data_addr;
                req_ren[req_tail] <= data_ren;
                req_cacheable[req_tail] <= data_cacheable;
                req_tid[req_tail] <= data_rtid;
                tid_req_addr[data_rtid] <= data_addr;
                tid_req_ren[data_rtid] <= data_ren;
                tid_busy[data_rtid] <= 1'b1;
                req_tail <= req_tail + 1'b1;
            end
            if (req_pop)
                req_head <= req_head + 1'b1;
            req_count <= req_count + (req_push ? 2'd1 : 2'd0) -
                         (req_pop ? 2'd1 : 2'd0);

            if (req_hit_fire) begin
                tid_resp_pending[req_head_tid] <= 1'b1;
                tid_resp_data[req_head_tid] <= req_hit_data;
            end else if (req_mshr_ready_fire) begin
                tid_resp_pending[req_head_tid] <= 1'b1;
                tid_resp_data[req_head_tid] <= req_mshr_data_word;
            end else if (req_mshr_wait_fire) begin
                if (req_mshr_idx == 2'd0)
                    mshr_wait_mask0[req_head_tid] <= 1'b1;
                else
                    mshr_wait_mask1[req_head_tid] <= 1'b1;
            end else if (req_new_miss_fire) begin
                if (mshr_free_idx == 2'd0) begin
                    mshr_valid0 <= 1'b1;
                    mshr_line0 <= req_head_addr[31:5];
                    mshr_index0 <= req_head_index;
                    mshr_way0 <= (!cache_valid0[req_head_index]) ? 1'b0 :
                                 ((!cache_valid1[req_head_index]) ? 1'b1 :
                                  replace_way[req_head_index]);
                    mshr_critical_word0 <= req_head_word;
                    mshr_bank0 <= is_ext_addr(req_head_addr);
                    if (CLEAR_MSHR_DATA_ON_ALLOC)
                        mshr_data0 <= 256'd0;
                    mshr_word_valid0 <= 8'd0;
                    mshr_wait_mask0 <= (8'b1 << req_head_tid);
                end else begin
                    mshr_valid1 <= 1'b1;
                    mshr_line1 <= req_head_addr[31:5];
                    mshr_index1 <= req_head_index;
                    mshr_way1 <= (!cache_valid0[req_head_index]) ? 1'b0 :
                                 ((!cache_valid1[req_head_index]) ? 1'b1 :
                                  replace_way[req_head_index]);
                    mshr_critical_word1 <= req_head_word;
                    mshr_bank1 <= is_ext_addr(req_head_addr);
                    if (CLEAR_MSHR_DATA_ON_ALLOC)
                        mshr_data1 <= 256'd0;
                    mshr_word_valid1 <= 8'd0;
                    mshr_wait_mask1 <= (8'b1 << req_head_tid);
                end
                refill_order[refill_order_tail] <= mshr_free_idx;
                refill_order_tail <= refill_order_tail + 1'b1;
            end else if (req_head_uncached && req_process) begin
                uncached_read_pending <= 1'b1;
                uncached_read_started <= 1'b0;
                uncached_read_tid <= req_head_tid;
                uncached_read_addr <= req_head_addr;
                uncached_read_ren <= req_head_ren;
            end

            if (refill_start_fire0) begin
                refill_started0 <= 1'b1;
                refill_recv_count0 <= 3'd0;
            end
            if (ch0_last) begin
                refill_started0 <= 1'b0;
                refill_recv_count0 <= 3'd0;
            end else if (ch0_active && refill_started0 && dev_rvalid) begin
                refill_recv_count0 <= refill_recv_count0 + 1'b1;
            end
            if (refill_start_fire1) begin
                refill_started1 <= 1'b1;
                refill_recv_count1 <= 3'd0;
            end
            if (ch1_last) begin
                refill_started1 <= 1'b0;
                refill_recv_count1 <= 3'd0;
            end else if (ch1_active && refill_started1 && dev_rvalid1) begin
                refill_recv_count1 <= refill_recv_count1 + 1'b1;
            end

            if (uncached_read_start_fire)
                uncached_read_started <= 1'b1;
            if (uncached_read_pending && uncached_read_started && dev_rvalid) begin
                tid_resp_pending[uncached_read_tid] <= 1'b1;
                tid_resp_data[uncached_read_tid] <= dev_rdata;
                uncached_read_pending <= 1'b0;
                uncached_read_started <= 1'b0;
            end

            refill_order_count <= refill_order_count +
                (req_new_miss_fire ? 2'd1 : 2'd0) -
                (ch0_last ? 2'd1 : 2'd0) -
                (ch1_last ? 2'd1 : 2'd0);

            if (ch0_active && refill_started0 && dev_rvalid) begin
                if (ch0_mshr_idx == 2'd0) begin
                    mshr_data0 <= merge_refill_word(mshr_data0, ch0_word_index, dev_rdata);
                    mshr_word_valid0[ch0_word_index] <= 1'b1;
                    for (core_i = 0; core_i < TID_COUNT; core_i = core_i + 1)
                        if (ch0_wait_match[core_i]) begin
                            tid_resp_pending[core_i] <= 1'b1;
                            tid_resp_data[core_i] <= forward_wcb_word(dev_rdata, tid_req_addr[core_i]);
                            mshr_wait_mask0[core_i] <= 1'b0;
                        end
                    if (ch0_last && ((ch0_wait_mask & ~ch0_wait_match) == 8'd0))
                        mshr_valid0 <= 1'b0;
                end else begin
                    mshr_data1 <= merge_refill_word(mshr_data1, ch0_word_index, dev_rdata);
                    mshr_word_valid1[ch0_word_index] <= 1'b1;
                    for (core_i = 0; core_i < TID_COUNT; core_i = core_i + 1)
                        if (ch0_wait_match[core_i]) begin
                            tid_resp_pending[core_i] <= 1'b1;
                            tid_resp_data[core_i] <= forward_wcb_word(dev_rdata, tid_req_addr[core_i]);
                            mshr_wait_mask1[core_i] <= 1'b0;
                        end
                    if (ch0_last && ((ch0_wait_mask & ~ch0_wait_match) == 8'd0))
                        mshr_valid1 <= 1'b0;
                end
            end
            if (ch1_active && refill_started1 && dev_rvalid1) begin
                if (ch1_mshr_idx == 2'd0) begin
                    mshr_data0 <= merge_refill_word(mshr_data0, ch1_word_index, dev_rdata1);
                    mshr_word_valid0[ch1_word_index] <= 1'b1;
                    for (core_i = 0; core_i < TID_COUNT; core_i = core_i + 1)
                        if (ch1_wait_match[core_i]) begin
                            tid_resp_pending[core_i] <= 1'b1;
                            tid_resp_data[core_i] <= forward_wcb_word(dev_rdata1, tid_req_addr[core_i]);
                            mshr_wait_mask0[core_i] <= 1'b0;
                        end
                    if (ch1_last && ((ch1_wait_mask & ~ch1_wait_match) == 8'd0))
                        mshr_valid0 <= 1'b0;
                end else begin
                    mshr_data1 <= merge_refill_word(mshr_data1, ch1_word_index, dev_rdata1);
                    mshr_word_valid1[ch1_word_index] <= 1'b1;
                    for (core_i = 0; core_i < TID_COUNT; core_i = core_i + 1)
                        if (ch1_wait_match[core_i]) begin
                            tid_resp_pending[core_i] <= 1'b1;
                            tid_resp_data[core_i] <= forward_wcb_word(dev_rdata1, tid_req_addr[core_i]);
                            mshr_wait_mask1[core_i] <= 1'b0;
                        end
                    if (ch1_last && ((ch1_wait_mask & ~ch1_wait_match) == 8'd0))
                        mshr_valid1 <= 1'b0;
                end
            end
        end
    end

    integer cache_i;
    always @(posedge cpu_clk or negedge cpu_rstn) begin
        if (!cpu_rstn) begin
            refill_commit_valid_q <= 1'b0;
            refill_commit_way_q   <= 1'b0;
            refill_commit_index_q <= 5'd0;
            refill_commit_tag_q   <= {TAG_WID{1'b0}};
            refill_commit_line_q  <= 256'd0;
            store_update_valid_q  <= 1'b0;
            store_update_index_q  <= 5'd0;
            store_update_way_q    <= 1'b0;
            store_update_word_q   <= 3'd0;
            store_update_wen_q    <= 4'h0;
            store_update_data_q   <= 32'd0;
            for (cache_i = 0; cache_i < CACHE_LINES; cache_i = cache_i + 1) begin
                cache_tag0[cache_i] <= 0;
                cache_tag1[cache_i] <= 0;
                cache_valid0[cache_i] <= 1'b0;
                cache_valid1[cache_i] <= 1'b0;
                replace_way[cache_i] <= 1'b0;
                cache_data0_b0[cache_i] <= 32'd0;
                cache_data0_b1[cache_i] <= 32'd0;
                cache_data0_b2[cache_i] <= 32'd0;
                cache_data0_b3[cache_i] <= 32'd0;
                cache_data0_b4[cache_i] <= 32'd0;
                cache_data0_b5[cache_i] <= 32'd0;
                cache_data0_b6[cache_i] <= 32'd0;
                cache_data0_b7[cache_i] <= 32'd0;
                cache_data1_b0[cache_i] <= 32'd0;
                cache_data1_b1[cache_i] <= 32'd0;
                cache_data1_b2[cache_i] <= 32'd0;
                cache_data1_b3[cache_i] <= 32'd0;
                cache_data1_b4[cache_i] <= 32'd0;
                cache_data1_b5[cache_i] <= 32'd0;
                cache_data1_b6[cache_i] <= 32'd0;
                cache_data1_b7[cache_i] <= 32'd0;
            end
        end else begin
            // Stage 1: Capture Refill Line Commit Register
            if (ch0_last) begin
                refill_commit_valid_q <= 1'b1;
                refill_commit_way_q   <= ch0_way;
                refill_commit_index_q <= ch0_index;
                refill_commit_tag_q   <= ch0_line[26:5];
                refill_commit_line_q  <= ch0_line_after_beat;
            end else if (ch1_last) begin
                refill_commit_valid_q <= 1'b1;
                refill_commit_way_q   <= ch1_way;
                refill_commit_index_q <= ch1_index;
                refill_commit_tag_q   <= ch1_line[26:5];
                refill_commit_line_q  <= ch1_line_after_beat;
            end else begin
                refill_commit_valid_q <= 1'b0;
            end

            // Stage 2: Write Refill Line to Cache Data Array Banks
            if (refill_commit_valid_q) begin
                if (!refill_commit_way_q) begin
                    cache_tag0[refill_commit_index_q] <= refill_commit_tag_q;
                    cache_valid0[refill_commit_index_q] <= 1'b1;
                    replace_way[refill_commit_index_q] <= 1'b1;
                    cache_data0_b0[refill_commit_index_q] <= refill_commit_line_q[0*32 +: 32];
                    cache_data0_b1[refill_commit_index_q] <= refill_commit_line_q[1*32 +: 32];
                    cache_data0_b2[refill_commit_index_q] <= refill_commit_line_q[2*32 +: 32];
                    cache_data0_b3[refill_commit_index_q] <= refill_commit_line_q[3*32 +: 32];
                    cache_data0_b4[refill_commit_index_q] <= refill_commit_line_q[4*32 +: 32];
                    cache_data0_b5[refill_commit_index_q] <= refill_commit_line_q[5*32 +: 32];
                    cache_data0_b6[refill_commit_index_q] <= refill_commit_line_q[6*32 +: 32];
                    cache_data0_b7[refill_commit_index_q] <= refill_commit_line_q[7*32 +: 32];
                end else begin
                    cache_tag1[refill_commit_index_q] <= refill_commit_tag_q;
                    cache_valid1[refill_commit_index_q] <= 1'b1;
                    replace_way[refill_commit_index_q] <= 1'b0;
                    cache_data1_b0[refill_commit_index_q] <= refill_commit_line_q[0*32 +: 32];
                    cache_data1_b1[refill_commit_index_q] <= refill_commit_line_q[1*32 +: 32];
                    cache_data1_b2[refill_commit_index_q] <= refill_commit_line_q[2*32 +: 32];
                    cache_data1_b3[refill_commit_index_q] <= refill_commit_line_q[3*32 +: 32];
                    cache_data1_b4[refill_commit_index_q] <= refill_commit_line_q[4*32 +: 32];
                    cache_data1_b5[refill_commit_index_q] <= refill_commit_line_q[5*32 +: 32];
                    cache_data1_b6[refill_commit_index_q] <= refill_commit_line_q[6*32 +: 32];
                    cache_data1_b7[refill_commit_index_q] <= refill_commit_line_q[7*32 +: 32];
                end
            end

            // Stage 1: Capture Store Cache Update Register
            if (store_cache_update_fire) begin
                store_update_valid_q <= 1'b1;
                store_update_index_q <= input_index;
                store_update_way_q   <= cache_store_hit1;
                store_update_word_q  <= data_addr[4:2];
                store_update_wen_q   <= data_wen;
                store_update_data_q  <= data_wdata;
            end else begin
                store_update_valid_q <= 1'b0;
            end

            // Stage 2: Commit Store Word Update to Cache Data Array Banks
            if (store_update_valid_q) begin
                if (!store_update_way_q) begin
                    case (store_update_word_q)
                        3'd0: cache_data0_b0[store_update_index_q] <= merge_bytes(cache_data0_b0[store_update_index_q], store_update_wen_q, store_update_data_q);
                        3'd1: cache_data0_b1[store_update_index_q] <= merge_bytes(cache_data0_b1[store_update_index_q], store_update_wen_q, store_update_data_q);
                        3'd2: cache_data0_b2[store_update_index_q] <= merge_bytes(cache_data0_b2[store_update_index_q], store_update_wen_q, store_update_data_q);
                        3'd3: cache_data0_b3[store_update_index_q] <= merge_bytes(cache_data0_b3[store_update_index_q], store_update_wen_q, store_update_data_q);
                        3'd4: cache_data0_b4[store_update_index_q] <= merge_bytes(cache_data0_b4[store_update_index_q], store_update_wen_q, store_update_data_q);
                        3'd5: cache_data0_b5[store_update_index_q] <= merge_bytes(cache_data0_b5[store_update_index_q], store_update_wen_q, store_update_data_q);
                        3'd6: cache_data0_b6[store_update_index_q] <= merge_bytes(cache_data0_b6[store_update_index_q], store_update_wen_q, store_update_data_q);
                        3'd7: cache_data0_b7[store_update_index_q] <= merge_bytes(cache_data0_b7[store_update_index_q], store_update_wen_q, store_update_data_q);
                    endcase
                end else begin
                    case (store_update_word_q)
                        3'd0: cache_data1_b0[store_update_index_q] <= merge_bytes(cache_data1_b0[store_update_index_q], store_update_wen_q, store_update_data_q);
                        3'd1: cache_data1_b1[store_update_index_q] <= merge_bytes(cache_data1_b1[store_update_index_q], store_update_wen_q, store_update_data_q);
                        3'd2: cache_data1_b2[store_update_index_q] <= merge_bytes(cache_data1_b2[store_update_index_q], store_update_wen_q, store_update_data_q);
                        3'd3: cache_data1_b3[store_update_index_q] <= merge_bytes(cache_data1_b3[store_update_index_q], store_update_wen_q, store_update_data_q);
                        3'd4: cache_data1_b4[store_update_index_q] <= merge_bytes(cache_data1_b4[store_update_index_q], store_update_wen_q, store_update_data_q);
                        3'd5: cache_data1_b5[store_update_index_q] <= merge_bytes(cache_data1_b5[store_update_index_q], store_update_wen_q, store_update_data_q);
                        3'd6: cache_data1_b6[store_update_index_q] <= merge_bytes(cache_data1_b6[store_update_index_q], store_update_wen_q, store_update_data_q);
                    endcase
                end
            end
            if (req_hit_fire)
                replace_way[req_head_index] <= req_hit0 ? 1'b1 : 1'b0;

            // Maintenance invalidation is part of the same cache-array
            // write port as refill allocation.  Keeping cache_valid0/1 in
            // this single sequential block is important for both synthesis
            // and the real hardware: a maintenance clear and a refill commit
            // must never become two independent drivers for the same RAM/FF
            // bit.  maint_ready prevents an ordinary maintenance operation
            // from overlapping an active refill; if a future caller changes
            // that contract, the textual priority below still gives the
            // maintenance invalidate the final write for that cycle.
            if (maint_state == M_APPLY) begin
                case (maint_mode_r)
                    2'b10: begin
                        if (maint_hit0) cache_valid0[maint_index_r] <= 1'b0;
                        if (maint_hit1) cache_valid1[maint_index_r] <= 1'b0;
                    end
                    2'b11: begin
                        cache_valid0[maint_index_r] <= 1'b0;
                        cache_valid1[maint_index_r] <= 1'b0;
                    end
                    default: begin
                        cache_valid0[maint_index_r] <= 1'b0;
                        cache_valid1[maint_index_r] <= 1'b0;
                    end
                endcase
            end else if (maint_state == M_ALL) begin
                cache_valid0[maint_count] <= 1'b0;
                cache_valid1[maint_count] <= 1'b0;
            end
        end
    end

    localparam M_IDLE = 3'd0;
    localparam M_LOOKUP = 3'd1;
    localparam M_APPLY = 3'd2;
    localparam M_ALL = 3'd3;
    localparam M_DONE = 3'd4;
    reg [2:0] maint_state;
    reg [4:0] maint_index_r, maint_count;
    reg [TAG_WID-1:0] maint_tag_r;
    reg [1:0] maint_mode_r;
    wire maint_hit0 = cache_valid0[maint_index_r] &&
                       (cache_tag0[maint_index_r] == maint_tag_r);
    wire maint_hit1 = cache_valid1[maint_index_r] &&
                       (cache_tag1[maint_index_r] == maint_tag_r);

    assign maint_ready = (maint_state == M_IDLE) &&
                         (req_count == 2'd0) && !active_refill &&
                         !uncached_read_pending && !uncached_write_pending &&
                         wcb_empty && !wcb_drain_active &&
                         (tid_resp_pending == 8'd0) && dev_widle;

    always @(posedge cpu_clk or negedge cpu_rstn) begin
        if (!cpu_rstn) begin
            maint_state <= M_IDLE;
            maint_index_r <= 5'd0;
            maint_count <= 5'd0;
            maint_tag_r <= 0;
            maint_mode_r <= 2'd0;
            maint_done <= 1'b0;
        end else begin
            maint_done <= 1'b0;
            case (maint_state)
                M_IDLE: if (maint_valid && maint_ready) begin
                    maint_index_r <= maint_addr[9:5];
                    maint_tag_r <= maint_addr[31:10];
                    maint_mode_r <= maint_mode;
                    maint_count <= 5'd0;
                    maint_state <= maint_all ? M_ALL : M_LOOKUP;
                end
                M_LOOKUP: maint_state <= M_APPLY;
                M_APPLY: begin
                    maint_state <= M_DONE;
                end
                M_ALL: begin
                    if (maint_count == CACHE_LINES-1) maint_state <= M_DONE;
                    else maint_count <= maint_count + 1'b1;
                end
                M_DONE: begin
                    maint_done <= 1'b1;
                    maint_state <= M_IDLE;
                end
                default: maint_state <= M_IDLE;
            endcase
        end
    end

`ifndef SYNTHESIS
    reg [63:0] tagged_cycle_count;
    reg [63:0] tagged_mshr_alloc_count;
    reg [63:0] tagged_mshr_complete_count;
    reg [63:0] tagged_refill_active_cycles;
    reg [63:0] tagged_response_count;
    reg [63:0] tagged_max_mshr;
    reg [63:0] tagged_max_req_fifo;
    initial $display("[DCACHE-TAGGED-CONFIG] MSHR=2 TID=8 external_refill=1");
    always @(posedge cpu_clk or negedge cpu_rstn) begin
        if (!cpu_rstn) begin
            tagged_cycle_count <= 0;
            tagged_mshr_alloc_count <= 0;
            tagged_mshr_complete_count <= 0;
            tagged_refill_active_cycles <= 0;
            tagged_response_count <= 0;
            tagged_max_mshr <= 0;
            tagged_max_req_fifo <= 0;
        end else begin
            tagged_cycle_count <= tagged_cycle_count + 1;
            if (req_new_miss_fire) tagged_mshr_alloc_count <= tagged_mshr_alloc_count + 1;
            if (any_refill_last) tagged_mshr_complete_count <= tagged_mshr_complete_count + 1;
            if (active_refill) tagged_refill_active_cycles <= tagged_refill_active_cycles + 1;
            if (resp_emit_found) tagged_response_count <= tagged_response_count + 1;
            if (refill_order_count > tagged_max_mshr) tagged_max_mshr <= refill_order_count;
            if (req_count > tagged_max_req_fifo) tagged_max_req_fifo <= req_count;
            if (tagged_cycle_count > 0 && (tagged_cycle_count % 100000 == 0)) begin
                $display("[DCACHE-TAGGED-STATS] cycles=%0d mshr_alloc=%0d mshr_complete=%0d active_cycles=%0d responses=%0d max_mshr=%0d max_req=%0d tid_pending=%0d",
                         tagged_cycle_count, tagged_mshr_alloc_count,
                         tagged_mshr_complete_count, tagged_refill_active_cycles,
                         tagged_response_count, tagged_max_mshr,
                         tagged_max_req_fifo, tid_resp_pending);
                $display("[DCACHE-MSHR-STATS] cycles=%0d alloc=%0d complete=%0d active_cycles=%0d max_ord_occ=%0d",
                         tagged_cycle_count, tagged_mshr_alloc_count,
                         tagged_mshr_complete_count, tagged_refill_active_cycles,
                         tagged_max_mshr);
            end
        end
    end
    always @(posedge cpu_clk) begin
        if (cpu_rstn) begin
            if (refill_order_count > 2'd2)
                $fatal(1, "[ASSERT-DCACHE-TAGGED] refill order FIFO overflow");
            if (req_count > 2'd2)
                $fatal(1, "[ASSERT-DCACHE-TAGGED] request FIFO overflow");
            if (wcb_order_count > 3'd4)
                $fatal(1, "[ASSERT-DCACHE-TAGGED] WCB order overflow");
        end
    end
`endif
endmodule
