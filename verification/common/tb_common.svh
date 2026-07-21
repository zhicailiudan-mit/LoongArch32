`ifndef LOONG_UNIT_TB_COMMON_SVH
`define LOONG_UNIT_TB_COMMON_SVH

task automatic tb_expect(input bit condition, input string message);
    if (!condition) begin
        $display("[UNIT-FAIL] %s", message);
        $fatal(2);
        $finish;
    end
endtask

task automatic tb_note(input string message);
    $display("[UNIT] %s", message);
endtask

`endif
