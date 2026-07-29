`ifndef SOC_VERIFY_TEST_PROFILE_VH
`define SOC_VERIFY_TEST_PROFILE_VH

// Select exactly one test profile.  Change only this line before elaborating
// the soc_verify simulation; the MIF and reference traces switch together.
//`define TEST_PROFILE_STREAM
//`define TEST_PROFILE_MATRIX
//`define TEST_PROFILE_CRYPTONIGHT
`define TEST_PROFILE_MIXED
//`define TEST_PROFILE_COMPREHENSIVE

`ifdef TEST_PROFILE_STREAM
  `define SRAM_INIT_FILE        "C:/Users/wanlinc/Desktop/Me/Loogn cpu v1/func_test/func/obj/inst_ram_stream.mif"
  `define TRACE_REF_FILE        "C:/Users/wanlinc/Desktop/Me/Loogn cpu v1/func_test/gettrace/golden_trace_stream.txt"
  `define TRACE_REF_WDATA_FILE  "C:/Users/wanlinc/Desktop/Me/Loogn cpu v1/func_test/gettrace/golden_trace_wdata_stream.txt"
  `define TRACE_REF_BJ_FILE     "C:/Users/wanlinc/Desktop/Me/Loogn cpu v1/func_test/gettrace/golden_trace_bj_stream.txt"
`elsif TEST_PROFILE_MATRIX
  `define SRAM_INIT_FILE        "C:/Users/wanlinc/Desktop/Me/Loogn cpu v1/func_test/func/obj/inst_ram_matrix.mif"
  `define TRACE_REF_FILE        "C:/Users/wanlinc/Desktop/Me/Loogn cpu v1/func_test/gettrace/golden_trace_matrix.txt"
  `define TRACE_REF_WDATA_FILE  "C:/Users/wanlinc/Desktop/Me/Loogn cpu v1/func_test/gettrace/golden_trace_wdata_matrix.txt"
  `define TRACE_REF_BJ_FILE     "C:/Users/wanlinc/Desktop/Me/Loogn cpu v1/func_test/gettrace/golden_trace_bj_matrix.txt"
`elsif TEST_PROFILE_CRYPTONIGHT
  `define SRAM_INIT_FILE        "C:/Users/wanlinc/Desktop/Me/Loogn cpu v1/func_test/func/obj/inst_ram_cryptonight.mif"
  `define TRACE_REF_FILE        "C:/Users/wanlinc/Desktop/Me/Loogn cpu v1/func_test/gettrace/golden_trace_cryptonight.txt"
  `define TRACE_REF_WDATA_FILE  "C:/Users/wanlinc/Desktop/Me/Loogn cpu v1/func_test/gettrace/golden_trace_wdata_cryptonight.txt"
  `define TRACE_REF_BJ_FILE     "C:/Users/wanlinc/Desktop/Me/Loogn cpu v1/func_test/gettrace/golden_trace_bj_cryptonight.txt"
`elsif TEST_PROFILE_MIXED
  `define SRAM_INIT_FILE        "C:/Users/wanlinc/Desktop/Me/Loogn cpu v1/func_test/func/obj/inst_ram_mixed.mif"
  `define TRACE_REF_FILE        "C:/Users/wanlinc/Desktop/Me/Loogn cpu v1/func_test/gettrace/golden_trace_mixed.txt"
  `define TRACE_REF_WDATA_FILE  "C:/Users/wanlinc/Desktop/Me/Loogn cpu v1/func_test/gettrace/golden_trace_wdata_mixed.txt"
  `define TRACE_REF_BJ_FILE     "C:/Users/wanlinc/Desktop/Me/Loogn cpu v1/func_test/gettrace/golden_trace_bj_mixed.txt"
`elsif TEST_PROFILE_COMPREHENSIVE
  `define SRAM_INIT_FILE        "C:/Users/wanlinc/Desktop/Me/Loogn cpu v1/func_test/func/obj/inst_ram.mif"
  `define TRACE_REF_FILE        "C:/Users/wanlinc/Desktop/Me/Loogn cpu v1/func_test/gettrace/golden_trace_comprehensive.txt"
  `define TRACE_REF_WDATA_FILE  "C:/Users/wanlinc/Desktop/Me/Loogn cpu v1/func_test/gettrace/golden_trace_wdata_comprehensive.txt"
  `define TRACE_REF_BJ_FILE     "C:/Users/wanlinc/Desktop/Me/Loogn cpu v1/func_test/gettrace/golden_trace_bj_comprehensive.txt"
`else
  `define SRAM_INIT_FILE        "C:/Users/wanlinc/Desktop/Me/Loogn cpu v1/func_test/func/obj/inst_ram.mif"
  `define TRACE_REF_FILE        "C:/Users/wanlinc/Desktop/Me/Loogn cpu v1/func_test/gettrace/golden_trace.txt"
  `define TRACE_REF_WDATA_FILE  "C:/Users/wanlinc/Desktop/Me/Loogn cpu v1/func_test/gettrace/golden_trace_wdata.txt"
  `define TRACE_REF_BJ_FILE     "C:/Users/wanlinc/Desktop/Me/Loogn cpu v1/func_test/gettrace/golden_trace_bj.txt"
`endif

`endif
