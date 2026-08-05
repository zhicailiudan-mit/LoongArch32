`timescale 1ns / 1ps

import cpu_types_pkg::*;

module PrivilegeSystem (
    input  logic             cpu_clk,
    input  logic             cpu_rstn,

    input  privilege_req_t   req,
    output logic             req_ready,
    output privilege_rsp_t   rsp,
    output privilege_state_t state,
    output logic             busy,

    output logic             icache_maint_valid,
    input  logic             icache_maint_ready,
    input  logic             icache_maint_done,
    output logic             dcache_maint_valid,
    input  logic             dcache_maint_ready,
    input  logic             dcache_maint_done,
    output logic             cache_maint_all,
    output logic [1:0]       cache_maint_mode,
    output logic [31:0]      cache_maint_addr,
    output logic [31:0]      cache_maint_ctag
);

    localparam logic [13:0] CSR_CRMD = 14'h0000;
    localparam logic [13:0] CSR_CTAG = 14'h0098;
    localparam logic [13:0] CSR_DMW0 = 14'h0180;
    localparam logic [13:0] CSR_DMW1 = 14'h0181;

    localparam logic [1:0] PS_IDLE = 2'd0;
    localparam logic [1:0] PS_SEND = 2'd1;
    localparam logic [1:0] PS_WAIT = 2'd2;

    logic [1:0] ps_state;
    privilege_state_t state_r;
    privilege_rsp_t rsp_r;
    uop_id_t pending_uop_id;
    logic [31:0] pending_pc;
    logic [31:0] pending_result;
    logic pending_reg_write;
    logic need_icache, need_dcache;
    logic icache_sent, dcache_sent;
    logic icache_finished, dcache_finished;
    logic pending_all;
    logic [1:0] pending_mode;
    logic [31:0] pending_addr;

    // The cache maintenance handshake (maint_valid -> cache -> maint_done)
    // crosses into the dcache/L2 whose flush/refill burst machinery forms a
    // deep combinational chain (FSM -> invalidate -> burst counters -> BRAM
    // address).  The valid is registered at the boundary so the maintenance
    // FSM's combinational output terminates at a register; the handshake is
    // level-based and the FSM advances only on the registered valid, so the
    // +1 latency on the (rare, serialized) maintenance op changes nothing.
    logic icache_maint_valid_c;
    logic dcache_maint_valid_c;
    logic icache_maint_valid_q;
    logic dcache_maint_valid_q;

    logic [31:0] csr_old_value;
    logic [31:0] csr_write_mask;
    logic [31:0] csr_exchange_mask;
    logic [31:0] csr_new_value;
    logic [31:0] cpucfg_value;
    logic csr_changes_mapping;
    logic req_is_privileged;
    logic privilege_fault;

    assign state = state_r;
    assign rsp = rsp_r;
    assign req_ready = (ps_state == PS_IDLE);
    assign busy = (ps_state != PS_IDLE);

    always_comb begin
        case (req.csr_num)
            CSR_CRMD: csr_old_value = state_r.crmd;
            CSR_CTAG: csr_old_value = state_r.ctag;
            CSR_DMW0: csr_old_value = state_r.dmw0;
            CSR_DMW1: csr_old_value = state_r.dmw1;
            default:  csr_old_value = 32'h0000_0000;
        endcase

        case (req.csr_num)
            CSR_CRMD: csr_write_mask = 32'h0000_03ff;
            CSR_CTAG: csr_write_mask = 32'hffff_ffff;
            CSR_DMW0,
            CSR_DMW1: csr_write_mask = 32'hee00_0039;
            default:  csr_write_mask = 32'h0000_0000;
        endcase

        csr_exchange_mask = req.mask_value & csr_write_mask;
        if (req.system_op == SYS_CSRXCHG)
            csr_new_value = (csr_old_value & ~csr_exchange_mask) |
                            (req.source_value & csr_exchange_mask);
        else
            csr_new_value = (csr_old_value & ~csr_write_mask) |
                            (req.source_value & csr_write_mask);

        // LA32, 32-bit PA/VA.  Both implemented caches have 32-byte lines,
        // 32 indices and one way (1 KiB per cache).  CPUCFG indices are
        // hexadecimal architectural indices, not decimal 10/11/12.
        case (req.source_value[5:0])
            6'd0:  cpucfg_value = 32'h0000_0000;
            6'd1:  cpucfg_value = 32'h0001_f1f0;
            6'h10: cpucfg_value = 32'h0000_0005;
            6'h11: cpucfg_value = 32'h0505_0000;
            6'h12: cpucfg_value = 32'h0505_0000;
            default: cpucfg_value = 32'h0000_0000;
        endcase

        csr_changes_mapping = ((req.system_op == SYS_CSRWR) ||
                               (req.system_op == SYS_CSRXCHG)) &&
                              ((req.csr_num == CSR_CRMD) ||
                               (req.csr_num == CSR_DMW0) ||
                               (req.csr_num == CSR_DMW1));
        req_is_privileged = (req.system_op == SYS_CACOP) ||
                            (req.system_op == SYS_CSRWR) ||
                            (req.system_op == SYS_CSRXCHG) ||
                            (req.system_op == SYS_CSRRD);
        privilege_fault = req_is_privileged && (state_r.crmd[1:0] != 2'b00);
    end

    always_comb begin
        icache_maint_valid_c = (ps_state == PS_SEND) && need_icache && !icache_sent;
        dcache_maint_valid_c = (ps_state == PS_SEND) && need_dcache && !dcache_sent;
        cache_maint_all = pending_all;
        cache_maint_mode = pending_mode;
        cache_maint_addr = pending_addr;
        cache_maint_ctag = state_r.ctag;
    end

    assign icache_maint_valid = icache_maint_valid_q;
    assign dcache_maint_valid = dcache_maint_valid_q;

    always_ff @(posedge cpu_clk or negedge cpu_rstn) begin
        if (!cpu_rstn) begin
            ps_state <= PS_IDLE;
            // Direct-address mode with the existing cacheable MAT setting.
            // The privilege placeholder must preserve the pre-existing
            // instruction/data-cache behavior until CSR semantics are enabled.
            // DA=1, PG=0; DATF=01 and DATM=01.  The old 0x88 value left
            // DATF=00, making every instruction request uncached even though
            // the ICache hit pipeline and refill arrays were enabled.
            state_r.crmd <= 32'h0000_00a8;
            state_r.dmw0 <= 32'h0000_0000;
            state_r.dmw1 <= 32'h0000_0000;
            state_r.ctag <= 32'h0000_0000;
            rsp_r <= '0;
            pending_uop_id <= '0;
            pending_pc <= 32'h0000_0000;
            pending_result <= 32'h0000_0000;
            pending_reg_write <= 1'b0;
            need_icache <= 1'b0;
            need_dcache <= 1'b0;
            icache_sent <= 1'b0;
            dcache_sent <= 1'b0;
            icache_finished <= 1'b0;
            dcache_finished <= 1'b0;
            pending_all <= 1'b0;
            pending_mode <= 2'b00;
            pending_addr <= 32'h0000_0000;
            icache_maint_valid_q <= 1'b0;
            dcache_maint_valid_q <= 1'b0;
        end else begin
            rsp_r <= '0;
            icache_maint_valid_q <= icache_maint_valid_c;
            dcache_maint_valid_q <= dcache_maint_valid_c;

            case (ps_state)
                PS_IDLE: begin
                    if (req.valid) begin
                        pending_uop_id <= req.uop_id;
                        pending_pc <= req.pc;
                        pending_result <= (req.system_op == SYS_CPUCFG) ?
                                          cpucfg_value : csr_old_value;
                        pending_reg_write <= (req.system_op != SYS_CACOP);
                        icache_sent <= 1'b0;
                        dcache_sent <= 1'b0;
                        icache_finished <= 1'b0;
                        dcache_finished <= 1'b0;
                        need_icache <= 1'b0;
                        need_dcache <= 1'b0;
                        pending_all <= 1'b0;
                        pending_mode <= req.cacop_op[4:3];
                        pending_addr <= req.address;

                        if (privilege_fault) begin
                            rsp_r.valid <= 1'b1;
                            rsp_r.uop_id <= req.uop_id;
                            rsp_r.result <= 32'h0000_0000;
                            rsp_r.reg_write <= 1'b0;
                            rsp_r.exception_valid <= 1'b1;
                            rsp_r.exception_code <= 6'h0d;
                            rsp_r.serializing <= 1'b1;
                        end else begin
                            if ((req.system_op == SYS_CSRWR) ||
                                (req.system_op == SYS_CSRXCHG)) begin
                                case (req.csr_num)
                                    CSR_CRMD: state_r.crmd <= csr_new_value;
                                    CSR_CTAG: state_r.ctag <= csr_new_value;
                                    CSR_DMW0: state_r.dmw0 <= csr_new_value;
                                    CSR_DMW1: state_r.dmw1 <= csr_new_value;
                                    default: begin end
                                endcase
                            end

                            if (csr_changes_mapping) begin
                                need_icache <= 1'b1;
                                need_dcache <= 1'b1;
                                pending_all <= 1'b1;
                                pending_mode <= 2'b01;
                                ps_state <= PS_SEND;
                            end else if (req.system_op == SYS_CACOP) begin
                                case (req.cacop_op[2:0])
                                    3'd0: need_icache <= 1'b1;
                                    3'd1: need_dcache <= 1'b1;
                                    3'd2: begin
                                        need_icache <= 1'b1;
                                        need_dcache <= 1'b1;
                                    end
                                    default: begin end
                                endcase

                                if (req.cacop_op[2:0] <= 3'd2)
                                    ps_state <= PS_SEND;
                                else begin
                                    rsp_r.valid <= 1'b1;
                                    rsp_r.uop_id <= req.uop_id;
                                    rsp_r.reg_write <= 1'b0;
                                    rsp_r.serializing <= 1'b1;
                                    rsp_r.redirect_valid <= 1'b1;
                                    rsp_r.redirect_target <= req.pc + 32'd4;
                                end
                            end else begin
                                rsp_r.valid <= 1'b1;
                                rsp_r.uop_id <= req.uop_id;
                                rsp_r.result <= (req.system_op == SYS_CPUCFG) ?
                                                cpucfg_value : csr_old_value;
                                rsp_r.reg_write <= (req.system_op != SYS_CACOP);
                                rsp_r.serializing <= 1'b1;
                            end
                        end
                    end
                end

                PS_SEND: begin
                    if (icache_maint_valid && icache_maint_ready)
                        icache_sent <= 1'b1;
                    if (dcache_maint_valid && dcache_maint_ready)
                        dcache_sent <= 1'b1;

                    if ((!need_icache || icache_sent || icache_maint_ready) &&
                        (!need_dcache || dcache_sent || dcache_maint_ready))
                        ps_state <= PS_WAIT;
                end

                PS_WAIT: begin
                    if (icache_maint_done)
                        icache_finished <= 1'b1;
                    if (dcache_maint_done)
                        dcache_finished <= 1'b1;

                    if ((!need_icache || icache_finished || icache_maint_done) &&
                        (!need_dcache || dcache_finished || dcache_maint_done)) begin
                        rsp_r.valid <= 1'b1;
                        rsp_r.uop_id <= pending_uop_id;
                        rsp_r.result <= pending_result;
                        rsp_r.reg_write <= pending_reg_write;
                        rsp_r.serializing <= 1'b1;
                        rsp_r.redirect_valid <= 1'b1;
                        rsp_r.redirect_target <= pending_pc + 32'd4;
                        ps_state <= PS_IDLE;
                    end
                end

                default: ps_state <= PS_IDLE;
            endcase
        end
    end

endmodule
