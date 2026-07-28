`ifndef CPU_TYPES_PKG_SV
`define CPU_TYPES_PKG_SV

`include "defines.vh"

package cpu_types_pkg;

    typedef struct packed {
        logic [`UOP_EPOCH_W-1:0] epoch;
        logic [`ROB_TAG_W-1:0]   rob_tag;
    } uop_id_t;

    function automatic logic uop_id_equal(input uop_id_t a, input uop_id_t b);
        uop_id_equal = (a == b);
    endfunction

    // The identifier is a wrapping allocation sequence.  With at most
    // ROB_DEPTH live instructions, a non-zero forward distance smaller than
    // half of the identifier space unambiguously means "younger".
    function automatic logic uop_is_younger(input uop_id_t candidate,
                                             input uop_id_t boundary);
        logic [`UOP_ID_W-1:0] distance;
        begin
            distance = candidate - boundary;
            uop_is_younger = (distance != 0) &&
                             !distance[`UOP_ID_W-1];
        end
    endfunction

    // The source fields are intentionally declared in the order used by the
    // the existing decode field order: value, architectural register, used.
    typedef struct packed {
        logic [31:0] value;
        logic [4:0]  arch_reg;
        logic        used;
    } decoded_src_t;

    // The current decode field order places ras_ptr before the remaining
    // prediction fields.
    typedef struct packed {
        logic [2:0]  ras_ptr;
        logic        valid;
        logic        taken;
        logic [31:0] target;
        logic [9:0]  index;
        logic [2:0]  ras_sp_before;
        logic [3:0]  ras_count_before;
        // Observation-only: BTB lookup result sampled with this instruction.
        // It is never consumed by functional control.
        logic        perf_btb_hit;
    } prediction_meta_t;

    // Frontend packet in the same field order as the existing IF_ID packet:
    // pc, instruction, then the prediction/RAS metadata.
    typedef struct packed {
        logic [31:0] pc;
        logic [31:0] instruction;
        prediction_meta_t pred;
    } fetch_uop_t;

    typedef enum logic [2:0] {
        SYS_NONE     = 3'd0,
        SYS_CPUCFG   = 3'd1,
        SYS_CACOP    = 3'd2,
        SYS_CSRWR    = 3'd3,
        SYS_CSRXCHG  = 3'd4,
        SYS_CSRRD    = 3'd5
    } system_op_e;

    typedef enum logic [2:0] {
        PROD_UNKNOWN = 3'd0,
        PROD_ALU     = 3'd1,
        PROD_LOAD    = 3'd2,
        PROD_MULDIV  = 3'd3,
        PROD_BRANCH  = 3'd4
    } producer_type_e;

    typedef struct packed {
        logic [31:0] pc;
        decoded_src_t src0;
        decoded_src_t src1;
        logic [31:0] imm;
        logic [1:0]  npc_op;
        logic        reg_write;
        logic [4:0]  arch_rd;
        logic [1:0]  result_sel;
        logic [4:0]  alu_op;
        logic        src_a_sel;
        logic        src_b_sel;
        logic [3:0]  store_mask;
        logic [2:0]  load_ext_op;
        logic        is_br_jmp;
        logic        is_ld_st;
        logic        is_call;
        logic        is_ret;
        system_op_e  system_op;
        logic [13:0] csr_num;
        logic [4:0]  cacop_op;
        logic        serializing;
        prediction_meta_t pred;
    } decoded_uop_t;

    typedef struct packed {
        uop_id_t uop_id;
        logic [31:0] pc;
        logic [31:0] src0_value;
        logic [31:0] src1_value;
        logic        src1_ready;
        uop_id_t     src1_id;
        logic [4:0]  arch_rs1;
        logic [4:0]  arch_rs2;
        logic        src0_used;
        logic        src1_used;
        logic [31:0] imm;
        logic [1:0]  npc_op;
        logic        reg_write;
        logic [4:0]  arch_rd;
        logic [1:0]  result_sel;
        logic [4:0]  alu_op;
        logic        src_a_sel;
        logic        src_b_sel;
        logic [3:0]  store_mask;
        logic [2:0]  load_ext_op;
        logic        is_br_jmp;
        logic        is_ld_st;
        logic        is_call;
        logic        is_ret;
        system_op_e  system_op;
        logic [13:0] csr_num;
        logic [4:0]  cacop_op;
        logic        serializing;
        prediction_meta_t pred;
    } issue_uop_t;

    // Rename-to-scheduler packet. A lane is one packet; lane numbering is
    // carried by the array index at the module boundary instead of being
    // repeated in every field name.
    typedef struct packed {
        logic                    valid;
        logic                    src0_ready;
        uop_id_t                 src0_id;
        logic                    src1_ready;
        uop_id_t                 src1_id;
        issue_uop_t              uop;
    } dispatch_uop_t;

    typedef struct packed {
        logic                    valid;
        uop_id_t                 uop_id;
        logic [31:0]             value;
        logic                    reg_write;
    } completion_t;

    // LSU queue entry.  This contains only information already present on
    // execute_result_t; the queues add no architectural state or ordering
    // semantics on their own.
    typedef struct packed {
        logic                    valid;
        uop_id_t                 uop_id;
        logic [31:0]             pc;
        logic [31:0]             address;
        logic [31:0]             store_data;
        logic [3:0]              store_wen;
        logic [2:0]              load_ext_op;
        logic                    reg_write;
        logic [4:0]              arch_rd;
        logic                    store_data_ready;
        uop_id_t                 store_data_src_id;
    } lsu_entry_t;

    typedef struct packed {
        uop_id_t uop_id;
        logic        valid;
        logic [31:0] pc;
        logic        has_dest;
        logic        reg_write;
        logic [4:0]  arch_rd;
        logic [31:0] value;
    } commit_t;

    // One recovery event is shared by frontend, rename/ROB, LSU and debug
    // routing.  branch_flush identifies the resolving branch event that must
    // still be allowed to complete in the same cycle.
    typedef struct packed {
        logic                    redirect_valid;
        logic                    pipeline_flush;
        logic                    recover_valid;
        logic                    branch_flush;
        logic                    system_flush;
        logic [31:0]             redirect_target;
        uop_id_t                 recover_id;
    } recovery_event_t;

    // Main execution result.  These fields are the existing integer/branch outputs
    // grouped only for the execute-to-memory and execute-to-frontend links.
    typedef struct packed {
        logic                    valid;
        uop_id_t                 uop_id;
        logic [31:0]             pc;
        logic [31:0]             src0_value;
        logic [31:0]             src1_value;
        logic                    store_data_ready;
        uop_id_t                 store_data_src_id;
        logic [31:0]             imm;
        logic [31:0]             alu_result;
        logic                    reg_write;
        logic [4:0]              arch_rd;
        logic [1:0]              result_sel;
        logic [3:0]              store_mask;
        logic [2:0]              load_ext_op;
        logic                    is_ld_st;
        logic                    ldst_unalign;
        logic [1:0]              npc_op;
        logic                    alu_flag;
        logic                    is_br_jmp;
        logic                    is_call;
        logic                    is_ret;
        logic [2:0]              ras_ptr;
        logic                    branch_taken;
        logic [31:0]             branch_target;
        logic [31:0]             writeback_value;
        logic                    select_ram;
    } execute_result_t;

    // Existing external data-access request/response pins, grouped without
    // changing the bus protocol or its handshake semantics.
    typedef struct packed {
        logic [3:0]  ren;
        logic [31:0] addr;
        logic [3:0]  wen;
        logic [31:0] wdata;
    } memory_request_t;

    typedef struct packed {
        logic        rready;
        logic        valid;
        logic [31:0] rdata;
        logic        wready;
        logic        wposted;
        logic        wresp;
    } memory_response_t;

    typedef struct packed {
        logic                    valid;
        system_op_e              system_op;
        uop_id_t                 uop_id;
        logic [31:0]             source_value;
        logic [31:0]             mask_value;
        logic [13:0]             csr_num;
        logic [4:0]              cacop_op;
        logic [31:0]             address;
        logic [31:0]             pc;
    } privilege_req_t;

    typedef struct packed {
        logic                    valid;
        uop_id_t                 uop_id;
        logic [31:0]             result;
        logic                    reg_write;
        logic                    exception_valid;
        logic [5:0]              exception_code;
        logic [9:0]              exception_subcode;
        logic                    serializing;
        logic                    redirect_valid;
        logic [31:0]             redirect_target;
    } privilege_rsp_t;

    typedef struct packed {
        logic [31:0]             crmd;
        logic [31:0]             dmw0;
        logic [31:0]             dmw1;
        logic [31:0]             ctag;
    } privilege_state_t;

    localparam int DECODED_UOP_W = $bits(decoded_uop_t);
    localparam int ISSUE_UOP_W   = $bits(issue_uop_t);

endpackage

`endif
