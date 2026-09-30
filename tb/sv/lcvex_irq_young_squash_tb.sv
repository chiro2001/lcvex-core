// lcvex_irq_young_squash_tb.sv
//
// T-051：直接在核心 GIC IRQ 线上注入 ordinary IRQ，检查最老 WB 提交边界
// 同拍不会把 ID/EX、EX/MEM、MEM/WB 或年轻 transaction 带入 IRQ 向量。
// 该 TB 只使用已有 lcvex_soc_tb 内存/延迟模型；FIFO 和 MEM_DELAY_MODE
// 由顶层参数在 Makefile 中分别编译运行。

`timescale 1ns/1ps

/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off PINMISSING */
/* verilator lint_off MULTIDRIVEN */
/* verilator lint_off WIDTHEXPAND */
module lcvex_irq_young_squash_tb #(
  parameter int MEM_DELAY_MODE = 0,
  parameter int FETCH_FIFO_ENABLE = 1,
  parameter int I_L1_ENABLE = 0,
  parameter int D_L1_ENABLE = 0,
  parameter int L2_ENABLE = 0,
  parameter logic [63:0] RESET_PC = 64'h0000_0000_4400_0000
);
  import lcvex_pkg::*;

  localparam logic [63:0] BASE = 64'h0000_0000_4400_0000;
  localparam logic [63:0] SRAM = 64'h0000_0000_4000_0000;
  localparam logic [31:0] NOP = 32'hD503201F;
  localparam logic [31:0] B_SELF = 32'h14000000;

  logic clk = 1'b0;
  logic rst_n = 1'b0;
  logic commit_ready = 1'b1;
  logic prog_we = 1'b0;
  logic [63:0] prog_addr = 64'd0;
  logic [7:0]  prog_strb = 8'd0;
  logic [63:0] prog_wdata = 64'd0;
  logic [63:0] restore_fp_v_lo [0:31] = '{default:64'd0};
  logic [63:0] restore_fp_v_hi [0:31] = '{default:64'd0};

  logic irq_drive = 1'b0;
  bit irq_forced = 1'b0;
  bit fp_cpacr_forced = 1'b0;
  bit memwb_forced = 1'b0;
  bit commit_fire_forced = 1'b0;

  logic [31:0] prog_words [0:63];

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
  logic        commit_fpcr_we;
  logic [31:0] commit_fpcr_wdata;
  logic        commit_fpsr_we;
  logic [31:0] commit_fpsr_wdata;
  logic [31:0] fpcr_state;
  logic [31:0] fpsr_state;
  logic [63:0] fp_cpacr_el1_state;
  logic [63:0] fp_v_lo [0:31];
  logic [63:0] fp_v_hi [0:31];
  logic        tlb_invalidate;
  logic        uart_tx_valid;
  logic [7:0]  uart_tx_char;
  logic        timer_phys_irq;
  logic        timer_virt_irq;
  logic        gic_irq_out;
  logic        gic_fiq_out;
  logic [63:0] dbg_rdata;

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
      .prog_we(prog_we),
      .prog_addr(prog_addr),
      .prog_strb(prog_strb),
      .prog_wdata(prog_wdata),
      .commit_valid(commit_valid),
      .commit_pc(commit_pc),
      .commit_next_pc(commit_next_pc),
      .commit_insn(commit_insn),
      .commit_gpr_we(commit_gpr_we),
      .commit_gpr_rd(commit_gpr_rd),
      .commit_gpr_wdata(commit_gpr_wdata),
      .commit_gpr2_we(commit_gpr2_we),
      .commit_gpr2_rd(commit_gpr2_rd),
      .commit_gpr2_wdata(commit_gpr2_wdata),
      .commit_gpr3_we(commit_gpr3_we),
      .commit_gpr3_rd(commit_gpr3_rd),
      .commit_gpr3_wdata(commit_gpr3_wdata),
      .commit_sp_we(commit_sp_we),
      .commit_sp_wdata(commit_sp_wdata),
      .commit_nzcv_we(commit_nzcv_we),
      .commit_nzcv(commit_nzcv),
      .commit_mem_we(commit_mem_we),
      .commit_mem_addr(commit_mem_addr),
      .commit_mem_wdata(commit_mem_wdata),
      .commit_mem_strb(commit_mem_strb),
      .commit_mem2_we(commit_mem2_we),
      .commit_mem2_addr(commit_mem2_addr),
      .commit_mem2_wdata(commit_mem2_wdata),
      .commit_mem2_strb(commit_mem2_strb),
      .commit_exc_valid(commit_exc_valid),
      .commit_exc_code(commit_exc_code),
      .commit_exc_esr(commit_exc_esr),
      .commit_exc_far(commit_exc_far),
      .commit_mon_we(commit_mon_we),
      .commit_mon_valid(commit_mon_valid),
      .commit_mon_addr(commit_mon_addr),
      .commit_mon_data(commit_mon_data),
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
      .tlb_invalidate(tlb_invalidate),
      .uart_tx_valid(uart_tx_valid),
      .uart_tx_char(uart_tx_char),
      .timer_phys_irq(timer_phys_irq),
      .timer_virt_irq(timer_virt_irq),
      .gic_irq_out(gic_irq_out),
      .gic_fiq_out(gic_fiq_out),
      .dbg_addr(32'd0),
      .dbg_rdata(dbg_rdata)
  );

  always #5 clk = ~clk;

  function automatic logic [31:0] movz(input integer rd, input integer imm16,
                                        input integer hw);
    movz = 32'hD2800000 | (32'(hw) << 21) |
           (32'(imm16 & 16'hffff) << 5) | 32'(rd & 31);
  endfunction

  function automatic logic [31:0] fp3(input logic [31:0] base_insn,
                                       input integer rd, input integer rn,
                                       input integer rm);
    fp3 = base_insn | (32'(rm) << 16) | (32'(rn) << 5) | 32'(rd);
  endfunction

  task automatic release_irq_sources;
    begin
      irq_drive = 1'b0;
      if (irq_forced) begin
        release dut.gic_irq;
        irq_forced = 1'b0;
      end
    end
  endtask

  task automatic release_injection;
    begin
      release_irq_sources();
      if (fp_cpacr_forced) begin
        release dut.core.fp_state.cpacr_el1_state;
        fp_cpacr_forced = 1'b0;
      end
      if (memwb_forced) begin
        release_old_wb_override();
      end
    end
  endtask

  task automatic release_old_wb_override;
    begin
      if (memwb_forced) begin
        release dut.core.memwb_exc;
        release dut.core.memwb_pc;
        release dut.core.memwb_next_pc;
        release dut.core.memwb_insn;
        release dut.core.memwb_wb_we;
        release dut.core.memwb_wb_rd;
        release dut.core.memwb_wb2_we;
        release dut.core.memwb_wb2_rd;
        release dut.core.memwb_wb3_we;
        release dut.core.memwb_wb3_rd;
        release dut.core.memwb_sp_we;
        release dut.core.memwb_nzcv_we;
        release dut.core.memwb_is_load;
        release dut.core.memwb_is_store;
        release dut.core.memwb_is_ldxr;
        release dut.core.memwb_is_stxr;
        release dut.core.memwb_is_clrex;
        release dut.core.memwb_is_pair;
        release dut.core.memwb_fp_valid;
        release dut.core.memwb_fp_wb_we;
        release dut.core.memwb_fp_fpsr_we;
        release dut.core.memwb_neon_valid;
        release dut.core.memwb_neon_wb_we;
        if (commit_fire_forced) begin
          release dut.core.commit_fire;
          commit_fire_forced = 1'b0;
        end
        memwb_forced = 1'b0;
      end
    end
  endtask

  // A normal scalar stream intentionally alternates empty/valid elastic
  // boundaries.  A memory or held-FP transaction can nevertheless coexist
  // with an older WB entry in F1a; this helper makes that precise boundary
  // explicit when the small directed TB reaches the transaction first.
  task automatic ensure_old_wb(input logic [63:0] old_pc);
    begin
      if (!dut.core.memwb_valid) begin
        force dut.core.memwb_exc = 1'b0;
        force dut.core.memwb_pc = old_pc;
        force dut.core.memwb_next_pc = old_pc + 64'd4;
        force dut.core.memwb_insn = NOP;
        force dut.core.memwb_wb_we = 1'b0;
        force dut.core.memwb_wb_rd = 5'd0;
        force dut.core.memwb_wb2_we = 1'b0;
        force dut.core.memwb_wb2_rd = 5'd0;
        force dut.core.memwb_wb3_we = 1'b0;
        force dut.core.memwb_wb3_rd = 5'd0;
        force dut.core.memwb_sp_we = 1'b0;
        force dut.core.memwb_nzcv_we = 1'b0;
        force dut.core.memwb_is_load = 1'b0;
        force dut.core.memwb_is_store = 1'b0;
        force dut.core.memwb_is_ldxr = 1'b0;
        force dut.core.memwb_is_stxr = 1'b0;
        force dut.core.memwb_is_clrex = 1'b0;
        force dut.core.memwb_is_pair = 1'b0;
        force dut.core.memwb_fp_valid = 1'b0;
        force dut.core.memwb_fp_wb_we = 1'b0;
        force dut.core.memwb_fp_fpsr_we = 1'b0;
        force dut.core.memwb_neon_valid = 1'b0;
        force dut.core.memwb_neon_wb_we = 1'b0;
        force dut.core.commit_fire = 1'b1;
        commit_fire_forced = 1'b1;
        memwb_forced = 1'b1;
      end
    end
  endtask

  task automatic load_program(input integer words);
    begin
      release_injection();
      rst_n = 1'b0;
      commit_ready = 1'b1;
      repeat (2) @(posedge clk);
      prog_we = 1'b1;
      prog_strb = 8'h0f;
      for (int i = 0; i < words; i++) begin
        prog_addr = BASE + 64'(i * 4);
        prog_wdata = {32'd0, prog_words[i]};
        @(posedge clk);
      end
      prog_we = 1'b0;
      prog_strb = 8'd0;
      @(posedge clk);
      rst_n = 1'b1;
      repeat (2) @(posedge clk);
    end
  endtask

  task automatic write_mem_word(input logic [63:0] addr,
                                input logic [63:0] value);
    begin
      prog_we = 1'b1;
      prog_strb = 8'hff;
      prog_addr = addr;
      prog_wdata = value;
      @(posedge clk);
      #1;
      prog_we = 1'b0;
      prog_strb = 8'd0;
    end
  endtask

  task automatic wait_for_idex_slot(output logic [63:0] old_pc,
                                     output bit natural_old_wb);
    begin
      old_pc = 64'd0;
      natural_old_wb = 1'b0;
      for (int i = 0; i < 1200; i++) begin
        @(posedge clk);
        #1;
        if (dut.core.idex_valid && dut.core.memwb_valid) begin
          old_pc = dut.core.memwb_pc;
          natural_old_wb = 1'b1;
          return;
        end
      end
      // FIFO-off's elastic schedule may not overlap an ordinary ALU with WB;
      // use the first real ID/EX observation as the direct stage boundary.
      for (int i = 0; i < 1200; i++) begin
        @(posedge clk);
        #1;
        if (dut.core.idex_valid) begin
          old_pc = BASE + 64'h100;
          return;
        end
      end
      $fatal(1, "T051 timeout waiting for ID/EX slot");
    end
  endtask

  task automatic wait_for_store_slot(output logic [63:0] old_pc);
    begin
      old_pc = 64'd0;
      for (int i = 0; i < 1600; i++) begin
        @(posedge clk);
        #1;
        if (dut.core.exmem_valid && dut.core.exmem_is_store &&
            dut.core.dmem_req_valid) begin
          old_pc = dut.core.memwb_valid ? dut.core.memwb_pc : BASE + 64'h100;
          return;
        end
      end
      $fatal(1, "T051 timeout waiting for younger store transaction");
    end
  endtask

  task automatic wait_for_fp_slot(output logic [63:0] old_pc);
    begin
      old_pc = 64'd0;
      for (int i = 0; i < 1800; i++) begin
        @(posedge clk);
        #1;
        if (dut.core.idex_valid && dut.core.fp_tx_candidate &&
            dut.core.fp_rsp_valid) begin
          old_pc = dut.core.memwb_valid ? dut.core.memwb_pc : BASE + 64'h200;
          return;
        end
      end
      $fatal(1, "T051 timeout waiting for held FP response");
    end
  endtask

  task automatic inject_irq(input logic [63:0] old_pc,
                             input bit check_not_ready,
                             input string label);
    begin
      // IRQ must be pending but cannot be taken while the consumer is not
      // ready.  Once ready is restored, the same cycle is the precise edge.
      dut.core.daif = 4'b0000;
      irq_drive = 1'b1;
      force dut.gic_irq = irq_drive;
      irq_forced = 1'b1;
      #1;
      if (!dut.core.irq_pending_raw)
        $fatal(1, "T051 %s IRQ was not pending", label);
      if (check_not_ready) begin
        commit_ready = 1'b0;
        #1;
        if (dut.core.irq_taken)
          $fatal(1, "T051 %s irq_taken asserted with commit_ready=0", label);
        @(posedge clk);
        #1;
        if (dut.core.irq_taken ||
            (!dut.core.memwb_valid && !commit_fire_forced))
          $fatal(1, "T051 %s WB was not held while commit_ready=0", label);
        commit_ready = 1'b1;
        #1;
      end
      if (!dut.core.irq_taken || !commit_ready)
        $fatal(1, "T051 %s precise irq_taken edge missing", label);
      if (dut.core.dmem_req_valid || dut.core.dmem_req_accept ||
          dut.core.maint_dmem_req_valid || dut.core.maint_dmem_req_accept)
        $fatal(1, "T051 %s younger dmem request leaked on IRQ edge", label);
      @(posedge clk);
      #1;
      // A forced synthetic older WB is released after the edge so the
      // post-edge stage check observes the core's real squash assignment.
      release_old_wb_override();
      release_irq_sources();
      if (!commit_valid || !commit_exc_valid || commit_exc_code != EXC_IRQ)
        $fatal(1, "T051 %s IRQ packet missing pc=%h code=%h", label,
               commit_pc, commit_exc_code);
      if (commit_pc != old_pc)
        $fatal(1, "T051 %s older WB pc changed: got=%h want=%h", label,
               commit_pc, old_pc);
      if (commit_next_pc != dut.core.irq_vector_core || !commit_nzcv_we ||
          commit_nzcv != 4'd0 || !commit_sp_we ||
          dut.core.elr_el1 != old_pc + 64'd4 || dut.core.el != 1'b1 ||
          dut.core.sp_sel != 1'b1 || dut.core.daif != 4'hf ||
          dut.core.nzcv != 4'd0)
        $fatal(1, "T051 %s IRQ architectural boundary mismatch next=%h elr=%h daif=%h nzcv=%h",
               label, commit_next_pc, dut.core.elr_el1, dut.core.daif,
               dut.core.nzcv);
      if (commit_mem_we || commit_mem2_we || commit_vec_write_count != 3'd0 ||
          commit_fpcr_we || commit_fpsr_we)
        $fatal(1, "T051 %s younger side effect leaked in IRQ packet", label);
      if (dut.core.ifid_valid || dut.core.idex_valid || dut.core.exmem_valid ||
          dut.core.memwb_valid || dut.core.fetch_pending ||
          dut.core.fetch_trans_busy || dut.core.data_trans_active ||
          dut.core.dmem_req_issued || dut.core.dmem_done ||
          dut.core.fp_tx_issued || dut.core.fp_tx_busy || dut.core.fp_rsp_valid)
        $fatal(1, "T051 %s young state survived IRQ: ifid=%b idex=%b exmem=%b memwb=%b dmem=%b fp=%b",
               label, dut.core.ifid_valid, dut.core.idex_valid,
               dut.core.exmem_valid, dut.core.memwb_valid,
               dut.core.dmem_req_issued, dut.core.fp_tx_busy);
      release_injection();
    end
  endtask

  task automatic check_accepted_store_guard;
    begin
      // Let the real younger store request be accepted once.  An IRQ that
      // arrives while that write response is outstanding must remain pending;
      // clearing EX/MEM here would lose an irreversible side effect.
      bit accepted;
      accepted = 1'b0;
      for (int i = 0; i < 40; i++) begin
        @(posedge clk);
        #1;
        if ((dut.core.dmem_req_issued && dut.core.dmem_req.we) ||
            (dut.core.dmem_done && dut.core.exmem_is_store)) begin
          accepted = 1'b1;
          break;
        end
      end
      if (!accepted)
        $fatal(1, "T051 accepted-store guard did not observe a write request");
      ensure_old_wb(BASE + 64'h180);
      dut.core.daif = 4'b0000;
      irq_drive = 1'b1;
      force dut.gic_irq = irq_drive;
      irq_forced = 1'b1;
      #1;
      if (!dut.core.irq_pending_raw || !dut.core.irq_irrevocable_pending ||
          dut.core.irq_taken)
        $fatal(1, "T051 accepted-store write was not fenced before IRQ");
      release_injection();
    end
  endtask

  task automatic run_alu_case;
    logic [63:0] old_pc;
    bit natural_old_wb;
    begin
      for (int i = 0; i < 64; i++) prog_words[i] = NOP;
      prog_words[0] = movz(0, 1, 0);
      prog_words[1] = movz(1, 2, 0);
      prog_words[2] = 32'h8B010042; // add x2,x2? (ordinary ALU producer)
      prog_words[3] = movz(3, 4, 0);
      prog_words[15] = B_SELF;
      load_program(16);
      wait_for_idex_slot(old_pc, natural_old_wb);
      ensure_old_wb(old_pc);
      inject_irq(old_pc, natural_old_wb, "ALU-IDEX");
      $display("T051 ALU ID/EX PASS fifo=%0d delay=%0d",
               FETCH_FIFO_ENABLE, MEM_DELAY_MODE);
    end
  endtask

  task automatic run_store_case;
    logic [63:0] old_pc;
    begin
      for (int i = 0; i < 64; i++) prog_words[i] = NOP;
      prog_words[0] = movz(0, 1, 0);
      prog_words[1] = movz(1, 16'h4000, 1); // x1 = SRAM base
      prog_words[2] = 32'hF9400023;          // ldr x3,[x1] (older memory op)
      prog_words[3] = movz(2, 16'h0055, 0);
      prog_words[4] = 32'hB9000022;          // str w2,[x1] (younger)
      prog_words[15] = B_SELF;
      load_program(16);
      wait_for_store_slot(old_pc);
      check_accepted_store_guard();
      load_program(16);
      wait_for_store_slot(old_pc);
      ensure_old_wb(old_pc);
      inject_irq(old_pc, 1'b0, "STORE");
      $display("T051 STORE PASS fifo=%0d delay=%0d", FETCH_FIFO_ENABLE,
               MEM_DELAY_MODE);
    end
  endtask

  task automatic run_fp_case;
    logic [63:0] old_pc;
    begin
      for (int i = 0; i < 64; i++) prog_words[i] = NOP;
      prog_words[0] = movz(0, 1, 0); // older non-FP commit
      prog_words[1] = fp3(32'h1E202800, 2, 0, 1); // fadd s2,s0,s1
      prog_words[15] = B_SELF;
      load_program(16);
      force dut.core.fp_state.cpacr_el1_state = 64'h0000_0000_0030_0000;
      fp_cpacr_forced = 1'b1;
      wait_for_fp_slot(old_pc);
      ensure_old_wb(old_pc);
      inject_irq(old_pc, 1'b0, "FP");
      $display("T051 FP held-response PASS fifo=%0d delay=%0d",
               FETCH_FIFO_ENABLE, MEM_DELAY_MODE);
    end
  endtask

  task automatic run_neon_case;
    logic [63:0] old_pc;
    begin
      for (int i = 0; i < 64; i++) prog_words[i] = NOP;
      prog_words[0] = movz(0, 1, 0);
      prog_words[1] = 32'h4E201C02; // and v2.16b,v0.16b,v1.16b
      prog_words[15] = B_SELF;
      load_program(16);
      force dut.core.fp_state.cpacr_el1_state = 64'h0000_0000_0030_0000;
      fp_cpacr_forced = 1'b1;
      old_pc = BASE + 64'h280;
      for (int i = 0; i < 1200; i++) begin
        @(posedge clk);
        #1;
        if (dut.core.idex_valid && dut.core.idex_d.neon_valid &&
            !dut.core.idex_d.neon_fp_valid) begin
          old_pc = dut.core.memwb_valid ? dut.core.memwb_pc : old_pc;
          break;
        end
        if (i == 1199)
          $fatal(1, "T051 timeout waiting for younger NEON integer stage");
      end
      ensure_old_wb(old_pc);
      inject_irq(old_pc, 1'b0, "NEON");
      $display("T051 NEON integer PASS fifo=%0d delay=%0d",
               FETCH_FIFO_ENABLE, MEM_DELAY_MODE);
    end
  endtask

  task automatic run_muldiv_case;
    logic [63:0] old_pc;
    bit irq_commit_seen;
    begin
      for (int i = 0; i < 64; i++) prog_words[i] = NOP;
      prog_words[0] = movz(0, 3, 0);
      prog_words[1] = movz(1, 4, 0);
      prog_words[2] = 32'h9B017C02; // mul x2,x0,x1 (long EX transaction)
      prog_words[15] = B_SELF;
      load_program(16);
      old_pc = BASE + 64'h300;
      for (int i = 0; i < 1200; i++) begin
        @(posedge clk);
        #1;
        if (dut.core.idex_valid && dut.core.is_muldiv &&
            !dut.core.muldiv_done) begin
          if (dut.core.memwb_valid)
            old_pc = dut.core.memwb_pc;
          break;
        end
        if (i == 1199)
          $fatal(1, "T051 timeout waiting for muldiv mid-run");
      end
      ensure_old_wb(old_pc);
      dut.core.daif = 4'b0000;
      irq_drive = 1'b1;
      force dut.gic_irq = irq_drive;
      irq_forced = 1'b1;
      #1;
      if (!dut.core.irq_pending_raw || !dut.core.irq_irrevocable_pending ||
          dut.core.irq_taken)
        $fatal(1, "T051 muldiv mid-run was not fenced from IRQ");
      irq_commit_seen = 1'b0;
      for (int i = 0; i < 600; i++) begin
        @(posedge clk);
        #1;
        if (commit_valid && commit_exc_valid &&
            commit_exc_code == EXC_IRQ) begin
          irq_commit_seen = 1'b1;
          if (!commit_gpr_we || commit_gpr_rd != 5'd2 ||
              commit_gpr_wdata != 64'd12)
            $fatal(1, "T051 muldiv IRQ commit lost result: we=%b rd=%0d data=%h",
                   commit_gpr_we, commit_gpr_rd, commit_gpr_wdata);
          break;
        end
        // The synthetic old WB is needed only for FIFO-off's non-overlap
        // schedule; release it after its single guarded boundary.
        if (commit_fire_forced)
          release_old_wb_override();
      end
      if (!irq_commit_seen)
        $fatal(1, "T051 muldiv did not finish exactly once before IRQ");
      release_injection();
      $display("T051 muldiv mid/done PASS fifo=%0d delay=%0d",
               FETCH_FIFO_ENABLE, MEM_DELAY_MODE);
    end
  endtask

  task automatic run_mmu_ptw_case;
    logic [63:0] old_pc;
    bit accepted;
    bit irq_commit_seen;
    begin
      // Enable a real 4-level walk after mapping both the code page and a
      // distinct data page.  The IRQ is injected only after a PTW request has
      // been accepted, so the MMU quarantine path must drain that response.
      for (int i = 0; i < 64; i++) prog_words[i] = NOP;
      prog_words[0]  = 32'hD2A88025; // movz x5,#0x4401,lsl#16
      prog_words[1]  = 32'hD5182005; // msr ttbr0_el1,x5
      prog_words[2]  = 32'hD2A88028; // movz x8,#0x4401,lsl#16
      prog_words[3]  = 32'hD518C008; // msr vbar_el1,x8
      prog_words[4]  = 32'hD2800205; // movz x5,#0x10
      prog_words[5]  = 32'hF2A00025; // movk x5,#0x1,lsl#16 (TCR=0x100010)
      prog_words[6]  = 32'hD5182045; // msr tcr_el1,x5
      prog_words[7]  = 32'hD2801FE5; // movz x5,#0xff
      prog_words[8]  = 32'hD518A205; // msr mair_el1,x5
      prog_words[9]  = 32'hD2A018A5; // movz x5,#0xc5,lsl#16
      prog_words[10] = 32'hF2810725; // movk x5,#0x839
      prog_words[11] = 32'hD5181005; // msr sctlr_el1,x5 (M=1)
      prog_words[12] = 32'hD2A80000; // movz x0,#0x4000,lsl#16
      prog_words[13] = 32'hF9400009; // ldr x9,[x0] -> data PTW
      prog_words[14] = B_SELF;
      prog_words[15] = B_SELF;
      load_program(16);
      rst_n = 1'b0;
      repeat (2) @(posedge clk);
      write_mem_word(64'h0000_0000_4401_0000, 64'h0000_0000_4401_1003);
      write_mem_word(64'h0000_0000_4401_1008, 64'h0000_0000_4401_2003);
      write_mem_word(64'h0000_0000_4401_2000, 64'h0000_0000_4401_3003);
      write_mem_word(64'h0000_0000_4401_2100, 64'h0000_0000_4401_4003);
      write_mem_word(64'h0000_0000_4401_3000, 64'h0000_0000_4400_84C3);
      write_mem_word(64'h0000_0000_4401_4000, 64'h0000_0000_4400_04C3);
      write_mem_word(64'h0000_0000_4401_4800, 64'h0000_0000_4401_04C3);
      rst_n = 1'b1;

      accepted = 1'b0;
      for (int i = 0; i < 3000; i++) begin
        @(posedge clk);
        #1;
        if (dut.core.data_trans_active && dut.core.ptw_req_valid &&
            dut.core.ptw_req_ready) begin
          // Let this request cross the arbiter boundary before asserting IRQ.
          @(posedge clk);
          #1;
          accepted = 1'b1;
          break;
        end
        if (i == 2999)
          $fatal(1, "T051 timeout waiting for natural data PTW acceptance");
      end
      old_pc = dut.core.memwb_valid ? dut.core.memwb_pc : BASE + 64'h380;
      ensure_old_wb(old_pc);
      dut.core.daif = 4'b0000;
      irq_drive = 1'b1;
      force dut.gic_irq = irq_drive;
      irq_forced = 1'b1;
      #1;
      if (!accepted || !dut.core.irq_pending_raw || !dut.core.irq_taken)
        $fatal(1, "T051 natural PTW IRQ boundary was not taken");
      if (!dut.core.mmu_abort || dut.core.tlb_invalidate)
        $fatal(1, "T051 ordinary IRQ used the wrong MMU cancel path");
      if (dut.core.ptw_req_valid)
        $fatal(1, "T051 natural PTW IRQ edge issued a new PTW request");
      @(posedge clk);
      #1;
      release_old_wb_override();
      release_irq_sources();
      if (dut.core.mmu_done || dut.core.mmu_fault)
        $fatal(1, "T051 aborted PTW manufactured done/fault");
      irq_commit_seen = 1'b0;
      for (int i = 0; i < 500; i++) begin
        @(posedge clk);
        #1;
        if (!dut.core.mmu_walking && !dut.core.mmu_done &&
            !dut.core.data_trans_active) begin
          irq_commit_seen = 1'b1;
          break;
        end
      end
      if (!irq_commit_seen)
        $fatal(1, "T051 natural PTW quarantine did not drain");
      if (dut.core.data_trans_active)
        $fatal(1, "T051 stale PTW result leaked after IRQ");
      $display("T051 natural MMU PTW abort/quarantine PASS fifo=%0d delay=%0d",
               FETCH_FIFO_ENABLE, MEM_DELAY_MODE);
    end
  endtask

  initial begin
    $display("=== lcvex_irq_young_squash_tb fifo=%0d delay=%0d ===",
             FETCH_FIFO_ENABLE, MEM_DELAY_MODE);
    run_alu_case();
    run_store_case();
    run_fp_case();
    run_neon_case();
    run_muldiv_case();
    run_mmu_ptw_case();
    $display("PASS: T051 IRQ young-stage/transaction squash fifo=%0d delay=%0d",
             FETCH_FIFO_ENABLE, MEM_DELAY_MODE);
    $finish;
  end
endmodule
/* verilator lint_on PINMISSING */
/* verilator lint_on WIDTHEXPAND */
/* verilator lint_on MULTIDRIVEN */
/* verilator lint_on UNUSEDSIGNAL */
