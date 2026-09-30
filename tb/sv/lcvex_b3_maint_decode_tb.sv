// lcvex_b3_maint_decode_tb.sv
// B3 维护指令解码器级定向测试。
// 覆盖：
//   - IC/DC 已支持 tuple 的 EL1 解码；
//   - EL0 DC ZVA 由 SCTLR_EL1.DZE(bit14) 门控，未开启时 EC=0x18，
//     开启时正常 SYS_MAINT；
//   - EL0 其它 cache maintenance 由 SCTLR_EL1.UCI(bit26) 门控；
//   - PL1-only maintenance 在 EL0 UDEF；
//   - TLBI EL1 基线 valid，EL2/op1=4 空间 UDEF；
//   - 未批准 DC CVADP 保持 UDEF（负测，不实实现）。
// 只例化 lcvex_decode，避免完整 SoC 重编译。

`timescale 1ns/1ps

/* verilator lint_off UNUSEDSIGNAL */
module lcvex_b3_maint_decode_tb;
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
    .contextidr_el1(64'd0),
    .tcr2_el1(tcr2_el1), .pir_el1(pir_el1), .pire0_el1(pire0_el1),
    .par_el1(par_el1), .daif(daif), .zcr_el1(zcr_el1),
    .smcr_el1(smcr_el1), .csselr_el1(csselr_el1),
    .mmu_en(mmu_en),
    .d(d)
  );

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
      $fatal(1, "lcvex_b3_maint_decode_tb failed");
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
    vbar_el1 = 64'd0; elr_el1 = 64'd0; spsr_el1 = 64'd0;
    sctlr_el1 = 64'd0; tcr_el1 = 64'd0; ttbr0_el1 = 64'd0;
    ttbr1_el1 = 64'd0; mair_el1 = 64'd0; esr_el1 = 32'd0;
    far_el1 = 64'd0; sp_el0 = 64'd0; cpacr_el1 = 64'd0;
    fpcr_read_data = 32'd0; fpsr_read_data = 32'd0;
    fp_access_allowed = 1'b1;
    mdscr_el1 = 64'd0; pmuserenr_el0 = 64'd0; cntkctl_el1 = 64'd0;
    tpidr_el0 = 64'd0; tpidrro_el0 = 64'd0; tpidr_el1 = 64'd0;
    tcr2_el1 = 64'd0; pir_el1 = 64'd0; pire0_el1 = 64'd0;
    par_el1 = 64'd0; daif = 4'hF; zcr_el1 = 64'd0;
    smcr_el1 = 64'd0; csselr_el1 = 64'd0; mmu_en = 1'b0;
    gpr[2] = 64'h0000_0000_4400_0100;

    // EL1 DC ZVA: valid SYS_MAINT.
    insn = enc_sys(1'b0, 2'd1, 3'd3, 4'd7, 4'd4, 3'd1, 5'd2);
    #1;
    check(d.valid == 1'b1, "EL1 DC ZVA valid");
    check(d.exc == 1'b0, "EL1 DC ZVA no exception");
    check(d.sys_op == lcvex_pkg::SYS_MAINT, "EL1 DC ZVA sys_op");
    check(d.maint_op == lcvex_pkg::MAINT_DC_ZVA, "EL1 DC ZVA maint_op");
    check(d.maint_va == 64'h0000_0000_4400_0100, "EL1 DC ZVA maint VA");

    // EL0 DC ZVA with DZE=0 -> System Register Trap EC=0x18.
    el = 1'b0;
    sctlr_el1 = 64'd0;
    insn = enc_sys(1'b0, 2'd1, 3'd3, 4'd7, 4'd4, 3'd1, 5'd2);
    #1;
    check(d.valid == 1'b1, "EL0 DC ZVA DZE=0 retains valid decode");
    check(d.exc == 1'b1 && d.exc_code == lcvex_pkg::EXC_SYSREG_TRAP,
          "EL0 DC ZVA DZE=0 trap EC=0x18");

    // EL0 DC ZVA with DZE=1 -> normal SYS_MAINT, no trap.
    sctlr_el1[14] = 1'b1;
    insn = enc_sys(1'b0, 2'd1, 3'd3, 4'd7, 4'd4, 3'd1, 5'd2);
    #1;
    check(d.valid == 1'b1, "EL0 DC ZVA DZE=1 valid");
    check(d.exc == 1'b0, "EL0 DC ZVA DZE=1 no trap");
    check(d.sys_op == lcvex_pkg::SYS_MAINT, "EL0 DC ZVA DZE=1 SYS_MAINT");
    check(d.maint_op == lcvex_pkg::MAINT_DC_ZVA, "EL0 DC ZVA DZE=1 maint_op");

    // EL0 DC CVAP with UCI=0 -> SYSREG trap EC=0x18.
    sctlr_el1 = 64'd0;
    insn = enc_sys(1'b0, 2'd1, 3'd3, 4'd7, 4'd12, 3'd1, 5'd2);
    #1;
    check(d.valid == 1'b1, "EL0 DC CVAP UCI=0 retains valid decode");
    check(d.exc == 1'b1 && d.exc_code == lcvex_pkg::EXC_SYSREG_TRAP,
          "EL0 DC CVAP UCI=0 trap EC=0x18");

    // EL0 DC CVAP with UCI=1 -> normal SYS_MAINT.
    sctlr_el1[26] = 1'b1;
    insn = enc_sys(1'b0, 2'd1, 3'd3, 4'd7, 4'd12, 3'd1, 5'd2);
    #1;
    check(d.valid == 1'b1, "EL0 DC CVAP UCI=1 valid");
    check(d.exc == 1'b0, "EL0 DC CVAP UCI=1 no trap");
    check(d.maint_op == lcvex_pkg::MAINT_DC_CVAP, "EL0 DC CVAP UCI=1 maint_op");

    // EL0 DC IVAC is PL1-only -> UDEF.
    insn = enc_sys(1'b0, 2'd1, 3'd0, 4'd7, 4'd6, 3'd1, 5'd2);
    #1;
    check(d.valid == 1'b0, "EL0 DC IVAC rejected");
    check(d.exc == 1'b1 && d.exc_code == lcvex_pkg::EXC_UDEF,
          "EL0 DC IVAC UDEF");

    // EL1 TLBI VMALLE1IS -> SYS_MAINT / MAINT_TLBI.
    el = 1'b1;
    insn = enc_sys(1'b0, 2'd1, 3'd0, 4'd8, 4'd3, 3'd0, 5'd31);
    #1;
    check(d.valid == 1'b1, "EL1 TLBI VMALLE1IS valid");
    check(d.sys_op == lcvex_pkg::SYS_MAINT, "EL1 TLBI VMALLE1IS sys_op");
    check(d.maint_op == lcvex_pkg::MAINT_TLBI, "EL1 TLBI VMALLE1IS maint_op");

    // EL1 TLBI VAE1IS: QEMU AArch64 encoding is CRm=3, op2=1 (IS group);
    // Rt carries the VA operand.
    insn = enc_sys(1'b0, 2'd1, 3'd0, 4'd8, 4'd3, 3'd1, 5'd2);
    #1;
    check(d.valid == 1'b1, "EL1 TLBI VAE1IS valid");
    check(d.maint_op == lcvex_pkg::MAINT_TLBI, "EL1 TLBI VAE1IS maint_op");
    check(d.maint_va == 64'h0000_0000_4400_0100, "EL1 TLBI VAE1IS maint VA");

    // EL0 TLBI is PL1-only -> UDEF.
    el = 1'b0;
    insn = enc_sys(1'b0, 2'd1, 3'd0, 4'd8, 4'd3, 3'd0, 5'd31);
    #1;
    check(d.valid == 1'b0, "EL0 TLBI rejected");
    check(d.exc == 1'b1 && d.exc_code == lcvex_pkg::EXC_UDEF, "EL0 TLBI UDEF");

    // EL2-space TLBI (op1=4) must not alias implemented EL1 forms -> UDEF.
    el = 1'b1;
    insn = enc_sys(1'b0, 2'd1, 3'd4, 4'd8, 4'd3, 3'd0, 5'd31);
    #1;
    check(d.valid == 1'b0, "EL1 TLBI op1=4 rejected");
    check(d.exc == 1'b1 && d.exc_code == lcvex_pkg::EXC_UDEF,
          "EL1 TLBI op1=4 UDEF");

    // Asserted/deferred DC CVADP remains UDEF in this profile.
    insn = enc_sys(1'b0, 2'd1, 3'd3, 4'd7, 4'd13, 3'd1, 5'd2);
    #1;
    check(d.valid == 1'b0, "DC CVADP remains rejected");
    check(d.exc == 1'b1 && d.exc_code == lcvex_pkg::EXC_UDEF,
          "DC CVADP UDEF negative");

    $display("PASS: lcvex_b3_maint_decode_tb (DC ZVA DZE gate, cache/TLBI maintenance matrix)");
    $finish;
  end
endmodule
