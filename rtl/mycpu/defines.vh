`ifndef DEFINES_VH
`define DEFINES_VH

`define ENABLE_ICACHE
`define ENABLE_DCACHE
`define ENABLE_BPU

// The out-of-order backend can retire two architectural register writes per
// cycle.  Enable the matching two-wide simulation checker by default.  Comment
// this define only when running an unmodified, legacy one-wide testbench.
`define DUAL_COMMIT_TRACE

// Backend sizing shared by ROB, RAT, issue queue and pipeline tags.
`define ROB_DEPTH 32
`define ROB_TAG_W 5
`define UOP_EPOCH_W 2
`define UOP_ID_W (`UOP_EPOCH_W + `ROB_TAG_W)

`define CACHE_BLK_LEN   8
`define CACHE_BLK_SIZE  (`CACHE_BLK_LEN*32)
`define CACHE_BLK_NUM   32

`define PC_INIT_VAL 32'h1c000000

`define NPC_PC4     2'b00
`define NPC_ALU     2'b01
`define NPC_RET     2'b10
`define NPC_CALL    2'b11

`define EXT_5_Z       3'b000
`define EXT_12_S      3'b001
`define EXT_12_Z      3'b010
`define EXT_16_S      3'b011
`define EXT_26_S      3'b100
`define EXT_20        3'b110

`define ALU_ADD     5'b00000
`define ALU_SUB     5'b00001
`define ALU_AND     5'b00010
`define ALU_OR      5'b00011
`define ALU_XOR     5'b00100
`define ALU_COM     5'b00101
`define ALU_UCOM    5'b00110
`define ALU_SLL     5'b00111
`define ALU_SRL     5'b01000
`define ALU_SRA     5'b01001
`define ALU_COP     5'b01010
`define ALU_EQU     5'b01011
`define ALU_UEQU    5'b01100
`define ALU_LES     5'b01101
`define ALU_ULES    5'b01110
`define ALU_MOR     5'b01111
`define ALU_UMOR    5'b10000
`define ALU_PC4     5'b10001
`define ALU_MULL    5'b10010
`define ALU_MULH    5'b10011
`define ALU_UMUL    5'b10100
`define ALU_NOR     5'b11001






`define N_RAM_EXT   3'b000
`define RAM_EXT_B_Z 3'b001
`define RAM_EXT_B_S 3'b010
`define RAM_EXT_H_Z 3'b011
`define RAM_EXT_H_S 3'b100
`define RAM_EXT_N   3'b101



`define RAM_WE_N    4'b0000
`define RAM_WE_B    4'b0001
`define RAM_WE_H    4'b0011
`define RAM_WE_W    4'b1111

`define R2_RK       1'b1
`define R2_RD       1'b0

`define ALUA_R1     1'b1
`define ALUA_PC     1'b0

`define ALUB_R2     1'b1
`define ALUB_EXT    1'b0

`define WR_RD       1'b1
`define WR_Rr1      1'b0

`define WD_ALU      2'b11
`define WD_RAM      2'b01


`endif
