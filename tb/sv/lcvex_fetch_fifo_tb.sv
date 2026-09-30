// lcvex_fetch_fifo_tb.sv
// F1a 定向骨架：2-entry FIFO、taken-branch flush、延迟响应 quarantine 和
// commit_ready 背压。该入口显式打开 FETCH_FIFO_ENABLE；旧测试继续使用默认 0。

`timescale 1ns/1ps

/* verilator lint_off UNUSEDSIGNAL */
module lcvex_fetch_fifo_tb #(
  parameter int MEM_DELAY_MODE = 2,
  parameter int FETCH_FIFO_ENABLE = 1,
  parameter int I_L1_ENABLE = 0,
  parameter int D_L1_ENABLE = 0,
  parameter int L2_ENABLE = 0,
  parameter logic [63:0] RESET_PC = 64'h0000_0000_4400_0000
);
  logic clk = 1'b0;
  logic rst_n = 1'b0;
  logic commit_ready = 1'b1;
  logic prog_we = 1'b0;
  logic [63:0] prog_addr = 64'd0;
  logic [7:0]  prog_strb = 8'd0;
  logic [63:0] prog_wdata = 64'd0;
  logic [63:0] restore_fp_v_lo [0:31] = '{default:64'd0};
  logic [63:0] restore_fp_v_hi [0:31] = '{default:64'd0};
  logic        restore_sys_valid = 1'b0;
  logic [63:0] restore_pc = 64'h0000_0000_4400_0000;

  logic        commit_valid;
  logic [31:0] commit_insn;
  logic [63:0] commit_pc;
  logic [63:0] commit_next_pc;
  logic        commit_exc_valid;
  logic [31:0] commit_exc_code;
  logic        tlb_invalidate;
  logic        fetch_control_fence;
  int          commits;
  int          held_cycles;
  bit          saw_branch;
  bit          saw_target;
  bit          saw_epoch_bump;
  bit          saw_fence;
  logic [7:0]  epoch_before;

  // Optional pre-fix diagnostic image.  The default branch below remains the
  // original taken-branch smoke; PROBE_HEX/PROBE_WORDS is used only by the
  // T-046 root-cause probe and does not alter the DUT interface.
  // H-03 page-table images are larger than the original F1a probe window.
  logic [31:0] probe_mem [0:32767];
  string probe_hex;
  string h03_label;
  integer probe_word_count;
  bit probe_mode;
  bit h04_probe_mode;
  bit h04_expect_drop;
  bit h03_probe_mode;
  bit h03_hold_ready;
  bit h03_negative;
  bit h03_stop_requested;
  bit h03_context_mode;
  string h03_context_kind;
  integer h03_context_reg;
  logic [63:0] h03_context_value;
  logic [31:0] maint_owner_words [0:4];
  bit          maint_owner_mode;

  // Only the architectural fields needed by this smoke are wired. Other
  // lcvex_soc_tb outputs are intentionally left open to keep this BFM small.
  lcvex_soc_tb #(
      .RESET_PC(RESET_PC),
      .MEM_DELAY_MODE(MEM_DELAY_MODE),
      .I_L1_ENABLE(I_L1_ENABLE),
      .D_L1_ENABLE(D_L1_ENABLE),
      .L2_ENABLE(L2_ENABLE),
      .FETCH_FIFO_ENABLE(FETCH_FIFO_ENABLE),
      .FETCH_FIFO_DEPTH(2),
      .FETCH_EPOCH_W(8)
  ) dut (
      .clk(clk),
      .rst_n(rst_n),
      .commit_ready(commit_ready),
      .difftest_wait_release(1'b0),
      .difftest_wait_cntvct_valid(1'b0),
      .difftest_wait_cntvct(64'd0),
      .difftest_restore_sys_valid(restore_sys_valid),
      .difftest_restore_fp_valid(1'b0),
      .difftest_restore_fpcr(32'd0),
      .difftest_restore_fpsr(32'd0),
      .difftest_restore_fp_v_lo(restore_fp_v_lo),
      .difftest_restore_fp_v_hi(restore_fp_v_hi),
      .difftest_restore_pc(restore_pc),
      .difftest_restore_sp_el0(64'd0),
      .difftest_restore_sp_el1(64'd0),
      .difftest_restore_nzcv(4'd0),
      .difftest_restore_el(1'b0),
      .difftest_restore_sp_sel(1'b0),
      .difftest_restore_daif(4'd0),
      .difftest_restore_pan(1'b0),
      .difftest_restore_dit(1'b0),
      .difftest_restore_ssbs(1'b0),
      .difftest_restore_uao(1'b0),
      .difftest_restore_tco(1'b0),
      .difftest_restore_allint(1'b0),
      .difftest_restore_elr_el1(64'd0),
      .difftest_restore_spsr_el1(64'd0),
      .difftest_restore_vbar_el1(64'd0),
      .difftest_restore_sctlr_el1(64'd0),
      .difftest_restore_tcr_el1(64'd0),
      .difftest_restore_ttbr0_el1(64'd0),
      .difftest_restore_ttbr1_el1(64'd0),
      .difftest_restore_mair_el1(64'd0),
      .difftest_restore_esr_el1(32'd0),
      .difftest_restore_far_el1(64'd0),
      .difftest_restore_par_el1(64'd0),
      .difftest_restore_cpacr_el1(64'd0),
      .difftest_restore_mdscr_el1(64'd0),
      .difftest_restore_pmuserenr_el0(64'd0),
      .difftest_restore_cntkctl_el1(64'd0),
      .difftest_restore_tpidr_el0(64'd0),
      .difftest_restore_tpidrro_el0(64'd0),
      .difftest_restore_tpidr_el1(64'd0),
      .difftest_restore_pir_el1(64'd0),
      .difftest_restore_pire0_el1(64'd0),
      .difftest_restore_zcr_el1(64'd0),
      .difftest_restore_smcr_el1(64'd0),
      .difftest_restore_csselr_el1(64'd0),
      .difftest_restore_tcr2_el1(64'd0),
      .difftest_restore_contextidr_el1(64'd0),
      .difftest_restore_excl_valid(1'b0),
      .difftest_restore_excl_addr(64'd0),
      .difftest_restore_excl_data(64'd0),
      .difftest_restore_excl_data_hi(64'd0),
      .difftest_restore_cntpct(64'd0),
      .difftest_restore_cntp_cval(64'd0),
      .difftest_restore_cntp_ctl(2'd0),
      .difftest_restore_cntv_cval(64'd0),
      .difftest_restore_cntv_ctl(2'd0),
      .prog_we(prog_we),
      .prog_addr(prog_addr),
      .prog_strb(prog_strb),
      .prog_wdata(prog_wdata),
      .commit_insn(commit_insn),
      .commit_valid(commit_valid),
      .commit_pc(commit_pc),
      .commit_next_pc(commit_next_pc),
      .commit_exc_valid(commit_exc_valid),
      .commit_exc_code(commit_exc_code),
      .tlb_invalidate(tlb_invalidate),
      .fetch_control_fence(fetch_control_fence),
      .dbg_addr(32'd0)
  );

  always #5 clk = ~clk;

  // movz x0,#1; b target; two wrong-path instructions; target; b .
  logic [31:0] prog_words [0:5];
  logic [31:0] h04_prog_words [0:15];
  logic [31:0] t010_iabt_words [0:3];
  bit          t010_iabt_mode;
  initial begin : h03_config
    probe_mode = 1'b0;
    h04_probe_mode = $test$plusargs("H04_PROBE");
    h04_expect_drop = $test$plusargs("H04_PREFIX");
    h03_probe_mode = $test$plusargs("H03_PROBE");
    h03_hold_ready = $test$plusargs("H03_HOLD");
    h03_negative = $test$plusargs("H03_NEGATIVE");
    h03_stop_requested = 1'b0;
    h03_context_mode = $test$plusargs("H03_CONTEXT");
    t010_iabt_mode = $test$plusargs("T010_IABT");
    maint_owner_mode = $test$plusargs("MAINT_OWNER");
    h03_context_kind = "unknown";
    void'($value$plusargs("H03_CONTEXT_KIND=%s", h03_context_kind));
    h03_context_reg = 0;
    void'($value$plusargs("H03_CONTEXT_REG=%d", h03_context_reg));
    h03_context_value = 64'd0;
    void'($value$plusargs("H03_CONTEXT_VALUE=%h", h03_context_value));
    h03_label = "unknown";
    void'($value$plusargs("H03_LABEL=%s", h03_label));
    probe_word_count = 0;
    if ($value$plusargs("PROBE_HEX=%s", probe_hex)) begin
      if (!$value$plusargs("PROBE_WORDS=%d", probe_word_count))
        $fatal(1, "PROBE_HEX requires PROBE_WORDS");
      if (probe_word_count < 1 || probe_word_count > 32768)
        $fatal(1, "invalid PROBE_WORDS=%0d", probe_word_count);
      $readmemh(probe_hex, probe_mem);
      probe_mode = 1'b1;
    end
  end

  // T-010 encoding fixture: the predecode must agree with lcvex_decode.sv for
  // each supported control-flow family and reject reserved encodings.
  initial begin : t010_predecode_fixture
    #1;
    if (!dut.core.raw_control_flow(32'h14000000) ||
        !dut.core.raw_control_flow(32'h94000000) ||
        !dut.core.raw_control_flow(32'h54000000) ||
        !dut.core.raw_control_flow(32'h34000000) ||
        !dut.core.raw_control_flow(32'h35000000) ||
        !dut.core.raw_control_flow(32'h36000000) ||
        !dut.core.raw_control_flow(32'h37000000) ||
        !dut.core.raw_control_flow(32'hD61F0000) ||
        !dut.core.raw_control_flow(32'hD63F0000) ||
        !dut.core.raw_control_flow(32'hD65F03C0))
      $fatal(1, "T-010 supported control-flow predecode fixture failed");
    if (dut.core.raw_control_flow(32'h54000010) ||
        dut.core.raw_control_flow(32'hD67F0000) ||
        dut.core.raw_control_flow(32'h00000000) ||
        dut.core.raw_control_flow(32'hD4000001) ||
        dut.core.raw_control_flow(32'hD69F03E0) ||
        dut.core.raw_control_flow(32'hD5033F9F))
      $fatal(1, "T-010 reserved control-flow encoding was fenced");
  end

  // A live fence may not accept a younger ordinary fetch. The core SVA checks
  // this at the same sampling edge; this smoke provides a visible failure.
  always @(posedge clk) begin
    if (fetch_control_fence &&
        (dut.core.fetch_req_accept || dut.core.imem_req_accept))
      $fatal(1, "control-flow fence accepted a younger fetch");
  end

  // A negative-control probe exits its named test block immediately; finish
  // on the next edge so no same-region H03 post-fix assertions can run.
  always @(posedge clk) begin
    if (h03_stop_requested)
      $finish;
  end

  initial begin : h03_test_main
    prog_words[0] = 32'hD2800020;
    prog_words[1] = 32'h14000003;  // 0x44000004 -> 0x44000010
    prog_words[2] = 32'hD2800041;  // must be flushed
    prog_words[3] = 32'hD2800062;  // must be flushed
    prog_words[4] = 32'hD2800083;
    prog_words[5] = 32'h14000000;
    for (int i = 0; i < 16; i++)
      h04_prog_words[i] = 32'hD503201F;  // nop: keep a sequential FIFO window
    // MUL creates a short execution stall while the frontend can fill the
    // FIFO behind a still-valid IF/ID entry.
    h04_prog_words[0] = 32'hD2800060;     // movz x0,#3
    h04_prog_words[1] = 32'hD2800081;     // movz x1,#4
    h04_prog_words[2] = 32'h9B017C02;     // mul x2,x0,x1
    h04_prog_words[15] = 32'h14000000;    // b .
    t010_iabt_words[0] = 32'hD28A0000;    // movz x0,#0x5000
    t010_iabt_words[1] = 32'hD61F0000;    // br x0 -> target IABT
    t010_iabt_words[2] = 32'hD28000A1;    // younger instruction, not executed
    t010_iabt_words[3] = 32'h14000000;    // b .
    maint_owner_words[0] = 32'hD2A88000;  // movz x0,#0x4400,lsl #16
    maint_owner_words[1] = 32'hD50B7520;  // ic ivau, x0
    maint_owner_words[2] = 32'hD508831F;  // tlbi vmalle1is
    maint_owner_words[3] = 32'h14000001;  // b loop
    maint_owner_words[4] = 32'h14000000;  // loop: b .
  end

  initial begin
    $display("=== lcvex_fetch_fifo_tb: F1a FIFO/epoch/quarantine skeleton ===");
    for (int i = 0; i < 2; i++) @(posedge clk);
    prog_we = 1'b1;
    for (int i = 0; i < (maint_owner_mode ? 5 :
                         (t010_iabt_mode ? 4 :
                         (h03_context_mode ? probe_word_count :
                         (h03_probe_mode ? probe_word_count :
                         (h04_probe_mode ? 16 : (probe_mode ? probe_word_count : 6)))))); i++) begin
      prog_addr = 64'h0000_0000_4400_0000 + 64'(i * 4);
      prog_strb = 8'h0f;
      prog_wdata = {32'd0,
                    maint_owner_mode ? maint_owner_words[i] :
                    t010_iabt_mode ? t010_iabt_words[i] :
                    (h03_context_mode ? probe_mem[i] :
                    (h03_probe_mode ? probe_mem[i] :
                    (h04_probe_mode ? h04_prog_words[i] :
                     (probe_mode ? probe_mem[i] : prog_words[i])))) };
      @(posedge clk);
    end
    prog_we = 1'b0;
    rst_n = 1'b1;

    if (t010_iabt_mode) begin : t010_iabt_negative
      bit decode_seen;
      bit commit_seen;
      bit epoch_changed;
      logic [7:0] decode_epoch;
      decode_seen = 1'b0;
      commit_seen = 1'b0;
      epoch_changed = 1'b0;
      decode_epoch = '0;
      for (int cycle = 0; cycle < 240; cycle++) begin
        @(posedge clk);
        #1;
        if (dut.core.ifid_valid && dut.core.d.valid && dut.core.d.exc &&
            (dut.core.d.exc_code == 32'h0000_0021)) begin
          if (fetch_control_fence)
            $fatal(1, "T-010 branch-target IABT incorrectly held fetch fence");
          if (dut.core.d.exc_elr != 64'h0000_0000_0000_5000)
            $fatal(1, "T-010 branch-target IABT ELR mismatch: %h",
                   dut.core.d.exc_elr);
          decode_seen = 1'b1;
          decode_epoch = dut.core.fetch_epoch;
        end
        if (decode_seen && dut.core.fetch_epoch != decode_epoch)
          epoch_changed = 1'b1;
        if (commit_valid && commit_exc_valid) begin
          if (commit_pc != 64'h0000_0000_4400_0004 ||
              commit_exc_code != 32'h0000_0021 ||
              dut.core.commit_exc_far_r != 64'h0000_0000_0000_5000)
            $fatal(1, "T-010 branch-target IABT commit mismatch pc=%h code=%h far=%h",
                   commit_pc, commit_exc_code, dut.core.commit_exc_far_r);
          commit_seen = 1'b1;
          break;
        end
      end
      if (!decode_seen)
        $fatal(1, "T-010 branch-target IABT decode d.valid/d.exc not observed");
      if (!commit_seen)
        $fatal(1, "T-010 branch-target IABT commit not observed");
      if (!epoch_changed)
        $fatal(1, "T-010 branch-target IABT did not preserve epoch/flush semantics");
      $display("T010_IABT_NEGATIVE_PASS decode=1 fence=0 commit=1 far=0x5000 epoch_changed=1");
      $finish;
    end

    if (maint_owner_mode) begin : maint_owner_test
      bit pending_seen;
      bit response_seen;
      bit restore_sent;
      bit ic_commit_seen;
      logic pending_prev;
      pending_seen = 1'b0;
      response_seen = 1'b0;
      restore_sent = 1'b0;
      ic_commit_seen = 1'b0;
      pending_prev = 1'b0;
      $display("=== T-007 maintenance response-owner probe fifo=%0d il1=%0d dly=%0d ===",
               FETCH_FIFO_ENABLE, I_L1_ENABLE, MEM_DELAY_MODE);
      for (int cycle = 0; cycle < 900; cycle++) begin
        @(posedge clk);
        #1;

        // The registered pending bit changes on the request/response edge;
        // this observes both handshakes without relying on a post-edge pulse
        // whose state machine may already have advanced to MS_WAIT/MS_DONE.
        if (!pending_prev && dut.core.maint_imem_rsp_pending) begin
          pending_seen = 1'b1;
          if (!dut.core.maint_imem_rsp_owner ||
              !dut.core.imem_rsp_ready)
            $fatal(1, "maintenance response owner not ready at cycle %0d", cycle);
          restore_sys_valid = 1'b1;
        end
        if (pending_prev && !dut.core.maint_imem_rsp_pending)
          response_seen = 1'b1;
        pending_prev = dut.core.maint_imem_rsp_pending;

        if (dut.core.maint_imem_rsp_pending) begin
          if (!dut.core.maint_imem_rsp_owner ||
              !dut.core.imem_rsp_ready || dut.core.maint_imem_req_valid ||
              dut.core.fetch_imem_rsp_current)
            $fatal(1, "maintenance pending response lost owner at cycle %0d",
                   cycle);
        end
        if (dut.core.memwb_fetch_wait &&
            (dut.core.maint_imem_req_valid ||
             dut.core.maint_imem_req_accept ||
             dut.core.maint_dmem_req_valid ||
             dut.core.maint_dmem_req_accept || dut.tlb_invalidate))
          $fatal(1, "maintenance side effect crossed fetch-wait at cycle %0d",
                 cycle);
        if (dut.tlb_invalidate && dut.core.memwb_fetch_wait)
          $fatal(1, "TLBI pulse crossed fetch-wait at cycle %0d", cycle);
        if (commit_valid && commit_insn == 32'hD50B7520)
          ic_commit_seen = 1'b1;

        if (restore_sent)
          restore_sys_valid = 1'b0;
        if (restore_sys_valid)
          restore_sent = 1'b1;

        if (restore_sent && response_seen) begin
          if (!pending_seen)
            $fatal(1, "maintenance response owner probe never accepted request");
          if (ic_commit_seen)
            $fatal(1, "killed IC IVAU unexpectedly committed");
          $display("T007_MAINT_OWNER_PASS pending=1 response_drained=1 restore_kill=1 ic_commit=0");
          h03_stop_requested = 1'b1;
          disable maint_owner_test;
        end
      end
      $fatal(1, "maintenance response owner probe timed out pending=%0d response=%0d restore=%0d",
             pending_seen, response_seen, restore_sent);
    end

    if (probe_mode && !h03_probe_mode && !h03_context_mode) begin
      $display("=== T-046 pre-fix internal token probe (%0d cycles) ===",
               1000);
      for (int cycle = 0; cycle < 1000; cycle++) begin
        @(posedge clk);
        #1;
        $display("PROBE cycle=%0d fifo_count=%0d fifo_head_valid=%0d fifo_head_pc=%h fifo_head_epoch=%0d fifo_head_seq=%0d fifo_push=%0d fifo_pop=%0d fifo_flush=%0d stale_drain=%0d stale_drop=%0d epoch=%0d ifid_valid=%0d ifid_pc=%h ifid_epoch=%0d ifid_seq=%0d idex_valid=%0d idex_pc=%h idex_epoch=%0d idex_seq=%0d exmem_valid=%0d exmem_pc=%h exmem_epoch=%0d exmem_seq=%0d memwb_valid=%0d memwb_pc=%h memwb_epoch=%0d memwb_seq=%0d memwb_committed=%0d commit_valid=%0d commit_pc=%h commit_epoch=%0d commit_seq=%0d fire_ifid_idex=%0d fire_idex_exmem=%0d fire_exmem_memwb=%0d fire_commit=%0d stall_if=%0d stall_id=%0d load_use=%0d fp_load_use=%0d mem_busy=%0d dmem_pending=%0d data_trans=%0d data_mmu_issue=%0d",
                 cycle, dut.core.fetch_fifo_count,
                 dut.core.fetch_fifo_head_valid_dbg,
                 dut.core.fetch_fifo_head_pc_dbg,
                 dut.core.fetch_fifo_head_epoch_dbg,
                 dut.core.fetch_fifo_head_seq_dbg,
                 dut.core.fetch_fifo_push, dut.core.fetch_fifo_pop,
                 dut.core.fetch_fifo_flush, dut.core.fetch_stale_drain,
                 dut.core.fetch_stale_rsp_drop, dut.core.fetch_epoch,
                 dut.core.ifid_valid, dut.core.ifid_pc,
                 dut.core.ifid_token_epoch, dut.core.ifid_token_seq,
                 dut.core.idex_valid, dut.core.idex_pc,
                 dut.core.idex_token_epoch, dut.core.idex_token_seq,
                 dut.core.exmem_valid, dut.core.exmem_pc,
                 dut.core.exmem_token_epoch, dut.core.exmem_token_seq,
                 dut.core.memwb_valid, dut.core.memwb_pc,
                 dut.core.memwb_token_epoch, dut.core.memwb_token_seq,
                 dut.core.memwb_committed_r,
                 commit_valid, commit_pc, dut.core.commit_token_epoch,
                 dut.core.commit_token_seq,
                 dut.core.dbg_ifid_to_idex_fire,
                 dut.core.dbg_idex_to_exmem_fire,
                 dut.core.dbg_exmem_to_memwb_fire,
                 dut.core.dbg_commit_fire, dut.core.stall_if,
                 dut.core.stall_id, dut.core.load_use,
                 dut.core.fp_load_use, dut.core.mem_busy,
                 dut.core.dmem_pending, dut.core.data_trans_active,
                 dut.core.data_mmu_issue);
      end
      $display("PROBE_DONE");
      $finish;
    end

    if (h03_context_mode) begin : h03_context_probe
      bit context_seen;
      bit refresh_seen;
      bit fresh_seen;
      bit fresh_normal_seen;
      bit sys_commit_seen;
      bit commit_seen;
      bit old_normal_seen;
      bit old_fault_seen;
      bit old_pending_seen;
      bit old_translated_seen;
      bit negative_done;
      int redirect_count;
      logic [7:0] context_epoch;
      logic [63:0] context_pc;
      logic [63:0] context_target;
      context_seen = 1'b0;
      refresh_seen = 1'b0;
      fresh_seen = 1'b0;
      fresh_normal_seen = 1'b0;
      sys_commit_seen = 1'b0;
      commit_seen = 1'b0;
      old_normal_seen = 1'b0;
      old_fault_seen = 1'b0;
      old_pending_seen = 1'b0;
      old_translated_seen = 1'b0;
      negative_done = 1'b0;
      redirect_count = 0;
      context_epoch = '0;
      context_pc = '0;
      context_target = '0;
      $display("=== T-006 context refresh kind=%s reg=%0d value=%h ===",
               h03_context_kind, h03_context_reg, h03_context_value);
      for (int cycle = 0; cycle < 2200; cycle++) begin
        @(posedge clk);
        #1;
        $display("H03_CONTEXT label=%s cycle=%0d kind=%s ifid_valid=%0d ifid_pc=%h ifid_insn=%h ifid_epoch=%0d d_next_pc=%h sys_reg=%0d sys_at_id=%0d sys_context_change=%0d refresh_needed=%0d sys_redirect=%0d sys_commit_ready=%0d sys_commit=%0d sys_fetch_merge=%0d sys_fetch_merge_allowed=%0d mmu_en_eff=%0d fetch_epoch=%0d fetch_pending=%0d fetch_translated=%0d fetch_trans_busy=%0d fetch_fifo_count=%0d fetch_fifo_has_target=%0d fetch_fifo_head_fault=%0d fetch_faulted=%0d fetch_pc_r=%h fetch_ctx_epoch=%0d fetch_ctx_seq=%0d fetch_next_settled=%0d commit_valid=%0d commit_pc=%h commit_exc=%0d commit_code=%h commit_esr=%h commit_far=%h sctlr=%h tcr=%h ttbr0=%h ttbr1=%h mair=%h",
                 h03_label, cycle, h03_context_kind,
                 dut.core.ifid_valid, dut.core.ifid_pc, dut.core.ifid_insn,
                 dut.core.ifid_token_epoch, dut.core.d.next_pc,
                 dut.core.d.sys_reg, dut.core.sys_at_id,
                 dut.core.sys_fetch_context_change,
                 dut.core.sys_fetch_context_refresh_needed,
                 dut.core.sys_fetch_redirect, dut.core.sys_commit_ready,
                 dut.core.sys_commit, dut.core.sys_fetch_merge,
                 dut.core.sys_fetch_merge_allowed, dut.core.mmu_en_eff,
                 dut.core.fetch_epoch, dut.core.fetch_pending,
                 dut.core.fetch_translated, dut.core.fetch_trans_busy,
                 dut.core.fetch_fifo_count, dut.core.fetch_fifo_has_target,
                 dut.core.fetch_fifo_head_fault, dut.core.fetch_faulted,
                 dut.core.fetch_pc_r, dut.core.fetch_ctx_epoch,
                 dut.core.fetch_ctx_seq, dut.core.fetch_next_settled,
                 commit_valid, commit_pc, commit_exc_valid,
                 commit_exc_code, dut.core.commit_exc_esr_r,
                 dut.core.commit_exc_far_r, dut.core.sctlr_el1,
                 dut.core.tcr_el1, dut.core.ttbr0_el1,
                 dut.core.ttbr1_el1, dut.core.mair_el1);

        if (!context_seen && dut.core.ifid_valid &&
            dut.core.sys_fetch_context_change &&
            (dut.core.d.sys_reg == h03_context_reg) &&
            ((dut.core.d.sys_reg == 5 &&
              ((h03_context_kind inside {"disable", "disable_fault"})
                   ? !dut.core.d.sys_wdata[0]
                   : dut.core.d.sys_wdata[0])) ||
             (dut.core.d.sys_reg != 5 && dut.core.mmu_en_eff))) begin
          context_seen = 1'b1;
          context_epoch = dut.core.ifid_token_epoch;
          context_pc = dut.core.ifid_pc;
          context_target = dut.core.d.next_pc;
        end
        if (context_seen) begin
          if (dut.core.sys_fetch_redirect) begin
            redirect_count++;
            if (redirect_count > 1)
              $fatal(1, "context refresh redirected more than once label=%s",
                     h03_label);
          end
          if (dut.core.fetch_epoch != context_epoch)
            refresh_seen = 1'b1;

          if (!refresh_seen && dut.core.fetch_epoch == context_epoch &&
              dut.core.ifid_valid && (dut.core.d.next_pc == context_target)) begin
            if (dut.core.fetch_pending &&
                (dut.core.fetch_pc_r == context_target) &&
                (dut.core.fetch_ctx_epoch == context_epoch))
              old_pending_seen = 1'b1;
            if (dut.core.fetch_translated &&
                (dut.core.fetch_pc_r == context_target) &&
                (dut.core.fetch_ctx_epoch == context_epoch))
              old_translated_seen = 1'b1;
            if (dut.core.fetch_fifo_has_target) begin
              if (dut.core.fetch_fifo_head_fault &&
                  (dut.core.fetch_fifo_head_pc_dbg == context_target))
                old_fault_seen = 1'b1;
              else
                old_normal_seen = 1'b1;
            end
          end

          if (refresh_seen && dut.core.ifid_valid &&
              (dut.core.d.next_pc == context_target) &&
              (dut.core.fetch_fifo_has_target ||
               (dut.core.fetch_faulted &&
                dut.core.fetch_ctx_epoch == dut.core.fetch_epoch &&
                dut.core.fetch_pc_r == context_target)))
            fresh_seen = 1'b1;
          if ((h03_context_kind == "disable_fault") && commit_seen &&
              !dut.core.mmu_en_eff && dut.core.fetch_fifo_has_target &&
              !dut.core.fetch_fifo_head_fault &&
              ((dut.core.ifid_pc == context_target) ||
               (dut.core.fetch_fifo_head_pc_dbg == context_target)))
            fresh_normal_seen = 1'b1;

          if (dut.core.sys_commit && dut.core.ifid_valid &&
              (dut.core.d.sys_reg == h03_context_reg)) begin
            if (!refresh_seen &&
                !(h03_context_kind inside {"disable", "disable_fault"}))
              $fatal(1, "context-changing MSR committed before refresh label=%s",
                     h03_label);
            sys_commit_seen = 1'b1;
            if ((h03_context_kind == "old_fault") ||
                (h03_context_kind == "old_pending") ||
                (h03_context_kind == "old_pending_fault") ||
                (h03_context_kind == "fault")) begin
              if (!dut.core.sys_fetch_merge)
                $fatal(1, "fresh fault did not use sys_fetch_merge label=%s",
                       h03_label);
            end else if (dut.core.sys_fetch_merge) begin
              $fatal(1, "normal context outcome unexpectedly merged as fault label=%s",
                     h03_label);
            end
          end

          if (commit_valid && (commit_pc == context_pc)) begin
            commit_seen = 1'b1;
            if ((h03_context_kind == "old_fault") ||
                (h03_context_kind == "old_pending") ||
                (h03_context_kind == "old_pending_fault") ||
                (h03_context_kind == "fault")) begin
              if (!commit_exc_valid || (commit_exc_code != 32'h0000_0021))
                $fatal(1, "fresh fault commit mismatch label=%s exc=%0d code=%h",
                       h03_label, commit_exc_valid, commit_exc_code);
            end else if (commit_exc_valid) begin
              $fatal(1, "normal context commit unexpectedly has exception label=%s",
                     h03_label);
            end
            case (h03_context_reg)
              5: if (dut.core.sctlr_el1 !== h03_context_value)
                   $fatal(1, "SCTLR write effect missing label=%s got=%h exp=%h",
                          h03_label, dut.core.sctlr_el1, h03_context_value);
              6: if (dut.core.tcr_el1 !== h03_context_value)
                   $fatal(1, "TCR write effect missing label=%s got=%h exp=%h",
                          h03_label, dut.core.tcr_el1, h03_context_value);
              7: if (dut.core.ttbr0_el1 !== h03_context_value)
                   $fatal(1, "TTBR0 write effect missing label=%s got=%h exp=%h",
                          h03_label, dut.core.ttbr0_el1, h03_context_value);
              8: if (dut.core.ttbr1_el1 !== h03_context_value)
                   $fatal(1, "TTBR1 write effect missing label=%s got=%h exp=%h",
                          h03_label, dut.core.ttbr1_el1, h03_context_value);
              9: if (dut.core.mair_el1 !== h03_context_value)
                   $fatal(1, "MAIR write effect missing label=%s got=%h exp=%h",
                          h03_label, dut.core.mair_el1, h03_context_value);
              default: $fatal(1, "unexpected context reg=%0d label=%s",
                               h03_context_reg, h03_label);
            endcase
            negative_done = 1'b1;
            if (h03_context_kind != "disable_fault")
              break;
          end
          if ((h03_context_kind == "disable_fault") && commit_seen &&
              fresh_normal_seen) begin
            negative_done = 1'b1;
            break;
          end
        end
      end

      if (!context_seen)
        $fatal(1, "context-changing MSR not observed label=%s", h03_label);
      if (redirect_count !=
          ((h03_context_kind inside {"disable", "disable_fault"}) ? 0 : 1))
        $fatal(1, "context redirect count=%0d label=%s", redirect_count,
               h03_label);
      if (!(h03_context_kind inside {"disable", "disable_fault"})) begin
        if (!refresh_seen || !fresh_seen || !sys_commit_seen || !commit_seen)
          $fatal(1, "context outcome incomplete refresh=%0d fresh=%0d sys=%0d commit=%0d label=%s",
                 refresh_seen, fresh_seen, sys_commit_seen, commit_seen,
                 h03_label);
        if ((h03_context_kind == "old_normal") && !old_normal_seen)
          $fatal(1, "old normal FIFO target not observed label=%s", h03_label);
        if ((h03_context_kind == "old_fault") && !old_fault_seen)
          $fatal(1, "old fault FIFO head not observed label=%s", h03_label);
        if ((h03_context_kind == "old_pending") && !old_pending_seen)
          $fatal(1, "old pending context not observed label=%s", h03_label);
        if ((h03_context_kind == "old_translated") && !old_translated_seen)
          $fatal(1, "old translated context not observed label=%s", h03_label);
      end else begin
        if (dut.core.sys_fetch_context_refresh_needed)
          $fatal(1, "SCTLR disable unexpectedly requested refresh label=%s",
                 h03_label);
        if (!sys_commit_seen || !commit_seen)
          $fatal(1, "SCTLR disable commit missing label=%s", h03_label);
        if ((h03_context_kind == "disable_fault") &&
            (!old_fault_seen || !fresh_normal_seen))
          $fatal(1, "SCTLR disable fault refresh incomplete old_fault=%0d fresh_normal=%0d label=%s",
                 old_fault_seen, fresh_normal_seen, h03_label);
      end
      $display("H03_CONTEXT_PASS label=%s kind=%s old_normal=%0d old_fault=%0d old_pending=%0d old_translated=%0d redirects=%0d refresh=%0d fresh=%0d sys_commit=%0d commit=%0d",
               h03_label, h03_context_kind, old_normal_seen, old_fault_seen,
               old_pending_seen, old_translated_seen, redirect_count,
               refresh_seen, fresh_seen, sys_commit_seen, commit_seen);
      h03_stop_requested = 1'b1;
      disable h03_test_main;
    end

    if (h03_probe_mode) begin
      bit fault_seen;
      bit held_armed;
      bit held_released;
      bit commit_after_fault;
      bit negative_done;
      int fault_cycle;
      int held_cycle;
      int hold_count;
      int post_fault_cycles;
      string expected_mode;
      fault_seen = 1'b0;
      held_armed = 1'b0;
      held_released = !h03_hold_ready;
      commit_after_fault = 1'b0;
      negative_done = 1'b0;
      fault_cycle = -1;
      held_cycle = -1;
      hold_count = 0;
      post_fault_cycles = 0;
      expected_mode = $test$plusargs("H03_EXPECT_COMMIT") ? "post-fix" : "pre-fix";
      $display("=== T-006 H-03 %s fault-head probe label=%s hold=%0d negative=%0d ===",
               expected_mode, h03_label, h03_hold_ready, h03_negative);
      for (int cycle = 0; cycle < 2200; cycle++) begin
        @(posedge clk);
        #1;

        // Fill the FIFO behind a blocked WB, then release after the held
        // fault is captured.  This is intentionally testbench-only control.
        if (h03_hold_ready && !held_armed &&
            (dut.core.fetch_fifo_count == 2'd2) &&
            (dut.core.fetch_trans_busy || dut.core.fetch_pending)) begin
          commit_ready = 1'b0;
          held_armed = 1'b1;
          held_cycle = cycle;
        end
        if (h03_hold_ready && held_armed && !held_released) begin
          hold_count++;
          if (dut.core.fetch_fault_pending ||
              dut.core.fetch_fifo_head_fault) begin
            commit_ready = 1'b1;
            held_released = 1'b1;
          end else if (hold_count > 128) begin
            $fatal(1, "H03 held-fault arm never reached pending/head label=%s",
                   h03_label);
          end
        end

        $display("H03 label=%s cycle=%0d ready=%0d fifo_count=%0d head=%0d head_valid=%0d head_fault=%0d head_pc=%h head_epoch=%0d head_seq=%0d push=%0d push_fault=%0d pop=%0d pending=%0d faulted=%0d fetch_fsc=%h head_fsc=%h ifid_valid=%0d ifid_pc=%h ifid_epoch=%0d ifid_seq=%0d memwb_valid=%0d stall_if=%0d frontend_kill=%0d stale_drain=%0d stale_drop=%0d commit_valid=%0d commit_exc=%0d commit_code=%h commit_esr=%h commit_next=%h commit_far=%h epoch=%0d",
                 h03_label, cycle, commit_ready, dut.core.fetch_fifo_count,
                 dut.core.fetch_fifo_head, dut.core.fetch_fifo_head_valid_dbg,
                 dut.core.fetch_fifo_head_fault,
                 dut.core.fetch_fifo_head_pc_dbg,
                 dut.core.fetch_fifo_head_epoch_dbg,
                 dut.core.fetch_fifo_head_seq_dbg,
                 dut.core.fetch_fifo_push, dut.core.fetch_fifo_push_fault,
                 dut.core.fetch_fifo_pop, dut.core.fetch_pending,
                 dut.core.fetch_faulted, dut.core.fetch_fsc_r,
                 dut.core.fetch_fifo_fsc_r[dut.core.fetch_fifo_head],
                 dut.core.ifid_valid, dut.core.ifid_pc,
                 dut.core.ifid_token_epoch, dut.core.ifid_token_seq,
                 dut.core.memwb_valid,
                 dut.core.stall_if, dut.core.frontend_kill,
                 dut.core.fetch_stale_drain, dut.core.fetch_stale_rsp_drop,
                 commit_valid, commit_exc_valid, commit_exc_code,
                 dut.core.commit_exc_esr_r,
                 commit_next_pc, dut.core.commit_exc_far_r,
                 dut.core.fetch_epoch);

        // T-006 first-trace fields distinguish a pending/translated request
        // from a settled outcome.  Keep this entirely diagnostic: the probe
        // does not drive commit_ready or any DUT state.
        if (dut.core.sys_at_id || dut.core.sys_commit ||
            dut.core.fetch_next_settled || dut.core.fetch_faulted) begin
          $display("H03_SETTLED_TRACE label=%s cycle=%0d ifid_valid=%0d ifid_pc=%h ifid_insn=%h sys_op=%0d sys_reg=%0d sys_at_id=%0d sys_fetch_context_change=%0d sys_commit_ready=%0d sys_commit=%0d sys_fetch_merge=%0d d_next_pc=%h fetch_pc_r=%h fetch_pending=%0d fetch_translated=%0d fetch_trans_busy=%0d fetch_fifo_has_target=%0d fetch_faulted=%0d fetch_next_settled=%0d fetch_fault_pending=%0d fetch_fifo_count=%0d fetch_fifo_head_fault=%0d fetch_epoch=%0d fetch_ctx_epoch=%0d fetch_ctx_seq=%0d",
                   h03_label, cycle, dut.core.ifid_valid, dut.core.ifid_pc,
                   dut.core.ifid_insn, dut.core.d.sys_op, dut.core.d.sys_reg,
                   dut.core.sys_at_id, dut.core.sys_fetch_context_change,
                   dut.core.sys_commit_ready,
                   dut.core.sys_commit, dut.core.sys_fetch_merge,
                   dut.core.d.next_pc, dut.core.fetch_pc_r,
                   dut.core.fetch_pending, dut.core.fetch_translated,
                   dut.core.fetch_trans_busy, dut.core.fetch_fifo_has_target,
                   dut.core.fetch_faulted, dut.core.fetch_next_settled,
                   dut.core.fetch_fault_pending, dut.core.fetch_fifo_count,
                   dut.core.fetch_fifo_head_fault, dut.core.fetch_epoch,
                   dut.core.fetch_ctx_epoch, dut.core.fetch_ctx_seq);
        end

        // MMU-off branch->invalid is a negative control for this task.  The
        // existing fetch_merge_wb path must merge that first IABT into the
        // older branch commit; stop before the unrelated vector re-fetch can
        // become a standalone fault head.
        if (h03_negative && commit_valid && commit_exc_valid) begin
          if (commit_exc_code != 32'h0000_0021)
            $fatal(1, "H03 negative control unexpected exception code=%h label=%s",
                   commit_exc_code, h03_label);
          $display("H03_NEGATIVE_PASS label=%s cycle=%0d code=%h esr=%h next=%h far=%h",
                   h03_label, cycle, commit_exc_code,
                   dut.core.commit_exc_esr_r, commit_next_pc,
                   dut.core.commit_exc_far_r);
          negative_done = 1'b1;
          h03_stop_requested = 1'b1;
          disable h03_test_main;
        end

        if (dut.core.fetch_fifo_head_fault && !fault_seen) begin
          fault_seen = 1'b1;
          fault_cycle = cycle;
          post_fault_cycles = 0;
        end
        if (fault_seen) begin
          post_fault_cycles++;
          if (commit_valid && commit_exc_valid)
            commit_after_fault = 1'b1;
          if (post_fault_cycles >= 160)
            break;
        end
      end

      if (h03_negative && !negative_done)
        $fatal(1, "H03 negative control saw no merged IABT label=%s", h03_label);

      if (!fault_seen)
        $fatal(1, "H03 did not observe current-epoch fault head label=%s",
               h03_label);
      if ($test$plusargs("H03_EXPECT_TIMEOUT")) begin
        if (commit_after_fault)
          $fatal(1, "H03 pre-fix unexpectedly committed IABT label=%s", h03_label);
        $display("H03_PRE_FIX_REPRO label=%s fault_cycle=%0d held_armed=%0d held_cycle=%0d head_fault=%0d no_iabt=1 timeout_window=160",
                 h03_label, fault_cycle, held_armed, held_cycle,
                 dut.core.fetch_fifo_head_fault);
      end else begin
        if (!commit_after_fault)
          $fatal(1, "H03 post-fix did not commit IABT label=%s", h03_label);
        $display("H03_POST_FIX_PASS label=%s fault_cycle=%0d held_armed=%0d held_cycle=%0d",
                 h03_label, fault_cycle, held_armed, held_cycle);
      end
      $finish;
    end

    if (h04_probe_mode) begin
      bit armed;
      bit checked;
      bit precondition_ok;
      logic [63:0] armed_ifid_pc;
      logic [15:0] armed_ifid_seq;
      int arm_cycle;
      armed = 1'b0;
      checked = 1'b0;
      precondition_ok = 1'b0;
      armed_ifid_pc = '0;
      armed_ifid_seq = '0;
      arm_cycle = -1;
      $display("=== T-004 H-04 %s commit-ready/IFID hold probe ===",
               h04_expect_drop ? "pre-fix" : "post-fix");
      for (int cycle = 0; cycle < 700; cycle++) begin
        @(posedge clk);
        #1;
        $display("H04 cycle=%0d ready=%0d fifo_count=%0d fifo_head_pc=%h fifo_pop=%0d ifid_valid=%0d ifid_pc=%h ifid_seq=%0d memwb_valid=%0d stall_if=%0d stall_id=%0d frontend_kill=%0d dmem_pending=%0d data_trans=%0d data_mmu_issue=%0d ex_busy=%0d wfi_idle=%0d commit_valid=%0d",
                 cycle, commit_ready, dut.core.fetch_fifo_count,
                 dut.core.fetch_fifo_head_pc_dbg, dut.core.fetch_fifo_pop,
                 dut.core.ifid_valid, dut.core.ifid_pc,
                 dut.core.ifid_token_seq, dut.core.memwb_valid,
                 dut.core.stall_if, dut.core.stall_id, dut.core.frontend_kill,
                 dut.core.dmem_pending, dut.core.data_trans_active,
                 dut.core.data_mmu_issue, dut.core.ex_busy, dut.core.wfi_idle,
                 commit_valid);
        if (!armed && commit_ready && dut.core.ifid_valid &&
            (dut.core.fetch_fifo_count != 2'd0) &&
            !dut.core.memwb_valid && !dut.core.stall_if &&
            !dut.core.frontend_kill && !dut.core.dmem_pending &&
            !dut.core.data_trans_active && !dut.core.data_mmu_issue &&
            !dut.core.ex_busy && !dut.core.wfi_idle) begin
          armed = 1'b1;
          arm_cycle = cycle;
          armed_ifid_pc = dut.core.ifid_pc;
          armed_ifid_seq = dut.core.ifid_token_seq;
          $display("H04_ARM cycle=%0d ifid_pc=%h ifid_seq=%0d fifo_count=%0d",
                   cycle, dut.core.ifid_pc, dut.core.ifid_token_seq,
                   dut.core.fetch_fifo_count);
          commit_ready = 1'b0;
          #1;
          if (!dut.core.memwb_valid && !dut.core.stall_if &&
              dut.core.ifid_valid &&
              (dut.core.fetch_fifo_count != 2'd0)) begin
            if (h04_expect_drop && dut.core.fetch_fifo_pop)
              $fatal(1, "H04 pre-fix expected pop=0 in ready-low window");
            if (!h04_expect_drop && !dut.core.fetch_fifo_pop)
              $fatal(1, "H04 post-fix expected FIFO progress in ready-low window");
            precondition_ok = 1'b1;
            $display("H04_READY_LOW cycle=%0d ready=%0d fifo_count=%0d fifo_pop=%0d ifid_valid=%0d ifid_pc=%h ifid_seq=%0d memwb_valid=%0d stall_if=%0d",
                     cycle, commit_ready, dut.core.fetch_fifo_count,
                     dut.core.fetch_fifo_pop, dut.core.ifid_valid,
                     dut.core.ifid_pc, dut.core.ifid_token_seq,
                     dut.core.memwb_valid, dut.core.stall_if);
          end else begin
            $fatal(1, "H04 ready-low precondition was not stable");
          end
        end else if (armed && !checked && cycle == arm_cycle + 1) begin
          checked = 1'b1;
          if (h04_expect_drop) begin
            if (dut.core.ifid_valid) begin
              $fatal(1, "H04 pre-fix did not reproduce IFID drop at cycle %0d",
                     cycle);
            end
          end else begin
            if (!dut.core.ifid_valid) begin
              $fatal(1, "H04 post-fix lost IFID at cycle %0d", cycle);
            end
            if (!dut.core.idex_valid ||
                dut.core.idex_pc != armed_ifid_pc ||
                dut.core.idex_token_seq != armed_ifid_seq) begin
              $fatal(1, "H04 post-fix did not transfer armed IFID exactly once");
            end
          end
          $display("H04_%s cycle=%0d ifid_valid=%0d ifid_pc=%h ifid_seq=%0d idex_valid=%0d idex_pc=%h idex_seq=%0d fifo_count=%0d fifo_pop=%0d stall_if=%0d",
                   h04_expect_drop ? "REPRO" : "POSTFIX",
                   cycle, dut.core.ifid_valid, dut.core.ifid_pc,
                   dut.core.ifid_token_seq, dut.core.idex_valid,
                   dut.core.idex_pc, dut.core.idex_token_seq,
                   dut.core.fetch_fifo_count, dut.core.fetch_fifo_pop,
                   dut.core.stall_if);
          commit_ready = 1'b1;
          $display("H04 %s check complete", h04_expect_drop ? "pre-fix reproduction" : "post-fix hold");
          break;
        end
      end
      if (!checked)
        $fatal(1, "H04 probe did not find exact window");
      if (!precondition_ok)
        $fatal(1, "H04 probe did not observe ready-low window");
      $finish;
    end else begin

    commits = 0;
    held_cycles = 0;
    saw_branch = 1'b0;
    saw_target = 1'b0;
    saw_epoch_bump = 1'b0;
    saw_fence = 1'b0;
    epoch_before = dut.core.fetch_epoch;

    for (int cycle = 0; cycle < 700; cycle++) begin
      @(posedge clk);
      if (dut.core.fetch_fifo_count > 2)
        $fatal(1, "FIFO overflow: occupancy=%0d", dut.core.fetch_fifo_count);
      saw_fence |= fetch_control_fence;
      if (dut.core.fetch_fifo_count != dut.core.fetch_fifo_occupancy)
        $fatal(1, "FIFO occupancy mirror mismatch");
      if (dut.core.fetch_epoch != epoch_before)
        saw_epoch_bump = 1'b1;

      if (commit_valid) begin
        commits++;
        if (commit_pc == 64'h0000_0000_4400_0004) begin
          saw_branch = 1'b1;
          // Let wrong-path requests become stale while the delayed BFM is
          // active, then exercise the atomic commit_ready boundary.
          commit_ready = 1'b0;
        end else if (commit_pc == 64'h0000_0000_4400_0010) begin
          saw_target = 1'b1;
        end else if (commit_pc == 64'h0000_0000_4400_0008 ||
                     commit_pc == 64'h0000_0000_4400_000c) begin
          $fatal(1, "wrong-path instruction committed: pc=0x%h", commit_pc);
        end
      end

      if (!commit_ready) begin
        if (held_cycles != 0 && commit_valid)
          $fatal(1, "commit_ready=0 produced commit at cycle %0d", cycle);
        held_cycles++;
        if (held_cycles == 10)
          commit_ready = 1'b1;
      end
      if (saw_target && saw_branch && saw_epoch_bump && held_cycles >= 10)
        break;
    end

    if (!saw_branch || !saw_target)
      $fatal(1, "branch/target commits missing branch=%b target=%b", saw_branch,
             saw_target);
    if (!saw_epoch_bump)
      $fatal(1, "taken branch did not bump fetch epoch");
    if (!saw_fence)
      $fatal(1, "taken branch did not exercise control-flow fetch fence");

    // Reset in-flight state must clear both IF/ID and FIFO before release.
    rst_n = 1'b0;
    repeat (2) @(posedge clk);
    if (dut.core.fetch_fifo_count !== 2'd0 || dut.core.ifid_valid !== 1'b0)
      $fatal(1, "reset did not clear frontend state");
    rst_n = 1'b1;
    $display("PASS: F1a FIFO bounds, flush/epoch, delayed-response and backpressure skeleton (%0d commits)", commits);
    $finish;
    end
  end
endmodule
/* verilator lint_on UNUSEDSIGNAL */
