// lcvex_b3_sysreg_access_tb.sv
// B3 系统寄存器访问矩阵解码器级定向测试。
// 重点验证：
//   - EL1 MRS/MSR 常用寄存器读写方向；
//   - EL0 对 EL1-only 寄存器的访问为 UDEF；
//   - Generic Timer EL0 gate 未打开时产生 EC=0x18 SYSREG trap；
//   - OSLAR_EL1 是 QEMU PL1_W write-only，MRS 应为 UDEF；
//   - 未识别 SYS 编码应为 UDEF。
// 只例化 lcvex_decode，避免完整 SoC 重编译；核心提交/写回时机由
// 既有 core/commit-backpressure 测试覆盖。

`timescale 1ns/1ps

/* verilator lint_off UNUSEDSIGNAL */
module lcvex_b3_sysreg_access_tb;
  logic [31:0] insn;
  logic [63:0] pc;
  logic [63:0] gpr [0:30];
  logic [127:0] v [0:31];
  logic [63:0] sp;
  logic [3:0]  nzcv;
  logic        el, sp_sel, dit, ssbs, uao, pan, tco, allint;
  logic [63:0] vbar_el1, elr_el1, spsr_el1, sctlr_el1, tcr_el1;
  logic [63:0] ttbr0_el1, ttbr1_el1, mair_el1, far_el1;
  logic [31:0] esr_el1;
  logic [63:0] sp_el0, cpacr_el1, mdscr_el1, pmuserenr_el0;
  logic [63:0] cntkctl_el1, tpidr_el0, tpidrro_el0, tpidr_el1;
  logic [63:0] contextidr_el1;
  logic [63:0] tcr2_el1, pir_el1, pire0_el1, par_el1;
  logic [3:0]  daif;
  logic [63:0] zcr_el1, smcr_el1, csselr_el1;
  logic [31:0] fpcr_read_data, fpsr_read_data;
  logic        fp_access_allowed, mmu_en;
  lcvex_pkg::decoded_insn_t d;

  lcvex_decode dut (
    .insn(insn), .pc(pc),
    .gpr(gpr), .v(v), .sp(sp), .nzcv(nzcv),
    .el(el), .sp_sel(sp_sel), .dit(dit), .ssbs(ssbs), .uao(uao),
    .pan(pan), .tco(tco), .allint(allint),
    .vbar_el1(vbar_el1), .elr_el1(elr_el1), .spsr_el1(spsr_el1),
    .sctlr_el1(sctlr_el1), .tcr_el1(tcr_el1),
    .ttbr0_el1(ttbr0_el1), .ttbr1_el1(ttbr1_el1), .mair_el1(mair_el1),
    .esr_el1(esr_el1), .far_el1(far_el1), .sp_el0(sp_el0),
    .cpacr_el1(cpacr_el1), .fpcr_read_data(fpcr_read_data),
    .fpsr_read_data(fpsr_read_data), .fp_access_allowed(fp_access_allowed),
    .mdscr_el1(mdscr_el1), .pmuserenr_el0(pmuserenr_el0),
    .cntkctl_el1(cntkctl_el1), .tpidr_el0(tpidr_el0),
    .tpidrro_el0(tpidrro_el0), .tpidr_el1(tpidr_el1),
    .contextidr_el1(contextidr_el1),
    .tcr2_el1(tcr2_el1), .pir_el1(pir_el1), .pire0_el1(pire0_el1),
    .par_el1(par_el1), .daif(daif), .zcr_el1(zcr_el1),
    .smcr_el1(smcr_el1), .csselr_el1(csselr_el1),
    .mmu_en(mmu_en),
    .d(d)
  );

  // AArch64 SYS encoding: 1101010100 l op0 op1 CRn CRm op2 Rt
  function automatic logic [31:0] enc_sys(
      input logic read, input logic [1:0] op0,
      input logic [2:0] op1, input logic [3:0] crn,
      input logic [3:0] crm, input logic [2:0] op2,
      input logic [4:0] rt);
    enc_sys = 32'hD5000000 | ({31'd0, read} << 21) |
             ({30'd0, op0} << 19) | ({29'd0, op1} << 16) |
             ({28'd0, crn} << 12) | ({28'd0, crm} << 8) |
             ({29'd0, op2} << 5) | {27'd0, rt};
  endfunction

  task automatic check(input logic cond, input string msg);
    if (!cond) begin
      $display("FAIL: %s", msg);
      $fatal(1, "lcvex_b3_sysreg_access_tb failed");
    end
  endtask

  initial begin
    pc = 64'h44000000;
    for (int i = 0; i < 31; i++) begin
      gpr[i] = 64'd0;
    end
    for (int i = 0; i < 32; i++) begin
      v[i] = 128'd0;
    end
    sp = 64'd0;
    nzcv = 4'd0;
    el = 1'b1;
    sp_sel = 1'b1;
    dit = 1'b0; ssbs = 1'b0; uao = 1'b0; pan = 1'b0; tco = 1'b0;
    allint = 1'b0;
    vbar_el1 = 64'h0; elr_el1 = 64'h0; spsr_el1 = 64'h0;
    sctlr_el1 = 64'hC50838; tcr_el1 = 64'd0; ttbr0_el1 = 64'd0;
    ttbr1_el1 = 64'd0; mair_el1 = 64'd0; esr_el1 = 32'd0;
    far_el1 = 64'd0; sp_el0 = 64'd0; cpacr_el1 = 64'd0;
    fpcr_read_data = 32'd0; fpsr_read_data = 32'd0;
    fp_access_allowed = 1'b1;
    mdscr_el1 = 64'd0; pmuserenr_el0 = 64'd0; cntkctl_el1 = 64'd0;
    tpidr_el0 = 64'd0; tpidrro_el0 = 64'd0; tpidr_el1 = 64'd0;
    contextidr_el1 = 64'h1234_5678_9ABC_DEF0;
    tcr2_el1 = 64'd0; pir_el1 = 64'd0; pire0_el1 = 64'd0;
    par_el1 = 64'd0; daif = 4'hF; zcr_el1 = 64'd0;
    smcr_el1 = 64'd0; csselr_el1 = 64'd0; mmu_en = 1'b0;
    gpr[1] = 64'h1234_5678_9ABC_DEF0;
    gpr[2] = 64'd0;

    // EL1 MRS VBAR_EL1: valid MRS, returns stored value.
    vbar_el1 = 64'h0000_0000_4401_0000;
    insn = enc_sys(1'b1, 2'd3, 3'd0, 4'd12, 4'd0, 3'd0, 5'd2);
    #1;
    check(d.valid == 1'b1, "EL1 MRS VBAR_EL1 valid");
    check(d.exc == 1'b0, "EL1 MRS VBAR_EL1 no exception");
    check(d.sys_op == lcvex_pkg::SYS_MRS, "EL1 MRS VBAR_EL1 sys_op");
    check(d.sys_reg == lcvex_pkg::SREG_VBAR_EL1, "EL1 MRS VBAR_EL1 sys_reg");
    check(d.wb_we == 1'b1 && d.wb_rd == 5'd2, "EL1 MRS VBAR_EL1 writeback");
    check(d.wb_extra == 64'h0000_0000_4401_0000, "EL1 MRS VBAR_EL1 value");

    // EL1 MRS SCTLR_EL1: decoder returns low 32 bits (existing mask).
    sctlr_el1 = 64'h1111_2222_3333_4444;
    insn = enc_sys(1'b1, 2'd3, 3'd0, 4'd1, 4'd0, 3'd0, 5'd3);
    #1;
    check(d.valid == 1'b1, "EL1 MRS SCTLR_EL1 valid");
    check(d.wb_extra == 64'h0000_0000_3333_4444, "EL1 MRS SCTLR_EL1 low32 mask");

    // EL1 MRS MIDR_EL1: read-only ID returns constant.
    insn = enc_sys(1'b1, 2'd3, 3'd0, 4'd0, 4'd0, 3'd0, 5'd4);
    #1;
    check(d.valid == 1'b1, "EL1 MRS MIDR_EL1 valid");
    check(d.sys_reg == lcvex_pkg::SREG_MIDR_EL1, "EL1 MRS MIDR_EL1 sys_reg");
    check(d.wb_extra == lcvex_pkg::MIDR_EL1_VAL, "EL1 MRS MIDR_EL1 reset value");

    // EL1 MSR TPIDR_EL0: valid MSR, source register latched.
    insn = enc_sys(1'b0, 2'd3, 3'd3, 4'd13, 4'd0, 3'd2, 5'd1);
    #1;
    check(d.valid == 1'b1, "EL1 MSR TPIDR_EL0 valid");
    check(d.exc == 1'b0, "EL1 MSR TPIDR_EL0 no exception");
    check(d.sys_op == lcvex_pkg::SYS_MSR, "EL1 MSR TPIDR_EL0 sys_op");
    check(d.sys_reg == lcvex_pkg::SREG_TPIDR_EL0, "EL1 MSR TPIDR_EL0 sys_reg");
    check(d.sys_wdata == 64'h1234_5678_9ABC_DEF0, "EL1 MSR TPIDR_EL0 source value");

    // EL1 MRS CONTEXTIDR_EL1: returns core state.
    insn = enc_sys(1'b1, 2'd3, 3'd0, 4'd13, 4'd0, 3'd1, 5'd7);
    #1;
    check(d.valid == 1'b1, "EL1 MRS CONTEXTIDR_EL1 valid");
    check(d.sys_reg == lcvex_pkg::SREG_CONTEXTIDR_EL1,
          "EL1 MRS CONTEXTIDR_EL1 sys_reg");
    check(d.wb_extra == 64'h1234_5678_9ABC_DEF0,
          "EL1 MRS CONTEXTIDR_EL1 value");

    // EL1 MSR CONTEXTIDR_EL1: RW decode accepted.
    insn = enc_sys(1'b0, 2'd3, 3'd0, 4'd13, 4'd0, 3'd1, 5'd1);
    #1;
    check(d.valid == 1'b1, "EL1 MSR CONTEXTIDR_EL1 valid");
    check(d.sys_op == lcvex_pkg::SYS_MSR, "EL1 MSR CONTEXTIDR_EL1 sys_op");
    check(d.sys_reg == lcvex_pkg::SREG_CONTEXTIDR_EL1,
          "EL1 MSR CONTEXTIDR_EL1 sys_reg");

    // EL0 MRS VBAR_EL1: EL1-only register at EL0 -> UDEF.
    el = 1'b0;
    insn = enc_sys(1'b1, 2'd3, 3'd0, 4'd12, 4'd0, 3'd0, 5'd2);
    #1;
    check(d.valid == 1'b0, "EL0 MRS VBAR_EL1 rejected");
    check(d.exc == 1'b1 && d.exc_code == lcvex_pkg::EXC_UDEF, "EL0 MRS VBAR_EL1 UDEF");

    // EL0 MRS CNTPCT with CNTKCTL gate closed -> SYSREG trap EC=0x18.
    cntkctl_el1 = 64'd0;
    insn = enc_sys(1'b1, 2'd3, 3'd3, 4'd14, 4'd0, 3'd1, 5'd2);
    #1;
    check(d.valid == 1'b1, "EL0 CNTPCT gate-closed retains valid decode");
    check(d.exc == 1'b1 && d.exc_code == lcvex_pkg::EXC_SYSREG_TRAP,
          "EL0 CNTPCT gate-closed trap EC=0x18");

    // EL0 MRS CNTPCT with CNTKCTL bit0 open -> normal MRS, no trap.
    cntkctl_el1 = 64'd1;
    insn = enc_sys(1'b1, 2'd3, 3'd3, 4'd14, 4'd0, 3'd1, 5'd2);
    #1;
    check(d.valid == 1'b1, "EL0 CNTPCT gate-open valid");
    check(d.exc == 1'b0, "EL0 CNTPCT gate-open no trap");
    check(d.sys_op == lcvex_pkg::SYS_MRS, "EL0 CNTPCT gate-open MRS");

    // EL1-up: OSLAR_EL1 is PL1_W; MRS must be UDEF.
    el = 1'b1;
    insn = enc_sys(1'b1, 2'd2, 3'd0, 4'd1, 4'd0, 3'd4, 5'd5);
    #1;
    check(d.valid == 1'b0, "EL1 MRS OSLAR_EL1 rejected");
    check(d.exc == 1'b1 && d.exc_code == lcvex_pkg::EXC_UDEF,
          "EL1 MRS OSLAR_EL1 UDEF");

    // EL1 MSR OSLAR_EL1: write-only is accepted.
    insn = enc_sys(1'b0, 2'd2, 3'd0, 4'd1, 4'd0, 3'd4, 5'd1);
    #1;
    check(d.valid == 1'b1, "EL1 MSR OSLAR_EL1 valid");
    check(d.exc == 1'b0, "EL1 MSR OSLAR_EL1 no exception");
    check(d.sys_op == lcvex_pkg::SYS_MSR, "EL1 MSR OSLAR_EL1 sys_op");
    check(d.sys_reg == lcvex_pkg::SREG_OSLAR_EL1, "EL1 MSR OSLAR_EL1 sys_reg");

    // EL1 MRS OSDLR_EL1: PL1_RW debug shim reads zero.
    insn = enc_sys(1'b1, 2'd2, 3'd0, 4'd1, 4'd3, 3'd4, 5'd6);
    #1;
    check(d.valid == 1'b1, "EL1 MRS OSDLR_EL1 valid");
    check(d.sys_reg == lcvex_pkg::SREG_OSDLR_EL1, "EL1 MRS OSDLR_EL1 sys_reg");
    check(d.wb_extra == 64'd0, "EL1 MRS OSDLR_EL1 read zero");

    // EL1 MRS OSLSR_EL1: read-only, resetvalue 10 (0xA).
    insn = enc_sys(1'b1, 2'd2, 3'd0, 4'd1, 4'd1, 3'd4, 5'd6);
    #1;
    check(d.valid == 1'b1, "EL1 MRS OSLSR_EL1 valid");
    check(d.sys_reg == lcvex_pkg::SREG_OSLSR_EL1, "EL1 MRS OSLSR_EL1 sys_reg");
    check(d.wb_extra == 64'd10, "EL1 MRS OSLSR_EL1 reset value");

    // EL1 MSR OSLSR_EL1: read-only, write must be UDEF.
    insn = enc_sys(1'b0, 2'd2, 3'd0, 4'd1, 4'd1, 3'd4, 5'd1);
    #1;
    check(d.valid == 1'b0, "EL1 MSR OSLSR_EL1 rejected");
    check(d.exc == 1'b1 && d.exc_code == lcvex_pkg::EXC_UDEF,
          "EL1 MSR OSLSR_EL1 UDEF");

    // Unknown/unsupported SYS space at EL1 -> UDEF.
    insn = enc_sys(1'b1, 2'd3, 3'd0, 4'd15, 4'd0, 3'd0, 5'd7);
    #1;
    check(d.valid == 1'b0, "unknown sysreg rejected");
    check(d.exc == 1'b1 && d.exc_code == lcvex_pkg::EXC_UDEF, "unknown sysreg UDEF");

    $display("PASS: lcvex_b3_sysreg_access_tb (EL1/EL0 sysreg access matrix, OSLAR write-only)");
    $finish;
  end
endmodule
