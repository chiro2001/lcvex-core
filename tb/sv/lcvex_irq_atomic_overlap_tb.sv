// lcvex_irq_atomic_overlap_tb.sv
//
// T-054：普通 IRQ 与真实 CASP/STXR/DC ZVA 流水事务重叠。
//
// 该 TB 只在真实事务已经进入 core 的 EX/MEM 或 maintenance FSM 后驱动
// gic_irq；不 force commit_fire、MEM/WB metadata、stage valid 或架构状态。
// 观测请求接受、事务相位、提交包和 IRQ 边界，覆盖 FIFO off/on 与
// MEM_DELAY_MODE 0/2（由 Makefile 分别编译运行）。

`timescale 1ns/1ps

/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off PINMISSING */
/* verilator lint_off WIDTHEXPAND */
module lcvex_irq_atomic_overlap_tb #(
  parameter int MEM_DELAY_MODE = 0,
  parameter int FETCH_FIFO_ENABLE = 1,
  parameter int I_L1_ENABLE = 0,
  parameter int D_L1_ENABLE = 0,
  parameter int L2_ENABLE = 0,
  parameter logic [63:0] RESET_PC = 64'h0000_0000_4400_0000
);
  import lcvex_pkg::*;

  localparam logic [63:0] BASE = 64'h0000_0000_4400_0000;
  localparam logic [63:0] CASP_ADDR = 64'h0000_0000_4408_2000;
  localparam logic [63:0] STXR_ADDR = 64'h0000_0000_4408_3000;
  localparam logic [63:0] ZVA_BLOCK = 64'h0000_0000_4409_0000;
  localparam logic [31:0] B_SELF = 32'h1400_0000;

  logic clk = 1'b0;
  logic rst_n = 1'b0;
  logic commit_ready = 1'b1;
  logic prog_we = 1'b0;
  logic [63:0] prog_addr = 64'd0;
  logic [7:0] prog_strb = 8'd0;
  logic [63:0] prog_wdata = 64'd0;
  logic [31:0] prog_words [0:127];
  logic [63:0] restore_fp_v_lo [0:31] = '{default:64'd0};
  logic [63:0] restore_fp_v_hi [0:31] = '{default:64'd0};
  logic irq_drive = 1'b0;
  bit irq_forced = 1'b0;

  // Only the inputs needed by the ordinary SV driver are declared here.  The
  // output commit packet remains available through dut.commit_* hierarchy.
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
      .dbg_addr(32'd0)
  );

  always #5 clk = ~clk;

  function automatic logic [31:0] movz(input integer rd, input integer imm16,
                                        input integer hw);
    movz = 32'hD2800000 | (32'(hw) << 21) |
           (32'(imm16 & 16'hffff) << 5) | 32'(rd & 31);
  endfunction

  function automatic logic [31:0] movk(input integer rd, input integer imm16,
                                        input integer hw);
    movk = 32'hF2800000 | (32'(hw) << 21) |
           (32'(imm16 & 16'hffff) << 5) | 32'(rd & 31);
  endfunction

  function automatic logic [31:0] str_x(input integer rt, input integer rn,
                                         input integer imm12);
    str_x = 32'hF9000000 | (32'(imm12 & 12'hfff) << 10) |
            (32'(rn & 31) << 5) | 32'(rt & 31);
  endfunction

  function automatic logic [31:0] ldr_x(input integer rt, input integer rn,
                                         input integer imm12);
    ldr_x = 32'hF9400000 | (32'(imm12 & 12'hfff) << 10) |
            (32'(rn & 31) << 5) | 32'(rt & 31);
  endfunction

  function automatic logic [31:0] casp_x(input integer rs, input integer rt,
                                          input integer rn, input bit acquire,
                                          input bit rel);
    // Matches a64.py _enc_casp: CASPAL has a=1,r=1; CASP has a=r=0.
    casp_x = 32'h48207C00 | (32'(acquire) << 22) |
             (32'(rel) << 15) | (32'(rs & 31) << 16) |
             (32'(rn & 31) << 5) | 32'(rt & 31);
  endfunction

  function automatic logic [31:0] ldxr_x(input integer rt, input integer rn);
    ldxr_x = 32'hC85F7C00 | (32'(rn & 31) << 5) | 32'(rt & 31);
  endfunction

  function automatic logic [31:0] stxr_w(input integer rs, input integer rt,
                                          input integer rn);
    stxr_w = 32'h88007C00 | (32'(rs & 31) << 16) |
             (32'(rn & 31) << 5) | 32'(rt & 31);
  endfunction

  function automatic logic [31:0] dc_zva(input integer rt);
    dc_zva = 32'hD50B7420 | 32'(rt & 31);
  endfunction

  task automatic release_irq;
    begin
      irq_drive = 1'b0;
      if (irq_forced) begin
        release dut.gic_irq;
        irq_forced = 1'b0;
      end
    end
  endtask

  task automatic write_image(input integer words,
                             input logic [63:0] preload_addr,
                             input logic [63:0] preload_data);
    begin
      release_irq();
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
      if (preload_addr != 64'd0) begin
        prog_strb = 8'hff;
        prog_addr = preload_addr;
        prog_wdata = preload_data;
        @(posedge clk);
      end
      prog_we = 1'b0;
      prog_strb = 8'd0;
      @(posedge clk);
      rst_n = 1'b1;
      repeat (2) @(posedge clk);
    end
  endtask

  task automatic set_common_program;
    begin
      for (int i = 0; i < 128; i++) prog_words[i] = 32'hD503201F;
      // VBAR=0x44010000 and unmask IRQ before the target transaction.
      prog_words[0] = movz(8, 16'h4401, 1);
      prog_words[1] = 32'hD518C008;  // msr vbar_el1,x8
      prog_words[2] = 32'hD50342FF;  // daifclr #2
    end
  endtask

  task automatic wait_irq_packet(input string label,
                                 input logic [63:0] expected_pc,
                                 input bit expect_mem,
                                 input bit expect_mem2,
                                 input integer expect_mem_count);
    bit seen;
    begin
      seen = 1'b0;
      for (int i = 0; i < 1200; i++) begin
        @(posedge clk);
        #1;
        if (dut.commit_valid && dut.commit_exc_valid &&
            dut.commit_exc_code == EXC_IRQ) begin
          seen = 1'b1;
          if (dut.commit_pc != expected_pc ||
              dut.commit_next_pc != 64'h0000_0000_4401_0280 ||
              dut.commit_mem_we != expect_mem ||
              dut.commit_mem2_we != expect_mem2 ||
              dut.commit_exc_esr != 32'd0 || dut.commit_exc_far != 64'd0) begin
            $fatal(1, "T054 %s IRQ packet mismatch pc=%h next=%h mem=%b/%b",
                   label, dut.commit_pc, dut.commit_next_pc,
                   dut.commit_mem_we, dut.commit_mem2_we);
          end
          if (target_write_count != expect_mem_count)
            $fatal(1, "T054 %s accepted-write count=%0d want=%0d",
                   label, target_write_count, expect_mem_count);
          if (label == "CASP-match" &&
              (!dut.commit_gpr_we || dut.commit_gpr_rd != 5'd0 ||
               dut.commit_gpr_wdata != 64'h11 ||
               !dut.commit_gpr2_we || dut.commit_gpr2_rd != 5'd1 ||
               dut.commit_gpr2_wdata != 64'h22 ||
               dut.commit_mem_wdata != 64'h33 ||
               dut.commit_mem2_wdata != 64'h44 ||
               dut.commit_mem_addr != CASP_ADDR ||
               dut.commit_mem_strb != 8'hff ||
               dut.commit_mem2_addr != CASP_ADDR + 64'd8 ||
               dut.commit_mem2_strb != 8'hff ||
               casp_low_accept_count != 1 || casp_high_accept_count != 1 ||
               casp_low_addr != CASP_ADDR ||
               casp_high_addr != CASP_ADDR + 64'd8 ||
               casp_low_data != 64'h33 || casp_high_data != 64'h44 ||
               casp_low_strb != 8'hff || casp_high_strb != 8'hff))
            $fatal(1, "T054 CASP match packet old/new pair mismatch");
          if (label == "CASP-mismatch" &&
              (!dut.commit_gpr_we || dut.commit_gpr_rd != 5'd0 ||
               dut.commit_gpr_wdata != 64'h11 ||
               !dut.commit_gpr2_we || dut.commit_gpr2_rd != 5'd1 ||
               dut.commit_gpr2_wdata != 64'h22 ||
               dut.commit_mem_we || dut.commit_mem2_we ||
               casp_low_accept_count != 0 || casp_high_accept_count != 0))
            $fatal(1, "T054 CASP mismatch packet old pair mismatch");
          if (label == "STXR-success" &&
              (!dut.commit_gpr_we || dut.commit_gpr_rd != 5'd7 ||
               dut.commit_gpr_wdata != 64'd0 ||
               dut.commit_mem_addr != STXR_ADDR ||
               dut.commit_mem_wdata != 64'haa ||
               dut.commit_mem_strb != 8'h0f))
            $fatal(1, "T054 STXR success status packet mismatch");
          if (label == "STXR-fail" &&
              (!dut.commit_gpr_we || dut.commit_gpr_rd != 5'd7 ||
               dut.commit_gpr_wdata != 64'd1))
            $fatal(1, "T054 STXR fail status packet mismatch");
          break;
        end
      end
      if (!seen)
        $fatal(1, "T054 %s IRQ packet timeout", label);
      release_irq();
    end
  endtask

  integer target_write_count;
  logic [63:0] active_target;
  logic [63:0] active_target_hi;
  bit count_target_writes;
  logic [7:0] target_write_mask;
  bit target_bad_data;
  integer casp_low_accept_count;
  integer casp_high_accept_count;
  logic [63:0] casp_low_addr;
  logic [63:0] casp_high_addr;
  logic [63:0] casp_low_data;
  logic [63:0] casp_high_data;
  logic [7:0] casp_low_strb;
  logic [7:0] casp_high_strb;
  /* verilator lint_off BLKSEQ */
  always @(posedge clk) begin
    #1;
    // Count only requests accepted after the target transaction is observed;
    // initialization writes use the same target but occur before that point.
    if (count_target_writes && dut.core.dmem_req_accept &&
        dut.core.dmem_req.we &&
        (dut.core.dmem_req.addr >= active_target &&
         dut.core.dmem_req.addr <= active_target_hi &&
         ((dut.core.dmem_req.addr - active_target) <= 64'd56) &&
         (dut.core.dmem_req.addr[2:0] == active_target[2:0])) ) begin
      target_write_count = target_write_count + 1;
      if (active_target == ZVA_BLOCK) begin
        target_write_mask[dut.core.dmem_req.addr[5:3]] = 1'b1;
        if (dut.core.dmem_req.wdata != 64'd0)
          target_bad_data = 1'b1;
      end else if (active_target == CASP_ADDR) begin
        if (dut.core.dmem_req.addr == active_target) begin
          casp_low_accept_count = casp_low_accept_count + 1;
          casp_low_addr = dut.core.dmem_req.addr;
          casp_low_data = dut.core.dmem_req.wdata;
          casp_low_strb = dut.core.dmem_req.strb;
        end else if (dut.core.dmem_req.addr == active_target_hi) begin
          casp_high_accept_count = casp_high_accept_count + 1;
          casp_high_addr = dut.core.dmem_req.addr;
          casp_high_data = dut.core.dmem_req.wdata;
          casp_high_strb = dut.core.dmem_req.strb;
        end
      end
    end
  end
  /* verilator lint_on BLKSEQ */

  task automatic run_casp_match;
    logic [63:0] op_pc;
    bit injected;
    begin
      set_common_program();
      prog_words[3] = movz(20, 16'h4408, 1);
      prog_words[4] = movk(20, 16'h2000, 0);
      prog_words[5] = movz(0, 16'h0011, 0);
      prog_words[6] = movz(1, 16'h0022, 0);
      prog_words[7] = str_x(0, 20, 0);
      prog_words[8] = str_x(1, 20, 1);
      prog_words[9] = movz(2, 16'h0033, 0);
      prog_words[10] = movz(3, 16'h0044, 0);
      prog_words[11] = casp_x(0, 2, 20, 1'b1, 1'b1);
      prog_words[12] = B_SELF;
      write_image(13, 64'd0, 64'd0);
      active_target = CASP_ADDR;
      active_target_hi = CASP_ADDR + 64'd8;
      target_write_count = 0;
      target_write_mask = 8'd0;
      target_bad_data = 1'b0;
      casp_low_accept_count = 0;
      casp_high_accept_count = 0;
      casp_low_addr = 64'd0;
      casp_high_addr = 64'd0;
      casp_low_data = 64'd0;
      casp_high_data = 64'd0;
      casp_low_strb = 8'd0;
      casp_high_strb = 8'd0;
      count_target_writes = 1'b0;
      injected = 1'b0;
      op_pc = BASE + 64'd44;
      for (int i = 0; i < 1200; i++) begin
        @(posedge clk);
        #1;
        if (dut.core.exmem_valid && dut.core.exmem_is_atomic &&
            dut.core.exmem_atomic_op == ATOMIC_CASP)
          count_target_writes = 1'b1;
        if (dut.core.exmem_valid && dut.core.exmem_is_atomic &&
            dut.core.exmem_atomic_op == ATOMIC_CASP &&
            dut.core.atomic_phase >= 2'd2 &&
            dut.core.dmem_req_issued && dut.core.dmem_req.we) begin
          irq_drive = 1'b1;
          force dut.gic_irq = irq_drive;
          irq_forced = 1'b1;
          injected = 1'b1;
          #1;
          if (!dut.core.irq_pending_raw ||
              !dut.core.irq_irrevocable_pending || dut.core.irq_taken)
            $fatal(1, "T054 CASP match accepted write was not fenced");
          break;
        end
      end
      if (!injected) $fatal(1, "T054 CASP match write phase timeout");
      wait_irq_packet("CASP-match", op_pc, 1'b1, 1'b1, 2);
      active_target = 64'd0;
      active_target_hi = 64'd0;
      $display("T054 CASP match PASS fifo=%0d delay=%0d accepted=%0d low=%0d high=%0d",
               FETCH_FIFO_ENABLE, MEM_DELAY_MODE, target_write_count,
               casp_low_accept_count, casp_high_accept_count);
    end
  endtask

  task automatic run_casp_mismatch;
    logic [63:0] op_pc;
    bit injected;
    begin
      set_common_program();
      prog_words[3] = movz(20, 16'h4408, 1);
      prog_words[4] = movk(20, 16'h2000, 0);
      prog_words[5] = movz(0, 16'h0011, 0);
      prog_words[6] = movz(1, 16'h0022, 0);
      prog_words[7] = str_x(0, 20, 0);
      prog_words[8] = str_x(1, 20, 1);
      prog_words[9] = movz(0, 16'h0055, 0);
      prog_words[10] = movz(1, 16'h0066, 0);
      prog_words[11] = movz(2, 16'h0077, 0);
      prog_words[12] = movz(3, 16'h0088, 0);
      prog_words[13] = casp_x(0, 2, 20, 1'b0, 1'b0);
      prog_words[14] = B_SELF;
      write_image(15, 64'd0, 64'd0);
      active_target = CASP_ADDR;
      active_target_hi = CASP_ADDR + 64'd8;
      target_write_count = 0;
      target_write_mask = 8'd0;
      target_bad_data = 1'b0;
      casp_low_accept_count = 0;
      casp_high_accept_count = 0;
      casp_low_addr = 64'd0;
      casp_high_addr = 64'd0;
      casp_low_data = 64'd0;
      casp_high_data = 64'd0;
      casp_low_strb = 8'd0;
      casp_high_strb = 8'd0;
      count_target_writes = 1'b0;
      injected = 1'b0;
      op_pc = BASE + 64'd52;
      for (int i = 0; i < 1200; i++) begin
        @(posedge clk);
        #1;
        if (dut.core.exmem_valid && dut.core.exmem_is_atomic &&
            dut.core.exmem_atomic_op == ATOMIC_CASP)
          count_target_writes = 1'b1;
        if (dut.core.exmem_valid && dut.core.exmem_is_atomic &&
            dut.core.exmem_atomic_op == ATOMIC_CASP &&
            dut.core.atomic_phase == 2'd1 &&
            dut.core.dmem_req_issued && !dut.core.dmem_req.we) begin
          irq_drive = 1'b1;
          force dut.gic_irq = irq_drive;
          irq_forced = 1'b1;
          injected = 1'b1;
          #1;
          if (!dut.core.irq_pending_raw || dut.core.irq_taken)
            $fatal(1, "T054 CASP mismatch read phase IRQ edge invalid");
          break;
        end
      end
      if (!injected) $fatal(1, "T054 CASP mismatch read phase timeout");
      wait_irq_packet("CASP-mismatch", op_pc, 1'b0, 1'b0, 0);
      active_target = 64'd0;
      active_target_hi = 64'd0;
      $display("T054 CASP mismatch PASS fifo=%0d delay=%0d accepted=%0d low=%0d high=%0d",
               FETCH_FIFO_ENABLE, MEM_DELAY_MODE, target_write_count,
               casp_low_accept_count, casp_high_accept_count);
    end
  endtask

  task automatic run_stxr_success;
    logic [63:0] op_pc;
    bit injected;
    begin
      set_common_program();
      prog_words[3] = movz(20, 16'h4408, 1);
      prog_words[4] = movk(20, 16'h3000, 0);
      prog_words[5] = movz(0, 16'h0011, 0);
      prog_words[6] = str_x(0, 20, 0);
      prog_words[7] = ldxr_x(5, 20);
      prog_words[8] = movz(6, 16'h00aa, 0);
      prog_words[9] = stxr_w(7, 6, 20);
      prog_words[10] = B_SELF;
      write_image(11, 64'd0, 64'd0);
      active_target = STXR_ADDR;
      active_target_hi = STXR_ADDR;
      target_write_count = 0;
      target_write_mask = 8'd0;
      target_bad_data = 1'b0;
      count_target_writes = 1'b0;
      injected = 1'b0;
      op_pc = BASE + 64'd36;
      for (int i = 0; i < 1200; i++) begin
        @(posedge clk);
        #1;
        if (dut.core.exmem_valid && dut.core.exmem_is_stxr)
          count_target_writes = 1'b1;
        if (dut.core.exmem_valid && dut.core.exmem_is_stxr &&
            !dut.core.stxr_read_phase && dut.core.dmem_req_issued &&
            dut.core.dmem_req.we) begin
          irq_drive = 1'b1;
          force dut.gic_irq = irq_drive;
          irq_forced = 1'b1;
          injected = 1'b1;
          #1;
          if (!dut.core.irq_pending_raw ||
              !dut.core.irq_irrevocable_pending || dut.core.irq_taken)
            $fatal(1, "T054 STXR success accepted write was not fenced");
          break;
        end
      end
      if (!injected) $fatal(1, "T054 STXR success write phase timeout");
      wait_irq_packet("STXR-success", op_pc, 1'b1, 1'b0, 1);
      active_target = 64'd0;
      active_target_hi = 64'd0;
      $display("T054 STXR success PASS fifo=%0d delay=%0d accepted=%0d",
               FETCH_FIFO_ENABLE, MEM_DELAY_MODE, target_write_count);
    end
  endtask

  task automatic run_stxr_id_squash;
    logic [63:0] old_pc;
    logic [31:0] stxr_word;
    bit injected;
    begin
      set_common_program();
      prog_words[3] = movz(20, 16'h4408, 1);
      prog_words[4] = movk(20, 16'h3000, 0);
      prog_words[5] = movz(6, 16'h00bb, 0);
      prog_words[6] = ldr_x(5, 20, 0);  // older real MEM/WB entry
      prog_words[7] = stxr_w(7, 6, 20);
      prog_words[8] = B_SELF;
      stxr_word = prog_words[7];
      write_image(9, STXR_ADDR, 64'h1234);
      active_target = STXR_ADDR;
      active_target_hi = STXR_ADDR;
      target_write_count = 0;
      target_write_mask = 8'd0;
      target_bad_data = 1'b0;
      count_target_writes = 1'b0;
      injected = 1'b0;
      old_pc = 64'd0;
      for (int i = 0; i < 1200; i++) begin
        @(posedge clk);
        #1;
        // The STXR is still in IF/ID while a real older instruction occupies
        // MEM/WB.  No stage or commit metadata is synthesized here.
        if (dut.core.ifid_valid && dut.core.ifid_insn == stxr_word &&
            dut.core.memwb_valid) begin
          old_pc = dut.core.memwb_pc;
          count_target_writes = 1'b1;
          irq_drive = 1'b1;
          force dut.gic_irq = irq_drive;
          irq_forced = 1'b1;
          injected = 1'b1;
          #1;
          if (!dut.core.irq_pending_raw || !dut.core.commit_fire ||
              !dut.core.irq_taken)
            $fatal(1, "T054 STXR ID real-WB IRQ squash edge missing");
          break;
        end
      end
      if (!injected)
        $fatal(1, "T054 STXR ID/real-WB overlap timeout");
      wait_irq_packet("STXR-ID-squash", old_pc, 1'b0, 1'b0, 0);
      if (target_write_count != 0)
        $fatal(1, "T054 STXR ID squash leaked a store count=%0d",
               target_write_count);
      active_target = 64'd0;
      active_target_hi = 64'd0;
      $display("T054 STXR ID/real-WB squash PASS fifo=%0d delay=%0d accepted=%0d",
               FETCH_FIFO_ENABLE, MEM_DELAY_MODE, target_write_count);
    end
  endtask

  task automatic run_stxr_fail;
    logic [63:0] op_pc;
    bit injected;
    begin
      set_common_program();
      prog_words[3] = movz(20, 16'h4408, 1);
      prog_words[4] = movk(20, 16'h3000, 0);
      prog_words[5] = movz(6, 16'h00bb, 0);
      prog_words[6] = stxr_w(7, 6, 20);
      prog_words[7] = B_SELF;
      write_image(8, 64'd0, 64'd0);
      active_target = STXR_ADDR;
      active_target_hi = STXR_ADDR;
      target_write_count = 0;
      target_write_mask = 8'd0;
      target_bad_data = 1'b0;
      count_target_writes = 1'b0;
      injected = 1'b0;
      op_pc = BASE + 64'd24;
      for (int i = 0; i < 1200; i++) begin
        @(posedge clk);
        #1;
        if (dut.core.exmem_valid && dut.core.exmem_is_stxr)
          count_target_writes = 1'b1;
        if (dut.core.exmem_valid && dut.core.exmem_is_stxr &&
            dut.core.stxr_read_phase && dut.core.dmem_req_issued &&
            !dut.core.dmem_req.we) begin
          irq_drive = 1'b1;
          force dut.gic_irq = irq_drive;
          irq_forced = 1'b1;
          injected = 1'b1;
          #1;
          if (!dut.core.irq_pending_raw || dut.core.irq_taken)
            $fatal(1, "T054 STXR fail read phase IRQ edge invalid");
          break;
        end
      end
      if (!injected) $fatal(1, "T054 STXR fail read phase timeout");
      wait_irq_packet("STXR-fail", op_pc, 1'b0, 1'b0, 0);
      active_target = 64'd0;
      active_target_hi = 64'd0;
      $display("T054 STXR fail PASS fifo=%0d delay=%0d accepted=%0d",
               FETCH_FIFO_ENABLE, MEM_DELAY_MODE, target_write_count);
    end
  endtask

  task automatic run_dc_zva;
    logic [63:0] op_pc;
    bit injected;
    integer accepted_before;
    integer writes_after_irq;
    begin
      set_common_program();
      prog_words[3] = movz(9, 16'h4409, 1);
      prog_words[4] = movk(9, 16'h0010, 0);
      prog_words[5] = dc_zva(9);
      prog_words[6] = B_SELF;
      write_image(7, ZVA_BLOCK, 64'h1122_3344_5566_7788);
      active_target = ZVA_BLOCK;
      active_target_hi = ZVA_BLOCK + 64'd56;
      target_write_count = 0;
      target_write_mask = 8'd0;
      target_bad_data = 1'b0;
      count_target_writes = 1'b0;
      injected = 1'b0;
      accepted_before = 0;
      op_pc = BASE + 64'd20;
      for (int i = 0; i < 1600; i++) begin
        @(posedge clk);
        #1;
        if (dut.core.maint_state == 3'd5)
          count_target_writes = 1'b1;
        if (dut.core.maint_state == 3'd5 &&
            dut.core.maint_dmem_req_accept) begin
          accepted_before = target_write_count;
          if (dut.core.maint_zva_idx < 3'd2) continue;
          irq_drive = 1'b1;
          force dut.gic_irq = irq_drive;
          irq_forced = 1'b1;
          injected = 1'b1;
          #1;
          if (!dut.core.irq_pending_raw ||
              !dut.core.irq_irrevocable_pending || dut.core.irq_taken)
            $fatal(1, "T054 DC ZVA accepted beat was not fenced");
          break;
        end
      end
      if (!injected) $fatal(1, "T054 DC ZVA multi-beat injection timeout");
      wait_irq_packet("DC-ZVA", op_pc, 1'b0, 1'b0, 8);
      // The IRQ packet is the DC ZVA system-commit boundary.  The maintenance
      // FSM and every data/atomic phase must be idle immediately afterwards;
      // no delayed beat or duplicate commit may leak into the vector stream.
      if (dut.core.maint_state != 3'd0 || dut.core.maint_zva_active ||
          dut.core.maint_dmem_req_valid || dut.core.maint_dmem_req_accept ||
          dut.core.dmem_req_issued || dut.core.dmem_done ||
          dut.core.data_trans_active || dut.core.dabt_pending ||
          dut.core.pair_part || dut.core.stxr_read_phase ||
          dut.core.atomic_read_phase || dut.core.atomic_phase != 2'd0 ||
          dut.core.stxp_cmp_hi || dut.core.exmem_atomic_store ||
          dut.core.atomic128_second_needed || dut.core.memwb_valid)
        $fatal(1, "T054 DC ZVA IRQ left transaction state active");
      writes_after_irq = target_write_count;
      for (int i = 0; i < 8; i++) begin
        @(posedge clk);
        #1;
        if (target_write_count != writes_after_irq ||
            (dut.commit_valid &&
             (dut.commit_mem_we || dut.commit_mem2_we)) ||
            (dut.commit_valid && dut.commit_insn == dc_zva(9)))
          $fatal(1, "T054 DC ZVA post-IRQ write/commit leaked");
      end
      if (accepted_before < 2)
        $fatal(1, "T054 DC ZVA did not establish a mid-beat overlap");
      if (target_write_mask != 8'hff || target_bad_data)
        $fatal(1, "T054 DC ZVA beat mask/data mismatch mask=%h bad=%b",
               target_write_mask, target_bad_data);
      active_target = 64'd0;
      active_target_hi = 64'd0;
      $display("T054 DC ZVA PASS fifo=%0d delay=%0d accepted=%0d mask=%h",
               FETCH_FIFO_ENABLE, MEM_DELAY_MODE, target_write_count,
               target_write_mask);
    end
  endtask

  initial begin
    target_write_count = 0;
    active_target = 64'd0;
    active_target_hi = 64'd0;
    count_target_writes = 1'b0;
    target_write_mask = 8'd0;
    target_bad_data = 1'b0;
    $display("=== lcvex_irq_atomic_overlap_tb fifo=%0d delay=%0d ===",
             FETCH_FIFO_ENABLE, MEM_DELAY_MODE);
    run_casp_match();
    run_casp_mismatch();
    run_stxr_id_squash();
    run_stxr_success();
    run_stxr_fail();
    run_dc_zva();
    $display("PASS: T054 natural CASP/STXR/DC ZVA IRQ overlap fifo=%0d delay=%0d",
             FETCH_FIFO_ENABLE, MEM_DELAY_MODE);
    $finish;
  end
endmodule
