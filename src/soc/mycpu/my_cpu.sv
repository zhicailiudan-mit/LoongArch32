`timescale 1ns / 1ps

`include "defines.vh"
import cpu_types_pkg::*;

module MyCpu (
    input  wire         cpu_rstn,
    input  wire         cpu_clk,

    // Instruction Fetch Interface
    output wire         ifetch_rreq,
    input  wire         ifetch_ready,
    output wire [31:0]  ifetch_addr,
    output wire         ifetch_cacheable,
    output wire         ifetch_dual,
    input  wire         ifetch_valid,
    input  wire [31:0]  ifetch_inst,
    input  wire         ifetch1_valid,
    input  wire [31:0]  ifetch1_inst,
    output wire         pred_error,

    // Data Access Interface
    output wire [3:0]   daccess_ren,
    output wire [31:0]  daccess_addr,
    output wire         daccess_cacheable,
    output wire [2:0]   daccess_load_tid,
    input  wire         daccess_rready,
    input  wire         daccess_valid,
    input  wire [31:0]  daccess_rdata,
    input  wire [2:0]   daccess_response_tid,
    output wire [3:0]   daccess_wen,
    output wire [31:0]  daccess_wdata,
    input  wire         daccess_wready,
    input  wire         daccess_wposted,
    input  wire         daccess_wresp,
    output wire         daccess_line_alloc_valid,
    output wire [31:0]  daccess_line_alloc_addr,
    output wire [`CACHE_BLK_SIZE-1:0] daccess_line_alloc_data,
    output wire [`CACHE_BLK_LEN-1:0] daccess_line_alloc_word_mask,
    input  wire         daccess_line_alloc_ready,

    // Cache maintenance interface
    output wire         icache_maint_valid,
    input  wire         icache_maint_ready,
    input  wire         icache_maint_done,
    output wire         dcache_maint_valid,
    input  wire         dcache_maint_ready,
    input  wire         dcache_maint_done,
    output wire         cache_maint_all,
    output wire [1:0]   cache_maint_mode,
    output wire [31:0]  cache_maint_addr,
    output wire [31:0]  cache_maint_ctag,

    // Official LA32R SoC trace boundary. debug0_wb_inst is retained even
    // though the current ROB packet does not carry the original instruction.
    output wire [31:0]  debug0_wb_pc,
    output wire [3:0]   debug0_wb_rf_wen,
    output wire [4:0]   debug0_wb_rf_wnum,
    output wire [31:0]  debug0_wb_rf_wdata,
    output wire [31:0]  debug0_wb_inst
);

    // Global control remains at the top-level boundary.  The equations are
    // unchanged from the pre-wrapper implementation.
    wire alu_done;
    wire muldiv_busy;
    wire ldst_suspend;
    wire ldst1_suspend;
    wire privilege_busy;

    wire frontend_branch_mispredict;
    wire branch_mispredict;
    wire branch_redirect_valid;
    wire [31:0] branch_redirect_target;
    uop_id_t branch_recover_id;
    wire branch_pipeline_flush;
    wire system_redirect_valid;
    recovery_event_t recovery_event;
    wire redirect_valid = recovery_event.redirect_valid;
    wire [31:0] redirect_target = recovery_event.redirect_target;
    wire pipeline_flush = recovery_event.pipeline_flush;
    wire recover_valid = recovery_event.recover_valid;
    wire uop_id_t recover_id = recovery_event.recover_id;

    wire [1:0] fetch_valid;
    wire fetch_ready;
    fetch_uop_t fetch_uop0;
    fetch_uop_t fetch_uop1;
    wire [1:0] decode_valid;
    wire decode_ready;
    decoded_uop_t decode_uop0;
    decoded_uop_t decode_uop1;
    commit_t commit0;
    commit_t commit1;

    wire issue0_valid;
    wire issue0_ready;
    wire issue0_fire;
    issue_uop_t issue0;
    wire issue1_valid;
    wire issue1_ready;
    wire issue1_fire;
    issue_uop_t issue1;
    wire system_issue_valid;
    wire system_issue_ready;
    wire system_issue_fire;
    wire privilege_req_ready;
    issue_uop_t system_issue;

    execute_result_t execute_result;
    execute_result_t execute_result1;
    completion_t issue1_completion;
    completion_t issue1_exec_completion;
    completion_t issue1_lsu_completion;
    completion_t main_completion;
    completion_t system_completion;
    memory_request_t dcache_req;
    memory_response_t dcache_rsp;
    privilege_req_t privilege_req;
    privilege_rsp_t privilege_rsp;
    privilege_state_t privilege_state;
    wire perf_bpu_wait;
    wire perf_icache_wait;
    wire [`ROB_TAG_W:0] perf_rob_occupancy;
    wire [3:0] perf_issue_occupancy;
    wire [3:0] perf_lq_occupancy;
    wire [2:0] perf_sq_occupancy;
    wire [2:0] perf_sb_occupancy;
    wire perf_rob_block;
    wire perf_issue_queue_block;
    wire perf_true_source_wait;
    wire perf_source_wait_dep_load;
    wire perf_source_wait_dep_muldiv;
    wire perf_source_wait_dep_alu;
    wire perf_source_wait_dep_branch;
    wire perf_source_wait_store_addr;
    wire perf_source_wait_store_data;
    wire perf_iq_no_ready;
    wire perf_serializing;
    wire perf_lsu_order;
    wire lsu_perf_order_block;
    wire perf_fetch_fire0;
    wire perf_fetch_fire1;
    wire perf_dispatch_fire0;
    wire perf_dispatch_fire1;
    wire perf_branch_fire;
    wire perf_branch_predicted_taken;
    wire perf_branch_actual_taken;
    wire perf_branch_mispredict;
    wire perf_branch_btb_hit;
    wire [31:0] perf_branch_pc;
    wire perf_branch_conditional;
    wire perf_branch_backward;
    wire perf_branch_jirl;
    wire perf_direction_mispredict;
    wire perf_target_mispredict;
    wire perf_btb_update;
    wire perf_btb_update_conditional;
    wire perf_btb_update_backward;
    wire perf_dcache_wait;
    wire perf_dcache_backpressure;
    wire perf_load_issue;
    wire perf_load_forward;
    wire perf_load_response;
    wire perf_store_issue;
    wire perf_store_release;
    wire perf_store_drain;
    wire store_line_alloc_valid;
    wire [31:0] store_line_alloc_addr;
    wire [`CACHE_BLK_SIZE-1:0] store_line_alloc_data;
    wire [`CACHE_BLK_LEN-1:0] store_line_alloc_word_mask;
    completion_t store_data_complete0;
    completion_t store_data_complete1;

    wire frontend_ifetch_rreq;
    wire [31:0] frontend_ifetch_addr;
    wire [31:0] translated_ifetch_addr;
    wire [31:0] translated_daccess_addr;
    wire [31:0] system_effective_addr = system_issue.src0_value + system_issue.imm;
    wire [31:0] translated_system_addr;
    wire [1:0] ifetch_mat, daccess_mat, system_mat;
    wire ifetch_dmw_hit, daccess_dmw_hit, system_dmw_hit;
    wire ifetch_page_miss, daccess_page_miss, system_page_miss;
    assign ifetch_rreq = frontend_ifetch_rreq & !privilege_busy;
    assign ifetch_addr = translated_ifetch_addr;
    assign daccess_ren   = dcache_req.ren;
    assign daccess_addr  = translated_daccess_addr;
    assign daccess_load_tid = dcache_req.load_tid;
    assign daccess_wen   = dcache_req.wen;
    assign daccess_wdata = dcache_req.wdata;
    // Full-line StoreBuffer allocation is disabled in correctness mode.  Keep
    // the legacy sideband at a constant zero so it cannot partially handshake.
    assign daccess_line_alloc_valid = 1'b0;
    assign daccess_line_alloc_addr = 32'h00000000;
    assign daccess_line_alloc_data = '0;
    assign daccess_line_alloc_word_mask = '0;

    always @(*) begin
        dcache_rsp = '0;
        dcache_rsp.rready = daccess_rready;
        dcache_rsp.valid  = daccess_valid;
        dcache_rsp.rdata  = daccess_rdata;
        dcache_rsp.load_tid = daccess_response_tid;
        dcache_rsp.wready = daccess_wready;
        dcache_rsp.wposted = daccess_wposted;
        dcache_rsp.wresp  = daccess_wresp;
    end

    GlobalControl u_global_control (
        .branch_mispredict    (branch_mispredict),
        .branch_redirect_valid(branch_redirect_valid),
        .branch_redirect_target(branch_redirect_target),
        .branch_pipeline_flush(branch_pipeline_flush),
        .branch_recover_id    (branch_recover_id),
        .system_redirect_valid(system_redirect_valid),
        .system_redirect_target(privilege_rsp.redirect_target),
        .system_recover_id    (privilege_rsp.uop_id),
        .pred_error           (pred_error),
        .recovery_event       (recovery_event)
    );

    Frontend u_frontend (
        .clk             (cpu_clk),
        .rstn            (cpu_rstn),
        .flush           (pipeline_flush),
        .redirect_valid  (redirect_valid),
        .redirect_target (redirect_target),
        // Fetch/decode must not stop for a lane-local LSU/MDU wait.  A branch
        // is never held by those resources, so BPU resolution needs no such
        // global stall qualifier.
        .ex_stall        (1'b0),
        .issue_uop       (issue0),
        .issue_valid     (issue0_valid),
        .issue_fire      (issue0_fire),
        .ex_valid        (execute_result.valid),
        .ex_is_br_jmp    (execute_result.is_br_jmp),
        .ex_is_call      (execute_result.is_call),
        .ex_is_ret       (execute_result.is_ret),
        .ex_is_conditional(execute_result.is_br_jmp &&
                           (execute_result.npc_op == `NPC_ALU)),
        .ex_offset_negative(execute_result.imm[31]),
        .ex_pc           (execute_result.pc),
        .ex_real_taken   (execute_result.branch_taken),
        .ex_real_target  (execute_result.branch_target),
        .ex_ras_ptr      (execute_result.ras_ptr),
        .ex_pred         (execute_result.pred),
        .branch_mispredict(frontend_branch_mispredict),
        .fetch_valid     (fetch_valid),
        .fetch_ready     (fetch_ready),
        .fetch_uop0      (fetch_uop0),
        .fetch_uop1      (fetch_uop1),
        .ifetch_rreq     (frontend_ifetch_rreq),
        .ifetch_ready    (ifetch_ready & !privilege_busy),
        .ifetch_addr     (frontend_ifetch_addr),
        .ifetch_dual     (ifetch_dual),
        .ifetch_valid    (ifetch_valid),
        .ifetch_inst     (ifetch_inst),
        .ifetch1_valid   (ifetch1_valid),
        .ifetch1_inst    (ifetch1_inst),
        .perf_bpu_wait   (perf_bpu_wait),
        .perf_icache_wait(perf_icache_wait),
        .perf_fetch_fire0(perf_fetch_fire0),
        .perf_fetch_fire1(perf_fetch_fire1),
        .perf_branch_fire(perf_branch_fire),
        .perf_branch_predicted_taken(perf_branch_predicted_taken),
        .perf_branch_actual_taken(perf_branch_actual_taken),
        .perf_branch_mispredict(perf_branch_mispredict),
        .perf_branch_btb_hit(perf_branch_btb_hit),
        .perf_branch_pc(perf_branch_pc),
        .perf_branch_conditional(perf_branch_conditional),
        .perf_branch_backward(perf_branch_backward),
        .perf_branch_jirl(perf_branch_jirl),
        .perf_direction_mispredict(perf_direction_mispredict),
        .perf_target_mispredict(perf_target_mispredict),
        .perf_btb_update(perf_btb_update),
        .perf_btb_update_conditional(perf_btb_update_conditional),
        .perf_btb_update_backward(perf_btb_update_backward)
    );

    DecodeCluster u_decode_cluster (
        .clk          (cpu_clk),
        .flush        (pipeline_flush),
        .fetch_valid  (fetch_valid),
        .fetch_ready  (fetch_ready),
        .fetch_uop0   (fetch_uop0),
        .fetch_uop1   (fetch_uop1),
        .decode_valid (decode_valid),
        .decode_ready (decode_ready),
        .decode_uop0  (decode_uop0),
        .decode_uop1  (decode_uop1),
        .commit0      (commit0),
        .commit1      (commit1)
    );

    ExecutionCluster u_execution_cluster (
        .cpu_rstn             (cpu_rstn),
        .cpu_clk              (cpu_clk),
        .lane0_result_stall   (ldst_suspend),
        .lane1_result_stall   (ldst1_suspend),
        .pred_error           (frontend_branch_mispredict),
        .recover_valid        (recover_valid),
        .system_flush         (recovery_event.system_flush),
        .recover_id           (recover_id),
        .store_data_complete0 (store_data_complete0),
        .store_data_complete1 (store_data_complete1),
        .store_data_commit0   (commit0),
        .store_data_commit1   (commit1),
        .issue0_valid     (issue0_valid),
        .issue0_fire      (issue0_fire),
        .issue0           (issue0),
        .issue0_ready     (issue0_ready),
        .issue1_valid         (issue1_valid),
        .issue1_fire          (issue1_fire),
        .issue1               (issue1),
        .issue1_ready         (issue1_ready),
        .execute_result       (execute_result),
        .execute_result1      (execute_result1),
        .issue1_complete      (issue1_exec_completion),
        .alu_done             (alu_done),
        .muldiv_busy          (muldiv_busy),
        .branch_mispredict    (branch_mispredict),
        .redirect_valid       (branch_redirect_valid),
        .redirect_target      (branch_redirect_target),
        .branch_recover_id    (branch_recover_id),
        .pipeline_flush       (branch_pipeline_flush)
    );

    wire rob_head_valid;
    uop_id_t rob_head_id;

    wire reserve0_valid;
    wire reserve0_ready;
    uop_id_t reserve0_uop_id;
    wire [31:0] reserve0_pc;
    wire [3:0] reserve0_store_mask;
    wire reserve0_src1_ready;
    wire [31:0] reserve0_src1_value;
    uop_id_t reserve0_src1_id;

    wire reserve1_valid;
    wire reserve1_ready;
    uop_id_t reserve1_uop_id;
    wire [31:0] reserve1_pc;
    wire [3:0] reserve1_store_mask;
    wire reserve1_src1_ready;
    wire [31:0] reserve1_src1_value;
    uop_id_t reserve1_src1_id;

    wire [1:0] store_reserve_credit;

    LoadStoreUnit #(
        .DECOUPLED_STORE_RESERVATION(1'b1)
    ) u_load_store_unit (
        .cpu_rstn       (cpu_rstn),
        .cpu_clk        (cpu_clk),
        .flush          (pipeline_flush),
        .branch_flush   (recovery_event.branch_flush),
        .recover_valid  (recover_valid),
        .system_flush   (recovery_event.system_flush),
        // LQ/SQ use the recovery id only for branch-younger filtering.
        // A system flush is handled independently and never consults it.
        .recover_id     (branch_recover_id),
        .rob_head_valid (rob_head_valid),
        .rob_head_id    (rob_head_id),
        .execute_result (execute_result),
        .execute_result1(execute_result1),
        .store_data_complete0(store_data_complete0),
        .store_data_complete1(store_data_complete1),
        .commit0        (commit0),
        .commit1        (commit1),
        .ldst_suspend   (ldst_suspend),
        .ldst1_suspend  (ldst1_suspend),
        .main_completion(main_completion),
        .lane1_completion(issue1_lsu_completion),
        .dcache_req     (dcache_req),
        .dcache_rsp     (dcache_rsp),
        .perf_lq_occupancy(perf_lq_occupancy),
        .perf_sq_occupancy(perf_sq_occupancy),
        .perf_sb_occupancy(perf_sb_occupancy),
         .perf_order_block(lsu_perf_order_block),
         .perf_dcache_wait(perf_dcache_wait),
         .perf_dcache_backpressure(perf_dcache_backpressure),
         .perf_load_issue(perf_load_issue),
         .perf_load_forward(perf_load_forward),
         .perf_load_response(perf_load_response),
         .perf_store_issue(perf_store_issue),
         .perf_store_release(perf_store_release),
         .perf_store_drain(perf_store_drain),
          .store_line_alloc_ready(1'b0),
         .store_line_alloc_valid(store_line_alloc_valid),
         .store_line_alloc_addr(store_line_alloc_addr),
         .store_line_alloc_data(store_line_alloc_data),
         .store_line_alloc_word_mask(store_line_alloc_word_mask),
        .reserve0_valid      (reserve0_valid),
        .reserve0_ready      (reserve0_ready),
        .reserve0_uop_id     (reserve0_uop_id),
        .reserve0_pc         (reserve0_pc),
        .reserve0_store_mask (reserve0_store_mask),
        .reserve0_src1_ready (reserve0_src1_ready),
        .reserve0_src1_value (reserve0_src1_value),
        .reserve0_src1_id    (reserve0_src1_id),
        .reserve1_valid      (reserve1_valid),
        .reserve1_ready      (reserve1_ready),
        .reserve1_uop_id     (reserve1_uop_id),
        .reserve1_pc         (reserve1_pc),
        .reserve1_store_mask (reserve1_store_mask),
        .reserve1_src1_ready (reserve1_src1_ready),
        .reserve1_src1_value (reserve1_src1_value),
        .reserve1_src1_id    (reserve1_src1_id),
        .store_reserve_credit(store_reserve_credit)
    );

    // Lane1's held execution packet is either an ALU/MDU operation or a
    // memory operation, so these sources are mutually exclusive by design.
    // Keep one explicit ownership mux at the backend completion boundary.
    always_comb begin
        issue1_completion = issue1_lsu_completion.valid ?
                            issue1_lsu_completion : issue1_exec_completion;
    end


    OooBackend u_ooo_backend (
        .clk                 (cpu_clk),
        .rstn                (cpu_rstn),
        .flush               (pipeline_flush),
        .system_flush        (recovery_event.system_flush),
        .redirect_valid      (redirect_valid),
        .decode_valid        (decode_valid),
        .decode_ready        (decode_ready),
        .decode_uop0         (decode_uop0),
        .decode_uop1         (decode_uop1),
         .recover_valid       (recover_valid),
         .recover_id          (recover_id),
        .main_complete       (main_completion),
        .issue1_complete     (issue1_completion),
        .system_complete     (system_completion),
        .issue0_valid    (issue0_valid),
        .issue0_ready    (issue0_ready),
        .issue0_fire     (issue0_fire),
        .issue0          (issue0),
        .issue1_valid        (issue1_valid),
        .issue1_ready        (issue1_ready),
        .issue1_fire         (issue1_fire),
        .issue1              (issue1),
        .system_issue_valid  (system_issue_valid),
        .system_issue_ready  (system_issue_ready),
        .system_issue_fire   (system_issue_fire),
        .system_issue        (system_issue),
        .commit0             (commit0),
        .commit1             (commit1),
        .store_data_complete0(store_data_complete0),
        .store_data_complete1(store_data_complete1),
        .reserve0_valid      (reserve0_valid),
        .reserve0_ready      (reserve0_ready),
        .reserve0_uop_id     (reserve0_uop_id),
        .reserve0_pc         (reserve0_pc),
        .reserve0_store_mask (reserve0_store_mask),
        .reserve0_src1_ready (reserve0_src1_ready),
        .reserve0_src1_value (reserve0_src1_value),
        .reserve0_src1_id    (reserve0_src1_id),
        .reserve1_valid      (reserve1_valid),
        .reserve1_ready      (reserve1_ready),
        .reserve1_uop_id     (reserve1_uop_id),
        .reserve1_pc         (reserve1_pc),
        .reserve1_store_mask (reserve1_store_mask),
        .reserve1_src1_ready (reserve1_src1_ready),
        .reserve1_src1_value (reserve1_src1_value),
        .reserve1_src1_id    (reserve1_src1_id),
        .store_reserve_credit(store_reserve_credit),
        .perf_rob_occupancy  (perf_rob_occupancy),
        .perf_issue_occupancy(perf_issue_occupancy),
        .perf_rob_block      (perf_rob_block),
        .perf_issue_queue_block(perf_issue_queue_block),
        .perf_true_source_wait(perf_true_source_wait),
        .perf_source_wait_dep_load(perf_source_wait_dep_load),
        .perf_source_wait_dep_muldiv(perf_source_wait_dep_muldiv),
        .perf_source_wait_dep_alu(perf_source_wait_dep_alu),
        .perf_source_wait_dep_branch(perf_source_wait_dep_branch),
        .perf_source_wait_store_addr(perf_source_wait_store_addr),
        .perf_source_wait_store_data(perf_source_wait_store_data),
        .perf_iq_no_ready(perf_iq_no_ready),
        .perf_lsu_order      (perf_lsu_order),
        .perf_serializing    (perf_serializing),
        .perf_dispatch_fire0 (perf_dispatch_fire0),
        .perf_dispatch_fire1 (perf_dispatch_fire1),
        .perf_serializing_block(),
        .rob_head_valid      (rob_head_valid),
        .rob_head_id         (rob_head_id)
    );

    AddressTranslate u_ifetch_translate (
        .vaddr     (frontend_ifetch_addr),
        .is_fetch  (1'b1),
        .crmd      (privilege_state.crmd),
        .dmw0      (privilege_state.dmw0),
        .dmw1      (privilege_state.dmw1),
        .paddr     (translated_ifetch_addr),
        .mat       (ifetch_mat),
        .cacheable (ifetch_cacheable),
        .dmw_hit   (ifetch_dmw_hit),
        .page_miss (ifetch_page_miss)
    );

    AddressTranslate u_daccess_translate (
        .vaddr     (dcache_req.addr),
        .is_fetch  (1'b0),
        .crmd      (privilege_state.crmd),
        .dmw0      (privilege_state.dmw0),
        .dmw1      (privilege_state.dmw1),
        .paddr     (translated_daccess_addr),
        .mat       (daccess_mat),
        .cacheable (daccess_cacheable),
        .dmw_hit   (daccess_dmw_hit),
        .page_miss (daccess_page_miss)
    );

    AddressTranslate u_system_translate (
        .vaddr     (system_effective_addr),
        .is_fetch  (system_issue.cacop_op[2:0] == 3'd0),
        .crmd      (privilege_state.crmd),
        .dmw0      (privilege_state.dmw0),
        .dmw1      (privilege_state.dmw1),
        .paddr     (translated_system_addr),
        .mat       (system_mat),
        .cacheable (),
        .dmw_hit   (system_dmw_hit),
        .page_miss (system_page_miss)
    );

    assign system_issue_ready = privilege_req_ready;
    assign system_redirect_valid = privilege_rsp.valid &&
                                   privilege_rsp.redirect_valid;

    always_comb begin
        privilege_req = '0;
        privilege_req.valid = system_issue_fire;
        privilege_req.system_op = system_issue.system_op;
        privilege_req.uop_id = system_issue.uop_id;
        privilege_req.source_value = system_issue.src0_value;
        privilege_req.mask_value = system_issue.src1_value;
        privilege_req.csr_num = system_issue.csr_num;
        privilege_req.cacop_op = system_issue.cacop_op;
        privilege_req.address = translated_system_addr;
        privilege_req.pc = system_issue.pc;

        system_completion = '0;
        system_completion.valid = privilege_rsp.valid;
        system_completion.uop_id = privilege_rsp.uop_id;
        system_completion.value = privilege_rsp.result;
        system_completion.reg_write = privilege_rsp.reg_write;

    end

    PrivilegeSystem u_privilege_system (
        .cpu_clk (cpu_clk),
        .cpu_rstn(cpu_rstn),
        .req     (privilege_req),
        .req_ready(privilege_req_ready),
        .rsp     (privilege_rsp),
        .state   (privilege_state),
        .busy    (privilege_busy),
        .icache_maint_valid(icache_maint_valid),
        .icache_maint_ready(icache_maint_ready),
        .icache_maint_done (icache_maint_done),
        .dcache_maint_valid(dcache_maint_valid),
        .dcache_maint_ready(dcache_maint_ready),
        .dcache_maint_done (dcache_maint_done),
        .cache_maint_all   (cache_maint_all),
        .cache_maint_mode  (cache_maint_mode),
        .cache_maint_addr  (cache_maint_addr),
        .cache_maint_ctag  (cache_maint_ctag)
    );


    ///////////////////////////////////////////////////////////////////////////
    // Trace Debug Interface
    // RegisterFile Write

`ifdef SYNTHESIS
    // The physical board does not consume the trace stream. Keep a compact
    // direct view in hardware while simulation uses the lossless serializer.
    assign debug0_wb_pc = commit0.pc;
    assign debug0_wb_rf_wen = {4{commit0.valid && commit0.reg_write}};
    assign debug0_wb_rf_wnum = commit0.arch_rd;
    assign debug0_wb_rf_wdata = commit0.value;
    assign debug0_wb_inst = 32'h0000_0000;
`endif

    ///////////////////////////////////////////////////////////////////////////

endmodule
