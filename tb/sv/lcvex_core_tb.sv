// lcvex_core_tb.sv
// 独立 SystemVerilog testbench：加载 MOVZ/B 小程序，
// 验证核心执行、提交包与 GPR 写回。
// 运行方式：make sim-sv

`timescale 1ns/1ps

/* verilator lint_off UNUSEDSIGNAL */  // testbench 仅检查部分字段
module lcvex_core_tb #(
    parameter logic TIMER_REALTIME = 1'b0,
    parameter logic [63:0] CNTFRQ_HZ = 64'd1_000_000_000,
    parameter int D_L1_ENABLE = 0,
    parameter int L2_ENABLE = 0,
    parameter int CATAPULT_COH_ENABLE = 0
);
  import lcvex_pkg::*;

  localparam logic [63:0] T016_BASE = 64'h0000_0000_4400_0000;
  localparam logic [63:0] T_REGOFF_RB = T016_BASE + 64'h100;
  localparam logic [63:0] T_REGOFF_TTBR0 = T016_BASE + 64'h1000;
  localparam logic [63:0] T_REGOFF_TTBR1 = T016_BASE + 64'h2000;
  localparam logic [63:0] T_REGOFF_DESCS = T016_BASE + 64'h3000;
  localparam logic [63:0] T_REGOFF_INFOS = T016_BASE + 64'h4000;
  localparam logic [63:0] T_MMU_BYTE_SRC = T016_BASE + 64'h5000;
  localparam int MMU_BYTE_COUNT = 128;
  logic        clk;
  logic        rst_n = 1'b0;
  logic        restore_sys_valid = 1'b0;
  logic [63:0] restore_sys_pc = 64'd0;
  logic        restore_sys_el = 1'b0;
  logic [63:0] restore_sys_sctlr = 64'd0;
  logic [63:0] restore_sys_tcr = 64'd0;
  logic [63:0] restore_sys_ttbr0 = 64'd0;
  logic [63:0] restore_sys_ttbr1 = 64'd0;
  logic [63:0] restore_sys_mair = 64'd0;
  logic        commit_ready = 1'b1;  // M1：提交消费者恒就绪（smoke 测试）
  logic        prog_we = 1'b0;
  logic [63:0] prog_addr = 64'd0;
  logic [7:0]  prog_strb = 8'h00;
  logic [63:0] prog_wdata = 64'd0;
  logic [31:0] dbg_addr = 32'd0;
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
  logic        tlb_invalidate;   // M2-4b：TLBI 脉冲（smoke 测试不检查）
  logic        uart_tx_valid;    // P6：PL011 TX（smoke 测试不检查）
  logic [7:0]  uart_tx_char;
  logic [7:0]  mmu_uart_chars[0:MMU_BYTE_COUNT-1];
  integer      mmu_uart_char_count;
  logic        timer_phys_irq;   // P6：Generic Timer IRQ（不检查）
  logic        timer_virt_irq;
  logic        gic_irq_out;      // P6：GIC IRQ（不检查）
  logic        gic_fiq_out;
  logic [63:0] dbg_rdata;        // P6：RAM 调试读口（不检查）
  logic        dbg_mmu_en, dbg_dec_valid, dbg_dec_exc;  // P6 调试（不检查）
  logic [63:0] dbg_vbar_el1, dbg_dec_pc;
  logic [31:0] dbg_dec_insn, dbg_dec_exc_code;
  logic        perf_dl1_read_miss;
  logic        perf_l2_read_hit;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      mmu_uart_char_count <= 0;
    end else if (uart_tx_valid) begin
      if (mmu_uart_char_count < MMU_BYTE_COUNT)
        mmu_uart_chars[mmu_uart_char_count] <= uart_tx_char;
      mmu_uart_char_count <= mmu_uart_char_count + 1;
    end
  end

  lcvex_soc_tb #(
      .TIMER_REALTIME(TIMER_REALTIME), .CNTFRQ_HZ(CNTFRQ_HZ),
      .D_L1_ENABLE(D_L1_ENABLE), .L2_ENABLE(L2_ENABLE),
      .CATAPULT_COH_ENABLE(CATAPULT_COH_ENABLE)
  ) dut (
      .clk             (clk),
      .rst_n           (rst_n),
      .commit_ready    (commit_ready),
      .difftest_wait_release(1'b0),
      .difftest_wait_cntvct_valid(1'b0),
      .difftest_wait_cntvct(64'd0),
      .difftest_restore_sys_valid(restore_sys_valid),
      .difftest_restore_fp_valid(1'b0),
      .difftest_restore_fpcr(32'd0),
      .difftest_restore_fpsr(32'd0),
      .difftest_restore_fp_v_lo(restore_fp_v_lo),
      .difftest_restore_fp_v_hi(restore_fp_v_hi),
      .difftest_restore_pc(restore_sys_pc),
      .difftest_restore_sp_el0(64'd0),
      .difftest_restore_sp_el1(64'd0),
      .difftest_restore_nzcv(4'd0),
      .difftest_restore_el(restore_sys_el),
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
      .difftest_restore_sctlr_el1(restore_sys_sctlr),
      .difftest_restore_tcr_el1(restore_sys_tcr),
      .difftest_restore_ttbr0_el1(restore_sys_ttbr0),
      .difftest_restore_ttbr1_el1(restore_sys_ttbr1),
      .difftest_restore_mair_el1(restore_sys_mair),
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
      .dbg_addr        (dbg_addr),
      .dbg_rdata       (dbg_rdata),
      .dbg_mmu_en      (dbg_mmu_en),
      .dbg_vbar_el1    (dbg_vbar_el1),
      .dbg_dec_valid   (dbg_dec_valid),
      .dbg_dec_exc     (dbg_dec_exc),
      .dbg_dec_insn    (dbg_dec_insn),
      .dbg_dec_pc      (dbg_dec_pc),
      .dbg_dec_exc_code(dbg_dec_exc_code),
      .perf_dl1_read_miss(perf_dl1_read_miss),
      .perf_l2_read_hit(perf_l2_read_hit)
  );

  always #5 clk = ~clk;  // 100 MHz

  task automatic wait_for_commit(input logic [63:0] expected_pc);
    bit seen;
    begin
      seen = 1'b0;
      for (int i = 0; i < 80; i++) begin
        @(posedge clk);
        if (commit_valid && commit_pc == expected_pc) begin
          seen = 1'b1;
          break;
        end
      end
      if (!seen)
        $fatal(1, "FAIL: 未观察到 PC=0x%h 的提交", expected_pc);
    end
  endtask

  // T-016 focused probes share this existing SoC harness so the checks see
  // the real core pipeline, FP wrapper and commit packet.  The loader keeps
  // reset asserted while writing, exactly as the normal smoke does.
  task automatic t016_start_case;
    begin
      rst_n      = 1'b0;
      restore_sys_valid = 1'b0;
      restore_sys_pc = 64'd0;
      restore_sys_el = 1'b0;
      restore_sys_sctlr = 64'd0;
      restore_sys_tcr = 64'd0;
      restore_sys_ttbr0 = 64'd0;
      restore_sys_ttbr1 = 64'd0;
      restore_sys_mair = 64'd0;
      prog_we    = 1'b0;
      prog_strb  = 8'h00;
      prog_addr  = 64'd0;
      prog_wdata = 64'd0;
      commit_ready = 1'b1;
      repeat (2) @(posedge clk);
    end
  endtask

  task automatic t016_write_word(input integer index,
                                 input logic [31:0] word);
    begin
      prog_we    = 1'b1;
      prog_addr  = T016_BASE + (64'(index) * 64'd4);
      prog_strb  = 8'h0f;
      prog_wdata = {32'd0, word};
      @(posedge clk);
    end
  endtask

  // Reproduce the loader's three-word LDR/STR post-index copy loop in local
  // SRAM. This is deliberately small so writeback/loop regressions fail in a
  // short core simulation instead of requiring a full Linux image boot.
  task automatic t_postindex_loop;
    integer loads;
    integer stores;
    integer byte_loads;
    integer byte_stores;
    bit done;
    begin
      t016_start_case();
      t016_write_word(0,  32'hD2A8_8000); // movz x0,#0x4400,lsl #16
      t016_write_word(1,  32'h9104_0000); // add x0,x0,#0x100
      t016_write_word(2,  32'hAA00_03E1); // mov x1,x0
      t016_write_word(3,  32'h9102_0021); // add x1,x1,#0x80
      t016_write_word(4,  32'hD280_0182); // movz x2,#12
      t016_write_word(5,  32'hB840_4403); // ldr w3,[x0],#4
      t016_write_word(6,  32'hB800_4423); // str w3,[x1],#4
      t016_write_word(7,  32'hF100_1042); // subs x2,x2,#4
      t016_write_word(8,  32'hF100_105F); // cmp x2,#4
      t016_write_word(9,  32'h5400_0043); // b.lo done
      t016_write_word(10, 32'h17FF_FFFB); // b loop
      t016_write_word(11, 32'hD2A8_8004); // movz x4,#0x4400,lsl #16
      t016_write_word(12, 32'h9108_0084); // add x4,x4,#0x200
      t016_write_word(13, 32'hAA04_03E5); // mov x5,x4
      t016_write_word(14, 32'h9102_00A5); // add x5,x5,#0x80
      t016_write_word(15, 32'hD280_0206); // movz x6,#16
      t016_write_word(16, 32'h3840_1487); // ldrb w7,[x4],#1
      t016_write_word(17, 32'h3800_14A7); // strb w7,[x5],#1
      t016_write_word(18, 32'hF100_04C6); // subs x6,x6,#1
      t016_write_word(19, 32'hB5FF_FFA6); // cbnz x6, byte_loop
      t016_write_word(20, 32'hD503_201F); // done: nop
      t016_write_word(21, 32'h1400_0000); // b .
      t016_write_word(64, 32'h1122_3344);
      t016_write_word(65, 32'h5566_7788);
      t016_write_word(66, 32'hAABB_CCDD);
      t016_write_word(128, 32'h4443_4241); // source bytes "ABCD"
      t016_write_word(129, 32'h4847_4645); // "EFGH"
      t016_write_word(130, 32'h4C4B_4A49); // "IJKL"
      t016_write_word(131, 32'h504F_4E4D); // "MNOP"
      prog_we = 1'b0;
      rst_n = 1'b1;

      loads = 0;
      stores = 0;
      byte_loads = 0;
      byte_stores = 0;
      done = 1'b0;
      for (int cycle = 0; cycle < 2000; cycle++) begin
        @(posedge clk);
        #1;
        if (commit_valid && commit_exc_valid)
          $fatal(1, "POSTINDEX unexpected exception pc=%h code=%h far=%h",
                 commit_pc, commit_exc_code, commit_exc_far);
        if (commit_valid && commit_pc == T016_BASE + 64'd20) begin
          if (!commit_gpr_we || commit_gpr_rd != 5'd3)
            $fatal(1, "POSTINDEX LDR GPR effect missing count=%0d", loads);
          if (!commit_gpr3_we || commit_gpr3_rd != 5'd0 ||
              commit_gpr3_wdata != (T016_BASE + 64'h104 + 64'(loads*4)))
            $fatal(1, "POSTINDEX LDR base writeback mismatch count=%0d rd=%0d data=%h",
                   loads, commit_gpr3_rd, commit_gpr3_wdata);
          case (loads)
            0: if (commit_gpr_wdata != 64'h1122_3344)
                 $fatal(1, "POSTINDEX first loaded word mismatch %h", commit_gpr_wdata);
            1: if (commit_gpr_wdata != 64'h5566_7788)
                 $fatal(1, "POSTINDEX second loaded word mismatch %h", commit_gpr_wdata);
            2: if (commit_gpr_wdata != 64'hAABB_CCDD)
                 $fatal(1, "POSTINDEX third loaded word mismatch %h", commit_gpr_wdata);
            default: $fatal(1, "POSTINDEX too many loads count=%0d", loads);
          endcase
          loads++;
        end
        if (commit_valid && commit_pc == T016_BASE + 64'd24) begin
          if (!commit_mem_we || commit_mem_addr !=
                                  (T016_BASE + 64'h180 + 64'(stores*4)) ||
              commit_mem_strb != 8'h0f)
            $fatal(1, "POSTINDEX STR memory effect mismatch count=%0d addr=%h strb=%h",
                   stores, commit_mem_addr, commit_mem_strb);
          if (!commit_gpr3_we || commit_gpr3_rd != 5'd1 ||
              commit_gpr3_wdata != (T016_BASE + 64'h184 + 64'(stores*4)))
            $fatal(1, "POSTINDEX STR base writeback mismatch count=%0d rd=%0d data=%h",
                   stores, commit_gpr3_rd, commit_gpr3_wdata);
          stores++;
        end
        if (commit_valid && commit_pc == T016_BASE + 64'd64) begin
          if (!commit_gpr_we || commit_gpr_rd != 5'd7 ||
              commit_gpr_wdata != (64'h41 + 64'(byte_loads)))
            $fatal(1, "POSTINDEX LDRB mismatch count=%0d rd=%0d data=%h",
                   byte_loads, commit_gpr_rd, commit_gpr_wdata);
          if (!commit_gpr3_we || commit_gpr3_rd != 5'd4 ||
              commit_gpr3_wdata !=
                  (T016_BASE + 64'h201 + 64'(byte_loads)))
            $fatal(1, "POSTINDEX LDRB base writeback mismatch count=%0d rd=%0d data=%h",
                   byte_loads, commit_gpr3_rd, commit_gpr3_wdata);
          byte_loads++;
        end
        if (commit_valid && commit_pc == T016_BASE + 64'd68) begin
          if (!commit_mem_we || commit_mem_addr !=
                                  (T016_BASE + 64'h280 + 64'(byte_stores)) ||
              commit_mem_strb != 8'h01 ||
              commit_mem_wdata[7:0] != (8'h41 + 8'(byte_stores)))
            $fatal(1, "POSTINDEX STRB memory effect mismatch count=%0d addr=%h data=%h strb=%h",
                   byte_stores, commit_mem_addr, commit_mem_wdata,
                   commit_mem_strb);
          if (!commit_gpr3_we || commit_gpr3_rd != 5'd5 ||
              commit_gpr3_wdata !=
                  (T016_BASE + 64'h281 + 64'(byte_stores)))
            $fatal(1, "POSTINDEX STRB base writeback mismatch count=%0d rd=%0d data=%h",
                   byte_stores, commit_gpr3_rd, commit_gpr3_wdata);
          byte_stores++;
        end
        if (commit_valid && commit_pc == T016_BASE + 64'd80) begin
          done = 1'b1;
          break;
        end
      end
      if (!done || loads != 3 || stores != 3 ||
          byte_loads != 16 || byte_stores != 16)
        $fatal(1, "POSTINDEX loops did not converge done=%b word=%0d/%0d byte=%0d/%0d pc=%h x2=%h x6=%h",
               done, loads, stores, byte_loads, byte_stores,
               dut.core.if_pc, dut.core.gpr[2], dut.core.gpr[6]);
      if (dut.core.gpr[0] != T016_BASE + 64'h10c ||
          dut.core.gpr[1] != T016_BASE + 64'h18c || dut.core.gpr[2] != 0 ||
          dut.core.gpr[4] != T016_BASE + 64'h210 ||
          dut.core.gpr[5] != T016_BASE + 64'h290 || dut.core.gpr[6] != 0)
        $fatal(1, "POSTINDEX final GPR mismatch x0=%h x1=%h x2=%h x4=%h x5=%h x6=%h",
               dut.core.gpr[0], dut.core.gpr[1], dut.core.gpr[2],
               dut.core.gpr[4], dut.core.gpr[5], dut.core.gpr[6]);

      dbg_addr = 32'h0400_0180;
      @(posedge clk);
      #1;
      if (dbg_rdata != 64'h5566_7788_1122_3344)
        $fatal(1, "POSTINDEX copied pair mismatch %016h", dbg_rdata);
      dbg_addr = 32'h0400_0188;
      @(posedge clk);
      #1;
      if (dbg_rdata[31:0] != 32'hAABB_CCDD)
        $fatal(1, "POSTINDEX copied tail mismatch %08h", dbg_rdata[31:0]);
      dbg_addr = 32'h0400_0280;
      @(posedge clk);
      #1;
      if (dbg_rdata != 64'h4847_4645_4443_4241)
        $fatal(1, "POSTINDEX byte-loop first 8 bytes mismatch %016h", dbg_rdata);
      dbg_addr = 32'h0400_0288;
      @(posedge clk);
      #1;
      if (dbg_rdata != 64'h504F_4E4D_4C4B_4A49)
        $fatal(1, "POSTINDEX byte-loop second 8 bytes mismatch %016h", dbg_rdata);
      $display("PASS POSTINDEX repeated LDR/STR and LDRB/STRB loops D_L1_ENABLE=%0d",
               D_L1_ENABLE);
    end
  endtask

  // T-002 Linux regression: mirror printk's descriptor-index sequence, where
  // two UMULLs follow an LDP and the second result is immediately consumed as
  // an LDR register offset. Run with stage-1 translation enabled: the MMU may
  // not capture that address until the ID source hazards have settled.
  task automatic t_umull_regoffset_ldr;
    bit done;
    bit saw_expected_addr;
    bit saw_stale_addr;
    begin
      t016_start_case();
      t016_write_word(0, 32'hD2A8_8019); // movz x25,#0x4400,lsl #16
      t016_write_word(1, 32'h9104_0339); // add x25,x25,#0x100
      t016_write_word(2, 32'hD280_003A); // movz x26,#1
      t016_write_word(3, 32'hD280_031B); // movz x27,#24
      t016_write_word(4, 32'hD280_0B1C); // movz x28,#88
      t016_write_word(5, 32'hB940_0321); // ldr w1,[x25]
      t016_write_word(6, 32'hF940_1322); // ldr x2,[x25,#32]
      t016_write_word(7, 32'h1AC1_2341); // lsl w1,w26,w1
      t016_write_word(8, 32'h5100_0421); // sub w1,w1,#1
      t016_write_word(9, 32'h8A02_0021); // and x1,x1,x2
      t016_write_word(10,32'hA940_AF28); // ldp x8,x11,[x25,#8]
      t016_write_word(11,32'h9BBC_7C2A); // umull x10,w1,w28
      t016_write_word(12,32'h9BBB_7C21); // umull x1,w1,w27 -> 0x17fe8
      t016_write_word(13,32'hF861_6903); // ldr x3,[x8,x1]
      t016_write_word(14,32'h1400_0000); // b .

      // One L1 block maps VA 0x40000000..0x7fffffff to the same PA range.
      // AttrIdx 0 is Normal WB; AF and inner-shareable are set.
      prog_we    = 1'b1;
      prog_addr  = T_REGOFF_TTBR0 + 64'd8;
      prog_strb  = 8'hff;
      prog_wdata = 64'h0000_0000_4000_0501;
      @(posedge clk);
      prog_we = 1'b1;
      prog_addr = T_REGOFF_RB;
      prog_strb = 8'hff;
      prog_wdata = 64'd12;
      @(posedge clk);
      prog_addr = T_REGOFF_RB + 64'd8;
      prog_wdata = T_REGOFF_DESCS;
      @(posedge clk);
      prog_addr = T_REGOFF_RB + 64'd16;
      prog_wdata = T_REGOFF_INFOS;
      @(posedge clk);
      prog_addr = T_REGOFF_RB + 64'd32;
      prog_wdata = 64'h0000_0000_ffff_efff;
      @(posedge clk);
      prog_we    = 1'b1;
      prog_addr  = T_REGOFF_DESCS + 64'h17fe8;
      prog_strb  = 8'hff;
      prog_wdata = 64'hc000_0000_ffff_efff;
      @(posedge clk);
      #1;
      prog_we = 1'b0;

      restore_sys_pc = T016_BASE;
      restore_sys_el = 1'b1;
      restore_sys_sctlr = 64'h0000_0000_0000_1005;
      restore_sys_tcr = 64'h0000_0035_b559_3519;
      restore_sys_ttbr0 = T_REGOFF_TTBR0;
      restore_sys_ttbr1 = 64'd0;
      restore_sys_mair = 64'h0000_0004_0044_ffff;
      rst_n = 1'b1;
      restore_sys_valid = 1'b1;
      @(posedge clk);
      #1;
      restore_sys_valid = 1'b0;
      @(negedge clk);
      if (!dut.core.mmu_en_eff || !dut.core.sctlr_el1[0])
        $fatal(1, "UMULL_REGOFFSET stage-1 translation was not enabled");

      done = 1'b0;
      saw_expected_addr = 1'b0;
      saw_stale_addr = 1'b0;
      for (int cycle = 0; cycle < 600; cycle++) begin
        @(negedge clk);
        if (dut.dmem_req_valid && dut.dmem_req_ready) begin
          if (dut.dmem_req.addr == (T_REGOFF_DESCS + 64'h17fe8))
            saw_expected_addr = 1'b1;
          if (dut.dmem_req.addr == (T_REGOFF_DESCS + 64'h0fff))
            saw_stale_addr = 1'b1;
        end
        @(posedge clk);
        #1;
        if (commit_valid && commit_exc_valid)
          $fatal(1, "UMULL_REGOFFSET unexpected exception pc=%h code=%h far=%h",
                 commit_pc, commit_exc_code, commit_exc_far);
        if (commit_valid && commit_pc == T016_BASE + 64'd52) begin
          if (!commit_gpr_we || commit_gpr_rd != 5'd3 ||
              commit_gpr_wdata != 64'hc000_0000_ffff_efff)
            $fatal(1, "UMULL_REGOFFSET LDR result mismatch addr_expected=%b addr_stale=%b rd=%0d data=%016h x1=%016h",
                   saw_expected_addr, saw_stale_addr,
                   commit_gpr_rd, commit_gpr_wdata, dut.core.gpr[1]);
          done = 1'b1;
          break;
        end
      end
      if (!done || !saw_expected_addr || saw_stale_addr ||
          dut.core.gpr[1] != 64'h17fe8 || dut.core.gpr[10] != 64'h57fa8)
        $fatal(1, "UMULL_REGOFFSET address/data invariant failed done=%b expected=%b stale=%b x1=%h x10=%h",
               done, saw_expected_addr, saw_stale_addr,
               dut.core.gpr[1], dut.core.gpr[10]);
      $display("PASS UMULL_REGOFFSET LDR D_L1_ENABLE=%0d", D_L1_ENABLE);
    end
  endtask

  function automatic logic [7:0] t_mmu_byte_pattern(input int index);
    t_mmu_byte_pattern = 8'h41 + 8'(index % 26);
  endfunction

  // Verify every byte lane of two cache lines through stage-1 translation and
  // D-L1. The TTBR1 variant uses a 39-bit high VA and a three-level 4 KiB page
  // walk, matching Linux's kernel linear-map address and page-table shape.
  task automatic t_mmu_ldrb_scan(input logic ttbr1_mode,
                                 input logic conflict_mode,
                                 input logic uart_mode);
    integer byte_loads;
    integer replay_byte_loads;
    integer conflict_loads;
    integer store_count;
    integer control_reads;
    integer physical_reads;
    integer dl1_target_misses;
    integer l2_target_hits;
    integer cycles_ran;
    bit done;
    logic [63:0] source_va;
    logic [31:0] init_word;
    logic [31:0] expected_head;
    logic [63:0] expected_tail;
    logic [63:0] data_req_addr[0:MMU_BYTE_COUNT*2-1];
    logic [7:0] expected_byte;
    begin
      t016_start_case();
      if (conflict_mode && !ttbr1_mode)
        $fatal(1, "MMU_LDRB conflict scenario requires TTBR1 high VA");
      if (conflict_mode && uart_mode)
        $fatal(1, "MMU_LDRB conflict and UART scenarios are mutually exclusive");
      if (uart_mode && (!ttbr1_mode || !CATAPULT_COH_ENABLE))
        $fatal(1, "MMU_LDRB UART scenario requires high VA and Catapult coherence");
      t016_write_word(0, 32'hD28A_0004); // movz x4,#0x5000
      if (uart_mode) begin
        // Synthetic kernel-image TTBR1 VA region, close to the observed
        // ffffffc080xxxxxx Linux PC range: root L1[258], L2[1], L3[5].
        t016_write_word(1, 32'hF2B0_0404); // movk x4,#0x8020,lsl #16
        t016_write_word(2, 32'hF2DF_F804); // movk x4,#0xffc0,lsl #32
        t016_write_word(3, 32'hF2FF_FFE4); // movk x4,#0xffff,lsl #48
      end else if (ttbr1_mode) begin
        t016_write_word(1, 32'hF2A8_8004); // movk x4,#0x4400,lsl #16
        t016_write_word(2, 32'hF2DF_F004); // movk x4,#0xff80,lsl #32
        t016_write_word(3, 32'hF2FF_FFE4); // movk x4,#0xffff,lsl #48
      end else begin
        t016_write_word(1, 32'hF2A8_8004); // movk x4,#0x4400,lsl #16
        t016_write_word(2, 32'hD503_201F);
        t016_write_word(3, 32'hD503_201F);
      end
      if (conflict_mode) begin
        t016_write_word(4, 32'h9100_0089); // add x9,x4,#0 (save source VA)
        t016_write_word(5, 32'hD280_1006); // movz x6,#128
        t016_write_word(6, 32'h3840_1487); // ldrb w7,[x4],#1
        t016_write_word(7, 32'hF100_04C6); // subs x6,x6,#1
        t016_write_word(8, 32'hB5FF_FFC6); // cbnz x6, first_scan
        t016_write_word(9, 32'h913E_0084); // add x4,x4,#0xf80 -> PA + 0x1000
        t016_write_word(10,32'h3940_0088); // ldrb w8,[x4] (same L1 set, page +1)
        t016_write_word(11,32'h9140_0484); // add x4,x4,#1,lsl #12
        t016_write_word(12,32'h9101_0084); // add x4,x4,#64 (next L1 set)
        t016_write_word(13,32'h3940_0088); // ldrb w8,[x4] (same L1 set, page +2)
        t016_write_word(14,32'h9100_0124); // add x4,x9,#0 (restore source VA)
        t016_write_word(15,32'hD280_1006); // movz x6,#128
        t016_write_word(16,32'h3840_1487); // ldrb w7,[x4],#1
        t016_write_word(17,32'hF100_04C6); // subs x6,x6,#1
        t016_write_word(18,32'hB5FF_FFC6); // cbnz x6, replay_scan
        t016_write_word(19,32'hD503_201F); // done: nop
        t016_write_word(20,32'h1400_0000); // b .
      end else if (uart_mode) begin
        t016_write_word(4, 32'hD2A1_2005); // movz x5,#0x0900,lsl #16
        t016_write_word(5, 32'hD280_1006); // movz x6,#128
        t016_write_word(6, 32'hB940_04A8); // ldr w8,[x5,#4] (JTAG UART WSPACE)
        t016_write_word(7, 32'h3840_1487); // ldrb w7,[x4],#1
        t016_write_word(8, 32'hB900_00A7); // str w7,[x5] (JTAG UART DATA)
        t016_write_word(9, 32'hF100_04C6); // subs x6,x6,#1
        t016_write_word(10,32'hB5FF_FF86); // cbnz x6, control/read/write loop
        t016_write_word(11,32'hD503_201F); // done: nop
        t016_write_word(12,32'h1400_0000); // b .
      end else begin
        t016_write_word(4, 32'hD280_1006); // movz x6,#128
        t016_write_word(5, 32'h3840_1487); // ldrb w7,[x4],#1
        t016_write_word(6, 32'hF100_04C6); // subs x6,x6,#1
        t016_write_word(7, 32'hB5FF_FFC6); // cbnz x6, byte_load
        t016_write_word(8, 32'hD503_201F); // done: nop
        t016_write_word(9, 32'h1400_0000); // b .
      end
      if (uart_mode)
        source_va = 64'hffff_ffc0_8020_5000;
      else
        source_va = ttbr1_mode ? 64'hffff_ff80_4400_5000 : T_MMU_BYTE_SRC;

      // Initialize two contiguous cache lines with distinctive printable bytes.
      for (int word_index = 0; word_index < MMU_BYTE_COUNT/4; word_index++) begin
        init_word = 32'd0;
        for (int byte_index = 0; byte_index < 4; byte_index++)
          init_word[byte_index*8 +: 8] =
              t_mmu_byte_pattern(word_index*4 + byte_index);
        @(negedge clk);
        prog_we = 1'b1;
        prog_addr = T_MMU_BYTE_SRC + 64'(word_index*4);
        prog_strb = 8'h0f;
        prog_wdata = {32'd0, init_word};
        @(posedge clk);
      end
      if (conflict_mode) begin
        // These lines differ by 4 KiB from the two target lines and therefore
        // alias the direct-mapped D-L1 sets while remaining in distinct L2 sets.
        for (int word_index = 0; word_index < 16; word_index++) begin
          @(negedge clk);
          prog_we = 1'b1;
          prog_addr = T_MMU_BYTE_SRC + 64'h1000 + 64'(word_index*4);
          prog_strb = 8'h0f;
          prog_wdata = {32'd0, 32'hc1c1_c1c1};
          @(posedge clk);
          @(negedge clk);
          prog_addr = T_MMU_BYTE_SRC + 64'h2040 + 64'(word_index*4);
          prog_wdata = {32'd0, 32'hd2d2_d2d2};
          @(posedge clk);
        end
      end
      expected_head = 32'd0;
      for (int byte_index = 0; byte_index < 4; byte_index++)
        expected_head[byte_index*8 +: 8] = t_mmu_byte_pattern(byte_index);
      expected_tail = 64'd0;
      for (int byte_index = 0; byte_index < 8; byte_index++)
        expected_tail[byte_index*8 +: 8] =
            t_mmu_byte_pattern(MMU_BYTE_COUNT - 8 + byte_index);
      dbg_addr = 32'h0400_0000;
      @(posedge clk);
      #1;
      if (dbg_rdata[31:0] != 32'hD28A_0004)
        $fatal(1, "MMU_LDRB program preload corrupt got=%08h", dbg_rdata[31:0]);
      dbg_addr = 32'h0400_5000;
      @(posedge clk);
      #1;
      if (dbg_rdata[31:0] != expected_head)
        $fatal(1, "MMU_LDRB source preload corrupt expected=%08h got=%08h",
               expected_head, dbg_rdata[31:0]);
      dbg_addr = 32'(T_MMU_BYTE_SRC - 64'h4000_0000 + MMU_BYTE_COUNT - 8);
      @(posedge clk);
      #1;
      if (dbg_rdata != expected_tail)
        $fatal(1, "MMU_LDRB preload tail corrupt expected=%016h got=%016h",
               expected_tail, dbg_rdata);

      // Identity-map VA 0x40000000..0x7fffffff as a 1 GiB Normal-WB block.
      prog_we = 1'b1;
      prog_addr = T_REGOFF_TTBR0;
      prog_strb = 8'hff;
      prog_wdata = 64'h0000_0000_0000_0501;
      @(posedge clk);
      @(negedge clk);
      prog_addr = T_REGOFF_TTBR0 + 64'd8;
      prog_strb = 8'hff;
      prog_wdata = 64'h0000_0000_4000_0501;
      @(posedge clk);
      @(negedge clk);
      prog_addr = T_REGOFF_RB;
      prog_wdata = 64'd12;
      @(posedge clk);
      @(negedge clk);
      prog_addr = T_REGOFF_RB + 64'd8;
      prog_wdata = T_REGOFF_DESCS;
      @(posedge clk);
      @(negedge clk);
      prog_addr = T_REGOFF_RB + 64'd16;
      prog_wdata = T_REGOFF_INFOS;
      @(posedge clk);
      @(negedge clk);
      prog_addr = T_REGOFF_RB + 64'd32;
      prog_wdata = 64'h0000_0000_ffff_efff;
      @(posedge clk);
      @(negedge clk);
      // TTBR1[1] -> L2[32] -> L3[5] -> 4 KiB page at PA 0x44005000.
      // The chosen high VA is 0xffffff8044005000 (39-bit T1SZ=25).
      prog_addr = T_REGOFF_TTBR1 + 64'd8;
      prog_wdata = T_REGOFF_DESCS | 64'h3;
      @(posedge clk);
      @(negedge clk);
      prog_addr = T_REGOFF_DESCS + 64'h100;
      prog_wdata = T_REGOFF_INFOS | 64'h3;
      @(posedge clk);
      @(negedge clk);
      // Kernel-image window: TTBR1 L1[258] -> L2[1] -> the same L3 table.
      prog_addr = T_REGOFF_TTBR1 + 64'h810;
      prog_wdata = T_REGOFF_DESCS | 64'h3;
      @(posedge clk);
      @(negedge clk);
      prog_addr = T_REGOFF_DESCS + 64'h8;
      prog_wdata = T_REGOFF_INFOS | 64'h3;
      @(posedge clk);
      @(negedge clk);
      prog_addr = T_REGOFF_INFOS + 64'h28;
      prog_wdata = T_MMU_BYTE_SRC | 64'h503;
      @(posedge clk);
      @(negedge clk);
      prog_addr = T_REGOFF_INFOS + 64'h30;
      prog_wdata = (T_MMU_BYTE_SRC + 64'h1000) | 64'h503;
      @(posedge clk);
      @(negedge clk);
      prog_addr = T_REGOFF_INFOS + 64'h38;
      prog_wdata = (T_MMU_BYTE_SRC + 64'h2000) | 64'h503;
      @(posedge clk);
      @(negedge clk);
      prog_we = 1'b0;
      if (uart_mode) begin
        dbg_addr = 32'h0400_1000;
        @(posedge clk);
        #1;
        if (dbg_rdata != 64'h0000_0000_0000_0501)
          $fatal(1, "MMU_LDRB UART identity device block corrupt got=%016h",
                 dbg_rdata);
      end
      dbg_addr = 32'h0400_1008;
      @(posedge clk);
      #1;
      if (dbg_rdata != 64'h0000_0000_4000_0501)
        $fatal(1, "MMU_LDRB root descriptor preload corrupt got=%016h",
               dbg_rdata);
      if (ttbr1_mode) begin
        dbg_addr = 32'h0400_2008;
        @(posedge clk);
        #1;
        if (dbg_rdata != (T_REGOFF_DESCS | 64'h3))
          $fatal(1, "MMU_LDRB TTBR1 root entry corrupt got=%016h", dbg_rdata);
        dbg_addr = 32'h0400_3100;
        @(posedge clk);
        #1;
        if (dbg_rdata != (T_REGOFF_INFOS | 64'h3))
          $fatal(1, "MMU_LDRB TTBR1 level-2 entry corrupt got=%016h", dbg_rdata);
        dbg_addr = 32'h0400_4028;
        @(posedge clk);
        #1;
        if (dbg_rdata != (T_MMU_BYTE_SRC | 64'h503))
          $fatal(1, "MMU_LDRB TTBR1 page entry corrupt got=%016h", dbg_rdata);
        if (uart_mode) begin
          dbg_addr = 32'h0400_2810;
          @(posedge clk);
          #1;
          if (dbg_rdata != (T_REGOFF_DESCS | 64'h3))
            $fatal(1, "MMU_LDRB kernel TTBR1 L1 entry corrupt got=%016h", dbg_rdata);
          dbg_addr = 32'h0400_3008;
          @(posedge clk);
          #1;
          if (dbg_rdata != (T_REGOFF_INFOS | 64'h3))
            $fatal(1, "MMU_LDRB kernel TTBR1 L2 entry corrupt got=%016h", dbg_rdata);
        end
        if (conflict_mode) begin
          dbg_addr = 32'h0400_4030;
          @(posedge clk);
          #1;
          if (dbg_rdata != ((T_MMU_BYTE_SRC + 64'h1000) | 64'h503))
            $fatal(1, "MMU_LDRB conflict page-1 entry corrupt got=%016h", dbg_rdata);
          dbg_addr = 32'h0400_4038;
          @(posedge clk);
          #1;
          if (dbg_rdata != ((T_MMU_BYTE_SRC + 64'h2000) | 64'h503))
            $fatal(1, "MMU_LDRB conflict page-2 entry corrupt got=%016h", dbg_rdata);
        end
      end

      restore_sys_pc = T016_BASE;
      restore_sys_el = 1'b1;
      restore_sys_sctlr = 64'h0000_0000_0000_1005;
      restore_sys_tcr = 64'h0000_0035_b559_3519;
      restore_sys_ttbr0 = T_REGOFF_TTBR0;
      restore_sys_ttbr1 = ttbr1_mode ? T_REGOFF_TTBR1 : 64'd0;
      restore_sys_mair = 64'h0000_0004_0044_ffff;
      rst_n = 1'b1;
      restore_sys_valid = 1'b1;
      @(posedge clk);
      #1;
      restore_sys_valid = 1'b0;
      @(negedge clk);
      if (!dut.core.mmu_en_eff || !dut.core.sctlr_el1[0])
        $fatal(1, "MMU_LDRB stage-1 translation was not enabled");

      byte_loads = 0;
      replay_byte_loads = 0;
      conflict_loads = 0;
      store_count = 0;
      control_reads = 0;
      physical_reads = 0;
      dl1_target_misses = 0;
      l2_target_hits = 0;
      cycles_ran = 0;
      for (int request_index = 0; request_index < MMU_BYTE_COUNT*2;
           request_index++)
        data_req_addr[request_index] = 64'd0;
      done = 1'b0;
      for (int cycle = 0; cycle < 20000; cycle++) begin
        cycles_ran = cycle + 1;
        @(negedge clk);
        if (dut.dmem_req_valid && dut.dmem_req_ready && !dut.dmem_req.we &&
            dut.dmem_req.addr >= T_MMU_BYTE_SRC &&
            dut.dmem_req.addr < T_MMU_BYTE_SRC + MMU_BYTE_COUNT &&
            physical_reads < MMU_BYTE_COUNT*2) begin
          data_req_addr[physical_reads] = dut.dmem_req.addr;
          physical_reads++;
        end
        if (perf_dl1_read_miss &&
            (((dut.dmem_req.addr >= T_MMU_BYTE_SRC) &&
              (dut.dmem_req.addr < T_MMU_BYTE_SRC + MMU_BYTE_COUNT)) ||
             ((dut.dmem_req.addr >= T_MMU_BYTE_SRC + 64'h1000) &&
              (dut.dmem_req.addr < T_MMU_BYTE_SRC + 64'h1040)) ||
             ((dut.dmem_req.addr >= T_MMU_BYTE_SRC + 64'h2040) &&
              (dut.dmem_req.addr < T_MMU_BYTE_SRC + 64'h2080))))
          dl1_target_misses++;
        if (perf_l2_read_hit &&
            dut.arb_req.addr >= T_MMU_BYTE_SRC &&
            dut.arb_req.addr < T_MMU_BYTE_SRC + MMU_BYTE_COUNT)
          l2_target_hits++;
        @(posedge clk);
        #1;
        if (uart_mode && commit_valid && cycles_ran < 1000 &&
            commit_pc >= T016_BASE + 64'd24 &&
            commit_pc <= T016_BASE + 64'd48)
          $display("MMU_LDRB_UART_TRACE cycle=%0d pc=%016h next=%016h insn=%08h x4=%016h x5=%016h x6=%016h gpr_we=%b rd=%0d data=%016h mem_we=%b mem_addr=%016h mem_data=%016h",
                   cycles_ran, commit_pc, commit_next_pc, commit_insn,
                   dut.core.gpr[4], dut.core.gpr[5], dut.core.gpr[6],
                   commit_gpr_we, commit_gpr_rd, commit_gpr_wdata,
                   commit_mem_we, commit_mem_addr, commit_mem_wdata);
        if (commit_valid && commit_exc_valid)
          $fatal(1, "MMU_LDRB unexpected exception pc=%h code=%h far=%h",
                 commit_pc, commit_exc_code, commit_exc_far);
        if (commit_valid &&
            ((!conflict_mode && !uart_mode &&
              commit_pc == T016_BASE + 64'd20) ||
             (conflict_mode && commit_pc == T016_BASE + 64'd24) ||
             (uart_mode && commit_pc == T016_BASE + 64'd28))) begin
          expected_byte = t_mmu_byte_pattern(byte_loads);
          if (!commit_gpr_we || commit_gpr_rd != 5'd7 ||
              commit_gpr_wdata != {56'd0, expected_byte} ||
              data_req_addr[byte_loads] !=
                  T_MMU_BYTE_SRC + 64'(byte_loads))
            $fatal(1, "MMU_LDRB byte mismatch index=%0d expected=%02h rd=%0d data=%016h req_pa=%016h dmem_rsp=%016h va=%016h pa=%016h",
                   byte_loads, expected_byte, commit_gpr_rd,
                   commit_gpr_wdata, data_req_addr[byte_loads],
                   dut.dmem_rsp.rdata, dut.core.exmem_mem_addr,
                   dut.core.exmem_mem_paddr);
          if (!commit_gpr3_we || commit_gpr3_rd != 5'd4 ||
              commit_gpr3_wdata != source_va + 64'(byte_loads + 1))
            $fatal(1, "MMU_LDRB writeback mismatch index=%0d rd=%0d data=%016h",
                   byte_loads, commit_gpr3_rd, commit_gpr3_wdata);
          byte_loads++;
        end
        if (uart_mode && commit_valid &&
            commit_pc == T016_BASE + 64'd24) begin
          if (!commit_gpr_we || commit_gpr_rd != 5'd8 ||
              commit_gpr_wdata != 64'h0000_0000_0040_0000)
            $fatal(1, "MMU_LDRB JTAG CONTROL/WSPACE read mismatch rd=%0d data=%016h",
                   commit_gpr_rd, commit_gpr_wdata);
          control_reads++;
        end
        if (uart_mode && commit_valid &&
            commit_pc == T016_BASE + 64'd32) begin
          expected_byte = t_mmu_byte_pattern(store_count);
          if (!commit_mem_we || commit_mem_addr != 64'h0000_0000_0900_0000 ||
              commit_mem_strb != 8'h0f ||
              commit_mem_wdata[7:0] != expected_byte)
            $fatal(1, "MMU_LDRB UART STR W mismatch index=%0d mem_we=%b addr=%016h strb=%02h data=%016h expected=%02h",
                   store_count, commit_mem_we, commit_mem_addr,
                   commit_mem_strb, commit_mem_wdata, expected_byte);
          store_count++;
        end
        if (conflict_mode && commit_valid &&
            (commit_pc == T016_BASE + 64'd40 ||
             commit_pc == T016_BASE + 64'd52)) begin
          expected_byte = (commit_pc == T016_BASE + 64'd40) ? 8'hc1 : 8'hd2;
          if (!commit_gpr_we || commit_gpr_rd != 5'd8 ||
              commit_gpr_wdata != {56'd0, expected_byte})
            $fatal(1, "MMU_LDRB conflict load mismatch pc=%h expected=%02h rd=%0d data=%016h",
                   commit_pc, expected_byte, commit_gpr_rd, commit_gpr_wdata);
          conflict_loads++;
        end
        if (conflict_mode && commit_valid &&
            commit_pc == T016_BASE + 64'd64) begin
          expected_byte = t_mmu_byte_pattern(replay_byte_loads);
          if (!commit_gpr_we || commit_gpr_rd != 5'd7 ||
              commit_gpr_wdata != {56'd0, expected_byte} ||
              data_req_addr[MMU_BYTE_COUNT + replay_byte_loads] !=
                  T_MMU_BYTE_SRC + 64'(replay_byte_loads))
            $fatal(1, "MMU_LDRB replay byte mismatch index=%0d expected=%02h rd=%0d data=%016h req_pa=%016h",
                   replay_byte_loads, expected_byte, commit_gpr_rd,
                   commit_gpr_wdata,
                   data_req_addr[MMU_BYTE_COUNT + replay_byte_loads]);
          if (!commit_gpr3_we || commit_gpr3_rd != 5'd4 ||
              commit_gpr3_wdata != source_va + 64'(replay_byte_loads + 1))
            $fatal(1, "MMU_LDRB replay writeback mismatch index=%0d rd=%0d data=%016h",
                   replay_byte_loads, commit_gpr3_rd, commit_gpr3_wdata);
          replay_byte_loads++;
        end
        if (commit_valid &&
            ((!conflict_mode && !uart_mode &&
              commit_pc == T016_BASE + 64'd32) ||
             (conflict_mode && commit_pc == T016_BASE + 64'd76) ||
             (uart_mode && commit_pc == T016_BASE + 64'd44))) begin
          if (uart_mode)
            $display("MMU_LDRB_UART_DONE cycle=%0d pc=%016h next=%016h x6=%016h loads=%0d stores=%0d",
                     cycles_ran, commit_pc, commit_next_pc,
                     dut.core.gpr[6], byte_loads, store_count);
          done = 1'b1;
          break;
        end
      end
      if (uart_mode) begin
        repeat (3) @(posedge clk);
        #1;
        if (store_count != MMU_BYTE_COUNT ||
            control_reads != MMU_BYTE_COUNT ||
            mmu_uart_char_count != MMU_BYTE_COUNT)
          $fatal(1, "MMU_LDRB UART byte count mismatch done=%b cycles=%0d loads=%0d control=%0d stores=%0d tx=%0d x4=%016h x5=%016h x6=%016h if_pc=%016h commit=%b/%b pc=%016h next=%016h insn=%08h wb=%b/%b pc=%016h next=%016h insn=%08h fetch_wait=%b target_settled=%b fetch=%b/%b/%b pc=%016h got=%b fault=%b fifo=%0d epoch=%0d head=%b/%016h/%0d stale=%b/%b/%b kill=%b fence=%b ctx=%0d freq=%b/%b done=%b imem=%b/%b addr=%016h ifid=%b pc=%016h insn=%08h idex=%b commit_valid=%b dreq=%b/%b addr=%016h we=%b bypass=%b drsp=%b/%b data=%016h issued=%b done=%b exmem=%b memwb=%b exaddr=%016h expa=%016h datareq=%b dataactive=%b mmu_req=%b mmu_accept=%b mmu_done=%b mmu_walk=%b mmu_state=%0d mmu_busy=%b mmu_reqva=%016h mmu_insn=%b poc=%b/%b addr=%016h delay=%b/%b",
                 done, cycles_ran, byte_loads, control_reads, store_count,
                 mmu_uart_char_count,
                 dut.core.gpr[4], dut.core.gpr[5], dut.core.gpr[6],
                 dut.core.if_pc, dut.core.commit_fire,
                 dut.core.memwb_committed_r, commit_pc, commit_next_pc,
                 commit_insn, dut.core.memwb_valid,
                 dut.core.memwb_committed_r, dut.core.memwb_pc,
                 dut.core.memwb_next_pc, dut.core.memwb_insn,
                 dut.core.memwb_fetch_wait,
                 dut.core.memwb_fetch_target_settled,
                 dut.core.fetch_pending, dut.core.fetch_translated,
                 dut.core.fetch_trans_busy, dut.core.fetch_pc_r,
                 dut.core.fetch_got_data, dut.core.fetch_faulted,
                 dut.core.fetch_fifo_count, dut.core.fetch_epoch,
                 dut.core.fetch_fifo_head_valid_dbg,
                 dut.core.fetch_fifo_head_pc_dbg,
                 dut.core.fetch_fifo_head_epoch_dbg,
                 dut.core.fetch_stale_mmu, dut.core.fetch_stale_imem,
                 dut.core.fetch_stale_drain, dut.core.frontend_kill,
                 dut.core.fetch_control_fence, dut.core.fetch_ctx_epoch,
                 dut.core.fetch_req_valid, dut.core.fetch_req_accept,
                 dut.core.mmu_done,
                 dut.imem_req_valid, dut.imem_req_ready, dut.imem_req.addr,
                 dut.core.ifid_valid, dut.core.ifid_pc, dut.core.ifid_insn,
                 dut.core.idex_valid, commit_valid,
                 dut.dmem_req_valid, dut.dmem_req_ready, dut.dmem_req.addr,
                 dut.dmem_req.we, dut.dmem_req.bypass, dut.dmem_rsp_valid,
                 dut.dmem_rsp_ready, dut.dmem_rsp.rdata,
                 dut.core.dmem_req_issued, dut.core.dmem_done,
                 dut.core.exmem_valid, dut.core.memwb_valid,
                 dut.core.exmem_mem_addr, dut.core.exmem_mem_paddr,
                 dut.core.data_req_valid, dut.core.data_trans_active,
                 dut.core.mmu_req_valid, dut.core.mmu_req_accept,
                 dut.core.mmu_done, dut.core.mmu_walking,
                 dut.core.mmu.state, dut.core.mmu.busy,
                 dut.core.mmu.req_va_r, dut.core.mmu.req_is_insn_r,
                 dut.l2_req_valid, dut.l2_req_accept,
                 dut.l2_req.addr, dut.del_req_valid, dut.del_req_ready);
        for (int byte_index = 0; byte_index < MMU_BYTE_COUNT; byte_index++)
          if (mmu_uart_chars[byte_index] != t_mmu_byte_pattern(byte_index))
            $fatal(1, "MMU_LDRB UART output mismatch index=%0d got=%02h expected=%02h",
                   byte_index, mmu_uart_chars[byte_index],
                   t_mmu_byte_pattern(byte_index));
      end
      if (!done || byte_loads != MMU_BYTE_COUNT ||
          replay_byte_loads != (conflict_mode ? MMU_BYTE_COUNT : 0) ||
          conflict_loads != (conflict_mode ? 2 : 0) ||
          store_count != (uart_mode ? MMU_BYTE_COUNT : 0) ||
          dut.core.gpr[4] != source_va + MMU_BYTE_COUNT ||
          dut.core.gpr[6] != 0 ||
          physical_reads != (conflict_mode ? 2*MMU_BYTE_COUNT : MMU_BYTE_COUNT))
        $fatal(1, "MMU_LDRB scan mismatch done=%b bytes=%0d replay=%0d conflict=%0d reads=%0d x4=%h x6=%h if_pc=%h el=%b mmu=%b walk=%b mmu_req=%b va=%016h pa=%016h fetch_valid=%b fetch_addr=%016h imem_valid=%b imem_ready=%b imem_addr=%016h last_pc=%h",
               done, byte_loads, replay_byte_loads, conflict_loads, physical_reads,
               dut.core.gpr[4], dut.core.gpr[6], dut.core.if_pc, dut.core.el,
               dut.core.mmu_en_eff, dut.core.mmu_walking,
               dut.core.mmu_req_valid, dut.core.mmu_req_va,
               dut.core.mmu_paddr, dut.core.fetch_imem_req_valid,
               dut.core.fetch_imem_req.addr, dut.imem_req_valid,
               dut.imem_req_ready, dut.imem_req.addr, commit_pc);
      if (conflict_mode && (CATAPULT_COH_ENABLE == 0) &&
          (D_L1_ENABLE == 0 || L2_ENABLE == 0 || dl1_target_misses < 6 ||
           l2_target_hits < 16))
        $fatal(1, "MMU_LDRB eviction path not exercised D_L1/L2=%0d/%0d dl1_miss=%0d l2_target_hit=%0d",
               D_L1_ENABLE, L2_ENABLE, dl1_target_misses, l2_target_hits);
      $display("PASS MMU_LDRB 128 printable bytes via %s%s D_L1_ENABLE=%0d L2_ENABLE=%0d CATAPULT_COH_ENABLE=%0d dl1_misses=%0d target_l2_hits=%0d",
               ttbr1_mode ? "TTBR1 4 KiB page" : "TTBR0 1 GiB block",
               conflict_mode ? " with direct-map eviction/replay" : "",
               D_L1_ENABLE, L2_ENABLE, CATAPULT_COH_ENABLE,
               dl1_target_misses, l2_target_hits);
    end
  endtask

  task automatic t016_check_owner_invariant;
    begin
      #1;
      if (dut.core.sys_commit === 1'b1) begin
        if (dut.core.fp_tx_active === 1'b1 ||
            dut.core.fp_tx_candidate === 1'b1 ||
            dut.core.fp_tx_issued === 1'b1 ||
            dut.core.fp_tx_busy === 1'b1 ||
            dut.core.fp_rsp_valid === 1'b1)
          $fatal(1, "T016 owner overlap at sys_commit");
        if (dut.core.fp_tx_kill === 1'b1)
          $fatal(1, "T016 sys_commit still drives fp_tx_kill");
      end
    end
  endtask

  // Run one short program whose system instruction is immediately younger
  // than an FP response.  The CPACR write is older than FP and is committed
  // before the response-producing FADD, so this is an architectural FP path,
  // not an FPEN-trap negative test.
  task automatic t016_system_after_fp(input logic [31:0] sys_insn,
                                      input integer system_kind,
                                      input string name);
    bit fp_seen;
    bit sys_seen;
    integer fp_index;
    integer sys_index;
    begin
      t016_start_case();
      if (system_kind == 1) begin
        // Give ERET an in-range ELR so this case exercises the normal return
        // path rather than the separate ERET-target abort behavior.
        t016_write_word(0, 32'hD2A8_800B); // movz x11,#0x4400,lsl#16
        t016_write_word(1, 32'hD518_402B); // msr elr_el1,x11
        t016_write_word(2, 32'hD2A0_060A); // movz x10,#0x30,lsl#16
        t016_write_word(3, 32'hD518_104A); // msr cpacr_el1,x10
        t016_write_word(4, 32'h1E20_2802); // fadd s2,s0,s1
        t016_write_word(5, sys_insn);
        t016_write_word(6, 32'h1400_0000); // b .
        fp_index = 4;
        sys_index = 5;
      end else begin
        t016_write_word(0, 32'hD2A0_060A); // movz x10,#0x30,lsl#16
        t016_write_word(1, 32'hD518_104A); // msr cpacr_el1,x10
        if (system_kind == 0) begin
          t016_write_word(2, 32'hD2A0_F90B); // movz x11,#0x7c8,lsl#16
          t016_write_word(3, 32'h1E20_2802); // fadd s2,s0,s0
          t016_write_word(4, sys_insn);
          t016_write_word(5, 32'h1400_0000); // b .
          fp_index = 3;
          sys_index = 4;
        end else begin
          t016_write_word(2, 32'h1E20_2802); // fadd s2,s0,s0
          t016_write_word(3, sys_insn);
          t016_write_word(4, 32'h1400_0000); // b .
          fp_index = 2;
          sys_index = 3;
        end
      end
      prog_we = 1'b0;
      rst_n = 1'b1;

      fp_seen = 1'b0;
      sys_seen = 1'b0;
      for (int cycle = 0; cycle < 1200; cycle++) begin
        @(posedge clk);
        t016_check_owner_invariant();
        if (commit_valid && commit_pc ==
                              (T016_BASE + (64'(fp_index) * 64'd4)))
          fp_seen = 1'b1;
        if (commit_valid && commit_pc ==
                              (T016_BASE + (64'(sys_index) * 64'd4))) begin
          sys_seen = 1'b1;
          if (commit_insn !== sys_insn)
            $fatal(1, "T016 %s system encoding mismatch: got %h want %h",
                   name, commit_insn, sys_insn);
          case (system_kind)
            0: begin // MSR FPCR, X11
              if (!commit_fpcr_we || commit_fpcr_wdata !== 32'h07c8_0000)
                $fatal(1, "T016 MSR after FP lost FPCR effect");
            end
            1: begin // ERET
              if (commit_exc_valid)
                $fatal(1, "T016 ERET after FP unexpectedly trapped");
            end
            2: begin // UDF/UDEF
              if (!commit_exc_valid || commit_exc_code !== EXC_UDEF)
                $fatal(1, "T016 UDEF after FP missing precise exception");
            end
            3: begin // WFI
              if (commit_exc_valid || dut.core.wfi_idle !== 1'b1)
                $fatal(1, "T016 WFI after FP did not enter idle");
            end
            default: $fatal(1, "T016 unknown system case %s", name);
          endcase
          break;
        end
      end
      if (!fp_seen)
        $fatal(1, "T016 %s did not retire the older FP response", name);
      if (!sys_seen)
        $fatal(1, "T016 %s system instruction did not retire", name);
      $display("PASS T016 system-after-FP %s", name);
    end
  endtask

  // A real multi-cycle MUL fills the fetch window.  When it releases, the
  // following MOVZ and FADD approach EX/MEM and ID/EX while MUL approaches
  // MEM/WB.  The small smoke schedule may still leave one elastic stage empty;
  // as in the IRQ-young directed TB, fill only that missing valid bit so real
  // stall_wb/exmem_can_accept logic creates the focused backpressure boundary.
  task automatic t016_held_response;
    logic [127:0] held_v;
    logic [63:0]  held_gpr;
    logic [31:0]  held_flags;
    logic [15:0]  held_tag;
    bit           saw_rsp;
    bit           released;
    integer       held_cycles;
    integer       consume_count;
    integer       fp_commit_count;
    bit           previous_rsp_valid;
    bit           cpacr_seen;
    bit           fp_started;
    bit           memwb_forced;
    bit           exmem_forced;
    bit           raw_boundary_seen;
    bit           hold_boundary_seen;
    begin
      t016_start_case();
      t016_write_word(0, 32'hD2A0_060A); // movz x10,#0x30,lsl#16
      t016_write_word(1, 32'hD518_104A); // msr cpacr_el1,x10
      t016_write_word(2, 32'hD280_0024); // movz x4,#1
      t016_write_word(3, 32'h9B04_7C85); // mul x5,x4,x4
      t016_write_word(4, 32'hD280_0020); // movz x0,#1
      t016_write_word(5, 32'h1E20_2802); // fadd s2,s0,s0
      t016_write_word(6, 32'h1400_0000); // b .
      prog_we = 1'b0;
      rst_n = 1'b1;
      // FPEN resets disabled.  Let the setup MSR retire first and wait until
      // the real FADD owns ID/EX before constructing the focused older-stage
      // backpressure boundary below.
      commit_ready = 1'b1;
      cpacr_seen = 1'b0;
      for (int cycle = 0; cycle < 200; cycle++) begin
        @(posedge clk);
        t016_check_owner_invariant();
        if (commit_valid && commit_pc == (T016_BASE + 64'd4)) begin
          cpacr_seen = 1'b1;
          break;
        end
      end
      if (!cpacr_seen)
        $fatal(1, "T016 held-response setup did not enable CPACR FPEN");
      fp_started = 1'b0;
      for (int cycle = 0; cycle < 200; cycle++) begin
        @(posedge clk);
        t016_check_owner_invariant();
        if (dut.core.fp_tx_candidate === 1'b1) begin
          fp_started = 1'b1;
          break;
        end
      end
      if (!fp_started)
        $fatal(1, "T016 held-response FADD did not enter ID/EX");
      commit_ready = 1'b0;
      memwb_forced = 1'b0;
      exmem_forced = 1'b0;
      raw_boundary_seen = 1'b0;
      hold_boundary_seen = 1'b0;
      #1;
      if (!dut.core.memwb_valid) begin
        force dut.core.memwb_valid = 1'b1;
        memwb_forced = 1'b1;
      end
      if (!dut.core.exmem_valid) begin
        force dut.core.exmem_valid = 1'b1;
        exmem_forced = 1'b1;
      end
      #1;
      if (!dut.core.stall_wb || dut.core.exmem_can_accept)
        $fatal(1, "T016 failed to establish focused WB backpressure");
      saw_rsp = 1'b0;
      released = 1'b0;
      held_cycles = 0;
      consume_count = 0;
      fp_commit_count = 0;
      previous_rsp_valid = 1'b0;

      for (int cycle = 0; cycle < 1400; cycle++) begin
        @(posedge clk);
        t016_check_owner_invariant();
        // R19: the wrapper-facing response handshake must remain open while
        // the core-side response is held by WB backpressure.  This proves
        // TX_DONE is decoupled from memwb_fetch_wait/stall_wb; the payload is
        // captured into the core's one-entry hold and consumed later through
        // the existing fp_rsp_ready boundary.
        if (dut.core.fp_exec_rsp_valid === 1'b1 &&
            dut.core.fp_rsp_hold_valid === 1'b0) begin
          if (dut.core.fp_exec_rsp_ready !== 1'b1)
            $fatal(1, "T016 R19 raw FP response remained coupled to WB stall");
          raw_boundary_seen = 1'b1;
        end
        if (dut.core.fp_rsp_hold_valid === 1'b1)
          hold_boundary_seen = 1'b1;
        if (dut.core.fp_rsp_valid === 1'b1) begin
          if (!saw_rsp) begin
            held_v = dut.core.fp_rsp.v_data;
            held_gpr = dut.core.fp_rsp.gpr_data;
            held_flags = dut.core.fp_rsp.fpsr_flags;
            held_tag = dut.core.fp_rsp.tag;
            saw_rsp = 1'b1;
          end else begin
            if (dut.core.fp_rsp.v_data !== held_v ||
                dut.core.fp_rsp.gpr_data !== held_gpr ||
                dut.core.fp_rsp.fpsr_flags !== held_flags ||
                dut.core.fp_rsp.tag !== held_tag)
              $fatal(1, "T016 TX_DONE payload changed under WB backpressure");
          end
          if (!released) begin
            if (dut.core.fp_rsp_ready !== 1'b0)
              $fatal(1, "T016 held FP response was accepted while WB blocked");
            held_cycles = held_cycles + 1;
            if (held_cycles >= 3) begin
              if (memwb_forced)
                release dut.core.memwb_valid;
              if (exmem_forced)
                release dut.core.exmem_valid;
              released = 1'b1;
              commit_ready = 1'b1;
            end
          end
        end
        // The combinational fp_consume pulse may be gone after the wrapper
        // state transition at this sampling point; count the held response's
        // observable TX_DONE valid falling edge instead.
        if (released && previous_rsp_valid &&
            dut.core.fp_rsp_valid === 1'b0)
          consume_count = consume_count + 1;
        if (commit_valid && commit_pc == (T016_BASE + 64'd20))
          fp_commit_count = fp_commit_count + 1;
        if (released && consume_count == 1 && fp_commit_count == 1)
          break;
        previous_rsp_valid = (dut.core.fp_rsp_valid === 1'b1);
      end
      if (!saw_rsp || held_cycles < 3 || !released ||
          !raw_boundary_seen || !hold_boundary_seen)
        $fatal(1, "T016 TX_DONE/R19 hold failed: saw=%0b held=%0d released=%0b raw_boundary=%0b hold_boundary=%0b ifid=%0b/%h idex=%0b/%h exmem=%0b/%h memwb=%0b/%h candidate=%0b issued=%0b busy=%0b rsp=%0b stall_id=%0b",
               saw_rsp, held_cycles, released, raw_boundary_seen,
               hold_boundary_seen,
               dut.core.ifid_valid, dut.core.ifid_pc,
               dut.core.idex_valid, dut.core.idex_pc,
               dut.core.exmem_valid, dut.core.exmem_pc,
               dut.core.memwb_valid, dut.core.memwb_pc,
               dut.core.fp_tx_candidate, dut.core.fp_tx_issued,
               dut.core.fp_tx_busy, dut.core.fp_rsp_valid,
               dut.core.stall_id);
      if (consume_count != 1 || fp_commit_count != 1)
        $fatal(1, "T016 FP held response consume=%0d commit=%0d",
               consume_count, fp_commit_count);
      $display("PASS T016 TX_DONE held response and single consume");
    end
  endtask

  function automatic logic [31:0] t016_cbnz_w(input integer rt,
                                               input integer from_index,
                                               input integer target_index);
    integer imm19;
    begin
      imm19 = target_index - from_index;
      t016_cbnz_w = 32'h3500_0000 |
                    ((imm19 & 32'h0007_ffff) << 5) | (rt & 31);
    end
  endfunction

  // SCVTF produces 3.5, then FCVTZS/FCVTZU writes W9=3.  CBNZ is the very
  // next instruction, so this probes the FP response's raw GPR payload and
  // the live forwarding path used by an immediate branch consumer.
  task automatic t016_fcvt_branch(input bit unsigned_convert,
                                  input string name);
    logic [31:0] fcvt_insn;
    bit raw_seen;
    bit fcvt_seen;
    bit bad_path_seen;
    bit target_seen;
    begin
      fcvt_insn = unsigned_convert ? 32'h1E39_00E9 : 32'h1E38_00E9;
      t016_start_case();
      t016_write_word(0, 32'h5280_00E8); // movz w8,#7
      t016_write_word(1, 32'hD2A0_060A); // movz x10,#0x30,lsl#16
      t016_write_word(2, 32'hD518_104A); // msr cpacr_el1,x10
      t016_write_word(3, 32'h1E02_FD07); // scvtf s7,w8,#1 => 3.5
      t016_write_word(4, fcvt_insn);      // FCVTZS/ZU W9,S7 => 3
      t016_write_word(5, t016_cbnz_w(9, 5, 8));
      t016_write_word(6, 32'hD281_75AC); // bad-path marker x12=0xBAD
      t016_write_word(7, 32'hD280_1B0D); // bad-path marker x13=0xD8
      t016_write_word(8, 32'hD281_4ACC); // taken marker x12=0xA56
      t016_write_word(9, 32'h1400_0000); // b .
      prog_we = 1'b0;
      rst_n = 1'b1;
      raw_seen = 1'b0;
      fcvt_seen = 1'b0;
      bad_path_seen = 1'b0;
      target_seen = 1'b0;

      for (int cycle = 0; cycle < 1800; cycle++) begin
        @(posedge clk);
        t016_check_owner_invariant();
        if (dut.core.fp_rsp_valid === 1'b1 &&
            dut.core.fp_rsp.gpr_we === 1'b1) begin
          if (dut.core.fp_rsp.gpr_rd !== 5'd9 ||
              dut.core.fp_rsp.gpr_data !== 64'd3)
            $fatal(1, "T016 %s raw FCVT GPR mismatch rd=%0d data=%h",
                   name, dut.core.fp_rsp.gpr_rd, dut.core.fp_rsp.gpr_data);
          raw_seen = 1'b1;
        end
        if (commit_valid && commit_pc == (T016_BASE + 64'd16)) begin
          if (!commit_gpr_we || commit_gpr_rd !== 5'd9 ||
              commit_gpr_wdata !== 64'd3)
            $fatal(1, "T016 %s FCVT commit GPR mismatch", name);
          fcvt_seen = 1'b1;
        end
        if (commit_valid && commit_pc == (T016_BASE + 64'd24))
          bad_path_seen = 1'b1;
        if (commit_valid && commit_pc == (T016_BASE + 64'd32)) begin
          if (!commit_gpr_we || commit_gpr_rd !== 5'd12 ||
              commit_gpr_wdata !== 64'hA56)
            $fatal(1, "T016 %s branch target marker mismatch", name);
          target_seen = 1'b1;
          break;
        end
      end
      if (!raw_seen || !fcvt_seen || bad_path_seen || !target_seen)
        $fatal(1, "T016 %s FCVT raw/branch probe failed raw=%b fcvt=%b bad=%b target=%b",
               name, raw_seen, fcvt_seen, bad_path_seen, target_seen);
      $display("PASS T016 %s immediate FCVT GPR RAW and CBNZ", name);
    end
  endtask

  task automatic t016_run_syskill_suite;
    begin
      $display("=== T016 focused core sys_commit/FP owner probes ===");
      t016_held_response();
      t016_system_after_fp(32'hD51B_440B, 0, "MSR_FPCR");
      t016_system_after_fp(32'hD69F_03E0, 1, "ERET");
      t016_system_after_fp(32'h0000_0000, 2, "UDEF");
      t016_system_after_fp(32'hD503_207F, 3, "WFI");
      t016_fcvt_branch(1'b0, "FCVTZS");
      t016_fcvt_branch(1'b1, "FCVTZU");
    end
  endtask

  initial begin
    $display("=== lcvex_core_tb: scalar + P7-0 FPCR/FPSR wiring smoke ===");
    clk = 1'b0;

    if ($test$plusargs("POSTINDEX_LOOP")) begin
      t_postindex_loop();
      $finish;
    end

    if ($test$plusargs("UMULL_REGOFFSET_LDR")) begin
      t_umull_regoffset_ldr();
      $finish;
    end

    if ($test$plusargs("MMU_TTBR1_LDRB_UART_SCAN")) begin
      t_mmu_ldrb_scan(1'b1, 1'b0, 1'b1);
      $finish;
    end

    if ($test$plusargs("MMU_TTBR1_LDRB_EVICT")) begin
      t_mmu_ldrb_scan(1'b1, 1'b1, 1'b0);
      $finish;
    end

    if ($test$plusargs("MMU_TTBR1_LDRB_SCAN")) begin
      t_mmu_ldrb_scan(1'b1, 1'b0, 1'b0);
      $finish;
    end

    if ($test$plusargs("MMU_LDRB_SCAN")) begin
      t_mmu_ldrb_scan(1'b0, 1'b0, 1'b0);
      $finish;
    end

    if ($test$plusargs("T016_SYSKILL")) begin
      t016_run_syskill_suite();
      $finish;
    end

    // 复位期间通过加载口写入程序：
    //   movz x0,#1; movz x1,#0x30,lsl#16; msr cpacr_el1,x1;
    //   mrs x2,fpcr; movz x3,#0x07c8,lsl#16; msr fpcr,x3; mrs x4,fpcr;
    //   movz x5,#0xffff; msr fpsr,x5; mrs x6,fpsr; b .
    repeat (2) @(posedge clk);
    prog_we    = 1'b1;
    prog_addr  = 64'h0000_0000_4400_0000;
    prog_strb  = 8'h0f;
    prog_wdata = 64'h0000_0000_D280_0020;
    @(posedge clk);
    prog_addr  = 64'h0000_0000_4400_0004;
    prog_wdata = 64'h0000_0000_D2A0_0601;
    @(posedge clk);
    prog_addr  = 64'h0000_0000_4400_0008;
    prog_wdata = 64'h0000_0000_D518_1041;
    @(posedge clk);
    prog_addr  = 64'h0000_0000_4400_000c;
    prog_wdata = 64'h0000_0000_D53B_4402;
    @(posedge clk);
    prog_addr  = 64'h0000_0000_4400_0010;
    prog_wdata = 64'h0000_0000_D2A0_F903;
    @(posedge clk);
    prog_addr  = 64'h0000_0000_4400_0014;
    prog_wdata = 64'h0000_0000_D51B_4403;
    @(posedge clk);
    prog_addr  = 64'h0000_0000_4400_0018;
    prog_wdata = 64'h0000_0000_D53B_4404;
    @(posedge clk);
    prog_addr  = 64'h0000_0000_4400_001c;
    prog_wdata = 64'h0000_0000_D29F_FFE5;
    @(posedge clk);
    prog_addr  = 64'h0000_0000_4400_0020;
    prog_wdata = 64'h0000_0000_D51B_4425;
    @(posedge clk);
    prog_addr  = 64'h0000_0000_4400_0024;
    prog_wdata = 64'h0000_0000_D53B_4426;
    @(posedge clk);
    prog_addr  = 64'h0000_0000_4400_0028;
    prog_wdata = 64'h0000_0000_D53B_E007;
    @(posedge clk);
    prog_addr  = 64'h0000_0000_4400_002c;
    prog_wdata = 64'h0000_0000_1400_0000;
    @(posedge clk);
    prog_we = 1'b0;

    rst_n = 1'b1;

    for (int i = 0; i < 40; i++) begin
      @(posedge clk);
      if (commit_valid) break;
    end

    if (!commit_valid)
      $fatal(1, "FAIL: 未观察到提交");
    if (commit_pc !== 64'h0000_0000_4400_0000)
      $fatal(1, "FAIL: commit_pc 应为 0x44000000，实际 0x%h", commit_pc);
    if (!commit_gpr_we || commit_gpr_rd !== 5'd0 || commit_gpr_wdata !== 64'd1)
      $fatal(1, "FAIL: x0 写回应为 1，实际 we=%b rd=%0d data=0x%h",
             commit_gpr_we, commit_gpr_rd, commit_gpr_wdata);
    if (commit_next_pc !== 64'h0000_0000_4400_0004)
      $fatal(1, "FAIL: next_pc 应为 0x44000004，实际 0x%h", commit_next_pc);

    wait_for_commit(64'h0000_0000_4400_0004);
    wait_for_commit(64'h0000_0000_4400_0008);
    if (fp_cpacr_el1_state !== 64'h0000_0000_0030_0000)
      $fatal(1, "FAIL: CPACR FPEN 接线值错误：0x%h", fp_cpacr_el1_state);

    wait_for_commit(64'h0000_0000_4400_000c);
    if (!commit_gpr_we || commit_gpr_rd !== 5'd2 || commit_gpr_wdata !== 64'd0)
      $fatal(1, "FAIL: MRS FPCR 读回错误：we=%b rd=%0d data=0x%h",
             commit_gpr_we, commit_gpr_rd, commit_gpr_wdata);
    wait_for_commit(64'h0000_0000_4400_0010);
    wait_for_commit(64'h0000_0000_4400_0014);
    if (!commit_fpcr_we || commit_fpcr_wdata !== 32'h07c8_0000)
      $fatal(1, "FAIL: MSR FPCR effect 错误：we=%b data=0x%h",
             commit_fpcr_we, commit_fpcr_wdata);
    wait_for_commit(64'h0000_0000_4400_0018);
    if (!commit_gpr_we || commit_gpr_rd !== 5'd4 ||
        commit_gpr_wdata !== 64'h0000_0000_07c8_0000)
      $fatal(1, "FAIL: MRS FPCR mask 读回错误：we=%b rd=%0d data=0x%h",
             commit_gpr_we, commit_gpr_rd, commit_gpr_wdata);
    wait_for_commit(64'h0000_0000_4400_001c);
    wait_for_commit(64'h0000_0000_4400_0020);
    if (!commit_fpsr_we || commit_fpsr_wdata !== 32'h0000_009f)
      $fatal(1, "FAIL: MSR FPSR effect 错误：we=%b data=0x%h",
             commit_fpsr_we, commit_fpsr_wdata);
    wait_for_commit(64'h0000_0000_4400_0024);
    if (!commit_gpr_we || commit_gpr_rd !== 5'd6 ||
        commit_gpr_wdata !== 64'h0000_0000_0000_009f)
      $fatal(1, "FAIL: MRS FPSR mask 读回错误：we=%b rd=%0d data=0x%h",
             commit_gpr_we, commit_gpr_rd, commit_gpr_wdata);
    wait_for_commit(64'h0000_0000_4400_0028);
    if (!commit_gpr_we || commit_gpr_rd !== 5'd7 ||
        commit_gpr_wdata !== CNTFRQ_HZ)
      $fatal(1, "FAIL: CNTFRQ_EL0 mismatch: we=%b rd=%0d data=0x%h expected=0x%h",
             commit_gpr_we, commit_gpr_rd, commit_gpr_wdata, CNTFRQ_HZ);
    if (TIMER_REALTIME) begin
      begin : check_realtime_tick
        logic [63:0] timer_start;
        timer_start = dut.core.cntpct_r;
        repeat (12) @(negedge clk);
        if ((dut.core.cntpct_r - timer_start) !== 64'd12)
          $fatal(1, "FAIL: realtime CNTVCT did not advance once per clock: start=%0d end=%0d",
                 timer_start, dut.core.cntpct_r);
      end
    end
    $display("PASS: CNTFRQ_EL0=%0d timer_realtime=%b",
             CNTFRQ_HZ, TIMER_REALTIME);
    if (fpcr_state !== 32'h07c8_0000 || fpsr_state !== 32'h0000_009f)
      $fatal(1, "FAIL: raw FPCR/FPSR state 错误：fpcr=0x%h fpsr=0x%h",
             fpcr_state, fpsr_state);

    $display("PASS: scalar + FPCR/FPSR MRS/MSR wiring and masked state");
    $finish;
  end
endmodule
/* verilator lint_on UNUSEDSIGNAL */
