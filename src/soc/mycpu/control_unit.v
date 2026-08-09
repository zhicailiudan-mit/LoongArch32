`timescale 1ns / 1ps

`include "mycpu_inst.vh"
`include "defines.vh"

module ControlUnit (
    input  wire [31:15] inst_31_15,
    output wire [ 1: 0] npc_op    ,
    output wire         is_br_jmp ,
    output wire         is_call   ,
    output wire         is_ret    ,
    output wire         is_ld_st  ,
    output wire [ 2: 0] ext_op    ,
    output wire         r2_sel    ,
    output wire         rR1_re    ,
    output wire         rR2_re    ,
    output wire         alua_sel  ,
    output wire         alub_sel  ,
    output wire [ 4: 0] alu_op    ,
    output wire [ 2: 0] ram_ext_op,
    output wire [ 3: 0] ram_we    ,
    output wire         rf_we     ,
    output wire         wr_sel    ,
    output wire         alu_suspend,
    output wire [ 1: 0] wd_sel    
);
    wire ADD_W     = (inst_31_15[31:15] == 17'h00020);
    wire SUB_W     = (inst_31_15[31:15] == 17'h00022);
    wire AND       = (inst_31_15[31:15] == 17'h00029); 
    wire OR        = (inst_31_15[31:15] == 17'h0002A); 
    wire XOR       = (inst_31_15[31:15] == 17'h0002B);
    wire NOR       = (inst_31_15[31:15] == 17'h00028);
    wire SLL_W     = (inst_31_15[31:15] == 17'h0002E);
    wire SRL_W     = (inst_31_15[31:15] == 17'h0002F);
    wire SRA_W     = (inst_31_15[31:15] == 17'h00030);
    wire SLT       = (inst_31_15[31:15] == 17'h00024);
    wire SLTU      = (inst_31_15[31:15] == 17'h00025);

    wire MUL_W     = (inst_31_15[31:15] == 17'h00038);
    wire MULH_W    = (inst_31_15[31:15] == 17'h00039);
    wire MULH_WU   = (inst_31_15[31:15] == 17'h0003A);
    
    wire SLLI_W    = (inst_31_15[31:15] == 17'h00081);   
    wire SRLI_W    = (inst_31_15[31:15] == 17'h00089);
    wire SRAI_W    = (inst_31_15[31:15] == 17'h00091);

    wire ADDI_W    = (inst_31_15[31:22] == 10'h00A  ); 
    wire ANDI      = (inst_31_15[31:22] == 10'h00D  );
    wire ORI       = (inst_31_15[31:22] == 10'h00E  );
    wire XORI      = (inst_31_15[31:22] == 10'h00F  );
    wire SLTI      = (inst_31_15[31:22] == 10'h008  );
    wire SLTUI     = (inst_31_15[31:22] == 10'h009  );
    wire LD_B      = (inst_31_15[31:22] == 10'h0A0  );
    wire LD_BU     = (inst_31_15[31:22] == 10'h0A8  );
    wire LD_H      = (inst_31_15[31:22] == 10'h0A1  );
    wire LD_HU     = (inst_31_15[31:22] == 10'h0A9  );
    wire LD_W      = (inst_31_15[31:22] == 10'h0A2  );
    wire ST_B      = (inst_31_15[31:22] == 10'h0A4  );
    wire ST_H      = (inst_31_15[31:22] == 10'h0A5  );
    wire ST_W      = (inst_31_15[31:22] == 10'h0A6  );

    wire LU12I_W   = (inst_31_15[31:25] == 7'h0A    );
    wire PCADDU12I = (inst_31_15[31:25] == 7'h0E    );
     
    wire BEQ       = (inst_31_15[31:26] == 6'h16    );
    wire BNE       = (inst_31_15[31:26] == 6'h17    );
    wire BLT       = (inst_31_15[31:26] == 6'h18    );
    wire BLTU      = (inst_31_15[31:26] == 6'h1A    );
    wire BGE       = (inst_31_15[31:26] == 6'h19    );
    wire BGEU      = (inst_31_15[31:26] == 6'h1B    );
    wire JIRL      = (inst_31_15[31:26] == 6'h13    );
    wire B         = (inst_31_15[31:26] == 6'h14    );
    wire BL        = (inst_31_15[31:26] == 6'h15    );


    wire TYPE_3R    = ADD_W | SUB_W | AND | OR | XOR | NOR | SLL_W | SRL_W | SRA_W | SLT | SLTU | MUL_W | MULH_W | MULH_WU;
    wire LOAD       = LD_B | LD_BU | LD_H | LD_HU | LD_W  ;
    wire STORE      = ST_B | ST_H | ST_W ;
    wire TYPE_2RI5  = SLLI_W | SRLI_W | SRAI_W ;
    wire TYPE_1RI20 = LU12I_W | PCADDU12I ;
    wire TYPE_2RI12 = ADDI_W | ANDI | ORI | XORI | SLTI | SLTUI ;
    wire is_branch  = BEQ | BNE | BLT | BLTU | BGE | BGEU;
    wire is_jump    = B | BL | JIRL;

    wire NPC_OP_PC4  = TYPE_3R | TYPE_1RI20 | LOAD | STORE | TYPE_2RI5 | TYPE_2RI12 ;
    wire NPC_OP_ALU  = BEQ | BNE | BLT | BLTU | BGE | BGEU ;
    wire NPC_OP_RET  = JIRL;
    wire NPC_OP_CALL = BL | B ;

    wire EXT_OP_12_S  = LOAD | STORE | ADDI_W | SLTI | SLTUI;
    wire EXT_OP_12_Z  = ORI | ANDI | XORI ;
    wire EXT_OP_16_S  = BEQ | BNE | BLT | BLTU | BGE | BGEU | JIRL ;
    wire EXT_OP_26_S  = B | BL ;
    wire EXT_OP_20    = PCADDU12I | LU12I_W ;
    wire EXT_OP_5_Z   = TYPE_2RI5 ;

    wire ALU_OP_ADD  = ADD_W | PCADDU12I | LOAD | STORE | ADDI_W;
    wire ALU_OP_SUB  = SUB_W ;
    wire ALU_OP_AND  = AND | ANDI ;
    wire ALU_OP_OR   = OR | ORI ;
    wire ALU_OP_XOR  = XOR | XORI ;
    wire ALU_OP_NOR  = NOR ;
    wire ALU_OP_COM  = SLT | SLTI  ;
    wire ALU_OP_UCOM = SLTU | SLTUI  ;
    wire ALU_OP_SLL  = SLLI_W | SLL_W ;
    wire ALU_OP_SRL  = SRL_W | SRLI_W ;
    wire ALU_OP_SRA  = SRA_W | SRAI_W ;
    wire ALU_OP_COP  = LU12I_W ;
    wire ALU_OP_EQU  = BEQ ;
    wire ALU_OP_UEQU = BNE ;
    wire ALU_OP_LES  = BLT ;
    wire ALU_OP_ULES = BLTU ;
    wire ALU_OP_MOR  = BGE ;
    wire ALU_OP_UMOR = BGEU ;  
    wire ALU_OP_PC4  = BL | JIRL;
    wire ALU_OP_MULL = MUL_W;
    wire ALU_OP_MULH = MULH_W;
    wire ALU_OP_UMUL = MULH_WU;
     
    wire ALPC = PCADDU12I | BL | JIRL ;
    
    wire WD_SEL_ALU = TYPE_3R | TYPE_2RI5 | TYPE_2RI12 | TYPE_1RI20 | BL | JIRL;
    wire WD_SEL_RAM = LOAD ;
    
    assign alu_suspend = MUL_W | MULH_W | MULH_WU;
    
    wire R1_RE_N = LU12I_W | PCADDU12I | B | BL ;
   
    wire ALUB_EXT = TYPE_2RI12 | TYPE_1RI20 | TYPE_2RI5 | LOAD | STORE;
       
    wire R2_SEL = STORE | BEQ | BNE | BGE | BGEU | BLT | BLTU ;  

    assign is_call = BL ;
    assign is_ret  = JIRL ; 

    assign npc_op = {2{NPC_OP_PC4 }}   & `NPC_PC4 |
                    {2{NPC_OP_ALU }}   & `NPC_ALU |
                    {2{NPC_OP_RET }}   & `NPC_RET |
                    {2{NPC_OP_CALL}}   & `NPC_CALL;

    assign is_br_jmp = BEQ | BNE | BGE | BGEU | BLT | BLTU|  B | BL | JIRL;

    assign ext_op = {3{EXT_OP_12_S}} & `EXT_12_S  |
                    {3{EXT_OP_12_Z}} & `EXT_12_Z  | 
                    {3{EXT_OP_16_S}} & `EXT_16_S  |
                    {3{EXT_OP_26_S}} & `EXT_26_S  |
                    {3{EXT_OP_20  }} & `EXT_20    |
                    {3{EXT_OP_5_Z }} & `EXT_5_Z   ;

    assign r2_sel = R2_SEL ? `R2_RD : `R2_RK;

    assign rR1_re = ~R1_RE_N;

    assign rR2_re = TYPE_3R | STORE | BEQ | BNE | BGE | BGEU | BLT | BLTU ;

    assign alua_sel =ALPC ? `ALUA_PC : `ALUA_R1;

    assign alub_sel = (ALUB_EXT) ? `ALUB_EXT : `ALUB_R2;

    assign alu_op = { 5{ALU_OP_ADD}} & `ALU_ADD  | 
                    { 5{ALU_OP_SUB}} & `ALU_SUB  | 
                    { 5{ALU_OP_AND}} & `ALU_AND  | 
                    { 5{ALU_OP_OR }} & `ALU_OR   | 
                    { 5{ALU_OP_XOR}} & `ALU_XOR  | 
                    { 5{ALU_OP_NOR}} & `ALU_NOR  |
                    { 5{ALU_OP_COM}} & `ALU_COM  | 
                    {5{ALU_OP_UCOM}} & `ALU_UCOM | 
                    { 5{ALU_OP_EQU}} & `ALU_EQU  |
                    {5{ALU_OP_UEQU}} & `ALU_UEQU |
                    { 5{ALU_OP_LES}} & `ALU_LES  |
                    {5{ALU_OP_ULES}} & `ALU_ULES |
                    { 5{ALU_OP_MOR}} & `ALU_MOR  |
                    {5{ALU_OP_UMOR}} & `ALU_UMOR |
                    { 5{ALU_OP_SLL}} & `ALU_SLL  |
                    { 5{ALU_OP_SRL}} & `ALU_SRL  |
                    { 5{ALU_OP_SRA}} & `ALU_SRA  |
                    { 5{ALU_OP_COP}} & `ALU_COP  |
                    { 5{ALU_OP_PC4}} & `ALU_PC4  |
                    {5{ALU_OP_MULL}} & `ALU_MULL |
                    {5{ALU_OP_MULH}} & `ALU_MULH |
                    {5{ALU_OP_UMUL}} & `ALU_UMUL;
                    
    assign ram_ext_op =  {3{LD_B}}  & `RAM_EXT_B_S| 
                         {3{LD_BU}} & `RAM_EXT_B_Z|
                         {3{LD_H}}  & `RAM_EXT_H_S|
                         {3{LD_HU}} & `RAM_EXT_H_Z|
                         {3{LD_W}}  & `RAM_EXT_N  |
                         {3{~LOAD}} & `N_RAM_EXT  ;

    assign ram_we = `RAM_WE_W &{4{ ST_W }}|
                    `RAM_WE_H &{4{ ST_H }}|
                    `RAM_WE_B &{4{ ST_B }}|
                    `RAM_WE_N &{4{~STORE}};
                    

    assign rf_we = (NPC_OP_PC4 & !STORE) | JIRL | BL;

    assign wr_sel = !BL ? `WR_RD  : `WR_Rr1;

    assign wd_sel = {2{WD_SEL_ALU}} & `WD_ALU |
                    {2{WD_SEL_RAM}} & `WD_RAM ;
    
    assign is_ld_st =(ram_we != 4'b0000) | wd_sel == `WD_RAM ; 

endmodule
