`timescale 1ns / 1ps

// -----------------------------------------------------------------------------
// 512 KiB, two-way, four-bank L2 data cache for the soc_verify tree.
//
// The L1 TaggedDCache keeps its existing two refill lanes, MSHRs, TIDs and
// WCB.  This module is inserted between that L1 and sram_bus_master.  The L2
// accepts a complete eight-word critical-word-first refill, can satisfy it
// from its own data banks, and fills a line from the lower SRAM bridge on a
// miss.
//
// Store policy in this revision:
//   * a normal RAM Store that hits in L2 merges into the line and sets dirty;
//   * a normal RAM Store that misses L2 enters a two-entry line store-merge
//     buffer (SBUF), where repeated words/bytes are combined;
//   * SBUF lines are drained as byte-masked word writes only when needed;
//   * a dirty L2 victim is captured in a two-entry writeback buffer (WBB) and
//     drained through the original SRAM write bridge before the replacement
//     refill is allowed to start;
//   * MMIO/uncached Stores bypass L2 and retain the original completion
//     handshake.
//
// A pending SBUF/WBB line is overlaid on lower-memory refill data.  Therefore
// a load cannot observe stale SRAM while a merged Store line is waiting to be
// drained.  Dirty L2 lines remain resident until replacement or maintenance.
// -----------------------------------------------------------------------------
module L2DCache #(
    parameter integer SET_COUNT  = 8192,
    parameter integer LINE_WORDS = 8
)(
    input  wire        cpu_rstn,
    input  wire        cpu_clk,

    // Upper read lane 0: TaggedDCache -> L2
    input  wire [3:0]  up0_cpu_ren,
    input  wire [31:0] up0_cpu_raddr,
    input  wire        up0_cpu_rburst,
    output wire        up0_dev_rrdy,
    output wire        up0_dev_rvalid,
    output wire [31:0] up0_dev_rdata,

    // Upper read lane 1: TaggedDCache -> L2
    input  wire [3:0]  up1_cpu_ren,
    input  wire [31:0] up1_cpu_raddr,
    input  wire        up1_cpu_rburst,
    output wire        up1_dev_rrdy,
    output wire        up1_dev_rvalid,
    output wire [31:0] up1_dev_rdata,

    // Upper Store path: TaggedDCache -> L2
    input  wire [3:0]  up_store_wen,
    input  wire [31:0] up_store_addr,
    input  wire [31:0] up_store_wdata,
    input  wire        up_store_cacheable,
    output wire        up_store_wrdy,
    output wire        up_store_wdone,
    output wire        up_store_widle,

    // Lower read lane 0: L2 -> sram_bus_master
    output wire [3:0]  mem0_cpu_ren,
    output wire [31:0] mem0_cpu_raddr,
    output wire        mem0_cpu_rburst,
    input  wire        mem0_dev_rrdy,
    input  wire        mem0_dev_rvalid,
    input  wire [31:0] mem0_dev_rdata,

    // Lower read lane 1: L2 -> sram_bus_master
    output wire [3:0]  mem1_cpu_ren,
    output wire [31:0] mem1_cpu_raddr,
    output wire        mem1_cpu_rburst,
    input  wire        mem1_dev_rrdy,
    input  wire        mem1_dev_rvalid,
    input  wire [31:0] mem1_dev_rdata,

    // Lower write path: L2 -> sram_bus_master
    output wire [3:0]  mem_store_wen,
    output wire [31:0] mem_store_addr,
    output wire [31:0] mem_store_wdata,
    input  wire        mem_store_wrdy,
    input  wire        mem_store_wdone,
    input  wire        mem_store_widle,

    // DCache maintenance request.  The L2 writes dirty lines before reporting
    // maintenance complete to the top-level CPU wrapper.
    input  wire        invalidate_all,
    output wire        maint_done
);

    localparam integer SET_W       = 13;
    localparam integer TAG_W       = 14;
    localparam integer BANK_DEPTH  = SET_COUNT * 2;
    localparam integer BUFFER_DEPTH= 2;

    localparam [2:0] ST_IDLE        = 3'd0;
    localparam [2:0] ST_HIT_RESP    = 3'd1;
    localparam [2:0] ST_MISS_REQ    = 3'd2;
    localparam [2:0] ST_MISS_REFILL = 3'd3;
    localparam [2:0] ST_UNC_REQ     = 3'd4;
    localparam [2:0] ST_UNC_RESP    = 3'd5;
    localparam [2:0] ST_EVICT_WAIT  = 3'd6;
    localparam [2:0] ST_UNC_HIT     = 3'd7;

    // ------------------------------------------------------------------
    // L2 arrays: 512 KiB data, 32B line, 2 ways, 4 banks.
    // ------------------------------------------------------------------
    (* ram_style = "block" *) reg [31:0] data0_b0 [0:BANK_DEPTH-1];
    (* ram_style = "block" *) reg [31:0] data0_b1 [0:BANK_DEPTH-1];
    (* ram_style = "block" *) reg [31:0] data0_b2 [0:BANK_DEPTH-1];
    (* ram_style = "block" *) reg [31:0] data0_b3 [0:BANK_DEPTH-1];
    (* ram_style = "block" *) reg [31:0] data1_b0 [0:BANK_DEPTH-1];
    (* ram_style = "block" *) reg [31:0] data1_b1 [0:BANK_DEPTH-1];
    (* ram_style = "block" *) reg [31:0] data1_b2 [0:BANK_DEPTH-1];
    (* ram_style = "block" *) reg [31:0] data1_b3 [0:BANK_DEPTH-1];

    reg [TAG_W-1:0] tag0 [0:SET_COUNT-1];
    reg [TAG_W-1:0] tag1 [0:SET_COUNT-1];
    reg              valid0 [0:SET_COUNT-1];
    reg              valid1 [0:SET_COUNT-1];
    reg              dirty0 [0:SET_COUNT-1];
    reg              dirty1 [0:SET_COUNT-1];
    reg              replace_way [0:SET_COUNT-1];

    // Two line-combining entries for Store misses.  A partial line is safe to
    // drain because byte_valid controls every lower write byte.
    reg [26:0]  sbuf_line [0:BUFFER_DEPTH-1];
    reg [255:0] sbuf_data [0:BUFFER_DEPTH-1];
    reg [31:0]  sbuf_byte_valid [0:BUFFER_DEPTH-1];
    reg         sbuf_valid [0:BUFFER_DEPTH-1];

    // Two dirty-victim writeback entries.
    reg [26:0]  wb_line [0:BUFFER_DEPTH-1];
    reg [255:0] wb_data [0:BUFFER_DEPTH-1];
    reg [31:0]  wb_byte_valid [0:BUFFER_DEPTH-1];
    reg         wb_valid [0:BUFFER_DEPTH-1];

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

    function automatic [31:0] merge_masked_word;
        input [31:0] base_data;
        input [3:0]  byte_enable;
        input [31:0] write_data;
        begin
            merge_masked_word = merge_bytes(base_data, byte_enable, write_data);
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

    function automatic [31:0] merge_line_mask;
        input [31:0] base_mask;
        input [4:0]  byte_offset;
        input [3:0]  byte_enable;
        reg [31:0] result;
        integer mi;
        begin
            result = base_mask;
            for (mi = 0; mi < 4; mi = mi + 1)
                if (byte_enable[mi])
                    result[byte_offset[4:2]*4 + mi] = 1'b1;
            merge_line_mask = result;
        end
    endfunction

    function automatic [31:0] select_word;
        input [255:0] line_data;
        input [2:0]   word_index;
        begin
            select_word = line_data[word_index*32 +: 32];
        end
    endfunction

    function automatic [31:0] read_word;
        input             way;
        input [SET_W-1:0] set_index;
        input [2:0]       word_index;
        integer bank_index;
        integer ram_index;
        begin
            bank_index = word_index[1:0];
            ram_index  = {set_index, word_index[2]};
            case ({way, bank_index[1:0]})
                3'd0: read_word = data0_b0[ram_index];
                3'd1: read_word = data0_b1[ram_index];
                3'd2: read_word = data0_b2[ram_index];
                3'd3: read_word = data0_b3[ram_index];
                3'd4: read_word = data1_b0[ram_index];
                3'd5: read_word = data1_b1[ram_index];
                3'd6: read_word = data1_b2[ram_index];
                default: read_word = data1_b3[ram_index];
            endcase
        end
    endfunction

    function automatic [255:0] read_line;
        input             way;
        input [SET_W-1:0] set_index;
        reg [255:0] result;
        integer li;
        begin
            result = 256'd0;
            for (li = 0; li < LINE_WORDS; li = li + 1)
                result[li*32 +: 32] = read_word(way, set_index, li[2:0]);
            read_line = result;
        end
    endfunction

    function automatic [31:0] overlay_pending_word;
        input [31:0] base_data;
        input [26:0] line_addr;
        input [2:0]  word_index;
        reg [31:0] result;
        integer oi;
        begin
            result = base_data;
            for (oi = 0; oi < BUFFER_DEPTH; oi = oi + 1) begin
                if (wb_valid[oi] && (wb_line[oi] == line_addr))
                    result = merge_bytes(result,
                        wb_byte_valid[oi][word_index*4 +: 4],
                        select_word(wb_data[oi], word_index));
                if (sbuf_valid[oi] && (sbuf_line[oi] == line_addr))
                    result = merge_bytes(result,
                        sbuf_byte_valid[oi][word_index*4 +: 4],
                        select_word(sbuf_data[oi], word_index));
            end
            overlay_pending_word = result;
        end
    endfunction

    // Form one final word when a refill commits.  Earlier refill beats are
    // already present in the array; the current response beat is supplied
    // explicitly because its array write is nonblocking in this clock edge.
    // Applying pending buffers across all eight words also covers a Store
    // that arrived after its target refill beat had already returned.
    function automatic [31:0] refill_commit_word;
        input             way;
        input [SET_W-1:0] set_index;
        input [2:0]       word_index;
        input [2:0]       response_index;
        input [31:0]      response_data;
        input [26:0]      refill_line_addr;
        input             current_store_valid;
        input [26:0]      current_store_line;
        input [2:0]       current_store_word;
        input [3:0]       current_store_wen;
        input [31:0]      current_store_data;
        reg [31:0] result;
        begin
            result = (word_index == response_index) ? response_data :
                     read_word(way, set_index, word_index);
            result = overlay_pending_word(result, refill_line_addr, word_index);
            if (current_store_valid &&
                (current_store_line == refill_line_addr) &&
                (current_store_word == word_index))
                result = merge_bytes(result, current_store_wen,
                                     current_store_data);
            refill_commit_word = result;
        end
    endfunction

    function automatic is_peripheral_addr;
        input [31:0] addr;
        begin
            is_peripheral_addr =
                ((addr >= 32'h1f00_0000) && (addr < 32'h1f60_0000)) ||
                (addr[31:16] == 16'hBFAF) ||
                (addr[31:16] == 16'hBFD0);
        end
    endfunction

    // ------------------------------------------------------------------
    // Read-lane state
    // ------------------------------------------------------------------
    reg [2:0] state0, state1;
    reg [31:0] addr0, addr1;
    reg [3:0]  ren0, ren1;
    reg        burst0, burst1;
    reg [SET_W-1:0] set0, set1;
    reg [TAG_W-1:0] tag_req0, tag_req1;
    reg        way0, way1;
    reg [2:0]  critical0, critical1;
    reg [2:0]  beat0, beat1;

    wire [SET_W-1:0] input_set0 = up0_cpu_raddr[17:5];
    wire [SET_W-1:0] input_set1 = up1_cpu_raddr[17:5];
    wire [TAG_W-1:0] input_tag0 = up0_cpu_raddr[31:18];
    wire [TAG_W-1:0] input_tag1 = up1_cpu_raddr[31:18];
    wire hit0_way0 = valid0[input_set0] && (tag0[input_set0] == input_tag0);
    wire hit0_way1 = valid1[input_set0] && (tag1[input_set0] == input_tag0);
    wire hit1_way0 = valid0[input_set1] && (tag0[input_set1] == input_tag1);
    wire hit1_way1 = valid1[input_set1] && (tag1[input_set1] == input_tag1);
    wire [26:0] line0 = {tag_req0, set0};
    wire [26:0] line1 = {tag_req1, set1};
    wire [2:0] response_word0 = critical0 + beat0;
    wire [2:0] response_word1 = critical1 + beat1;

    wire choose_way0 = !valid0[input_set0] ? 1'b0 :
                       (!valid1[input_set0] ? 1'b1 : replace_way[input_set0]);
    wire choose_way1 = !valid0[input_set1] ? 1'b0 :
                       (!valid1[input_set1] ? 1'b1 : replace_way[input_set1]);
    wire victim_dirty0 = choose_way0 ?
                         (valid1[input_set0] && dirty1[input_set0]) :
                         (valid0[input_set0] && dirty0[input_set0]);
    wire victim_dirty1 = choose_way1 ?
                         (valid1[input_set1] && dirty1[input_set1]) :
                         (valid0[input_set1] && dirty0[input_set1]);

    // ------------------------------------------------------------------
    // Writeback/store-buffer drain engine
    // ------------------------------------------------------------------
    reg        drain_active;
    reg        drain_is_wb;
    reg        drain_idx;
    reg [7:0]  drain_sent_mask;
    reg [7:0]  drain_valid_mask;
    reg [3:0]  drain_pending_count;
    reg [2:0]  drain_word_idx;
    reg [3:0]  drain_word_wen;
    reg [31:0] drain_word_data;
    reg [26:0] drain_line_addr;
    reg        drain_word_found;
    reg        bypass_pending;
    reg        store_ack_pending;
    integer drain_scan_i;

    always @(*) begin
        drain_word_idx   = 3'd0;
        drain_word_wen   = 4'h0;
        drain_word_data  = 32'h0;
        drain_line_addr  = 27'd0;
        drain_word_found = 1'b0;
        if (drain_active) begin
            if (drain_is_wb) begin
                drain_line_addr = wb_line[drain_idx];
                for (drain_scan_i = 0; drain_scan_i < LINE_WORDS; drain_scan_i = drain_scan_i + 1)
                    if (!drain_word_found &&
                        !drain_sent_mask[drain_scan_i] &&
                        (wb_byte_valid[drain_idx][drain_scan_i*4 +: 4] != 4'h0)) begin
                        drain_word_idx = drain_scan_i[2:0];
                        drain_word_wen = wb_byte_valid[drain_idx][drain_scan_i*4 +: 4];
                        drain_word_data = select_word(wb_data[drain_idx], drain_scan_i[2:0]);
                        drain_word_found = 1'b1;
                    end
            end else begin
                drain_line_addr = sbuf_line[drain_idx];
                for (drain_scan_i = 0; drain_scan_i < LINE_WORDS; drain_scan_i = drain_scan_i + 1)
                    if (!drain_word_found &&
                        !drain_sent_mask[drain_scan_i] &&
                        (sbuf_byte_valid[drain_idx][drain_scan_i*4 +: 4] != 4'h0)) begin
                        drain_word_idx = drain_scan_i[2:0];
                        drain_word_wen = sbuf_byte_valid[drain_idx][drain_scan_i*4 +: 4];
                        drain_word_data = select_word(sbuf_data[drain_idx], drain_scan_i[2:0]);
                        drain_word_found = 1'b1;
                    end
            end
        end
    end

    // The lower write bridge already contains a 16-entry request FIFO and a
    // matching completion FIFO.  Do not serialize every word on the CDC
    // round trip: enqueue consecutive words while ready, then retain the
    // SBUF/WBB owner until exactly the same number of physical completions
    // has returned.
    wire drain_fire = drain_active && drain_word_found && mem_store_wrdy;
    wire drain_done_fire = drain_active && mem_store_wdone &&
                           (drain_pending_count != 4'd0);
    wire [7:0] drain_valid_words = drain_is_wb ?
        {wb_byte_valid[drain_idx][28 +: 4] != 0,
         wb_byte_valid[drain_idx][24 +: 4] != 0,
         wb_byte_valid[drain_idx][20 +: 4] != 0,
         wb_byte_valid[drain_idx][16 +: 4] != 0,
         wb_byte_valid[drain_idx][12 +: 4] != 0,
         wb_byte_valid[drain_idx][ 8 +: 4] != 0,
         wb_byte_valid[drain_idx][ 4 +: 4] != 0,
         wb_byte_valid[drain_idx][ 0 +: 4] != 0} :
        {sbuf_byte_valid[drain_idx][28 +: 4] != 0,
         sbuf_byte_valid[drain_idx][24 +: 4] != 0,
         sbuf_byte_valid[drain_idx][20 +: 4] != 0,
         sbuf_byte_valid[drain_idx][16 +: 4] != 0,
         sbuf_byte_valid[drain_idx][12 +: 4] != 0,
         sbuf_byte_valid[drain_idx][ 8 +: 4] != 0,
         sbuf_byte_valid[drain_idx][ 4 +: 4] != 0,
         sbuf_byte_valid[drain_idx][ 0 +: 4] != 0};
    wire [7:0] drain_sent_after = drain_sent_mask |
        (drain_fire ? (8'b1 << drain_word_idx) : 8'h00);
    wire [3:0] drain_pending_after = drain_pending_count +
        (drain_fire ? 4'd1 : 4'd0) -
        (drain_done_fire ? 4'd1 : 4'd0);
    wire drain_all_sent_after =
        (drain_sent_after & drain_valid_words) == drain_valid_words;
    wire drain_complete = drain_active && drain_all_sent_after &&
                          (drain_pending_after == 4'd0);
    wire drain_start = !drain_active && mem_store_widle &&
                       !bypass_pending &&
                       !(up_store_cacheable && (up_store_wen != 4'h0) &&
                         up_store_wrdy) &&
                       (wb_valid[0] || wb_valid[1] ||
                        sbuf_valid[0] || sbuf_valid[1]);
    wire bypass_drive = !up_store_cacheable &&
                        !drain_active && !bypass_pending &&
                        (up_store_wen != 4'h0);

    assign mem_store_wen = bypass_drive ? up_store_wen :
                           (drain_active && drain_word_found ?
                            drain_word_wen : 4'h0);
    assign mem_store_addr = bypass_drive ? up_store_addr :
                            ({drain_line_addr, 5'b0} +
                             (drain_word_idx * 32'd4));
    assign mem_store_wdata = bypass_drive ? up_store_wdata : drain_word_data;

    always @(posedge cpu_clk or negedge cpu_rstn) begin
        if (!cpu_rstn) begin
            drain_active    <= 1'b0;
            drain_is_wb     <= 1'b0;
            drain_idx       <= 1'b0;
            drain_sent_mask <= 8'h0;
            drain_pending_count <= 4'd0;
        end else begin
            if (!drain_active) begin
                if (drain_start) begin
                    drain_active    <= 1'b1;
                    drain_sent_mask <= 8'h0;
                    drain_pending_count <= 4'd0;
                    if (wb_valid[0] || wb_valid[1]) begin
                        drain_is_wb <= 1'b1;
                        drain_idx   <= wb_valid[0] ? 1'b0 : 1'b1;
                    end else begin
                        drain_is_wb <= 1'b0;
                        drain_idx   <= sbuf_valid[0] ? 1'b0 : 1'b1;
                    end
                end
            end else begin
                if (drain_fire)
                    drain_sent_mask[drain_word_idx] <= 1'b1;
                case ({drain_fire, drain_done_fire})
                    2'b10: drain_pending_count <= drain_pending_count + 4'd1;
                    2'b01: drain_pending_count <= drain_pending_count - 4'd1;
                    default: drain_pending_count <= drain_pending_count;
                endcase
                if (drain_complete) begin
                    drain_active    <= 1'b0;
                    drain_sent_mask <= 8'h0;
                    drain_pending_count <= 4'd0;
                end
            end
        end
    end

    // ------------------------------------------------------------------
    // Store acceptance and maintenance state
    // ------------------------------------------------------------------
    wire [SET_W-1:0] store_set = up_store_addr[17:5];
    wire [TAG_W-1:0] store_tag = up_store_addr[31:18];
    wire store_hit0 = valid0[store_set] && (tag0[store_set] == store_tag);
    wire store_hit1 = valid1[store_set] && (tag1[store_set] == store_tag);
    wire wb_store_match0 = wb_valid[0] && (wb_line[0] == up_store_addr[31:5]);
    wire wb_store_match1 = wb_valid[1] && (wb_line[1] == up_store_addr[31:5]);
    wire sbuf_store_match0 = sbuf_valid[0] && (sbuf_line[0] == up_store_addr[31:5]);
    wire sbuf_store_match1 = sbuf_valid[1] && (sbuf_line[1] == up_store_addr[31:5]);
    wire wb_store_block0 = drain_active && drain_is_wb && (drain_idx == 1'b0);
    wire wb_store_block1 = drain_active && drain_is_wb && (drain_idx == 1'b1);
    wire sbuf_store_block0 = drain_active && !drain_is_wb && (drain_idx == 1'b0);
    wire sbuf_store_block1 = drain_active && !drain_is_wb && (drain_idx == 1'b1);
    wire wb_store_match_ready = (wb_store_match0 && !wb_store_block0) ||
                                 (wb_store_match1 && !wb_store_block1);
    wire sbuf_store_match_ready = (sbuf_store_match0 && !sbuf_store_block0) ||
                                   (sbuf_store_match1 && !sbuf_store_block1);
    wire sbuf_free_found = !sbuf_valid[0] || !sbuf_valid[1];
    wire sbuf_free_idx = !sbuf_valid[0] ? 1'b0 : 1'b1;

    reg flush_active;
    reg flush_scan_done;
    reg flush_scan_way;
    reg [SET_W-1:0] flush_scan_set;
    reg invalidate_all_d;
    reg maint_complete;

    wire flush_current_valid = flush_scan_way ?
                                valid1[flush_scan_set] : valid0[flush_scan_set];
    wire flush_current_dirty = flush_scan_way ?
                                (valid1[flush_scan_set] && dirty1[flush_scan_set]) :
                                (valid0[flush_scan_set] && dirty0[flush_scan_set]);
    wire wb_free_found = !wb_valid[0] || !wb_valid[1];
    wire wb_free_idx = !wb_valid[0] ? 1'b0 : 1'b1;
    wire invalidate_fire = invalidate_all && !invalidate_all_d;
    wire flush_can_scan = flush_active && !flush_scan_done &&
                          (state0 == ST_IDLE) && (state1 == ST_IDLE);
    wire flush_wb_alloc = flush_can_scan && flush_current_dirty && wb_free_found;
    wire flush_scan_advance = flush_can_scan &&
                              (!flush_current_dirty || flush_wb_alloc);

    // Dirty victim capture has lower priority than an active maintenance
    // flush.  Lane 0 wins if both refill lanes need a WBB entry in one cycle.
    wire evict_alloc0 = !flush_wb_alloc && !flush_active &&
                        (state0 == ST_EVICT_WAIT) && wb_free_found;
    wire evict_alloc1 = !flush_wb_alloc && !flush_active && !evict_alloc0 &&
                        (state1 == ST_EVICT_WAIT) && wb_free_found;

    wire normal_store_ready = !flush_active && !invalidate_all &&
                              !bypass_pending &&
                              (store_hit0 || store_hit1 ||
                               wb_store_match_ready || sbuf_store_match_ready ||
                               sbuf_free_found);
    // The cacheability bit must come from TaggedDCache.  Physical address
    // alone cannot distinguish a cacheable RAM access from an uncached DMW
    // alias or the early-boot uncached RAM window.
    wire bypass_store_ready = !up_store_cacheable && !flush_active &&
                              !invalidate_all && !drain_active &&
                              !bypass_pending &&
                              !wb_valid[0] && !wb_valid[1] &&
                              !sbuf_valid[0] && !sbuf_valid[1] &&
                              mem_store_wrdy;
    assign up_store_wrdy = up_store_cacheable ? normal_store_ready :
                           bypass_store_ready;
    wire normal_store_accept = up_store_cacheable &&
                                (up_store_wen != 4'h0) && up_store_wrdy;
    wire bypass_store_accept = !up_store_cacheable &&
                         (up_store_wen != 4'h0) && up_store_wrdy;

    // DCache's WCB accounts a write-completion pulse one cycle after the
    // lower-side request acceptance.  Keep this one-stage pipeline even
    // though a normal Store is already safe in L2, so the first word of a
    // back-to-back drain is not lost when the DCache outstanding count is 0.
    assign up_store_wdone = store_ack_pending ||
                            (bypass_pending && mem_store_wdone);
    assign up_store_widle = !flush_active && !bypass_pending &&
                            !store_ack_pending &&
                            !drain_active &&
                            !wb_valid[0] && !wb_valid[1] &&
                            !sbuf_valid[0] && !sbuf_valid[1] &&
                            mem_store_widle;
    assign maint_done = !invalidate_all || maint_complete;

    // ------------------------------------------------------------------
    // Read interface and pending-store forwarding
    // ------------------------------------------------------------------
    assign up0_dev_rrdy = (state0 == ST_IDLE) && !flush_active && !invalidate_all;
    assign up1_dev_rrdy = (state1 == ST_IDLE) && !flush_active && !invalidate_all;
    assign mem0_cpu_ren = (state0 == ST_MISS_REQ) ? 4'hf :
                          (state0 == ST_UNC_REQ) ? ren0 : 4'h0;
    assign mem0_cpu_raddr = addr0;
    assign mem0_cpu_rburst = (state0 == ST_MISS_REQ);
    assign mem1_cpu_ren = (state1 == ST_MISS_REQ) ? 4'hf :
                          (state1 == ST_UNC_REQ) ? ren1 : 4'h0;
    assign mem1_cpu_raddr = addr1;
    assign mem1_cpu_rburst = (state1 == ST_MISS_REQ);

    wire lane0_accept = up0_dev_rrdy && (up0_cpu_ren != 4'h0);
    wire lane1_accept = up1_dev_rrdy && (up1_cpu_ren != 4'h0);
    wire lane0_mem_fire = (state0 == ST_MISS_REQ || state0 == ST_UNC_REQ) &&
                          mem0_dev_rrdy;
    wire lane1_mem_fire = (state1 == ST_MISS_REQ || state1 == ST_UNC_REQ) &&
                          mem1_dev_rrdy;
    wire [31:0] refill_word0 = overlay_pending_word(
        mem0_dev_rdata, line0, response_word0);
    wire [31:0] refill_word1 = overlay_pending_word(
        mem1_dev_rdata, line1, response_word1);
    wire current_store_on_refill0 = normal_store_accept &&
                                     (up_store_addr[31:5] == line0) &&
                                     (up_store_addr[4:2] == response_word0);
    wire current_store_on_refill1 = normal_store_accept &&
                                     (up_store_addr[31:5] == line1) &&
                                     (up_store_addr[4:2] == response_word1);
    wire current_store_line0 = normal_store_accept &&
                                (state0 == ST_MISS_REFILL) &&
                                mem0_dev_rvalid &&
                                (up_store_addr[31:5] == line0);
    wire current_store_line1 = normal_store_accept &&
                                (state1 == ST_MISS_REFILL) &&
                                mem1_dev_rvalid &&
                                (up_store_addr[31:5] == line1);
    wire store_on_final_refill0 = current_store_line0 && (beat0 == 3'd7);
    wire store_on_final_refill1 = current_store_line1 && (beat1 == 3'd7);
    wire [31:0] refill_word0_with_store = current_store_on_refill0 ?
        merge_bytes(refill_word0, up_store_wen, up_store_wdata) : refill_word0;
    wire [31:0] refill_word1_with_store = current_store_on_refill1 ?
        merge_bytes(refill_word1, up_store_wen, up_store_wdata) : refill_word1;
    wire pending_line0 = (wb_valid[0] && (wb_line[0] == line0)) ||
                         (wb_valid[1] && (wb_line[1] == line0)) ||
                         (sbuf_valid[0] && (sbuf_line[0] == line0)) ||
                         (sbuf_valid[1] && (sbuf_line[1] == line0));
    wire pending_line1 = (wb_valid[0] && (wb_line[0] == line1)) ||
                         (wb_valid[1] && (wb_line[1] == line1)) ||
                         (sbuf_valid[0] && (sbuf_line[0] == line1)) ||
                         (sbuf_valid[1] && (sbuf_line[1] == line1));

    assign up0_dev_rvalid = (state0 == ST_HIT_RESP) ||
                            (state0 == ST_UNC_HIT) ||
                            (state0 == ST_MISS_REFILL && mem0_dev_rvalid) ||
                            (state0 == ST_UNC_RESP && mem0_dev_rvalid);
    assign up1_dev_rvalid = (state1 == ST_HIT_RESP) ||
                            (state1 == ST_UNC_HIT) ||
                            (state1 == ST_MISS_REFILL && mem1_dev_rvalid) ||
                            (state1 == ST_UNC_RESP && mem1_dev_rvalid);
    assign up0_dev_rdata = (state0 == ST_HIT_RESP) ?
                           read_word(way0, set0, response_word0) :
                           (state0 == ST_UNC_HIT) ?
                           overlay_pending_word(
                               read_word(way0, set0, response_word0),
                               line0, response_word0) :
                           ((state0 == ST_MISS_REFILL) ?
                            refill_word0_with_store :
                            ((state0 == ST_UNC_RESP) ?
                             overlay_pending_word(mem0_dev_rdata,
                                                   addr0[31:5],
                                                   addr0[4:2]) :
                             mem0_dev_rdata));
    assign up1_dev_rdata = (state1 == ST_HIT_RESP) ?
                           read_word(way1, set1, response_word1) :
                           (state1 == ST_UNC_HIT) ?
                           overlay_pending_word(
                               read_word(way1, set1, response_word1),
                               line1, response_word1) :
                           ((state1 == ST_MISS_REFILL) ?
                            refill_word1_with_store :
                            ((state1 == ST_UNC_RESP) ?
                             overlay_pending_word(mem1_dev_rdata,
                                                   addr1[31:5],
                                                   addr1[4:2]) :
                             mem1_dev_rdata));

    // ------------------------------------------------------------------
    // Main sequential state and arrays
    // ------------------------------------------------------------------
    integer reset_i;
    integer word_i;
    always @(posedge cpu_clk or negedge cpu_rstn) begin
        if (!cpu_rstn) begin
            state0 <= ST_IDLE;
            state1 <= ST_IDLE;
            addr0 <= 32'd0;
            addr1 <= 32'd0;
            ren0 <= 4'd0;
            ren1 <= 4'd0;
            burst0 <= 1'b0;
            burst1 <= 1'b0;
            set0 <= 13'd0;
            set1 <= 13'd0;
            tag_req0 <= 14'd0;
            tag_req1 <= 14'd0;
            way0 <= 1'b0;
            way1 <= 1'b0;
            critical0 <= 3'd0;
            critical1 <= 3'd0;
            beat0 <= 3'd0;
            beat1 <= 3'd0;
            bypass_pending <= 1'b0;
            store_ack_pending <= 1'b0;
            invalidate_all_d <= 1'b0;
            flush_active <= 1'b0;
            flush_scan_done <= 1'b0;
            flush_scan_way <= 1'b0;
            flush_scan_set <= 13'd0;
            maint_complete <= 1'b1;
            for (reset_i = 0; reset_i < SET_COUNT; reset_i = reset_i + 1) begin
                valid0[reset_i] <= 1'b0;
                valid1[reset_i] <= 1'b0;
                dirty0[reset_i] <= 1'b0;
                dirty1[reset_i] <= 1'b0;
                replace_way[reset_i] <= 1'b0;
            end
            for (reset_i = 0; reset_i < BUFFER_DEPTH; reset_i = reset_i + 1) begin
                sbuf_valid[reset_i] <= 1'b0;
                sbuf_line[reset_i] <= 27'd0;
                sbuf_data[reset_i] <= 256'd0;
                sbuf_byte_valid[reset_i] <= 32'd0;
                wb_valid[reset_i] <= 1'b0;
                wb_line[reset_i] <= 27'd0;
                wb_data[reset_i] <= 256'd0;
                wb_byte_valid[reset_i] <= 32'd0;
            end
        end else begin
            invalidate_all_d <= invalidate_all;

            if (bypass_store_accept)
                bypass_pending <= 1'b1;
            if (bypass_pending && mem_store_wdone)
                bypass_pending <= 1'b0;
            store_ack_pending <= normal_store_accept;

            if (invalidate_fire) begin
                flush_active <= 1'b1;
                flush_scan_done <= 1'b0;
                flush_scan_way <= 1'b0;
                flush_scan_set <= 13'd0;
                maint_complete <= 1'b0;
            end

            // A new upper read is accepted only while its lane is idle.  A
            // dirty victim enters EVICT_WAIT until a WBB slot is available.
            if (lane0_accept) begin
                addr0     <= up0_cpu_raddr;
                ren0      <= up0_cpu_ren;
                burst0    <= up0_cpu_rburst;
                set0      <= input_set0;
                tag_req0  <= input_tag0;
                critical0 <= up0_cpu_raddr[4:2];
                beat0     <= 3'd0;
                if (!up0_cpu_rburst) begin
                    way0 <= hit0_way1 && !hit0_way0;
                    state0 <= (hit0_way0 || hit0_way1) ?
                              ST_UNC_HIT : ST_UNC_REQ;
                end else if (hit0_way0 || hit0_way1) begin
                    way0 <= hit0_way1 && !hit0_way0;
                    state0 <= ST_HIT_RESP;
                end else begin
                    way0 <= choose_way0;
                    state0 <= victim_dirty0 ? ST_EVICT_WAIT : ST_MISS_REQ;
                    if (choose_way0) begin
                        valid1[input_set0] <= 1'b0;
                        if (!victim_dirty0) dirty1[input_set0] <= 1'b0;
                    end else begin
                        valid0[input_set0] <= 1'b0;
                        if (!victim_dirty0) dirty0[input_set0] <= 1'b0;
                    end
                end
            end

            if (lane1_accept) begin
                addr1     <= up1_cpu_raddr;
                ren1      <= up1_cpu_ren;
                burst1    <= up1_cpu_rburst;
                set1      <= input_set1;
                tag_req1  <= input_tag1;
                critical1 <= up1_cpu_raddr[4:2];
                beat1     <= 3'd0;
                if (!up1_cpu_rburst) begin
                    way1 <= hit1_way1 && !hit1_way0;
                    state1 <= (hit1_way0 || hit1_way1) ?
                              ST_UNC_HIT : ST_UNC_REQ;
                end else if (hit1_way0 || hit1_way1) begin
                    way1 <= hit1_way1 && !hit1_way0;
                    state1 <= ST_HIT_RESP;
                end else begin
                    way1 <= choose_way1;
                    state1 <= victim_dirty1 ? ST_EVICT_WAIT : ST_MISS_REQ;
                    if (choose_way1) begin
                        valid1[input_set1] <= 1'b0;
                        if (!victim_dirty1) dirty1[input_set1] <= 1'b0;
                    end else begin
                        valid0[input_set1] <= 1'b0;
                        if (!victim_dirty1) dirty0[input_set1] <= 1'b0;
                    end
                end
            end

            if (evict_alloc0) begin
                wb_valid[wb_free_idx] <= 1'b1;
                wb_line[wb_free_idx] <= way0 ?
                    {tag1[input_set0], input_set0} :
                    {tag0[input_set0], input_set0};
                wb_data[wb_free_idx] <= read_line(way0, input_set0);
                wb_byte_valid[wb_free_idx] <= 32'hffff_ffff;
                if (way0) dirty1[input_set0] <= 1'b0;
                else dirty0[input_set0] <= 1'b0;
                state0 <= ST_MISS_REQ;
            end
            if (evict_alloc1) begin
                wb_valid[wb_free_idx] <= 1'b1;
                wb_line[wb_free_idx] <= way1 ?
                    {tag1[input_set1], input_set1} :
                    {tag0[input_set1], input_set1};
                wb_data[wb_free_idx] <= read_line(way1, input_set1);
                wb_byte_valid[wb_free_idx] <= 32'hffff_ffff;
                if (way1) dirty1[input_set1] <= 1'b0;
                else dirty0[input_set1] <= 1'b0;
                state1 <= ST_MISS_REQ;
            end

            if (lane0_mem_fire && state0 == ST_MISS_REQ)
                state0 <= ST_MISS_REFILL;
            else if (lane0_mem_fire && state0 == ST_UNC_REQ)
                state0 <= ST_UNC_RESP;
            if (lane1_mem_fire && state1 == ST_MISS_REQ)
                state1 <= ST_MISS_REFILL;
            else if (lane1_mem_fire && state1 == ST_UNC_REQ)
                state1 <= ST_UNC_RESP;

            if (state0 == ST_HIT_RESP) begin
                if (beat0 == 3'd7) state0 <= ST_IDLE;
                else beat0 <= beat0 + 3'd1;
            end
            if (state1 == ST_HIT_RESP) begin
                if (beat1 == 3'd7) state1 <= ST_IDLE;
                else beat1 <= beat1 + 3'd1;
            end
            if (state0 == ST_UNC_RESP && mem0_dev_rvalid) state0 <= ST_IDLE;
            if (state1 == ST_UNC_RESP && mem1_dev_rvalid) state1 <= ST_IDLE;
            if (state0 == ST_UNC_HIT) state0 <= ST_IDLE;
            if (state1 == ST_UNC_HIT) state1 <= ST_IDLE;

            if (state0 == ST_MISS_REFILL && mem0_dev_rvalid) begin
                case ({way0, response_word0[1:0]})
                    3'd0: data0_b0[{set0, response_word0[2]}] <= refill_word0_with_store;
                    3'd1: data0_b1[{set0, response_word0[2]}] <= refill_word0_with_store;
                    3'd2: data0_b2[{set0, response_word0[2]}] <= refill_word0_with_store;
                    3'd3: data0_b3[{set0, response_word0[2]}] <= refill_word0_with_store;
                    3'd4: data1_b0[{set0, response_word0[2]}] <= refill_word0_with_store;
                    3'd5: data1_b1[{set0, response_word0[2]}] <= refill_word0_with_store;
                    3'd6: data1_b2[{set0, response_word0[2]}] <= refill_word0_with_store;
                    default: data1_b3[{set0, response_word0[2]}] <= refill_word0_with_store;
                endcase
                if (beat0 == 3'd7) begin
                    for (word_i = 0; word_i < LINE_WORDS; word_i = word_i + 1) begin
                        case ({way0, word_i[1:0]})
                            3'd0: data0_b0[{set0, word_i[2]}] <= refill_commit_word(
                                way0, set0, word_i[2:0], response_word0,
                                refill_word0_with_store, line0,
                                current_store_line0, up_store_addr[31:5],
                                up_store_addr[4:2], up_store_wen, up_store_wdata);
                            3'd1: data0_b1[{set0, word_i[2]}] <= refill_commit_word(
                                way0, set0, word_i[2:0], response_word0,
                                refill_word0_with_store, line0,
                                current_store_line0, up_store_addr[31:5],
                                up_store_addr[4:2], up_store_wen, up_store_wdata);
                            3'd2: data0_b2[{set0, word_i[2]}] <= refill_commit_word(
                                way0, set0, word_i[2:0], response_word0,
                                refill_word0_with_store, line0,
                                current_store_line0, up_store_addr[31:5],
                                up_store_addr[4:2], up_store_wen, up_store_wdata);
                            3'd3: data0_b3[{set0, word_i[2]}] <= refill_commit_word(
                                way0, set0, word_i[2:0], response_word0,
                                refill_word0_with_store, line0,
                                current_store_line0, up_store_addr[31:5],
                                up_store_addr[4:2], up_store_wen, up_store_wdata);
                            3'd4: data1_b0[{set0, word_i[2]}] <= refill_commit_word(
                                way0, set0, word_i[2:0], response_word0,
                                refill_word0_with_store, line0,
                                current_store_line0, up_store_addr[31:5],
                                up_store_addr[4:2], up_store_wen, up_store_wdata);
                            3'd5: data1_b1[{set0, word_i[2]}] <= refill_commit_word(
                                way0, set0, word_i[2:0], response_word0,
                                refill_word0_with_store, line0,
                                current_store_line0, up_store_addr[31:5],
                                up_store_addr[4:2], up_store_wen, up_store_wdata);
                            3'd6: data1_b2[{set0, word_i[2]}] <= refill_commit_word(
                                way0, set0, word_i[2:0], response_word0,
                                refill_word0_with_store, line0,
                                current_store_line0, up_store_addr[31:5],
                                up_store_addr[4:2], up_store_wen, up_store_wdata);
                            default: data1_b3[{set0, word_i[2]}] <= refill_commit_word(
                                way0, set0, word_i[2:0], response_word0,
                                refill_word0_with_store, line0,
                                current_store_line0, up_store_addr[31:5],
                                up_store_addr[4:2], up_store_wen, up_store_wdata);
                        endcase
                    end
                    if (way0) begin
                        tag1[set0] <= tag_req0;
                        valid1[set0] <= 1'b1;
                        dirty1[set0] <= pending_line0 || current_store_line0;
                    end else begin
                        tag0[set0] <= tag_req0;
                        valid0[set0] <= 1'b1;
                        dirty0[set0] <= pending_line0 || current_store_line0;
                    end
                    replace_way[set0] <= ~way0;
                    state0 <= ST_IDLE;
                    if (sbuf_valid[0] && sbuf_line[0] == line0 &&
                        !(drain_active && !drain_is_wb && drain_idx == 1'b0))
                        sbuf_valid[0] <= 1'b0;
                    if (sbuf_valid[1] && sbuf_line[1] == line0 &&
                        !(drain_active && !drain_is_wb && drain_idx == 1'b1))
                        sbuf_valid[1] <= 1'b0;
                    if (wb_valid[0] && wb_line[0] == line0 &&
                        !(drain_active && drain_is_wb && drain_idx == 1'b0))
                        wb_valid[0] <= 1'b0;
                    if (wb_valid[1] && wb_line[1] == line0 &&
                        !(drain_active && drain_is_wb && drain_idx == 1'b1))
                        wb_valid[1] <= 1'b0;
                end else begin
                    beat0 <= beat0 + 3'd1;
                end
            end

            if (state1 == ST_MISS_REFILL && mem1_dev_rvalid) begin
                case ({way1, response_word1[1:0]})
                    3'd0: data0_b0[{set1, response_word1[2]}] <= refill_word1_with_store;
                    3'd1: data0_b1[{set1, response_word1[2]}] <= refill_word1_with_store;
                    3'd2: data0_b2[{set1, response_word1[2]}] <= refill_word1_with_store;
                    3'd3: data0_b3[{set1, response_word1[2]}] <= refill_word1_with_store;
                    3'd4: data1_b0[{set1, response_word1[2]}] <= refill_word1_with_store;
                    3'd5: data1_b1[{set1, response_word1[2]}] <= refill_word1_with_store;
                    3'd6: data1_b2[{set1, response_word1[2]}] <= refill_word1_with_store;
                    default: data1_b3[{set1, response_word1[2]}] <= refill_word1_with_store;
                endcase
                if (beat1 == 3'd7) begin
                    for (word_i = 0; word_i < LINE_WORDS; word_i = word_i + 1) begin
                        case ({way1, word_i[1:0]})
                            3'd0: data0_b0[{set1, word_i[2]}] <= refill_commit_word(
                                way1, set1, word_i[2:0], response_word1,
                                refill_word1_with_store, line1,
                                current_store_line1, up_store_addr[31:5],
                                up_store_addr[4:2], up_store_wen, up_store_wdata);
                            3'd1: data0_b1[{set1, word_i[2]}] <= refill_commit_word(
                                way1, set1, word_i[2:0], response_word1,
                                refill_word1_with_store, line1,
                                current_store_line1, up_store_addr[31:5],
                                up_store_addr[4:2], up_store_wen, up_store_wdata);
                            3'd2: data0_b2[{set1, word_i[2]}] <= refill_commit_word(
                                way1, set1, word_i[2:0], response_word1,
                                refill_word1_with_store, line1,
                                current_store_line1, up_store_addr[31:5],
                                up_store_addr[4:2], up_store_wen, up_store_wdata);
                            3'd3: data0_b3[{set1, word_i[2]}] <= refill_commit_word(
                                way1, set1, word_i[2:0], response_word1,
                                refill_word1_with_store, line1,
                                current_store_line1, up_store_addr[31:5],
                                up_store_addr[4:2], up_store_wen, up_store_wdata);
                            3'd4: data1_b0[{set1, word_i[2]}] <= refill_commit_word(
                                way1, set1, word_i[2:0], response_word1,
                                refill_word1_with_store, line1,
                                current_store_line1, up_store_addr[31:5],
                                up_store_addr[4:2], up_store_wen, up_store_wdata);
                            3'd5: data1_b1[{set1, word_i[2]}] <= refill_commit_word(
                                way1, set1, word_i[2:0], response_word1,
                                refill_word1_with_store, line1,
                                current_store_line1, up_store_addr[31:5],
                                up_store_addr[4:2], up_store_wen, up_store_wdata);
                            3'd6: data1_b2[{set1, word_i[2]}] <= refill_commit_word(
                                way1, set1, word_i[2:0], response_word1,
                                refill_word1_with_store, line1,
                                current_store_line1, up_store_addr[31:5],
                                up_store_addr[4:2], up_store_wen, up_store_wdata);
                            default: data1_b3[{set1, word_i[2]}] <= refill_commit_word(
                                way1, set1, word_i[2:0], response_word1,
                                refill_word1_with_store, line1,
                                current_store_line1, up_store_addr[31:5],
                                up_store_addr[4:2], up_store_wen, up_store_wdata);
                        endcase
                    end
                    if (way1) begin
                        tag1[set1] <= tag_req1;
                        valid1[set1] <= 1'b1;
                        dirty1[set1] <= pending_line1 || current_store_line1;
                    end else begin
                        tag0[set1] <= tag_req1;
                        valid0[set1] <= 1'b1;
                        dirty0[set1] <= pending_line1 || current_store_line1;
                    end
                    replace_way[set1] <= ~way1;
                    state1 <= ST_IDLE;
                    if (sbuf_valid[0] && sbuf_line[0] == line1 &&
                        !(drain_active && !drain_is_wb && drain_idx == 1'b0))
                        sbuf_valid[0] <= 1'b0;
                    if (sbuf_valid[1] && sbuf_line[1] == line1 &&
                        !(drain_active && !drain_is_wb && drain_idx == 1'b1))
                        sbuf_valid[1] <= 1'b0;
                    if (wb_valid[0] && wb_line[0] == line1 &&
                        !(drain_active && drain_is_wb && drain_idx == 1'b0))
                        wb_valid[0] <= 1'b0;
                    if (wb_valid[1] && wb_line[1] == line1 &&
                        !(drain_active && drain_is_wb && drain_idx == 1'b1))
                        wb_valid[1] <= 1'b0;
                end else begin
                    beat1 <= beat1 + 3'd1;
                end
            end

            // Normal RAM Store: hit data is merged into L2 and becomes dirty;
            // misses are accumulated in SBUF or an already pending WBB line.
            if (normal_store_accept &&
                !store_on_final_refill0 && !store_on_final_refill1) begin
                if (store_hit0 || store_hit1) begin
                    if (store_hit0) begin
                        case (up_store_addr[4:2])
                            3'd0: data0_b0[{store_set,1'b0}] <= merge_masked_word(data0_b0[{store_set,1'b0}], up_store_wen, up_store_wdata);
                            3'd1: data0_b1[{store_set,1'b0}] <= merge_masked_word(data0_b1[{store_set,1'b0}], up_store_wen, up_store_wdata);
                            3'd2: data0_b2[{store_set,1'b0}] <= merge_masked_word(data0_b2[{store_set,1'b0}], up_store_wen, up_store_wdata);
                            3'd3: data0_b3[{store_set,1'b0}] <= merge_masked_word(data0_b3[{store_set,1'b0}], up_store_wen, up_store_wdata);
                            3'd4: data0_b0[{store_set,1'b1}] <= merge_masked_word(data0_b0[{store_set,1'b1}], up_store_wen, up_store_wdata);
                            3'd5: data0_b1[{store_set,1'b1}] <= merge_masked_word(data0_b1[{store_set,1'b1}], up_store_wen, up_store_wdata);
                            3'd6: data0_b2[{store_set,1'b1}] <= merge_masked_word(data0_b2[{store_set,1'b1}], up_store_wen, up_store_wdata);
                            default: data0_b3[{store_set,1'b1}] <= merge_masked_word(data0_b3[{store_set,1'b1}], up_store_wen, up_store_wdata);
                        endcase
                        dirty0[store_set] <= 1'b1;
                    end else begin
                        case (up_store_addr[4:2])
                            3'd0: data1_b0[{store_set,1'b0}] <= merge_masked_word(data1_b0[{store_set,1'b0}], up_store_wen, up_store_wdata);
                            3'd1: data1_b1[{store_set,1'b0}] <= merge_masked_word(data1_b1[{store_set,1'b0}], up_store_wen, up_store_wdata);
                            3'd2: data1_b2[{store_set,1'b0}] <= merge_masked_word(data1_b2[{store_set,1'b0}], up_store_wen, up_store_wdata);
                            3'd3: data1_b3[{store_set,1'b0}] <= merge_masked_word(data1_b3[{store_set,1'b0}], up_store_wen, up_store_wdata);
                            3'd4: data1_b0[{store_set,1'b1}] <= merge_masked_word(data1_b0[{store_set,1'b1}], up_store_wen, up_store_wdata);
                            3'd5: data1_b1[{store_set,1'b1}] <= merge_masked_word(data1_b1[{store_set,1'b1}], up_store_wen, up_store_wdata);
                            3'd6: data1_b2[{store_set,1'b1}] <= merge_masked_word(data1_b2[{store_set,1'b1}], up_store_wen, up_store_wdata);
                            default: data1_b3[{store_set,1'b1}] <= merge_masked_word(data1_b3[{store_set,1'b1}], up_store_wen, up_store_wdata);
                        endcase
                        dirty1[store_set] <= 1'b1;
                    end
                end else if (wb_store_match_ready) begin
                    if (wb_store_match0 && !wb_store_block0) begin
                        wb_data[0] <= merge_line_store(wb_data[0], up_store_addr[4:0], up_store_wen, up_store_wdata);
                        wb_byte_valid[0] <= merge_line_mask(wb_byte_valid[0], up_store_addr[4:0], up_store_wen);
                    end else begin
                        wb_data[1] <= merge_line_store(wb_data[1], up_store_addr[4:0], up_store_wen, up_store_wdata);
                        wb_byte_valid[1] <= merge_line_mask(wb_byte_valid[1], up_store_addr[4:0], up_store_wen);
                    end
                end else if (sbuf_store_match_ready) begin
                    if (sbuf_store_match0 && !sbuf_store_block0) begin
                        sbuf_data[0] <= merge_line_store(sbuf_data[0], up_store_addr[4:0], up_store_wen, up_store_wdata);
                        sbuf_byte_valid[0] <= merge_line_mask(sbuf_byte_valid[0], up_store_addr[4:0], up_store_wen);
                    end else begin
                        sbuf_data[1] <= merge_line_store(sbuf_data[1], up_store_addr[4:0], up_store_wen, up_store_wdata);
                        sbuf_byte_valid[1] <= merge_line_mask(sbuf_byte_valid[1], up_store_addr[4:0], up_store_wen);
                    end
                end else begin
                    sbuf_valid[sbuf_free_idx] <= 1'b1;
                    sbuf_line[sbuf_free_idx] <= up_store_addr[31:5];
                    sbuf_data[sbuf_free_idx] <= merge_line_store(256'd0, up_store_addr[4:0], up_store_wen, up_store_wdata);
                    sbuf_byte_valid[sbuf_free_idx] <= merge_line_mask(32'd0, up_store_addr[4:0], up_store_wen);
                end
            end

            // Finish a WBB/SBUF drain only after the lower bridge reports the
            // accepted word complete.
            if (drain_complete) begin
                if (drain_is_wb) begin
                    wb_valid[drain_idx] <= 1'b0;
                    wb_byte_valid[drain_idx] <= 32'd0;
                end else begin
                    sbuf_valid[drain_idx] <= 1'b0;
                    sbuf_byte_valid[drain_idx] <= 32'd0;
                end
            end

            // Maintenance scans both ways.  Dirty lines are moved to WBB and
            // only become invalid after their WBB entry has been allocated.
            if (flush_scan_advance) begin
                if (flush_current_dirty) begin
                    wb_valid[wb_free_idx] <= 1'b1;
                    wb_line[wb_free_idx] <= flush_scan_way ?
                        {tag1[flush_scan_set], flush_scan_set} :
                        {tag0[flush_scan_set], flush_scan_set};
                    wb_data[wb_free_idx] <= read_line(flush_scan_way, flush_scan_set);
                    wb_byte_valid[wb_free_idx] <= 32'hffff_ffff;
                end
                if (flush_scan_way) begin
                    if (flush_current_valid) begin
                        valid1[flush_scan_set] <= 1'b0;
                        dirty1[flush_scan_set] <= 1'b0;
                    end
                    if (flush_scan_set == SET_COUNT-1) begin
                        flush_scan_done <= 1'b1;
                    end else begin
                        flush_scan_set <= flush_scan_set + 1'b1;
                        flush_scan_way <= 1'b0;
                    end
                end else begin
                    if (flush_current_valid) begin
                        valid0[flush_scan_set] <= 1'b0;
                        dirty0[flush_scan_set] <= 1'b0;
                    end
                    flush_scan_way <= 1'b1;
                end
            end

            if (flush_active && flush_scan_done &&
                (state0 == ST_IDLE) && (state1 == ST_IDLE) &&
                !wb_valid[0] && !wb_valid[1] &&
                !sbuf_valid[0] && !sbuf_valid[1] &&
                !drain_active && !bypass_pending) begin
                flush_active <= 1'b0;
                maint_complete <= 1'b1;
            end
        end
    end


endmodule

// -----------------------------------------------------------------------------
// Explicit one-clock true-dual-port RAM used by the BRAM-native L2 below.
//
// The old bank processes placed two independent reads and two independent
// writes in one process.  Vivado is then free to model each bank as a
// four-port distributed/replicated RAM.  This wrapper makes the ownership
// visible: lane 0 always uses port A and lane 1 always uses port B.  A port may
// read and write in the same cycle; the nonblocking assignments intentionally
// preserve the old read-first behavior of the original bank process.
// -----------------------------------------------------------------------------
module L2DCacheDualPortRam32 #(
    parameter integer DEPTH      = 2048,
    parameter integer ADDR_WIDTH = $clog2(DEPTH)
)(
    input  wire                   clk,
    input  wire                   rstn,
    input  wire                   read_a,
    input  wire [ADDR_WIDTH-1:0]  addr_a,
    output wire [31:0]            rdata_a,
    input  wire                   write_a,
    input  wire [31:0]            wdata_a,
    input  wire                   read_b,
    input  wire [ADDR_WIDTH-1:0]  addr_b,
    output wire [31:0]            rdata_b,
    input  wire                   write_b,
    input  wire [31:0]            wdata_b
);
    (* ram_style = "block" *) reg [31:0] mem [0:DEPTH-1];
    reg [31:0] rdata_a_q, rdata_b_q;
    assign rdata_a = rdata_a_q;
    assign rdata_b = rdata_b_q;

    // Keep the two write ports in separate processes.  This is the Vivado
    // inference template for a true-dual-port RAM; putting both writes in one
    // process makes the tool treat the array as a four-port register file.
    always @(posedge clk) begin
        if (!rstn) begin
            rdata_a_q <= 32'h0;
        end else begin
            // Nonblocking ordering gives read-first behavior when read_a and
            // write_a target the same address in one cycle.
            if (read_a)
                rdata_a_q <= mem[addr_a];
            if (write_a)
                mem[addr_a] <= wdata_a;
        end
    end

    always @(posedge clk) begin
        if (!rstn) begin
            rdata_b_q <= 32'h0;
        end else begin
            if (read_b)
                rdata_b_q <= mem[addr_b];
            if (write_b)
                mem[addr_b] <= wdata_b;
        end
    end
endmodule

// Metadata RAM for the BRAM-native L2.  The metadata row has two independent
// lookup consumers (the two upper lanes), so keep the read ports explicit just
// like the eight data banks.  Each physical port has one shared address, which
// is the Vivado true-dual-port inference template; the L2 arbitrates whether
// that address is used for a read or a write in a given cycle.
// Only the output registers are reset; clearing every RAM word in reset would
// prevent block-RAM inference.  The L2 init/flush sweep supplies architectural
// invalidation after reset.
module L2DCacheMetaDualPortRam #(
    parameter integer DEPTH      = 512,
    parameter integer ADDR_WIDTH = $clog2(DEPTH),
    parameter integer DATA_WIDTH = 41
)(
    input  wire                    clk,
    input  wire                    rstn,
    input  wire                    read_a,
    input  wire [ADDR_WIDTH-1:0]   addr_a,
    output wire [DATA_WIDTH-1:0]   rdata_a,
    input  wire                    write_a,
    input  wire [DATA_WIDTH-1:0]   wdata_a,
    input  wire                    read_b,
    input  wire [ADDR_WIDTH-1:0]   addr_b,
    output wire [DATA_WIDTH-1:0]   rdata_b,
    input  wire                    write_b,
    input  wire [DATA_WIDTH-1:0]   wdata_b
);
    (* ram_style = "block" *) reg [DATA_WIDTH-1:0] mem [0:DEPTH-1];
    reg [DATA_WIDTH-1:0] rdata_a_q, rdata_b_q;

    assign rdata_a = rdata_a_q;
    assign rdata_b = rdata_b_q;

    always @(posedge clk) begin
        if (!rstn) begin
            rdata_a_q <= {DATA_WIDTH{1'b0}};
        end else begin
            if (read_a)
                rdata_a_q <= mem[addr_a];
            if (write_a)
                mem[addr_a] <= wdata_a;
        end
    end

    always @(posedge clk) begin
        if (!rstn) begin
            rdata_b_q <= {DATA_WIDTH{1'b0}};
        end else begin
            if (read_b)
                rdata_b_q <= mem[addr_b];
            if (write_b)
                mem[addr_b] <= wdata_b;
        end
    end
endmodule

// -----------------------------------------------------------------------------
// BRAM-native parameterized L2 validation implementation (32 KiB default).
//
// This module deliberately keeps the old L2DCache above intact.  The simulation
// top can select this implementation without changing the SRAM-side protocol.
// The data arrays are synchronous true-dual-port memories: port A is normally
// owned by lane 0 and port B by lane 1.  A lookup therefore has one registered
// BRAM latency, while a hit stream still returns one word per cycle afterwards.
//
// Default capacity: 32 KiB = 512 sets * 2 ways * 32 bytes/line.  SET_COUNT
// remains a parameter for small OOC synthesis experiments, but the simulation
// top selects 512 and no longer relies on the abandoned 64 KiB configuration.
// Address mapping is physical and fixed at line=[31:5], word=[4:2]:
//   bank      = word[1:0]
//   bank row  = {set,word[2]}
// The first validation revision keeps cacheable Stores in the existing two-entry
// SBUF and drains them to lower memory.  This avoids a third write port to the
// BRAM while preserving same-line forwarding and exact lower write completion.
// -----------------------------------------------------------------------------
module L2DCacheBram64 #(
    parameter integer SET_COUNT  = 512,
    parameter integer LINE_WORDS = 8
)(
    input  wire        cpu_rstn,
    input  wire        cpu_clk,

    input  wire [3:0]  up0_cpu_ren,
    input  wire [31:0] up0_cpu_raddr,
    input  wire        up0_cpu_rburst,
    output wire        up0_dev_rrdy,
    output wire        up0_dev_rvalid,
    output wire [31:0] up0_dev_rdata,

    input  wire [3:0]  up1_cpu_ren,
    input  wire [31:0] up1_cpu_raddr,
    input  wire        up1_cpu_rburst,
    output wire        up1_dev_rrdy,
    output wire        up1_dev_rvalid,
    output wire [31:0] up1_dev_rdata,

    input  wire [3:0]  up_store_wen,
    input  wire [31:0] up_store_addr,
    input  wire [31:0] up_store_wdata,
    input  wire        up_store_cacheable,
    output wire        up_store_wrdy,
    output wire        up_store_wdone,
    output wire        up_store_widle,

    output wire [3:0]  mem0_cpu_ren,
    output wire [31:0] mem0_cpu_raddr,
    output wire        mem0_cpu_rburst,
    input  wire        mem0_dev_rrdy,
    input  wire        mem0_dev_rvalid,
    input  wire [31:0] mem0_dev_rdata,

    output wire [3:0]  mem1_cpu_ren,
    output wire [31:0] mem1_cpu_raddr,
    output wire        mem1_cpu_rburst,
    input  wire        mem1_dev_rrdy,
    input  wire        mem1_dev_rvalid,
    input  wire [31:0] mem1_dev_rdata,

    output wire [3:0]  mem_store_wen,
    output wire [31:0] mem_store_addr,
    output wire [31:0] mem_store_wdata,
    input  wire        mem_store_wrdy,
    input  wire        mem_store_wdone,
    input  wire        mem_store_widle,

    input  wire        invalidate_all,
    output wire        maint_done
);

    localparam integer SET_W      = $clog2(SET_COUNT);
    localparam integer TAG_W      = 32 - 5 - SET_W;
    localparam integer BANK_DEPTH = SET_COUNT * 2;
    localparam integer META_W     = (2 * TAG_W) + 5;

    localparam [3:0] ST_IDLE         = 4'd0;
    localparam [3:0] ST_LOOKUP       = 4'd1;
    localparam [3:0] ST_HIT_STREAM   = 4'd2;
    localparam [3:0] ST_MISS_REQ     = 4'd3;
    localparam [3:0] ST_MISS_REFILL  = 4'd4;
    localparam [3:0] ST_EVICT_CAPTURE= 4'd5;
    localparam [3:0] ST_EVICT_WAIT   = 4'd6;
    localparam [3:0] ST_UNC_REQ      = 4'd7;
    localparam [3:0] ST_UNC_RESP     = 4'd8;
    localparam [3:0] ST_UNC_HIT      = 4'd9;
    localparam [3:0] ST_META_WAIT    = 4'd10;

    // Eight physical banks: two ways x four word banks.  Each instance below
    // is a true dual-port RAM.  Port A is lane 0 and port B is lane 1; the
    // refill writer is consequently a second operation on the lane's own
    // port, rather than an extra independent write port on the bank.

    // One synchronous two-port metadata row contains both ways.  Keep a
    // lane-local snapshot separate from the RAM outputs: maintenance reads
    // must never overwrite a refill's lookup metadata.
    reg  [META_W-1:0] meta_q0, meta_q1;
    wire [META_W-1:0] meta_ram_rdata_a, meta_ram_rdata_b;

    reg [3:0] state0, state1;
    reg [31:0] addr0, addr1;
    reg [3:0]  ren0, ren1;
    reg        burst0, burst1;
    reg [SET_W-1:0] set0, set1;
    reg [TAG_W-1:0] tag_req0, tag_req1;
    reg [2:0] critical0, critical1;
    reg [2:0] refill_beat0, refill_beat1;
    reg [2:0] evict_beat0, evict_beat1;
    reg       evict_read_pending0, evict_read_pending1;
    reg       wb_target0, wb_target1;
    reg       way0, way1;
    reg [26:0] victim_line0, victim_line1;
    reg [31:0] response_data0, response_data1;
    reg        response_valid0, response_valid1;

    reg        init_active;
    reg [SET_W-1:0] init_set;
    reg        invalidate_all_d;
    reg        flush_active;
    reg        flush_done;
    reg [SET_W-1:0] flush_set;
    reg        maint_complete;

    // A completed SBUF drain invalidates a matching L2 line.  The invalidation
    // is committed through the metadata RAM before another upper request is
    // admitted, so the newly written SRAM word can never be hidden by stale L2.
    reg        invalidate_pending;
    reg [26:0] invalidate_line;
    reg        invalidate_sbuf_idx;
    reg        invalidate_meta_rd_pending;

    reg [26:0]  sbuf_line [0:1];
    reg [255:0] sbuf_data [0:1];
    reg [31:0]  sbuf_byte_valid [0:1];
    reg         sbuf_valid [0:1];
    reg [26:0]  wb_line [0:1];
    reg [255:0] wb_data [0:1];
    reg [31:0]  wb_byte_valid [0:1];
    reg         wb_valid [0:1];

    reg        drain_active;
    reg        drain_is_wb;
    reg        drain_idx;
    reg [7:0]  drain_sent_mask;
    reg [7:0]  drain_valid_mask;
    reg [3:0]  drain_pending_count;
    reg [2:0]  drain_word_idx;
    reg [3:0]  drain_word_wen;
    reg [31:0] drain_word_data;
    reg [26:0] drain_line_addr;
    reg        drain_word_found;
    integer drain_scan_i;

    reg        bypass_pending;

    // Synchronous read outputs.  Each bank has a read port for each upper lane;
    // writes are assigned to the same lane-owned port.
    wire [31:0] rd0_w0_b0, rd0_w0_b1, rd0_w0_b2, rd0_w0_b3;
    wire [31:0] rd0_w1_b0, rd0_w1_b1, rd0_w1_b2, rd0_w1_b3;
    wire [31:0] rd1_w0_b0, rd1_w0_b1, rd1_w0_b2, rd1_w0_b3;
    wire [31:0] rd1_w1_b0, rd1_w1_b1, rd1_w1_b2, rd1_w1_b3;

    function automatic [31:0] merge_bytes;
        input [31:0] base_data;
        input [3:0]  byte_enable;
        input [31:0] write_data;
        integer bi;
        reg [31:0] result;
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
        integer bi;
        reg [255:0] result;
        begin
            result = base_line;
            for (bi = 0; bi < 4; bi = bi + 1)
                if (byte_enable[bi])
                    result[byte_offset[4:2]*32 + bi*8 +: 8] = write_data[bi*8 +: 8];
            merge_line_store = result;
        end
    endfunction

    function automatic [31:0] merge_line_mask;
        input [31:0] base_mask;
        input [4:0]  byte_offset;
        input [3:0]  byte_enable;
        integer mi;
        reg [31:0] result;
        begin
            result = base_mask;
            for (mi = 0; mi < 4; mi = mi + 1)
                if (byte_enable[mi])
                    result[byte_offset[4:2]*4 + mi] = 1'b1;
            merge_line_mask = result;
        end
    endfunction

    function automatic [255:0] set_line_word;
        input [255:0] base_line;
        input [2:0]   word_index;
        input [31:0]  word_data;
        reg [255:0] result;
        begin
            result = base_line;
            result[word_index*32 +: 32] = word_data;
            set_line_word = result;
        end
    endfunction

    function automatic [META_W-1:0] meta_replace_way;
        input [META_W-1:0] old_meta;
        input               replace_way;
        input [TAG_W-1:0]   new_tag;
        input               new_valid;
        input               new_dirty;
        reg [META_W-1:0] result;
        begin
            result = old_meta;
            if (!replace_way) begin
                result[TAG_W-1:0] = new_tag;
                result[TAG_W] = new_valid;
                result[TAG_W+1] = new_dirty;
            end else begin
                result[TAG_W+2 +: TAG_W] = new_tag;
                result[2*TAG_W+2] = new_valid;
                result[2*TAG_W+3] = new_dirty;
            end
            meta_replace_way = result;
        end
    endfunction

    function automatic [META_W-1:0] meta_invalidate_line;
        input [META_W-1:0] old_meta;
        input [TAG_W-1:0]   line_tag;
        reg [META_W-1:0] result;
        begin
            result = old_meta;
            if (result[TAG_W] && (result[TAG_W-1:0] == line_tag)) begin
                result[TAG_W] = 1'b0;
                result[TAG_W+1] = 1'b0;
            end
            if (result[2*TAG_W+2] &&
                (result[TAG_W+2 +: TAG_W] == line_tag)) begin
                result[2*TAG_W+2] = 1'b0;
                result[2*TAG_W+3] = 1'b0;
            end
            meta_invalidate_line = result;
        end
    endfunction

    function automatic is_peripheral_addr;
        input [31:0] addr;
        begin
            is_peripheral_addr =
                ((addr >= 32'h1f00_0000) && (addr < 32'h1f60_0000)) ||
                (addr[31:16] == 16'hBFAF) ||
                (addr[31:16] == 16'hBFD0);
        end
    endfunction

    function automatic [31:0] pick_rd0_word;
        input       pick_way;
        input [1:0] pick_bank;
        begin
            case ({pick_way, pick_bank})
                3'd0: pick_rd0_word = rd0_w0_b0;
                3'd1: pick_rd0_word = rd0_w0_b1;
                3'd2: pick_rd0_word = rd0_w0_b2;
                3'd3: pick_rd0_word = rd0_w0_b3;
                3'd4: pick_rd0_word = rd0_w1_b0;
                3'd5: pick_rd0_word = rd0_w1_b1;
                3'd6: pick_rd0_word = rd0_w1_b2;
                default: pick_rd0_word = rd0_w1_b3;
            endcase
        end
    endfunction

    function automatic [31:0] pick_rd1_word;
        input       pick_way;
        input [1:0] pick_bank;
        begin
            case ({pick_way, pick_bank})
                3'd0: pick_rd1_word = rd1_w0_b0;
                3'd1: pick_rd1_word = rd1_w0_b1;
                3'd2: pick_rd1_word = rd1_w0_b2;
                3'd3: pick_rd1_word = rd1_w0_b3;
                3'd4: pick_rd1_word = rd1_w1_b0;
                3'd5: pick_rd1_word = rd1_w1_b1;
                3'd6: pick_rd1_word = rd1_w1_b2;
                default: pick_rd1_word = rd1_w1_b3;
            endcase
        end
    endfunction

    function automatic [31:0] overlay_pending_word;
        input [31:0] base_data;
        input [26:0] line_addr;
        input [2:0]  word_index;
        integer oi;
        reg [31:0] result;
        begin
            result = base_data;
            for (oi = 0; oi < 2; oi = oi + 1) begin
                if (sbuf_valid[oi] && (sbuf_line[oi] == line_addr) &&
                    (sbuf_byte_valid[oi][word_index*4 +: 4] != 4'h0))
                    result = merge_bytes(result,
                        sbuf_byte_valid[oi][word_index*4 +: 4],
                        sbuf_data[oi][word_index*32 +: 32]);
                if (wb_valid[oi] && (wb_line[oi] == line_addr) &&
                    (wb_byte_valid[oi][word_index*4 +: 4] != 4'h0))
                    result = merge_bytes(result,
                        wb_byte_valid[oi][word_index*4 +: 4],
                        wb_data[oi][word_index*32 +: 32]);
            end
            overlay_pending_word = result;
        end
    endfunction

    wire [SET_W-1:0] input_set0 = up0_cpu_raddr[5+SET_W-1:5];
    wire [SET_W-1:0] input_set1 = up1_cpu_raddr[5+SET_W-1:5];
    wire [TAG_W-1:0] input_tag0 = up0_cpu_raddr[31:5+SET_W];
    wire [TAG_W-1:0] input_tag1 = up1_cpu_raddr[31:5+SET_W];
    wire [2:0] input_word0 = up0_cpu_raddr[4:2];
    wire [2:0] input_word1 = up1_cpu_raddr[4:2];

    wire [TAG_W-1:0] meta0_tag0 = meta_q0[TAG_W-1:0];
    wire             meta0_valid0 = meta_q0[TAG_W];
    wire             meta0_dirty0 = meta_q0[TAG_W+1];
    wire [TAG_W-1:0] meta0_tag1 = meta_q0[TAG_W+2 +: TAG_W];
    wire             meta0_valid1 = meta_q0[2*TAG_W+2];
    wire             meta0_dirty1 = meta_q0[2*TAG_W+3];
    wire             meta0_replace = meta_q0[2*TAG_W+4];

    wire [TAG_W-1:0] meta1_tag0 = meta_q1[TAG_W-1:0];
    wire             meta1_valid0 = meta_q1[TAG_W];
    wire             meta1_dirty0 = meta_q1[TAG_W+1];
    wire [TAG_W-1:0] meta1_tag1 = meta_q1[TAG_W+2 +: TAG_W];
    wire             meta1_valid1 = meta_q1[2*TAG_W+2];
    wire             meta1_dirty1 = meta_q1[2*TAG_W+3];
    wire             meta1_replace = meta_q1[2*TAG_W+4];

    wire hit0_way0 = meta0_valid0 && (meta0_tag0 == tag_req0);
    wire hit0_way1 = meta0_valid1 && (meta0_tag1 == tag_req0);
    wire hit1_way0 = meta1_valid0 && (meta1_tag0 == tag_req1);
    wire hit1_way1 = meta1_valid1 && (meta1_tag1 == tag_req1);
    wire lookup_hit0 = hit0_way0 || hit0_way1;
    wire lookup_hit1 = hit1_way0 || hit1_way1;
    wire lookup_way0 = hit0_way1 && !hit0_way0;
    wire lookup_way1 = hit1_way1 && !hit1_way0;
    wire victim_way0 = !meta0_valid0 ? 1'b0 :
                       !meta0_valid1 ? 1'b1 : meta0_replace;
    wire victim_way1 = !meta1_valid0 ? 1'b0 :
                       !meta1_valid1 ? 1'b1 : meta1_replace;
    wire victim_dirty0 = victim_way0 ? (meta0_valid1 && meta0_dirty1) :
                                       (meta0_valid0 && meta0_dirty0);
    wire victim_dirty1 = victim_way1 ? (meta1_valid1 && meta1_dirty1) :
                                       (meta1_valid0 && meta1_dirty0);
    wire [26:0] line0 = {tag_req0, set0};
    wire [26:0] line1 = {tag_req1, set1};

    wire lane0_active = (state0 != ST_IDLE);
    wire lane1_active = (state1 != ST_IDLE);
    wire common_read_block = init_active || flush_active || invalidate_pending ||
                              invalidate_all || bypass_pending;
    wire lane0_same_set_busy = lane1_active && (set1 == input_set0);
    wire lane1_same_set_busy = lane0_active && (set0 == input_set1);
    wire lane0_dirty_miss_pending = (state0 == ST_LOOKUP) &&
                                     !lookup_hit0 && burst0 && victim_dirty0;
    wire lane0_ready_base = !common_read_block && !lane0_active &&
                            !lane0_same_set_busy;
    wire lane1_ready_base = !common_read_block && !lane1_active &&
                            !lane1_same_set_busy && !lane0_dirty_miss_pending;
    wire lane0_accept = lane0_ready_base && (up0_cpu_ren != 4'h0);
    wire lane1_accept = lane1_ready_base &&
                        !(lane0_accept && (input_set1 == input_set0)) &&
                        (up1_cpu_ren != 4'h0);

    // Metadata maintenance is deliberately serialized with active lanes.  A
    // completed SBUF line first takes a synchronous metadata read, then the
    // following cycle performs the invalidate write.  This keeps the two
    // normal lookup/refill ports available and avoids a hidden third write
    // port in the RAM template.
    wire meta_invalidate_read_fire = invalidate_pending &&
                                     !invalidate_meta_rd_pending &&
                                     !init_active && !flush_active &&
                                     !drain_active && !bypass_pending &&
                                     (state0 == ST_IDLE) &&
                                     (state1 == ST_IDLE);
    wire meta_refill_write0_fire = (state0 == ST_MISS_REFILL) &&
                                   mem0_dev_rvalid &&
                                   (refill_beat0 == 3'd7);
    wire meta_refill_write1_fire = (state1 == ST_MISS_REFILL) &&
                                   mem1_dev_rvalid &&
                                   (refill_beat1 == 3'd7);
    wire meta_invalidate_write_fire = invalidate_meta_rd_pending &&
                                      !meta_refill_write0_fire &&
                                      !meta_refill_write1_fire;
    wire meta_flush_write_fire = flush_active && !flush_done &&
                                 (state0 == ST_IDLE) &&
                                 (state1 == ST_IDLE) &&
                                 !drain_active && !bypass_pending &&
                                 !invalidate_pending;
    wire meta_maint_write_fire = init_active ||
                                 meta_flush_write_fire ||
                                 meta_invalidate_write_fire;
    wire meta_write_a = meta_refill_write0_fire || meta_maint_write_fire;
    wire meta_write_b = meta_refill_write1_fire;
    // The address is shared by read/write on each physical RAM port, matching
    // the proven Vivado TDP template used by the data banks.  These operations
    // are mutually exclusive on a given port; maintenance has no new lookup
    // acceptance while it owns port A.
    wire [SET_W-1:0] meta_addr_a =
        (meta_invalidate_read_fire || meta_invalidate_write_fire) ?
            invalidate_line[SET_W-1:0] :
        meta_refill_write0_fire ? set0 :
        init_active ? init_set :
        meta_flush_write_fire ? flush_set : input_set0;
    wire [SET_W-1:0] meta_addr_b = meta_refill_write1_fire ? set1 : input_set1;
    wire [META_W-1:0] meta_wdata_a = meta_refill_write0_fire ?
        meta_replace_way(meta_q0, way0, tag_req0, 1'b1, 1'b0) :
        init_active || meta_flush_write_fire ? {META_W{1'b0}} :
        meta_invalidate_line(meta_ram_rdata_a,
                             invalidate_line[26:SET_W]);
    wire [META_W-1:0] meta_wdata_b =
        meta_replace_way(meta_q1, way1, tag_req1, 1'b1, 1'b0);

    L2DCacheMetaDualPortRam #(
        .DEPTH      (SET_COUNT),
        .ADDR_WIDTH (SET_W),
        .DATA_WIDTH (META_W)
    ) u_meta_ram (
        .clk        (cpu_clk),
        .rstn       (cpu_rstn),
        .read_a     (lane0_accept || meta_invalidate_read_fire),
        .addr_a     (meta_addr_a),
        .rdata_a    (meta_ram_rdata_a),
        .write_a    (meta_write_a),
        .wdata_a    (meta_wdata_a),
        .read_b     (lane1_accept),
        .addr_b     (meta_addr_b),
        .rdata_b    (meta_ram_rdata_b),
        .write_b    (meta_write_b),
        .wdata_b    (meta_wdata_b)
    );

    assign up0_dev_rrdy = lane0_ready_base;
    assign up1_dev_rrdy = lane1_ready_base &&
                          !(lane0_accept && (input_set1 == input_set0));

    wire sbuf_match0 = sbuf_valid[0] && (sbuf_line[0] == up_store_addr[31:5]);
    wire sbuf_match1 = sbuf_valid[1] && (sbuf_line[1] == up_store_addr[31:5]);
    wire wb_match0 = wb_valid[0] && (wb_line[0] == up_store_addr[31:5]);
    wire wb_match1 = wb_valid[1] && (wb_line[1] == up_store_addr[31:5]);
    wire drain_blocks_sbuf0 = drain_active && !drain_is_wb && (drain_idx == 1'b0);
    wire drain_blocks_sbuf1 = drain_active && !drain_is_wb && (drain_idx == 1'b1);
    wire drain_blocks_wb0 = drain_active && drain_is_wb && (drain_idx == 1'b0);
    wire drain_blocks_wb1 = drain_active && drain_is_wb && (drain_idx == 1'b1);
    wire sbuf_word_present0 =
        sbuf_byte_valid[0][up_store_addr[4:2]*4 +: 4] != 4'h0;
    wire sbuf_word_present1 =
        sbuf_byte_valid[1][up_store_addr[4:2]*4 +: 4] != 4'h0;
    wire sbuf_line_match = sbuf_match0 || sbuf_match1;
    // One accepted upper token owns one word slot.  Different words of the
    // same 32-byte line may merge before drain, but a second token for an
    // already-owned word waits until the older physical write completes.
    wire sbuf_match_ready =
        (sbuf_match0 && !drain_blocks_sbuf0 && !sbuf_word_present0) ||
        (sbuf_match1 && !drain_blocks_sbuf1 && !sbuf_word_present1);
    wire sbuf_free_found = !sbuf_valid[0] || !sbuf_valid[1];
    wire sbuf_free_idx = !sbuf_valid[0] ? 1'b0 : 1'b1;

    wire normal_store_ready = !init_active && !flush_active && !invalidate_all &&
                               !invalidate_pending && !bypass_pending &&
                               // WBB contains an older victim image.  Wait for
                               // it instead of merging a new upper token into
                               // an owner whose completions are not upper
                               // Store completions.
                               !(wb_match0 || wb_match1) &&
                               (sbuf_line_match ? sbuf_match_ready :
                                                  sbuf_free_found);
    wire bypass_store_ready = !init_active && !flush_active && !invalidate_all &&
                               !invalidate_pending && !bypass_pending &&
                               !drain_active && !sbuf_valid[0] && !sbuf_valid[1] &&
                               !wb_valid[0] && !wb_valid[1] &&
                               (state0 == ST_IDLE) && (state1 == ST_IDLE) &&
                               mem_store_wrdy;
    assign up_store_wrdy = up_store_cacheable ? normal_store_ready :
                           bypass_store_ready;
    wire normal_store_accept = up_store_cacheable &&
                                (up_store_wen != 4'h0) && up_store_wrdy;
    wire bypass_store_accept = !up_store_cacheable &&
                               (up_store_wen != 4'h0) && up_store_wrdy;

    // Lower write drain.  The SRAM bridge has a bounded request FIFO, so a
    // whole line may be issued without waiting for the CDC round trip after
    // every word.  The SBUF/WBB owner remains live until the number of real
    // mem_store_wdone pulses exactly matches the number of accepted words.
    always @(*) begin
        drain_word_idx   = 3'd0;
        drain_word_wen   = 4'h0;
        drain_word_data  = 32'h0;
        drain_line_addr  = 27'd0;
        drain_word_found = 1'b0;
        if (drain_active) begin
            if (drain_is_wb) begin
                drain_line_addr = wb_line[drain_idx];
                for (drain_scan_i = 0; drain_scan_i < LINE_WORDS; drain_scan_i = drain_scan_i + 1)
                    if (!drain_word_found &&
                        !drain_sent_mask[drain_scan_i] &&
                        drain_valid_mask[drain_scan_i]) begin
                        drain_word_idx = drain_scan_i[2:0];
                        drain_word_wen = wb_byte_valid[drain_idx][drain_scan_i*4 +: 4];
                        drain_word_data = wb_data[drain_idx][drain_scan_i*32 +: 32];
                        drain_word_found = 1'b1;
                    end
            end else begin
                drain_line_addr = sbuf_line[drain_idx];
                for (drain_scan_i = 0; drain_scan_i < LINE_WORDS; drain_scan_i = drain_scan_i + 1)
                    if (!drain_word_found &&
                        !drain_sent_mask[drain_scan_i] &&
                        drain_valid_mask[drain_scan_i]) begin
                        drain_word_idx = drain_scan_i[2:0];
                        drain_word_wen = sbuf_byte_valid[drain_idx][drain_scan_i*4 +: 4];
                        drain_word_data = sbuf_data[drain_idx][drain_scan_i*32 +: 32];
                        drain_word_found = 1'b1;
                    end
            end
        end
    end

    wire drain_req = drain_active && drain_word_found;
    wire drain_fire = drain_req && mem_store_wrdy;
    wire drain_done_fire = drain_active && mem_store_wdone &&
                           (drain_pending_count != 4'd0);
    // The owner mask is captured at drain_start.  During the physical drain
    // the source slot is pinned, so this is equivalent to rereading its
    // byte_valid bits but removes that 8-word scan from the completion/count
    // timing path.
    wire [7:0] drain_valid_words = drain_valid_mask;
    wire [7:0] drain_sent_after = drain_sent_mask |
        (drain_fire ? (8'b1 << drain_word_idx) : 8'h00);
    wire [3:0] drain_pending_after = drain_pending_count +
        (drain_fire ? 4'd1 : 4'd0) -
        (drain_done_fire ? 4'd1 : 4'd0);
    wire drain_all_sent_after =
        (drain_sent_after & drain_valid_words) == drain_valid_words;
    wire drain_complete = drain_active && drain_all_sent_after &&
                          (drain_pending_after == 4'd0);
    wire drain_start_is_wb = wb_valid[0] || wb_valid[1];
    wire drain_start_idx = drain_start_is_wb ?
                           (wb_valid[0] ? 1'b0 : 1'b1) :
                           (sbuf_valid[0] ? 1'b0 : 1'b1);
    wire [31:0] drain_start_byte_mask = drain_start_is_wb ?
                                        wb_byte_valid[drain_start_idx] :
                                        sbuf_byte_valid[drain_start_idx];
    wire [7:0] drain_start_valid_mask = {
        drain_start_byte_mask[28 +: 4] != 0,
        drain_start_byte_mask[24 +: 4] != 0,
        drain_start_byte_mask[20 +: 4] != 0,
        drain_start_byte_mask[16 +: 4] != 0,
        drain_start_byte_mask[12 +: 4] != 0,
        drain_start_byte_mask[ 8 +: 4] != 0,
        drain_start_byte_mask[ 4 +: 4] != 0,
        drain_start_byte_mask[ 0 +: 4] != 0};
    wire drain_start = !drain_active && mem_store_widle &&
                       !bypass_pending &&
                       // Keep the merge window open while the WCB is
                       // delivering another distinct word this cycle.
                       !normal_store_accept &&
                       // During an ordered SBUF invalidation, an older dirty
                       // victim may still need to drain so a same-set lane can
                       // leave ST_EVICT_WAIT.  Allow only WBB owners in that
                       // window; the completed SBUF image must remain pinned.
                       (wb_valid[0] || wb_valid[1] ||
                        (!invalidate_pending &&
                         (sbuf_valid[0] || sbuf_valid[1])));
    wire drain_start_sbuf = drain_start && !drain_start_is_wb;
    wire bypass_drive = !up_store_cacheable && !bypass_pending &&
                        (up_store_wen != 4'h0) && up_store_wrdy;

    assign mem_store_wen = bypass_drive ? up_store_wen :
                           (drain_req ? drain_word_wen : 4'h0);
    assign mem_store_addr = bypass_drive ? up_store_addr :
                            ({drain_line_addr, 5'b0} + (drain_word_idx * 32'd4));
    assign mem_store_wdata = bypass_drive ? up_store_wdata : drain_word_data;
    // Every SBUF word owns exactly one upper completion token.  Emit it only
    // when that word reaches physical SRAM; WBB completions are internal.
    wire cacheable_store_done = drain_done_fire && !drain_is_wb;
    assign up_store_wdone = cacheable_store_done ||
                            (bypass_pending && mem_store_wdone);
    assign up_store_widle = !init_active && !flush_active &&
                            !invalidate_pending && !bypass_pending &&
                            !drain_active &&
                            !sbuf_valid[0] && !sbuf_valid[1] &&
                            !wb_valid[0] && !wb_valid[1] && mem_store_widle;
    assign maint_done = !invalidate_all || maint_complete;

    wire [2:0] response_word0 = critical0 + refill_beat0;
    wire [2:0] response_word1 = critical1 + refill_beat1;
    wire [2:0] stream_word0 = critical0 + refill_beat0 + 3'd1;
    wire [2:0] stream_word1 = critical1 + refill_beat1 + 3'd1;
    wire current_store_refill0 = normal_store_accept &&
                                  (up_store_addr[31:5] == line0) &&
                                  (up_store_addr[4:2] == response_word0);
    wire current_store_refill1 = normal_store_accept &&
                                  (up_store_addr[31:5] == line1) &&
                                  (up_store_addr[4:2] == response_word1);
    wire [31:0] refill_data0_base = overlay_pending_word(
        mem0_dev_rdata, line0, response_word0);
    wire [31:0] refill_data1_base = overlay_pending_word(
        mem1_dev_rdata, line1, response_word1);
    wire [31:0] refill_data0 = current_store_refill0 ?
        merge_bytes(refill_data0_base, up_store_wen, up_store_wdata) : refill_data0_base;
    wire [31:0] refill_data1 = current_store_refill1 ?
        merge_bytes(refill_data1_base, up_store_wen, up_store_wdata) : refill_data1_base;

    wire data_wr0_en = (state0 == ST_MISS_REFILL) && mem0_dev_rvalid;
    wire data_wr1_en = (state1 == ST_MISS_REFILL) && mem1_dev_rvalid;
    wire data_wr0_way = way0;
    wire data_wr1_way = way1;
    wire [1:0] data_wr0_bank = response_word0[1:0];
    wire [1:0] data_wr1_bank = response_word1[1:0];
    wire [SET_W:0] data_wr0_row = {set0, response_word0[2]};
    wire [SET_W:0] data_wr1_row = {set1, response_word1[2]};
    wire [3:0] data_wr0_wen = 4'hf;
    wire [3:0] data_wr1_wen = 4'hf;

    // A synchronous read is issued on request acceptance, on each streaming
    // beat, or while capturing a dirty victim.  The victim request is also
    // issued on the lookup-to-EVICT transition; this accounts for BRAM latency.
    wire rd0_lookup_next = (state0 == ST_LOOKUP) && lookup_hit0 && burst0;
    wire rd1_lookup_next = (state1 == ST_LOOKUP) && lookup_hit1 && burst1;
    wire rd0_stream_next = (state0 == ST_HIT_STREAM) && response_valid0 &&
                           (refill_beat0 < 3'd6);
    wire rd1_stream_next = (state1 == ST_HIT_STREAM) && response_valid1 &&
                           (refill_beat1 < 3'd6);
    wire rd0_victim_next = (state0 == ST_EVICT_CAPTURE) &&
                           (evict_beat0 < 3'd7);
    wire rd1_victim_next = (state1 == ST_EVICT_CAPTURE) &&
                           (evict_beat1 < 3'd7);
    wire rd0_victim_start = (state0 == ST_LOOKUP) && !lookup_hit0 &&
                            burst0 && victim_dirty0 &&
                            !(wb_valid[0] && wb_valid[1]);
    wire rd1_victim_start = (state1 == ST_LOOKUP) && !lookup_hit1 &&
                            burst1 && victim_dirty1 &&
                            !(wb_valid[0] && wb_valid[1]);
    wire rd0_req = lane0_accept || rd0_lookup_next || rd0_stream_next ||
                   rd0_victim_next || rd0_victim_start;
    wire rd1_req = lane1_accept || rd1_lookup_next || rd1_stream_next ||
                   rd1_victim_next || rd1_victim_start;
    wire rd0_is_victim = rd0_victim_next || rd0_victim_start;
    wire rd1_is_victim = rd1_victim_next || rd1_victim_start;
    wire [SET_W-1:0] rd0_set = rd0_is_victim ? set0 :
                               lane0_accept ? input_set0 : set0;
    wire [SET_W-1:0] rd1_set = rd1_is_victim ? set1 :
                               lane1_accept ? input_set1 : set1;
    wire [2:0] rd0_word = rd0_victim_start ? 3'd0 :
                          rd0_victim_next ? (evict_read_pending0 ?
                                             (evict_beat0 + 3'd1) : evict_beat0) :
                          lane0_accept ? input_word0 :
                          (state0 == ST_LOOKUP) ? (critical0 + 3'd1) :
                          (critical0 + refill_beat0 + 3'd2);
    wire [2:0] rd1_word = rd1_victim_start ? 3'd0 :
                          rd1_victim_next ? (evict_read_pending1 ?
                                             (evict_beat1 + 3'd1) : evict_beat1) :
                          lane1_accept ? input_word1 :
                          (state1 == ST_LOOKUP) ? (critical1 + 3'd1) :
                          (critical1 + refill_beat1 + 3'd2);
    wire [1:0] rd0_bank = rd0_word[1:0];
    wire [1:0] rd1_bank = rd1_word[1:0];
    wire [SET_W:0] rd0_row = {rd0_set, rd0_word[2]};
    wire [SET_W:0] rd1_row = {rd1_set, rd1_word[2]};

    // Each data-bank wrapper has one address per physical port.  During a
    // refill that port is a writer, so its address must come from the refill
    // beat rather than the speculative streaming-read address (which is two
    // words ahead to cover the synchronous BRAM latency).  Without this mux,
    // a critical word at offset 4..7 was written into the row for offset 0..3
    // (and vice versa), producing a same-line value from the wrong word on a
    // later L2 hit.  The two operations are mutually exclusive per lane, so
    // selecting the write address preserves the one-read/one-write BRAM port.
    wire [SET_W:0] data_port_addr_a = data_wr0_en ? data_wr0_row : rd0_row;
    wire [SET_W:0] data_port_addr_b = data_wr1_en ? data_wr1_row : rd1_row;

    assign mem0_cpu_ren = (state0 == ST_MISS_REQ) ? 4'hf :
                          (state0 == ST_UNC_REQ) ? ren0 : 4'h0;
    assign mem0_cpu_raddr = addr0;
    assign mem0_cpu_rburst = (state0 == ST_MISS_REQ);
    assign mem1_cpu_ren = (state1 == ST_MISS_REQ) ? 4'hf :
                          (state1 == ST_UNC_REQ) ? ren1 : 4'h0;
    assign mem1_cpu_raddr = addr1;
    assign mem1_cpu_rburst = (state1 == ST_MISS_REQ);

    wire lower_fire0 = ((state0 == ST_MISS_REQ) || (state0 == ST_UNC_REQ)) &&
                       mem0_dev_rrdy;
    wire lower_fire1 = ((state1 == ST_MISS_REQ) || (state1 == ST_UNC_REQ)) &&
                       mem1_dev_rrdy;

    assign up0_dev_rvalid = response_valid0 ||
                            ((state0 == ST_MISS_REFILL) && mem0_dev_rvalid) ||
                            ((state0 == ST_UNC_RESP) && mem0_dev_rvalid);
    assign up1_dev_rvalid = response_valid1 ||
                            ((state1 == ST_MISS_REFILL) && mem1_dev_rvalid) ||
                            ((state1 == ST_UNC_RESP) && mem1_dev_rvalid);
    assign up0_dev_rdata = response_valid0 ? response_data0 :
                           (state0 == ST_MISS_REFILL) ? refill_data0 :
                           (state0 == ST_UNC_RESP) ?
                              overlay_pending_word(mem0_dev_rdata,
                                                   addr0[31:5], addr0[4:2]) :
                           32'h0;
    assign up1_dev_rdata = response_valid1 ? response_data1 :
                           (state1 == ST_MISS_REFILL) ? refill_data1 :
                           (state1 == ST_UNC_RESP) ?
                              overlay_pending_word(mem1_dev_rdata,
                                                   addr1[31:5], addr1[4:2]) :
                           32'h0;

    // ------------------------------------------------------------------
    // One explicit true-dual-port RAM instance per physical data bank.
    // Refill writes are full-word writes (data_wr*_wen is 4'hf), so no
    // read-modify-write mux is needed on the BRAM write ports.
    // ------------------------------------------------------------------
    L2DCacheDualPortRam32 #(.DEPTH(BANK_DEPTH), .ADDR_WIDTH(SET_W + 1))
    u_data0_b0 (
        .clk(cpu_clk), .rstn(cpu_rstn),
        .read_a(rd0_req && (rd0_bank == 2'd0)), .addr_a(data_port_addr_a),
        .rdata_a(rd0_w0_b0),
        .write_a(data_wr0_en && !data_wr0_way && (data_wr0_bank == 2'd0)),
        .wdata_a(refill_data0),
        .read_b(rd1_req && (rd1_bank == 2'd0)), .addr_b(data_port_addr_b),
        .rdata_b(rd1_w0_b0),
        .write_b(data_wr1_en && !data_wr1_way && (data_wr1_bank == 2'd0)),
        .wdata_b(refill_data1)
    );
    L2DCacheDualPortRam32 #(.DEPTH(BANK_DEPTH), .ADDR_WIDTH(SET_W + 1))
    u_data0_b1 (
        .clk(cpu_clk), .rstn(cpu_rstn),
        .read_a(rd0_req && (rd0_bank == 2'd1)), .addr_a(data_port_addr_a),
        .rdata_a(rd0_w0_b1),
        .write_a(data_wr0_en && !data_wr0_way && (data_wr0_bank == 2'd1)),
        .wdata_a(refill_data0),
        .read_b(rd1_req && (rd1_bank == 2'd1)), .addr_b(data_port_addr_b),
        .rdata_b(rd1_w0_b1),
        .write_b(data_wr1_en && !data_wr1_way && (data_wr1_bank == 2'd1)),
        .wdata_b(refill_data1)
    );
    L2DCacheDualPortRam32 #(.DEPTH(BANK_DEPTH), .ADDR_WIDTH(SET_W + 1))
    u_data0_b2 (
        .clk(cpu_clk), .rstn(cpu_rstn),
        .read_a(rd0_req && (rd0_bank == 2'd2)), .addr_a(data_port_addr_a),
        .rdata_a(rd0_w0_b2),
        .write_a(data_wr0_en && !data_wr0_way && (data_wr0_bank == 2'd2)),
        .wdata_a(refill_data0),
        .read_b(rd1_req && (rd1_bank == 2'd2)), .addr_b(data_port_addr_b),
        .rdata_b(rd1_w0_b2),
        .write_b(data_wr1_en && !data_wr1_way && (data_wr1_bank == 2'd2)),
        .wdata_b(refill_data1)
    );
    L2DCacheDualPortRam32 #(.DEPTH(BANK_DEPTH), .ADDR_WIDTH(SET_W + 1))
    u_data0_b3 (
        .clk(cpu_clk), .rstn(cpu_rstn),
        .read_a(rd0_req && (rd0_bank == 2'd3)), .addr_a(data_port_addr_a),
        .rdata_a(rd0_w0_b3),
        .write_a(data_wr0_en && !data_wr0_way && (data_wr0_bank == 2'd3)),
        .wdata_a(refill_data0),
        .read_b(rd1_req && (rd1_bank == 2'd3)), .addr_b(data_port_addr_b),
        .rdata_b(rd1_w0_b3),
        .write_b(data_wr1_en && !data_wr1_way && (data_wr1_bank == 2'd3)),
        .wdata_b(refill_data1)
    );
    L2DCacheDualPortRam32 #(.DEPTH(BANK_DEPTH), .ADDR_WIDTH(SET_W + 1))
    u_data1_b0 (
        .clk(cpu_clk), .rstn(cpu_rstn),
        .read_a(rd0_req && (rd0_bank == 2'd0)), .addr_a(data_port_addr_a),
        .rdata_a(rd0_w1_b0),
        .write_a(data_wr0_en && data_wr0_way && (data_wr0_bank == 2'd0)),
        .wdata_a(refill_data0),
        .read_b(rd1_req && (rd1_bank == 2'd0)), .addr_b(data_port_addr_b),
        .rdata_b(rd1_w1_b0),
        .write_b(data_wr1_en && data_wr1_way && (data_wr1_bank == 2'd0)),
        .wdata_b(refill_data1)
    );
    L2DCacheDualPortRam32 #(.DEPTH(BANK_DEPTH), .ADDR_WIDTH(SET_W + 1))
    u_data1_b1 (
        .clk(cpu_clk), .rstn(cpu_rstn),
        .read_a(rd0_req && (rd0_bank == 2'd1)), .addr_a(data_port_addr_a),
        .rdata_a(rd0_w1_b1),
        .write_a(data_wr0_en && data_wr0_way && (data_wr0_bank == 2'd1)),
        .wdata_a(refill_data0),
        .read_b(rd1_req && (rd1_bank == 2'd1)), .addr_b(data_port_addr_b),
        .rdata_b(rd1_w1_b1),
        .write_b(data_wr1_en && data_wr1_way && (data_wr1_bank == 2'd1)),
        .wdata_b(refill_data1)
    );
    L2DCacheDualPortRam32 #(.DEPTH(BANK_DEPTH), .ADDR_WIDTH(SET_W + 1))
    u_data1_b2 (
        .clk(cpu_clk), .rstn(cpu_rstn),
        .read_a(rd0_req && (rd0_bank == 2'd2)), .addr_a(data_port_addr_a),
        .rdata_a(rd0_w1_b2),
        .write_a(data_wr0_en && data_wr0_way && (data_wr0_bank == 2'd2)),
        .wdata_a(refill_data0),
        .read_b(rd1_req && (rd1_bank == 2'd2)), .addr_b(data_port_addr_b),
        .rdata_b(rd1_w1_b2),
        .write_b(data_wr1_en && data_wr1_way && (data_wr1_bank == 2'd2)),
        .wdata_b(refill_data1)
    );
    L2DCacheDualPortRam32 #(.DEPTH(BANK_DEPTH), .ADDR_WIDTH(SET_W + 1))
    u_data1_b3 (
        .clk(cpu_clk), .rstn(cpu_rstn),
        .read_a(rd0_req && (rd0_bank == 2'd3)), .addr_a(data_port_addr_a),
        .rdata_a(rd0_w1_b3),
        .write_a(data_wr0_en && data_wr0_way && (data_wr0_bank == 2'd3)),
        .wdata_a(refill_data0),
        .read_b(rd1_req && (rd1_bank == 2'd3)), .addr_b(data_port_addr_b),
        .rdata_b(rd1_w1_b3),
        .write_b(data_wr1_en && data_wr1_way && (data_wr1_bank == 2'd3)),
        .wdata_b(refill_data1)
    );

    // ------------------------------------------------------------------
    // Metadata, per-lane state, SBUF/WBB ownership, and maintenance.
    // ------------------------------------------------------------------
    integer init_i;
    always @(posedge cpu_clk or negedge cpu_rstn) begin
        if (!cpu_rstn) begin
            meta_q0 <= {META_W{1'b0}};
            meta_q1 <= {META_W{1'b0}};
            init_active <= 1'b1;
            init_set <= {SET_W{1'b0}};
            state0 <= ST_IDLE;
            state1 <= ST_IDLE;
            addr0 <= 32'h0;
            addr1 <= 32'h0;
            ren0 <= 4'h0;
            ren1 <= 4'h0;
            burst0 <= 1'b0;
            burst1 <= 1'b0;
            set0 <= {SET_W{1'b0}};
            set1 <= {SET_W{1'b0}};
            tag_req0 <= {TAG_W{1'b0}};
            tag_req1 <= {TAG_W{1'b0}};
            critical0 <= 3'h0;
            critical1 <= 3'h0;
            refill_beat0 <= 3'h0;
            refill_beat1 <= 3'h0;
            evict_beat0 <= 3'h0;
            evict_beat1 <= 3'h0;
            evict_read_pending0 <= 1'b0;
            evict_read_pending1 <= 1'b0;
            wb_target0 <= 1'b0;
            wb_target1 <= 1'b0;
            way0 <= 1'b0;
            way1 <= 1'b0;
            victim_line0 <= 27'h0;
            victim_line1 <= 27'h0;
            response_data0 <= 32'h0;
            response_data1 <= 32'h0;
            response_valid0 <= 1'b0;
            response_valid1 <= 1'b0;
            invalidate_all_d <= 1'b0;
            flush_active <= 1'b0;
            flush_done <= 1'b0;
            flush_set <= {SET_W{1'b0}};
            maint_complete <= 1'b1;
            invalidate_pending <= 1'b0;
            invalidate_line <= 27'h0;
            invalidate_sbuf_idx <= 1'b0;
            invalidate_meta_rd_pending <= 1'b0;
            bypass_pending <= 1'b0;
            drain_active <= 1'b0;
            drain_is_wb <= 1'b0;
            drain_idx <= 1'b0;
            drain_sent_mask <= 8'h0;
            drain_valid_mask <= 8'h0;
            drain_pending_count <= 4'd0;
            for (init_i = 0; init_i < 2; init_i = init_i + 1) begin
                sbuf_valid[init_i] <= 1'b0;
                sbuf_line[init_i] <= 27'h0;
                sbuf_data[init_i] <= 256'h0;
                sbuf_byte_valid[init_i] <= 32'h0;
                wb_valid[init_i] <= 1'b0;
                wb_line[init_i] <= 27'h0;
                wb_data[init_i] <= 256'h0;
                wb_byte_valid[init_i] <= 32'h0;
            end
        end else begin
            invalidate_all_d <= invalidate_all;

            if (init_active) begin
                // Synchronous metadata invalidate sweep.  The data RAMs are not
                // reset; valid bits alone define architectural contents.
                if (init_set == SET_COUNT-1) begin
                    init_active <= 1'b0;
                    init_set <= {SET_W{1'b0}};
                end else begin
                    init_set <= init_set + 1'b1;
                end
            end else begin
                if (lane0_accept) begin
                    addr0 <= up0_cpu_raddr;
                    ren0 <= up0_cpu_ren;
                    burst0 <= up0_cpu_rburst;
                    set0 <= input_set0;
                    tag_req0 <= input_tag0;
                    critical0 <= input_word0;
                    refill_beat0 <= 3'd0;
                    evict_beat0 <= 3'd0;
                    response_valid0 <= 1'b0;
                    state0 <= ST_META_WAIT;
                end
                if (lane1_accept) begin
                    addr1 <= up1_cpu_raddr;
                    ren1 <= up1_cpu_ren;
                    burst1 <= up1_cpu_rburst;
                    set1 <= input_set1;
                    tag_req1 <= input_tag1;
                    critical1 <= input_word1;
                    refill_beat1 <= 3'd0;
                    evict_beat1 <= 3'd0;
                    response_valid1 <= 1'b0;
                    state1 <= ST_META_WAIT;
                end

                // Metadata lookup has one explicit synchronous RAM cycle.
                // Capture the result into the lane snapshot before any hit,
                // victim, or refill decision consumes it.
                if (state0 == ST_META_WAIT) begin
                    meta_q0 <= meta_ram_rdata_a;
                    state0 <= ST_LOOKUP;
                end
                if (state1 == ST_META_WAIT) begin
                    meta_q1 <= meta_ram_rdata_b;
                    state1 <= ST_LOOKUP;
                end

                // A read issued into a synchronous BRAM becomes visible to the
                // control process on the following clock.  Keep one pending bit
                // so victim word capture is aligned with that latency.
                evict_read_pending0 <= rd0_victim_start || rd0_victim_next;
                evict_read_pending1 <= rd1_victim_start || rd1_victim_next;

                if ((state0 == ST_LOOKUP) && !lane0_accept) begin
                    if (!burst0) begin
                        if (lookup_hit0 && !is_peripheral_addr(addr0)) begin
                            way0 <= lookup_way0;
                            response_data0 <= overlay_pending_word(
                                pick_rd0_word(lookup_way0, critical0[1:0]),
                                line0, critical0);
                            response_valid0 <= 1'b1;
                            state0 <= ST_UNC_HIT;
                        end else begin
                            state0 <= ST_UNC_REQ;
                        end
                    end else if (lookup_hit0) begin
                        way0 <= lookup_way0;
                        response_data0 <= overlay_pending_word(
                            pick_rd0_word(lookup_way0, critical0[1:0]),
                            line0, critical0);
                        response_valid0 <= 1'b1;
                        refill_beat0 <= 3'd0;
                        state0 <= ST_HIT_STREAM;
                    end else begin
                        way0 <= victim_way0;
                        victim_line0 <= victim_way0 ?
                            {meta0_tag1, set0} : {meta0_tag0, set0};
                        evict_beat0 <= 3'd0;
                        if (victim_dirty0)
                            begin
                                wb_target0 <= wb_valid[0] ? 1'b1 : 1'b0;
                                state0 <= wb_valid[0] || wb_valid[1] ?
                                          ST_EVICT_WAIT : ST_EVICT_CAPTURE;
                            end
                        else
                            state0 <= ST_MISS_REQ;
                    end
                end
                if ((state1 == ST_LOOKUP) && !lane1_accept) begin
                    if (!burst1) begin
                        if (lookup_hit1 && !is_peripheral_addr(addr1)) begin
                            way1 <= lookup_way1;
                            response_data1 <= overlay_pending_word(
                                pick_rd1_word(lookup_way1, critical1[1:0]),
                                line1, critical1);
                            response_valid1 <= 1'b1;
                            state1 <= ST_UNC_HIT;
                        end else begin
                            state1 <= ST_UNC_REQ;
                        end
                    end else if (lookup_hit1) begin
                        way1 <= lookup_way1;
                        response_data1 <= overlay_pending_word(
                            pick_rd1_word(lookup_way1, critical1[1:0]),
                            line1, critical1);
                        response_valid1 <= 1'b1;
                        refill_beat1 <= 3'd0;
                        state1 <= ST_HIT_STREAM;
                    end else begin
                        way1 <= victim_way1;
                        victim_line1 <= victim_way1 ?
                            {meta1_tag1, set1} : {meta1_tag0, set1};
                        evict_beat1 <= 3'd0;
                        if (victim_dirty1)
                            begin
                                wb_target1 <= wb_valid[0] ? 1'b1 : 1'b0;
                                state1 <= wb_valid[0] || wb_valid[1] ?
                                          ST_EVICT_WAIT : ST_EVICT_CAPTURE;
                            end
                        else
                            state1 <= ST_MISS_REQ;
                    end
                end

                if ((state0 == ST_HIT_STREAM) && response_valid0) begin
                    if (refill_beat0 == 3'd7) begin
                        response_valid0 <= 1'b0;
                        state0 <= ST_IDLE;
                    end else begin
                        response_data0 <= overlay_pending_word(
                            pick_rd0_word(way0, stream_word0[1:0]),
                            line0, stream_word0);
                        refill_beat0 <= refill_beat0 + 3'd1;
                    end
                end
                if ((state1 == ST_HIT_STREAM) && response_valid1) begin
                    if (refill_beat1 == 3'd7) begin
                        response_valid1 <= 1'b0;
                        state1 <= ST_IDLE;
                    end else begin
                        response_data1 <= overlay_pending_word(
                            pick_rd1_word(way1, stream_word1[1:0]),
                            line1, stream_word1);
                        refill_beat1 <= refill_beat1 + 3'd1;
                    end
                end
                if ((state0 == ST_UNC_HIT) && response_valid0) begin
                    response_valid0 <= 1'b0;
                    state0 <= ST_IDLE;
                end
                if ((state1 == ST_UNC_HIT) && response_valid1) begin
                    response_valid1 <= 1'b0;
                    state1 <= ST_IDLE;
                end

                if (state0 == ST_EVICT_WAIT && !(wb_valid[0] || wb_valid[1])) begin
                    wb_target0 <= wb_valid[0] ? 1'b1 : 1'b0;
                    state0 <= ST_EVICT_CAPTURE;
                end
                if (state1 == ST_EVICT_WAIT && !(wb_valid[0] || wb_valid[1])) begin
                    wb_target1 <= wb_valid[0] ? 1'b1 : 1'b0;
                    state1 <= ST_EVICT_CAPTURE;
                end

                if (lower_fire0) begin
                    if (state0 == ST_MISS_REQ) state0 <= ST_MISS_REFILL;
                    else if (state0 == ST_UNC_REQ) state0 <= ST_UNC_RESP;
                end
                if (lower_fire1) begin
                    if (state1 == ST_MISS_REQ) state1 <= ST_MISS_REFILL;
                    else if (state1 == ST_UNC_REQ) state1 <= ST_UNC_RESP;
                end

                if ((state0 == ST_UNC_RESP) && mem0_dev_rvalid)
                    state0 <= ST_IDLE;
                if ((state1 == ST_UNC_RESP) && mem1_dev_rvalid)
                    state1 <= ST_IDLE;

                if ((state0 == ST_MISS_REFILL) && mem0_dev_rvalid) begin
                    if (refill_beat0 == 3'd7) begin
                        state0 <= ST_IDLE;
                        refill_beat0 <= 3'd0;
                    end else begin
                        refill_beat0 <= refill_beat0 + 3'd1;
                    end
                end
                if ((state1 == ST_MISS_REFILL) && mem1_dev_rvalid) begin
                    if (refill_beat1 == 3'd7) begin
                        state1 <= ST_IDLE;
                        refill_beat1 <= 3'd0;
                    end else begin
                        refill_beat1 <= refill_beat1 + 3'd1;
                    end
                end

                // Victim capture uses the registered synchronous BRAM output.
                // The first read is issued on the lookup transition; subsequent
                // reads are issued one beat at a time.
                if ((state0 == ST_EVICT_CAPTURE) && evict_read_pending0) begin
                    wb_data[wb_target0] <= set_line_word(
                        wb_data[wb_target0], evict_beat0,
                        pick_rd0_word(way0, evict_beat0[1:0]));
                    if (evict_beat0 == 3'd7) begin
                        wb_valid[wb_target0] <= 1'b1;
                        wb_line[wb_target0] <= victim_line0;
                        wb_byte_valid[wb_target0] <= 32'hffff_ffff;
                        state0 <= ST_MISS_REQ;
                        evict_beat0 <= 3'd0;
                    end else begin
                        evict_beat0 <= evict_beat0 + 3'd1;
                    end
                end
                if ((state1 == ST_EVICT_CAPTURE) && evict_read_pending1) begin
                    wb_data[wb_target1] <= set_line_word(
                        wb_data[wb_target1], evict_beat1,
                        pick_rd1_word(way1, evict_beat1[1:0]));
                    if (evict_beat1 == 3'd7) begin
                        wb_valid[wb_target1] <= 1'b1;
                        wb_line[wb_target1] <= victim_line1;
                        wb_byte_valid[wb_target1] <= 32'hffff_ffff;
                        state1 <= ST_MISS_REQ;
                        evict_beat1 <= 3'd0;
                    end else begin
                        evict_beat1 <= evict_beat1 + 3'd1;
                    end
                end

                if (bypass_store_accept)
                    bypass_pending <= 1'b1;
                if (bypass_pending && mem_store_wdone)
                    bypass_pending <= 1'b0;

                if (normal_store_accept) begin
                    if (sbuf_match0 && !drain_blocks_sbuf0 &&
                        !sbuf_word_present0) begin
                        sbuf_data[0] <= merge_line_store(sbuf_data[0], up_store_addr[4:0],
                                                         up_store_wen, up_store_wdata);
                        sbuf_byte_valid[0] <= merge_line_mask(sbuf_byte_valid[0],
                                                             up_store_addr[4:0], up_store_wen);
                    end else if (sbuf_match1 && !drain_blocks_sbuf1 &&
                                 !sbuf_word_present1) begin
                        sbuf_data[1] <= merge_line_store(sbuf_data[1], up_store_addr[4:0],
                                                         up_store_wen, up_store_wdata);
                        sbuf_byte_valid[1] <= merge_line_mask(sbuf_byte_valid[1],
                                                             up_store_addr[4:0], up_store_wen);
                    end else if (sbuf_free_found) begin
                        sbuf_valid[sbuf_free_idx] <= 1'b1;
                        sbuf_line[sbuf_free_idx] <= up_store_addr[31:5];
                        sbuf_data[sbuf_free_idx] <= merge_line_store(
                            256'h0, up_store_addr[4:0], up_store_wen, up_store_wdata);
                        sbuf_byte_valid[sbuf_free_idx] <= merge_line_mask(
                            32'h0, up_store_addr[4:0], up_store_wen);
                    end
                end

                // Start after the current merge run ends, then enqueue all
                // valid words while the lower FIFO is ready.
                if (drain_start) begin
                    if (wb_valid[0] || wb_valid[1]) begin
                        drain_is_wb <= 1'b1;
                        drain_idx <= wb_valid[0] ? 1'b0 : 1'b1;
                    end else begin
                        drain_is_wb <= 1'b0;
                        drain_idx <= sbuf_valid[0] ? 1'b0 : 1'b1;
                    end
                    drain_active <= 1'b1;
                    drain_sent_mask <= 8'h0;
                    drain_valid_mask <= drain_start_valid_mask;
                    drain_pending_count <= 4'd0;
                    if (drain_start_sbuf)
                        invalidate_line <= sbuf_line[drain_start_idx];
                end
                if (drain_active) begin
                    if (drain_fire)
                        drain_sent_mask[drain_word_idx] <= 1'b1;
                    case ({drain_fire, drain_done_fire})
                        2'b10: drain_pending_count <= drain_pending_count + 4'd1;
                        2'b01: drain_pending_count <= drain_pending_count - 4'd1;
                        default: drain_pending_count <= drain_pending_count;
                    endcase
                    if (drain_complete) begin
                        if (drain_is_wb) begin
                            wb_valid[drain_idx] <= 1'b0;
                            wb_byte_valid[drain_idx] <= 32'h0;
                        end else begin
                            invalidate_pending <= 1'b1;
                            invalidate_sbuf_idx <= drain_idx;
                            // invalidate_line was captured at drain_start,
                            // before the owner became write-completion
                            // constrained.  Keep the completed SBUF image
                            // alive until the stale BRAM tag is invalidated.
                        end
                        drain_active <= 1'b0;
                        drain_sent_mask <= 8'h0;
                        drain_valid_mask <= 8'h0;
                        drain_pending_count <= 4'd0;
                    end
                end

                if (meta_invalidate_read_fire)
                    invalidate_meta_rd_pending <= 1'b1;
                if (meta_invalidate_write_fire) begin
                    // The RAM output is the row read in the previous cycle.
                    // Keep the SBUF image pinned until this ordered write is
                    // actually issued, so same-line reads retain forwarding.
                    invalidate_meta_rd_pending <= 1'b0;
                    invalidate_pending <= 1'b0;
                    sbuf_valid[invalidate_sbuf_idx] <= 1'b0;
                    sbuf_byte_valid[invalidate_sbuf_idx] <= 32'h0;
                end

                if (invalidate_all && !invalidate_all_d) begin
                    flush_active <= 1'b1;
                    flush_done <= 1'b0;
                    flush_set <= {SET_W{1'b0}};
                    maint_complete <= 1'b0;
                end
                if (flush_active && !flush_done &&
                    (state0 == ST_IDLE) && (state1 == ST_IDLE) &&
                    !drain_active && !bypass_pending && !invalidate_pending) begin
                    if (flush_set == SET_COUNT-1) begin
                        flush_done <= 1'b1;
                    end else begin
                        flush_set <= flush_set + 1'b1;
                    end
                end
                if (flush_active && flush_done &&
                    (state0 == ST_IDLE) && (state1 == ST_IDLE) &&
                    !drain_active && !bypass_pending && !invalidate_pending &&
                    !sbuf_valid[0] && !sbuf_valid[1] &&
                    !wb_valid[0] && !wb_valid[1]) begin
                    flush_active <= 1'b0;
                    maint_complete <= 1'b1;
                end
            end
        end
    end


endmodule
