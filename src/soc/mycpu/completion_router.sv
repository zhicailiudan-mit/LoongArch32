`timescale 1ns / 1ps

`include "defines.vh"

import cpu_types_pkg::*;

// Single completion routing point.  System/privilege completion shares the
// lane-0 ROB path with the LSU completion; system completion has priority,
// matching the existing serializing-system behavior.  Both routed lanes are
// filtered against the live ROB mask after selection.
module CompletionRouter (
    input  completion_t             main_complete_in,
    input  completion_t             system_complete_in,
    input  completion_t             issue1_complete_in,
    input  logic [`ROB_DEPTH-1:0]   rob_live_mask,
    output completion_t             complete0,
    output completion_t             complete1
);
    completion_t lane0_source;

    always_comb begin
        lane0_source = system_complete_in.valid ?
                       system_complete_in : main_complete_in;

        complete0 = lane0_source;
        complete0.valid = lane0_source.valid &&
                          rob_live_mask[lane0_source.uop_id.rob_tag];
        complete1 = issue1_complete_in;
        complete1.valid = issue1_complete_in.valid &&
                          rob_live_mask[issue1_complete_in.uop_id.rob_tag];
    end

endmodule
