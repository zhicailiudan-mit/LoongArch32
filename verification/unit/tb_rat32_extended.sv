`timescale 1ns/1ps
`include "defines.vh"

module tb_rat32_extended;
  localparam int NREG=32, NTAG=`ROB_DEPTH, TW=`ROB_TAG_W, NCOV=18;
  // Independent recovery contract. recover_tag names the branch/checkpoint
  // uop itself, so recovery retains that uop and all older same-packet work.
  // rob_live_mask is the authoritative statement of surviving ROB owners.
  localparam bit CONTRACT_RETAINS_CHECKPOINT_UOP = 1'b1;
  localparam bit CONTRACT_SEES_OLDER_LANE       = 1'b1;
  localparam bit CONTRACT_LIVE_MASK_AUTHORITY   = 1'b1;
  logic clk,rstn;
  logic alloc_valid,alloc_rf_we,alloc_checkpoint;
  logic [4:0] alloc_rd; logic [TW-1:0] alloc_tag;
  logic alloc1_valid,alloc1_rf_we,alloc1_checkpoint;
  logic [4:0] alloc1_rd; logic [TW-1:0] alloc1_tag;
  logic recover_valid; logic [TW-1:0] recover_tag; logic [NTAG-1:0] rob_live_mask;
  logic commit_valid,commit_has_dest; logic [4:0] commit_rd; logic [TW-1:0] commit_tag;
  logic commit1_valid,commit1_has_dest; logic [4:0] commit1_rd; logic [TW-1:0] commit1_tag;
  logic [4:0] query_rs0,query_rs1,query_rs2,query_rs3;
  wire query_pending0,query_pending1,query_pending2,query_pending3;
  wire [TW-1:0] query_tag0,query_tag1,query_tag2,query_tag3;

  bit mv[0:NREG-1], cpv[0:NTAG-1][0:NREG-1], cp_defined[0:NTAG-1];
  logic [TW-1:0] mt[0:NREG-1], cpt[0:NTAG-1][0:NREG-1];
  // Stimulus-side ROB contract state.  This is deliberately separate from
  // the RAT reference model: it constrains generated traffic rather than
  // predicting DUT mapping behavior.
  bit gen_tag_live[0:NTAG-1],gen_tag_has_dest[0:NTAG-1],gen_tag_checkpoint[0:NTAG-1];
  logic [4:0] gen_tag_rd[0:NTAG-1];
  logic [NTAG-1:0] gen_checkpoint_live[0:NTAG-1];
  logic [TW-1:0] gen_rob_order[0:NTAG-1],gen_rob_compact[0:NTAG-1];
  integer gen_rob_head,gen_rob_tail,gen_rob_count;
  bit cov[0:NCOV-1],stop_on_error;
  integer scoreboard_error_count,assertion_error_count,protocol_error_count;
  integer ownership_error_count,timeout_error_count,seed,cycles,min_coverage;
  integer stop_arg,cycle_count,hist_wr,seq;
  string scope,current_case,hist[0:31];

  RAT32 dut(.*);
  initial begin clk=0; forever #5 clk=~clk; end

  // Concurrent interface/invariant assertions complement the behavioral
  // scoreboard.  Their action blocks feed the unified assertion counter, so
  // an SVA failure can never be hidden by a final PASS banner.
  a_no_unknown_pending: assert property (@(posedge clk) disable iff(!rstn)
      !$isunknown({query_pending0,query_pending1,query_pending2,query_pending3}))
    else begin
      assertion_error_count=assertion_error_count+1;
      $error("[RAT-EXT-ASSERT-FAIL] SVA: query pending contains X");
      if(stop_on_error) $fatal(2,"RAT SVA failure");
    end
  a_x0_internal_never_pending: assert property (@(posedge clk) disable iff(!rstn)
      !dut.map_valid[0])
    else begin
      assertion_error_count=assertion_error_count+1;
      $error("[RAT-EXT-ASSERT-FAIL] SVA: internal x0 mapping became pending");
      if(stop_on_error) $fatal(2,"RAT SVA failure");
    end
  a_lane0_raw_bypass_src0: assert property (@(posedge clk) disable iff(!rstn)
      alloc_valid && alloc_rf_we && (alloc_rd!=0) && (query_rs2==alloc_rd)
      |-> query_pending2 && (query_tag2==alloc_tag))
    else begin
      assertion_error_count=assertion_error_count+1;
      $error("[RAT-EXT-ASSERT-FAIL] SVA: lane1 src0 missed lane0 RAW bypass");
      if(stop_on_error) $fatal(2,"RAT SVA failure");
    end
  a_lane0_raw_bypass_src1: assert property (@(posedge clk) disable iff(!rstn)
      alloc_valid && alloc_rf_we && (alloc_rd!=0) && (query_rs3==alloc_rd)
      |-> query_pending3 && (query_tag3==alloc_tag))
    else begin
      assertion_error_count=assertion_error_count+1;
      $error("[RAT-EXT-ASSERT-FAIL] SVA: lane1 src1 missed lane0 RAW bypass");
      if(stop_on_error) $fatal(2,"RAT SVA failure");
    end
  // WAW state is checked explicitly immediately after the accepting edge in
  // step().  A next-cycle SVA would couple the result to unrelated traffic.

  task automatic clear_inputs;
    begin
      alloc_valid=0; alloc_rf_we=0; alloc_rd=0; alloc_tag=0; alloc_checkpoint=0;
      alloc1_valid=0; alloc1_rf_we=0; alloc1_rd=0; alloc1_tag=0; alloc1_checkpoint=0;
      recover_valid=0; recover_tag=0; rob_live_mask=0;
      commit_valid=0; commit_has_dest=0; commit_rd=0; commit_tag=0;
      commit1_valid=0; commit1_has_dest=0; commit1_rd=0; commit1_tag=0;
      query_rs0=0; query_rs1=0; query_rs2=0; query_rs3=0;
    end
  endtask

  task automatic model_reset;
    integer i,j;
    begin
      for(i=0;i<NREG;i=i+1) begin mv[i]=0; mt[i]=0; end
      for(j=0;j<NTAG;j=j+1) begin
        cp_defined[j]=0;
        gen_tag_live[j]=0; gen_tag_has_dest[j]=0; gen_tag_checkpoint[j]=0;
        gen_tag_rd[j]=0; gen_checkpoint_live[j]=0;
        gen_rob_order[j]=0; gen_rob_compact[j]=0;
        for(i=0;i<NREG;i=i+1) begin cpv[j][i]=0; cpt[j][i]=0; end
      end
      gen_rob_head=0; gen_rob_tail=0; gen_rob_count=0;
    end
  endtask

  function automatic integer find_free_tag(input integer start,input integer excluded);
    integer k,t,c;
    bit checkpoint_reserved;
    begin
      find_free_tag=-1;
      for(k=0;k<NTAG;k=k+1) begin
        t=(start+k)%NTAG;
        checkpoint_reserved=0;
        for(c=0;c<NTAG;c=c+1)
          if(gen_tag_checkpoint[c]&&gen_checkpoint_live[c][t]) checkpoint_reserved=1;
        if((find_free_tag<0)&&!gen_tag_live[t]&&!checkpoint_reserved&&(t!=excluded)) find_free_tag=t;
      end
    end
  endfunction

  function automatic integer find_live_checkpoint(input integer start);
    integer k,t;
    begin
      find_live_checkpoint=-1;
      for(k=0;k<NTAG;k=k+1) begin
        t=(start+k)%NTAG;
        if((find_live_checkpoint<0)&&gen_tag_live[t]&&gen_tag_checkpoint[t]) find_live_checkpoint=t;
      end
    end
  endfunction

  task automatic generator_apply;
    integer t,k,new_count,ordered_index;
    logic [TW-1:0] ordered_tag;
    logic [NTAG-1:0] lane0_snapshot,lane1_snapshot;
    begin
      lane0_snapshot='0; lane1_snapshot='0;
      for(t=0;t<NTAG;t=t+1) lane0_snapshot[t]=gen_tag_live[t];
      if(commit_valid) begin
        lane0_snapshot[commit_tag]=0;
        gen_tag_live[commit_tag]=0;
        gen_tag_checkpoint[commit_tag]=0;
        gen_rob_head=(gen_rob_head+1)%NTAG;
        gen_rob_count=gen_rob_count-1;
      end
      if(commit1_valid) begin
        lane0_snapshot[commit1_tag]=0;
        gen_tag_live[commit1_tag]=0;
        gen_tag_checkpoint[commit1_tag]=0;
        gen_rob_head=(gen_rob_head+1)%NTAG;
        gen_rob_count=gen_rob_count-1;
      end
      if(recover_valid) begin
        for(t=0;t<NTAG;t=t+1) begin
          gen_tag_live[t]=gen_tag_live[t]&&rob_live_mask[t];
          if(!rob_live_mask[t]) gen_tag_checkpoint[t]=0;
        end
        // A recovery consumes the checkpoint resource even though its ROB
        // entry may remain live.
        gen_tag_checkpoint[recover_tag]=0;
        new_count=0;
        for(k=0;k<gen_rob_count;k=k+1) begin
          ordered_index=(gen_rob_head+k)%NTAG;
          ordered_tag=gen_rob_order[ordered_index];
          if(rob_live_mask[ordered_tag]) begin
            gen_rob_compact[new_count]=ordered_tag;
            new_count=new_count+1;
          end
        end
        for(k=0;k<new_count;k=k+1) gen_rob_order[k]=gen_rob_compact[k];
        gen_rob_head=0; gen_rob_count=new_count; gen_rob_tail=new_count%NTAG;
      end else begin
        if(alloc_valid) begin
          gen_tag_live[alloc_tag]=1;
          gen_tag_has_dest[alloc_tag]=alloc_rf_we&&(alloc_rd!=0);
          gen_tag_rd[alloc_tag]=alloc_rd;
          gen_rob_order[gen_rob_tail]=alloc_tag;
          gen_rob_tail=(gen_rob_tail+1)%NTAG;
          gen_rob_count=gen_rob_count+1;
          lane0_snapshot[alloc_tag]=1;
          if(alloc_checkpoint) begin
            gen_tag_checkpoint[alloc_tag]=1;
            gen_checkpoint_live[alloc_tag]=lane0_snapshot;
          end
        end
        lane1_snapshot=lane0_snapshot;
        if(alloc1_valid) begin
          gen_tag_live[alloc1_tag]=1;
          gen_tag_has_dest[alloc1_tag]=alloc1_rf_we&&(alloc1_rd!=0);
          gen_tag_rd[alloc1_tag]=alloc1_rd;
          gen_rob_order[gen_rob_tail]=alloc1_tag;
          gen_rob_tail=(gen_rob_tail+1)%NTAG;
          gen_rob_count=gen_rob_count+1;
          lane1_snapshot[alloc1_tag]=1;
          if(alloc1_checkpoint) begin
            gen_tag_checkpoint[alloc1_tag]=1;
            gen_checkpoint_live[alloc1_tag]=lane1_snapshot;
          end
        end
      end
    end
  endtask

  task automatic check_generated_protocol;
    integer r;
    begin
      if(alloc_valid&&gen_tag_live[alloc_tag]) fail(2,"random generator reused a live lane0 ROB tag");
      if(alloc1_valid&&gen_tag_live[alloc1_tag]) fail(2,"random generator reused a live lane1 ROB tag");
      if(alloc_valid&&alloc1_valid&&(alloc_tag==alloc1_tag)) fail(2,"random generator duplicated a dual-allocation ROB tag");
      if(alloc1_valid&&!alloc_valid) fail(2,"random generator created a non-contiguous lane1-only packet");
      if(commit_valid&&!gen_tag_live[commit_tag]) fail(2,"random generator committed a non-live ROB tag");
      if(commit1_valid&&!gen_tag_live[commit1_tag]) fail(2,"random generator committed a non-live lane1 ROB tag");
      if(commit_valid&&commit1_valid&&(commit_tag==commit1_tag)) fail(2,"random generator committed one ROB tag twice");
      if(commit1_valid&&!commit_valid) fail(2,"random generator asserted commit1 without commit0");
      if(commit_valid&&((gen_rob_count<1)||(commit_tag!=gen_rob_order[gen_rob_head])))
        fail(2,"random commit0 did not select the oldest ROB entry");
      if(commit1_valid&&((gen_rob_count<2)||(commit1_tag!=gen_rob_order[(gen_rob_head+1)%NTAG])))
        fail(2,"random commit1 did not select the second-oldest ROB entry");
      if(recover_valid&&(!gen_tag_live[recover_tag]||!gen_tag_checkpoint[recover_tag]))
        fail(2,"random generator recovered an invalid checkpoint tag");
      for(r=0;r<NREG;r=r+1)
        if(mv[r]&&!gen_tag_live[mt[r]]) fail(3,$sformatf("RAT r%0d points to non-live generated tag %0d",r,mt[r]));
    end
  endtask

  function automatic integer cov_count;
    integer i; begin cov_count=0; for(i=0;i<NCOV;i=i+1) cov_count+=cov[i]; end
  endfunction

  function automatic bit cov_applicable(input integer point);
    begin
      // Integrated random traffic forbids direct-port lane1-only (point 1)
      // and recovery+allocation overlap (point 16). Directed/all profiles
      // retain the complete module-interface matrix.
      cov_applicable=!((scope=="random")&&((point==1)||(point==16)));
    end
  endfunction

  function automatic integer applicable_cov_count;
    integer i;
    begin applicable_cov_count=0; for(i=0;i<NCOV;i=i+1) if(cov_applicable(i)&&cov[i]) applicable_cov_count++; end
  endfunction

  function automatic integer applicable_cov_total;
    integer i;
    begin applicable_cov_total=0; for(i=0;i<NCOV;i=i+1) if(cov_applicable(i)) applicable_cov_total++; end
  endfunction

  task automatic dump(input string kind,input string msg);
    integer i,k;
    begin
      $display("[RAT-EXT-%s] test=%s case=%s seed=%0d cycle=%0d seq=%0d %s",
        kind,scope,current_case,seed,cycle_count,seq,msg);
      $display("[RAT-EXT-INPUT] a0=%b we=%b rd=%0d t=%0d cp=%b a1=%b we=%b rd=%0d t=%0d cp=%b c0=%b/%b rd=%0d t=%0d c1=%b/%b rd=%0d t=%0d rec=%b t=%0d live=%h",
        alloc_valid,alloc_rf_we,alloc_rd,alloc_tag,alloc_checkpoint,
        alloc1_valid,alloc1_rf_we,alloc1_rd,alloc1_tag,alloc1_checkpoint,
        commit_valid,commit_has_dest,commit_rd,commit_tag,
        commit1_valid,commit1_has_dest,commit1_rd,commit1_tag,
        recover_valid,recover_tag,rob_live_mask);
      $write("[RAT-EXT-MAP] ");
      for(i=1;i<NREG;i=i+1) if(mv[i]) $write("r%0d:t%0d ",i,mt[i]);
      $display("");
      for(k=0;k<32;k=k+1) begin i=(hist_wr+k)&31; if(hist[i]!="") $display("[RAT-EXT-HISTORY] %s",hist[i]); end
    end
  endtask

  task automatic fail(input integer cat,input string msg);
    string kind;
    begin
      case(cat)
        0: begin scoreboard_error_count++; kind="SCOREBOARD-FAIL"; end
        1: begin assertion_error_count++; kind="ASSERT-FAIL"; end
        2: begin protocol_error_count++; kind="PROTOCOL-FAIL"; end
        3: begin ownership_error_count++; kind="OWNERSHIP-FAIL"; end
        default: begin timeout_error_count++; kind="WATCHDOG"; end
      endcase
      dump(kind,msg);
      if(stop_on_error) $fatal(2,"[RAT-EXT] FAIL (STOP_ON_ERROR): %s",msg);
    end
  endtask

  task automatic exp(input bit ok,input string msg); if(!ok) fail(0,msg); endtask

  task automatic expected(input integer p,input logic[4:0] r,output bit v,output logic[TW-1:0] t);
    begin
      v=(r!=0)&&mv[r]; t=mt[r];
      if((p>=2)&&alloc_valid&&alloc_rf_we&&(alloc_rd!=0)&&(alloc_rd==r)) begin v=1; t=alloc_tag; end
      if(r==0) v=0;
    end
  endtask

  task automatic check_queries(input string phase);
    bit v; logic[TW-1:0] t;
    begin
      if($isunknown({query_pending0,query_pending1,query_pending2,query_pending3})) fail(1,{phase," pending contains X"});
      expected(0,query_rs0,v,t); exp(query_pending0===v,$sformatf("%s q0 r%0d pending exp=%b got=%b",phase,query_rs0,v,query_pending0));
      if(v) exp(query_tag0===t,$sformatf("%s q0 tag exp=%0d got=%0d",phase,t,query_tag0));
      expected(1,query_rs1,v,t); exp(query_pending1===v,$sformatf("%s q1 r%0d pending exp=%b got=%b",phase,query_rs1,v,query_pending1));
      if(v) exp(query_tag1===t,$sformatf("%s q1 tag exp=%0d got=%0d",phase,t,query_tag1));
      expected(2,query_rs2,v,t); exp(query_pending2===v,$sformatf("%s q2 r%0d pending exp=%b got=%b",phase,query_rs2,v,query_pending2));
      if(v) exp(query_tag2===t,$sformatf("%s q2 tag exp=%0d got=%0d",phase,t,query_tag2));
      expected(3,query_rs3,v,t); exp(query_pending3===v,$sformatf("%s q3 r%0d pending exp=%b got=%b",phase,query_rs3,v,query_pending3));
      if(v) exp(query_tag3===t,$sformatf("%s q3 tag exp=%0d got=%0d",phase,t,query_tag3));
    end
  endtask

  task automatic scan(input string phase);
    integer r;
    begin
      for(r=0;r<NREG;r=r+4) begin
        query_rs0=r; query_rs1=r+1; query_rs2=r+2; query_rs3=r+3; #1; check_queries(phase);
      end
    end
  endtask

  task automatic contract_capture_checkpoint(input logic[TW-1:0] tag);
    integer i;
    begin cp_defined[tag]=1; for(i=0;i<NREG;i=i+1) begin cpv[tag][i]=mv[i]; cpt[tag][i]=mt[i]; end end
  endtask

  task automatic apply_model;
    integer i;
    begin
      if(recover_valid) begin
        if(!cp_defined[recover_tag]) fail(2,$sformatf("undefined checkpoint %0d",recover_tag));
        else begin
          if(commit_valid||commit1_valid)
            fail(2,"recovery+commit is specification-ambiguous and excluded from scored transactions");
          for(i=0;i<NREG;i=i+1) begin
            mv[i]=cpv[recover_tag][i]&&
                  (!CONTRACT_LIVE_MASK_AUTHORITY||rob_live_mask[cpt[recover_tag][i]]);
            mt[i]=cpt[recover_tag][i];
          end
          cov[14]=1;
          if(rob_live_mask!={NTAG{1'b1}}) cov[15]=1;
          if(alloc_valid||alloc1_valid) cov[16]=1;
        end
      end else begin
        if(commit_valid&&commit_has_dest&&(commit_rd!=0)&&mv[commit_rd]&&(mt[commit_rd]==commit_tag)) mv[commit_rd]=0;
        if(commit1_valid&&commit1_has_dest&&(commit1_rd!=0)&&mv[commit1_rd]&&(mt[commit1_rd]==commit1_tag)) mv[commit1_rd]=0;
        if(alloc_valid&&alloc_checkpoint) begin
          contract_capture_checkpoint(alloc_tag);
          if(CONTRACT_RETAINS_CHECKPOINT_UOP&&alloc_rf_we&&(alloc_rd!=0)) begin cpv[alloc_tag][alloc_rd]=1; cpt[alloc_tag][alloc_rd]=alloc_tag; end
          cpv[alloc_tag][0]=0; cov[11]=1;
        end
        if(alloc1_valid&&alloc1_checkpoint) begin
          contract_capture_checkpoint(alloc1_tag);
          if(CONTRACT_SEES_OLDER_LANE&&alloc_valid&&alloc_rf_we&&(alloc_rd!=0)) begin cpv[alloc1_tag][alloc_rd]=1; cpt[alloc1_tag][alloc_rd]=alloc_tag; end
          if(CONTRACT_RETAINS_CHECKPOINT_UOP&&alloc1_rf_we&&(alloc1_rd!=0)) begin cpv[alloc1_tag][alloc1_rd]=1; cpt[alloc1_tag][alloc1_rd]=alloc1_tag; end
          cpv[alloc1_tag][0]=0; cov[12]=1;
        end
        if(alloc_valid&&alloc_rf_we&&(alloc_rd!=0)) begin if(mv[alloc_rd]) cov[17]=1; mv[alloc_rd]=1; mt[alloc_rd]=alloc_tag; end
        if(alloc1_valid&&alloc1_rf_we&&(alloc1_rd!=0)) begin if(mv[alloc1_rd]) cov[17]=1; mv[alloc1_rd]=1; mt[alloc1_rd]=alloc1_tag; end
      end
      mv[0]=0;
    end
  endtask

  task automatic sample_cov;
    begin
      if(alloc_valid&&!alloc1_valid) cov[0]=1;
      if(!alloc_valid&&alloc1_valid) cov[1]=1;
      if(alloc_valid&&alloc1_valid) cov[2]=1;
      if((alloc_valid||alloc1_valid)&&!(alloc_valid&&alloc_rf_we&&(alloc_rd!=0))&&!(alloc1_valid&&alloc1_rf_we&&(alloc1_rd!=0))) cov[3]=1;
      if((alloc_valid&&alloc_rf_we&&(alloc_rd==0))||(alloc1_valid&&alloc1_rf_we&&(alloc1_rd==0))) cov[4]=1;
      if(alloc_valid&&alloc_rf_we&&(alloc_rd!=0)&&alloc1_valid&&((query_rs2==alloc_rd)||(query_rs3==alloc_rd))) cov[5]=1;
      if(alloc_valid&&alloc_rf_we&&(alloc_rd!=0)&&alloc1_valid&&(query_rs2==alloc_rd)&&(query_rs3==alloc_rd)) cov[6]=1;
      if(alloc_valid&&alloc1_valid&&alloc_rf_we&&alloc1_rf_we&&(alloc_rd!=0)&&(alloc_rd==alloc1_rd)) cov[7]=1;
      if(cov[7]&&alloc_valid&&alloc1_valid&&((query_rs2==alloc_rd)||(query_rs3==alloc_rd))) cov[8]=1;
      if(commit_valid&&!commit1_valid) cov[9]=1;
      if(commit_valid&&commit1_valid) cov[10]=1;
      if((alloc_checkpoint||alloc1_checkpoint)&&(cp_defined[alloc_tag]||cp_defined[alloc1_tag])) cov[13]=1;
    end
  endtask

  task automatic record;
    begin
      hist[hist_wr]=$sformatf("cy=%0d a=%b%b we=%b%b rd=%0d/%0d t=%0d/%0d cp=%b%b c=%b%b rd=%0d/%0d t=%0d/%0d rec=%b:%0d live=%h",
        cycle_count,alloc1_valid,alloc_valid,alloc1_rf_we,alloc_rf_we,alloc_rd,alloc1_rd,alloc_tag,alloc1_tag,
        alloc1_checkpoint,alloc_checkpoint,commit1_valid,commit_valid,commit_rd,commit1_rd,commit_tag,commit1_tag,recover_valid,recover_tag,rob_live_mask);
      hist_wr=(hist_wr+1)&31;
    end
  endtask

  task automatic step(input string name);
    bit waw_check;
    logic [4:0] waw_rd;
    logic [TW-1:0] waw_tag;
    begin
      // Callers drive immediately after the preceding negedge.  Do not wait
      // for another negedge here: the intervening posedge would otherwise
      // accept the transaction before the pre-edge check.
      current_case=name; seq++; #1; check_queries("pre");
      if(name=="random") check_generated_protocol;
      sample_cov; record;
      waw_check=!recover_valid&&alloc_valid&&alloc1_valid&&alloc_rf_we&&alloc1_rf_we&&
                (alloc_rd!=0)&&(alloc_rd==alloc1_rd);
      waw_rd=alloc1_rd; waw_tag=alloc1_tag;
      @(posedge clk); cycle_count++; #1;
      if(waw_check)
        if(!(dut.map_valid[waw_rd]&&(dut.map_tag[waw_rd]===waw_tag)))
          fail(1,"post-edge WAW checker: lane1 is not newest producer");
      apply_model; generator_apply;
      alloc_valid=0; alloc1_valid=0; alloc_rf_we=0; alloc1_rf_we=0; alloc_checkpoint=0; alloc1_checkpoint=0;
      commit_valid=0; commit1_valid=0; recover_valid=0; scan("post"); clear_inputs;
      if(cycle_count>cycles+10000) fail(4,"global watchdog");
      // scan() is deliberately clock-free but spans several nanoseconds.
      // Return only on a clean drive edge, with all transaction inputs idle.
      @(negedge clk);
    end
  endtask

  task automatic reset_case(input string name);
    begin
      current_case=name; clear_inputs; rstn=0; repeat(2) @(posedge clk); #1; model_reset; rstn=1; @(negedge clk); scan("reset"); clear_inputs; @(negedge clk);
    end
  endtask

  task automatic set_a(input bit v0,input bit w0,input int r0,input int t0,input bit p0,
                       input bit v1,input bit w1,input int r1,input int t1,input bit p1);
    begin
      alloc_valid=v0; alloc_rf_we=w0; alloc_rd=r0; alloc_tag=t0; alloc_checkpoint=p0;
      alloc1_valid=v1; alloc1_rf_we=w1; alloc1_rd=r1; alloc1_tag=t1; alloc1_checkpoint=p1;
    end
  endtask

  task automatic characterize_recovery_commit_ambiguity;
    begin
      // This transaction is intentionally outside apply_model(), coverage,
      // and PASS/FAIL accounting.  It records the implementation choice but
      // cannot make an unspecified priority pass or fail.
      reset_case("ambiguity_setup_reset");
      set_a(1,1,15,0,1,0,0,0,0,0); step("ambiguity_checkpoint_setup");
      set_a(1,1,15,1,0,0,0,0,0,0); step("ambiguity_younger_mapping");
      current_case="characterize_recovery_commit_EXCLUDED";
      recover_valid=1; recover_tag=0; rob_live_mask='1;
      commit_valid=1; commit_has_dest=1; commit_rd=15; commit_tag=0;
      query_rs0=15; #1; @(posedge clk); #1;
      if(!query_pending0)
        $display("[RAT-EXT-AMBIGUITY] recovery+commit observed=COMMIT_APPLIED excluded_from_pass=1");
      else if(query_tag0==0)
        $display("[RAT-EXT-AMBIGUITY] recovery+commit observed=RECOVERY_ONLY excluded_from_pass=1");
      else
        $display("[RAT-EXT-AMBIGUITY] recovery+commit observed=OTHER pending=%b tag=%0d excluded_from_pass=1",query_pending0,query_tag0);
      clear_inputs; @(negedge clk); reset_case("ambiguity_cleanup_reset");
    end
  endtask

  task automatic directed;
    begin
      reset_case("directed_reset");
      query_rs2=3; query_rs3=4; set_a(1,1,1,1,0,1,1,2,2,0); step("dual_independent");
      query_rs2=3; query_rs3=3; set_a(1,1,3,3,0,1,1,4,4,0); step("dual_source_raw");
      query_rs2=5; query_rs3=2; set_a(1,1,5,5,0,1,1,5,6,0); step("raw_waw");
      set_a(1,1,0,7,0,1,0,8,8,0); step("x0_no_dest");
      set_a(0,0,0,0,0,1,1,9,9,0); step("lane1_interface");
      commit_valid=1;commit_has_dest=1;commit_rd=1;commit_tag=1;step("single_commit");
      commit_valid=1;commit_has_dest=1;commit_rd=3;commit_tag=3;commit1_valid=1;commit1_has_dest=1;commit1_rd=4;commit1_tag=4;step("dual_commit");
      set_a(1,1,11,11,1,0,0,0,0,0);step("checkpoint0");
      set_a(1,1,12,12,0,1,1,13,13,1);step("nested_checkpoint1");
      set_a(1,1,11,14,0,1,1,14,15,0);step("younger_overwrite");
      recover_valid=1;recover_tag=13;rob_live_mask='1;step("recover");
      set_a(1,1,15,0,1,0,0,0,0,0);step("checkpoint_wrap");
      set_a(1,1,15,1,0,0,0,0,0,0);step("overwrite_after_cp");
      recover_valid=1;recover_tag=0;rob_live_mask='1;step("recover_tag_wrap_checkpoint");
      set_a(1,1,16,2,1,0,0,0,0,0);step("cp_for_priority");
      recover_valid=1;recover_tag=2;rob_live_mask='1;set_a(1,1,17,3,0,1,1,18,4,0);step("recover_cancels_alloc");
      set_a(1,1,30,5,0,1,1,31,6,1);step("live_mask_checkpoint");
      set_a(1,1,30,7,0,1,1,31,8,0);step("live_mask_younger");
      recover_valid=1;recover_tag=6;rob_live_mask='1;rob_live_mask[5]=0;step("recovery_filters_dead_producer");
      reset_case("reset_during_activity");
      characterize_recovery_commit_ambiguity;
    end
  endtask

  task automatic random_run;
    integer n,d,pick,tag0_pick,tag1_pick,commit0_pick,commit1_pick;
    begin
      reset_case("random_reset"); d=$urandom(seed);
      for(n=0;n<cycles;n=n+1) begin
        query_rs0=$urandom_range(0,31); query_rs1=$urandom_range(0,31);
        recover_valid=0;
        pick=find_live_checkpoint($urandom_range(0,NTAG-1));
        if((pick>=0)&&($urandom_range(0,31)==0)) begin
          // A legal ROB recovery mask contains only tags that were live at
          // the checkpoint and are still live now.  Ambiguous same-cycle
          // commit/allocation traffic is reserved for directed tests.
          recover_valid=1; recover_tag=pick;
          rob_live_mask=gen_checkpoint_live[pick];
          for(d=0;d<NTAG;d=d+1) rob_live_mask[d]=rob_live_mask[d]&&gen_tag_live[d];
          alloc_valid=0; alloc1_valid=0; commit_valid=0; commit1_valid=0;
        end else begin
          // ROB retirement is strictly in program order.  Only the oldest
          // entry, followed optionally by the second-oldest, may commit.
          commit0_pick=(gen_rob_count>0)?gen_rob_order[gen_rob_head]:-1;
          commit_valid=(gen_rob_count>0)&&($urandom_range(0,3)==0);
          if(commit_valid) begin
            commit_tag=commit0_pick; commit_has_dest=gen_tag_has_dest[commit0_pick];
            commit_rd=gen_tag_rd[commit0_pick];
          end
          commit1_pick=(gen_rob_count>1)?gen_rob_order[(gen_rob_head+1)%NTAG]:-1;
          commit1_valid=commit_valid&&(gen_rob_count>1)&&($urandom_range(0,2)==0);
          if(commit1_valid) begin
            commit1_tag=commit1_pick; commit1_has_dest=gen_tag_has_dest[commit1_pick];
            commit1_rd=gen_tag_rd[commit1_pick];
          end

          tag0_pick=find_free_tag($urandom_range(0,NTAG-1),-1);
          alloc_valid=(tag0_pick>=0)&&($urandom_range(0,1)!=0);
          if(alloc_valid) begin
            alloc_tag=tag0_pick; alloc_rf_we=$urandom_range(0,1);
            alloc_rd=$urandom_range(0,NREG-1);
          end
          tag1_pick=find_free_tag($urandom_range(0,NTAG-1),alloc_valid?tag0_pick:-1);
          // Integrated RenameBundle packets are contiguous: lane1 cannot be
          // valid unless lane0 is valid.
          alloc1_valid=alloc_valid&&(tag1_pick>=0)&&($urandom_range(0,1)!=0);
          if(alloc1_valid) begin
            alloc1_tag=tag1_pick; alloc1_rf_we=$urandom_range(0,1);
            alloc1_rd=($urandom_range(0,3)==0)?alloc_rd:$urandom_range(0,NREG-1);
          end
          alloc_checkpoint=alloc_valid&&($urandom_range(0,31)==0);
          alloc1_checkpoint=alloc1_valid&&($urandom_range(0,31)==0);
        end
        query_rs2=(alloc_valid&&$urandom_range(0,2)==0)?alloc_rd:$urandom_range(0,NREG-1);
        query_rs3=(alloc_valid&&$urandom_range(0,2)==0)?alloc_rd:$urandom_range(0,NREG-1);
        step("random");
      end
    end
  endtask

  initial begin : main
    integer i,total; real pct;
    seed=1;cycles=1000;min_coverage=90;stop_arg=0;scope="all";
    i=$value$plusargs("SEED=%d",seed); i=$value$plusargs("CYCLES=%d",cycles);
    i=$value$plusargs("TEST=%s",scope); i=$value$plusargs("MIN_COVERAGE=%d",min_coverage); i=$value$plusargs("STOP_ON_ERROR=%d",stop_arg);
    stop_on_error=(stop_arg!=0); scoreboard_error_count=0;assertion_error_count=0;protocol_error_count=0;ownership_error_count=0;timeout_error_count=0;
    cycle_count=0;hist_wr=0;seq=0;rstn=0;clear_inputs;model_reset;
    for(i=0;i<NCOV;i=i+1) cov[i]=0; for(i=0;i<32;i=i+1) hist[i]="";
    if(scope=="all"||scope=="directed") directed;
    if(scope=="all"||scope=="random") random_run;
    if(scope!="all"&&scope!="directed"&&scope!="random") fail(2,{"unsupported TEST=",scope});
    clear_inputs;scan("final"); pct=100.0*applicable_cov_count()/applicable_cov_total();
    if(pct<min_coverage) fail(0,$sformatf("mandatory coverage %.2f below %0d",pct,min_coverage));
    total=scoreboard_error_count+assertion_error_count+protocol_error_count+ownership_error_count+timeout_error_count;
    $display("[RAT-EXT-COVER] mandatory=%.2f%% minimum=%0d%% hit=%0d/%0d profile=%s",pct,min_coverage,applicable_cov_count(),applicable_cov_total(),scope);
    if(scope=="random") $display("[RAT-EXT-COVER-SKIP] lane1-only and recovery+allocation are outside integrated-random protocol");
    $display("[RAT-EXT-ERRORS] total=%0d scoreboard=%0d assertion=%0d protocol=%0d ownership=%0d timeout=%0d",total,scoreboard_error_count,assertion_error_count,protocol_error_count,ownership_error_count,timeout_error_count);
    $display("[RAT-EXT-SKIP] physical allocation/FreeList/old_phys/RRAT/ARAT: absent from DUT interface");
    $display("[RAT-EXT-SKIP] exception/global flush and valid-ready payload stability: absent from RAT32 interface");
    $display("[RAT-EXT-PROFILE] lane1-only is legal at direct RAT32 ports; random uses stricter integrated contiguous-packet protocol");
    if(total==0) begin
      $display("[RAT-EXT] PASS seed=%0d cycles=%0d scope=%s",seed,cycles,scope);
      $finish;
    end else begin
      $display("[RAT-EXT] FAILURES=%0d seed=%0d cycles=%0d scope=%s",total,seed,cycles,scope);
      $fatal(2,"[RAT-EXT] regression failed with %0d errors",total);
    end
  end
endmodule
