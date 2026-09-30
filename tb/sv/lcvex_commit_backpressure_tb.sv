// lcvex_commit_backpressure_tb.sv
// M1-A 定向测试：显式 commit_fire 的 valid/ready 语义。
//  - 提交消费者中途拉低 commit_ready（背压）：WB 条目保持，不丢不重；
//  - 释放后流水线中已排队的条目连续提交（每周期一条，无气泡依赖）；
//  - 全程提交 PC 顺序与 GPR 写回值正确。
// 程序为纯 ALU（无访存），避免背压与 load 数据保持路径耦合
// （load 数据保持由 M1-B 内存 request/response 统一解决）。
// 运行：make sim-sv-backpressure

`timescale 1ns/1ps

/* verilator lint_off UNUSEDSIGNAL */
module lcvex_commit_backpressure_tb;
  logic        clk;
  logic        rst_n = 1'b0;
  logic        commit_ready = 1'b1;
  logic        prog_we = 1'b0;
  logic [63:0] prog_addr = 64'd0;
  logic [7:0]  prog_strb = 8'h00;
  logic [63:0] prog_wdata = 64'd0;
  logic [63:0] restore_fp_v_lo [0:31] = '{default:64'd0};
  logic [63:0] restore_fp_v_hi [0:31] = '{default:64'd0};

  logic        commit_valid;
  logic [63:0] commit_pc;
  logic [63:0] commit_next_pc;
  logic [31:0] commit_insn;
  logic        commit_gpr_we;
  logic [4:0]  commit_gpr_rd;
  logic [63:0] commit_gpr_wdata;
  logic        commit_gpr2_we;
  logic [4:0]  commit_gpr2_rd;
  logic [63:0] commit_gpr2_wdata;
  logic        commit_gpr3_we;
  logic [4:0]  commit_gpr3_rd;
  logic [63:0] commit_gpr3_wdata;
  logic        commit_sp_we;
  logic [63:0] commit_sp_wdata;
  logic        commit_nzcv_we;
  logic [3:0]  commit_nzcv;
  logic        commit_mem_we;
  logic [63:0] commit_mem_addr;
  logic [63:0] commit_mem_wdata;
  logic [7:0]  commit_mem_strb;
  logic        commit_mem2_we;
  logic [63:0] commit_mem2_addr;
  logic [63:0] commit_mem2_wdata;
  logic [7:0]  commit_mem2_strb;
  logic        commit_exc_valid;
  logic [31:0] commit_exc_code;
  logic [31:0] commit_exc_esr;
  logic [63:0] commit_exc_far;
  logic        commit_mon_we;
  logic        commit_mon_valid;
  logic [63:0] commit_mon_addr;
  logic [63:0] commit_mon_data;
  logic [63:0] commit_mon_data2;
  logic [2:0]  commit_vec_write_count;
  logic [4:0]  commit_vec_rd0, commit_vec_rd1, commit_vec_rd2, commit_vec_rd3;
  logic [63:0] commit_vec_wdata0_lo, commit_vec_wdata0_hi;
  logic [63:0] commit_vec_wdata1_lo, commit_vec_wdata1_hi;
  logic [63:0] commit_vec_wdata2_lo, commit_vec_wdata2_hi;
  logic [63:0] commit_vec_wdata3_lo, commit_vec_wdata3_hi;
  logic        commit_fpcr_we, commit_fpsr_we;
  logic [31:0] commit_fpcr_wdata, commit_fpsr_wdata;
  logic [31:0] fpcr_state, fpsr_state;
  logic [63:0] fp_cpacr_el1_state;
  logic [63:0] fp_v_lo [0:31], fp_v_hi [0:31];
  logic        tlb_invalidate;   // M2-4b：TLBI 脉冲（本 TB 不检查）
  logic        uart_tx_valid;    // P6：PL011 TX（本 TB 不检查）
  logic [7:0]  uart_tx_char;
  logic        timer_phys_irq;   // P6：Generic Timer IRQ（不检查）
  logic        timer_virt_irq;
  logic        gic_irq_out;      // P6：GIC IRQ（不检查）
  logic        gic_fiq_out;
  logic [63:0] dbg_rdata;        // P6：RAM 调试读口（不检查）
  logic        dbg_mmu_en, dbg_dec_valid, dbg_dec_exc;  // P6 调试（不检查）
  logic [63:0] dbg_vbar_el1, dbg_dec_pc;
  logic [31:0] dbg_dec_insn, dbg_dec_exc_code;

  lcvex_soc_tb dut (
      .clk             (clk),
      .rst_n           (rst_n),
      .commit_ready    (commit_ready),
      .difftest_wait_release(1'b0),
      .difftest_wait_cntvct_valid(1'b0),
      .difftest_wait_cntvct(64'd0),
      .difftest_restore_sys_valid(1'b0),
      .difftest_restore_fp_valid(1'b0),
      .difftest_restore_fpcr(32'd0),
      .difftest_restore_fpsr(32'd0),
      .difftest_restore_fp_v_lo(restore_fp_v_lo),
      .difftest_restore_fp_v_hi(restore_fp_v_hi),
      .difftest_restore_pc(64'd0),
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
      .prog_we         (prog_we),
      .prog_addr       (prog_addr),
      .prog_strb       (prog_strb),
      .prog_wdata      (prog_wdata),
      .commit_valid    (commit_valid),
      .commit_pc       (commit_pc),
      .commit_next_pc  (commit_next_pc),
      .commit_insn     (commit_insn),
      .commit_gpr_we   (commit_gpr_we),
      .commit_gpr_rd   (commit_gpr_rd),
      .commit_gpr_wdata(commit_gpr_wdata),
      .commit_gpr2_we  (commit_gpr2_we),
      .commit_gpr2_rd  (commit_gpr2_rd),
      .commit_gpr2_wdata(commit_gpr2_wdata),
      .commit_gpr3_we  (commit_gpr3_we),
      .commit_gpr3_rd  (commit_gpr3_rd),
      .commit_gpr3_wdata(commit_gpr3_wdata),
      .commit_sp_we    (commit_sp_we),
      .commit_sp_wdata (commit_sp_wdata),
      .commit_nzcv_we  (commit_nzcv_we),
      .commit_nzcv     (commit_nzcv),
      .commit_mem_we   (commit_mem_we),
      .commit_mem_addr (commit_mem_addr),
      .commit_mem_wdata(commit_mem_wdata),
      .commit_mem_strb (commit_mem_strb),
      .commit_mem2_we  (commit_mem2_we),
      .commit_mem2_addr(commit_mem2_addr),
      .commit_mem2_wdata(commit_mem2_wdata),
      .commit_mem2_strb(commit_mem2_strb),
      .commit_exc_valid(commit_exc_valid),
      .commit_exc_code (commit_exc_code),
      .commit_exc_esr  (commit_exc_esr),
      .commit_exc_far  (commit_exc_far),
      .commit_mon_we   (commit_mon_we),
      .commit_mon_valid(commit_mon_valid),
      .commit_mon_addr (commit_mon_addr),
      .commit_mon_data (commit_mon_data),
      .commit_mon_data2(commit_mon_data2),
      .commit_vec_write_count(commit_vec_write_count),
      .commit_vec_rd0(commit_vec_rd0),
      .commit_vec_rd1(commit_vec_rd1),
      .commit_vec_rd2(commit_vec_rd2),
      .commit_vec_rd3(commit_vec_rd3),
      .commit_vec_wdata0_lo(commit_vec_wdata0_lo),
      .commit_vec_wdata0_hi(commit_vec_wdata0_hi),
      .commit_vec_wdata1_lo(commit_vec_wdata1_lo),
      .commit_vec_wdata1_hi(commit_vec_wdata1_hi),
      .commit_vec_wdata2_lo(commit_vec_wdata2_lo),
      .commit_vec_wdata2_hi(commit_vec_wdata2_hi),
      .commit_vec_wdata3_lo(commit_vec_wdata3_lo),
      .commit_vec_wdata3_hi(commit_vec_wdata3_hi),
      .commit_fpcr_we(commit_fpcr_we),
      .commit_fpcr_wdata(commit_fpcr_wdata),
      .commit_fpsr_we(commit_fpsr_we),
      .commit_fpsr_wdata(commit_fpsr_wdata),
      .fpcr_state(fpcr_state),
      .fpsr_state(fpsr_state),
      .fp_cpacr_el1_state(fp_cpacr_el1_state),
      .fp_v_lo(fp_v_lo),
      .fp_v_hi(fp_v_hi),
      .tlb_invalidate  (tlb_invalidate),
      .uart_tx_valid   (uart_tx_valid),
      .uart_tx_char    (uart_tx_char),
      .timer_phys_irq  (timer_phys_irq),
      .timer_virt_irq  (timer_virt_irq),
      .gic_irq_out     (gic_irq_out),
      .gic_fiq_out     (gic_fiq_out),
      .dbg_addr        (32'd0),
      .dbg_rdata       (dbg_rdata),
      .dbg_mmu_en      (dbg_mmu_en),
      .dbg_vbar_el1    (dbg_vbar_el1),
      .dbg_dec_valid   (dbg_dec_valid),
      .dbg_dec_exc     (dbg_dec_exc),
      .dbg_dec_insn    (dbg_dec_insn),
      .dbg_dec_pc      (dbg_dec_pc),
      .dbg_dec_exc_code(dbg_dec_exc_code)
  );

  always #5 clk = ~clk;  // 100 MHz

  // 8 条纯 ALU 指令 + 自循环：
  //   movz xN, #(N+1)  @ 0x44000000 + 4*N
  logic [31:0] prog[9];
  initial begin
    for (int i = 0; i < 8; i++) begin
      prog[i] = 32'hD2800000 | (32'(i + 1) << 5) | (32'(i) & 31);
    end
    prog[8] = 32'h14000000;  // b .
  end

  int         commits = 0;
  int         consec = 0;
  int         max_consec = 0;
  logic [63:0] expect_pc[8];
  logic [63:0] expect_val[8];
  logic        violated = 1'b0;

  initial begin
    $display("=== lcvex_commit_backpressure_tb: commit_fire valid/ready ===");
    clk = 1'b0;
    for (int i = 0; i < 8; i++) begin
      expect_pc[i] = 64'h0000_0000_4400_0000 + 4 * i;
      expect_val[i] = 64'(i + 1);
    end

    repeat (2) @(posedge clk);
    prog_we = 1'b1;
    for (int i = 0; i < 9; i++) begin
      prog_addr = 64'h0000_0000_4400_0000 + 4 * i;
      prog_strb = 8'h0f;
      prog_wdata = {32'd0, prog[i]};
      @(posedge clk);
    end
    prog_we = 1'b0;
    rst_n = 1'b1;

    // 等前 3 条提交，然后拉低 commit_ready 保持 7 周期
    while (commits < 3) begin
      @(posedge clk);
      if (commit_valid) begin
        check_commit();
      end
    end
    $display("-- 施加背压 commit_ready=0 x7 周期 --");
    commit_ready = 1'b0;
    repeat (7) begin
      @(posedge clk);
      if (commit_valid) begin
        $display("FAIL: commit_ready=0 期间仍提交 pc=0x%h", commit_pc);
        violated = 1'b1;
      end
    end
    commit_ready = 1'b1;

    // 释放后继续收集剩余提交；流水线排队条目应连续提交
    while (commits < 8) begin
      @(posedge clk);
      if (commit_valid) begin
        $display("commit[%0d] pc=0x%h rd=%0d wdata=0x%h",
                 commits, commit_pc, commit_gpr_rd, commit_gpr_wdata);
        check_commit();
        consec++;
        if (consec > max_consec) max_consec = consec;
      end else begin
        consec = 0;
      end
    end

    if (violated) $fatal(1, "FAIL: 背压期间出现提交");
    if (commits != 8) $fatal(1, "FAIL: 提交数 %0d != 8", commits);
    if (max_consec < 2)
      $fatal(1, "FAIL: 释放后未观察到连续提交（max_consec=%0d）", max_consec);

    $display("PASS: 背压不丢不重、释放后连续提交 %0d 条、提交数=%0d",
             max_consec, commits);

    // System commits are ID-level architectural boundaries too.  Hold the
    // consumer after the first scalar instruction and prove that CPACR/FPCR
    // and the commit packet remain unchanged until ready is returned.
    $display("=== system commit backpressure: MSR/FP state atomicity ===");
    rst_n = 1'b0;
    commit_ready = 1'b1;
    repeat (2) @(posedge clk);
    prog_we = 1'b1;
    prog_addr = 64'h0000_0000_4400_0000;
    prog_strb = 8'h0f;
    prog_wdata = 64'h0000_0000_D2A0_0600;  // movz x0,#0x30,lsl#16
    @(posedge clk);
    prog_addr = 64'h0000_0000_4400_0004;
    prog_wdata = 64'h0000_0000_D518_1040;  // msr cpacr_el1,x0
    @(posedge clk);
    prog_addr = 64'h0000_0000_4400_0008;
    prog_wdata = 64'h0000_0000_D2A0_F901;  // movz x1,#0x07c8,lsl#16
    @(posedge clk);
    prog_addr = 64'h0000_0000_4400_000c;
    prog_wdata = 64'h0000_0000_D51B_4401;  // msr fpcr,x1
    @(posedge clk);
    prog_addr = 64'h0000_0000_4400_0010;
    prog_wdata = 64'h0000_0000_D53B_4402;  // mrs x2,fpcr
    @(posedge clk);
    prog_addr = 64'h0000_0000_4400_0014;
    prog_wdata = 64'h0000_0000_1400_0000;  // b .
    @(posedge clk);
    prog_we = 1'b0;
    // Assert backpressure before the first instruction reaches ID.  This
    // makes the sampled ready boundary unambiguous: the following CPACR MSR
    // may be decoded/held, but cannot fire or update state.
    commit_ready = 1'b0;
    rst_n = 1'b1;

    wait_for_decode(64'h0000_0000_4400_0004);
    repeat (8) begin
      @(posedge clk);
      if (commit_valid)
        $fatal(1, "FAIL: system commit ready=0 期间仍产生提交 pc=0x%h",
               commit_pc);
      if (fp_cpacr_el1_state !== 64'd0 || fpcr_state !== 32'd0)
        $fatal(1, "FAIL: system commit ready=0 更新 FP state cpacr=0x%h fpcr=0x%h",
               fp_cpacr_el1_state, fpcr_state);
    end
    commit_ready = 1'b1;
    wait_for_commit(64'h0000_0000_4400_0000);
    wait_for_commit(64'h0000_0000_4400_0004);
    if (fp_cpacr_el1_state !== 64'h0000_0000_0030_0000)
      $fatal(1, "FAIL: CPACR system commit release 后未更新：0x%h",
             fp_cpacr_el1_state);

    // Again locate FPCR in ID while the consumer is already stopped, then
    // verify the ID-level system commit remains inert until release.
    commit_ready = 1'b0;
    wait_for_decode(64'h0000_0000_4400_000c);
    repeat (8) begin
      @(posedge clk);
      if (commit_valid)
        $fatal(1, "FAIL: FPCR system commit ready=0 期间仍产生提交 pc=0x%h",
               commit_pc);
      if (fpcr_state !== 32'd0)
        $fatal(1, "FAIL: FPCR ready=0 期间提前更新：0x%h", fpcr_state);
    end
    commit_ready = 1'b1;
    wait_for_commit(64'h0000_0000_4400_000c);
    if (!commit_fpcr_we || commit_fpcr_wdata !== 32'h07c8_0000 ||
        fpcr_state !== 32'h07c8_0000)
      $fatal(1, "FAIL: FPCR system commit release 后错误 we=%b effect=0x%h state=0x%h",
             commit_fpcr_we, commit_fpcr_wdata, fpcr_state);

    $display("PASS: system MSR commit 与 commit_ready 原子绑定");
    $finish;
  end

  task automatic check_commit();
    if (commits >= 8) return;
    if (commit_pc !== expect_pc[commits])
      $fatal(1, "FAIL: 第 %0d 条提交 pc=0x%h 期望 0x%h",
             commits, commit_pc, expect_pc[commits]);
    if (!commit_gpr_we || commit_gpr_rd !== 5'(commits) ||
        commit_gpr_wdata !== expect_val[commits])
      $fatal(1, "FAIL: 第 %0d 条 x%0d 写回 0x%h 期望 0x%h",
             commits, commit_gpr_rd, commit_gpr_wdata, expect_val[commits]);
    commits++;
  endtask

  task automatic wait_for_commit(input logic [63:0] expected_pc);
    bit seen;
    begin
      seen = 1'b0;
      for (int i = 0; i < 120; i++) begin
        @(posedge clk);
        if (commit_valid && commit_pc == expected_pc) begin
          seen = 1'b1;
          break;
        end
      end
      if (!seen)
        $fatal(1, "FAIL: 未观察到 system commit PC=0x%h", expected_pc);
    end
  endtask

  task automatic wait_for_decode(input logic [63:0] expected_pc);
    bit seen;
    begin
      seen = 1'b0;
      for (int i = 0; i < 120; i++) begin
        @(posedge clk);
        if (commit_valid)
          $fatal(1, "FAIL: system commit 背压建立前已有提交 pc=0x%h",
                 commit_pc);
        if (dbg_dec_valid && dbg_dec_pc == expected_pc) begin
          seen = 1'b1;
          break;
        end
      end
      if (!seen)
        $fatal(1, "FAIL: 背压期间未观察到 ID PC=0x%h", expected_pc);
    end
  endtask
endmodule
/* verilator lint_on UNUSEDSIGNAL */
