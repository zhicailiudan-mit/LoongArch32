`timescale 1ns / 1ps

`include "defines.vh"
import cpu_types_pkg::*;

// Single recovery-event arbiter.  All consumers use the same selected
// redirect target/tag and flush classification.
module GlobalControl (
    input  logic                       branch_mispredict,
    input  logic                       branch_redirect_valid,
    input  logic [31:0]                branch_redirect_target,
    input  logic                       branch_pipeline_flush,
    input  uop_id_t                    branch_recover_id,
    input  logic                       system_redirect_valid,
    input  logic [31:0]                system_redirect_target,
    input  uop_id_t                    system_recover_id,
    output logic                       pred_error,
    output recovery_event_t            recovery_event
);

    always_comb begin
        recovery_event = '0;
        recovery_event.redirect_valid = system_redirect_valid |
                                        branch_redirect_valid;
        recovery_event.redirect_target = system_redirect_valid ?
                                         system_redirect_target :
                                         branch_redirect_target;
        recovery_event.pipeline_flush = branch_pipeline_flush |
                                        system_redirect_valid;
        recovery_event.recover_valid = branch_mispredict |
                                       system_redirect_valid;
        recovery_event.recover_id = system_redirect_valid ?
                                     system_recover_id : branch_recover_id;
        recovery_event.system_flush = system_redirect_valid;
        recovery_event.branch_flush = branch_pipeline_flush &&
                                      !system_redirect_valid;
        pred_error = recovery_event.redirect_valid;
    end

endmodule
