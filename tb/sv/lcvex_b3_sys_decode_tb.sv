// lcvex_b3_sys_decode_tb.sv
// B3 系统/维护/原子浏览器：本文件采用解码器级定向，覆盖 barrier 编码语义。
// 重点验证 QEMU a64.decode 口径：
//   - DSB/DMB 接受任意 domain/types 选项；
//   - ISB 接受任意 CRm；
//   - SB 仅接受 CRm==0000（0xD50330FF），CRm 非 0 的 op2=111 编码为 UDEF。
// 只例化 lcvex_decode，避免完整 SoC 重编译；核心提交/排空语义仍由
// 既有 barrier/commit-backpressure 覆盖。

`timescale 1ns/1ps

/* verilator lint_off UNUSEDSIGNAL */
module lcvex_b3_sys_decode_tb;
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

  task automatic check(input logic cond, input string msg);
    if (!cond) begin
      $display("FAIL: %s", msg);
      $fatal(1, "lcvex_b3_sys_decode_tb failed");
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
    sctlr_el1 = 64'hC50838; tcr_el1 = 64'd0; ttbr0_el1 = 64'd0;
    ttbr1_el1 = 64'd0; mair_el1 = 64'd0; esr_el1 = 32'd0;
    far_el1 = 64'd0; sp_el0 = 64'd0; cpacr_el1 = 64'd0;
    fpcr_read_data = 32'd0; fpsr_read_data = 32'd0;
    fp_access_allowed = 1'b1;
    mdscr_el1 = 64'd0; pmuserenr_el0 = 64'd0; cntkctl_el1 = 64'd0;
    tpidr_el0 = 64'd0; tpidrro_el0 = 64'd0; tpidr_el1 = 64'd0;
    tcr2_el1 = 64'd0; pir_el1 = 64'd0; pire0_el1 = 64'd0;
    par_el1 = 64'd0; daif = 4'hF; zcr_el1 = 64'd0;
    smcr_el1 = 64'd0; csselr_el1 = 64'd0; mmu_en = 1'b0;

    // DMB sy: QEMU accepts arbitrary domain/types; must decode as barrier.
    insn = 32'hD5033FBF;
    #1;
    check(d.valid == 1'b1, "DMB sy must decode valid");
    check(d.exc == 1'b0, "DMB sy no exception");
    check(d.sys_op == lcvex_pkg::SYS_BARRIER, "DMB sy sys_op");

    // DMB #0 (CRm=0, op2=101): also barrier.
    insn = 32'hD50330BF;
    #1;
    check(d.valid == 1'b1, "DMB CRm=0 must decode valid");
    check(d.sys_op == lcvex_pkg::SYS_BARRIER, "DMB CRm=0 sys_op");

    // DSB sy: must decode as barrier.
    insn = 32'hD5033F9F;
    #1;
    check(d.valid == 1'b1, "DSB sy must decode valid");
    check(d.exc == 1'b0, "DSB sy no exception");
    check(d.sys_op == lcvex_pkg::SYS_BARRIER, "DSB sy sys_op");

    // DSB #0 / SSBB encoding with CRm=0 is still the DSB_DMB space; QEMU's
    // DSB_DMB pattern accepts it.
    insn = 32'hD503309F;
    #1;
    check(d.valid == 1'b1, "DSB CRm=0 must decode valid");
    check(d.sys_op == lcvex_pkg::SYS_BARRIER, "DSB CRm=0 sys_op");

    // ISB sy: QEMU accepts any CRm in the ISB slot.
    insn = 32'hD5033FDF;
    #1;
    check(d.valid == 1'b1, "ISB sy must decode valid");
    check(d.exc == 1'b0, "ISB sy no exception");
    check(d.sys_op == lcvex_pkg::SYS_BARRIER, "ISB sy sys_op");

    // ISB #1 with non-zero CRm is also accepted by QEMU's ISB pattern.
    insn = 32'hD50331DF;
    #1;
    check(d.valid == 1'b1, "ISB CRm=1 must decode valid");
    check(d.sys_op == lcvex_pkg::SYS_BARRIER, "ISB CRm=1 sys_op");

    // SB: canonical CRm==0000, op2=111.
    insn = 32'hD50330FF;
    #1;
    check(d.valid == 1'b1, "SB canonical must decode valid");
    check(d.exc == 1'b0, "SB canonical no exception");
    check(d.sys_op == lcvex_pkg::SYS_BARRIER, "SB canonical sys_op");

    // SB with CRm=1 (0xD50331FF) is not allocated in QEMU a64.decode and
    // must be UDEF, not treated as a barrier.
    insn = 32'hD50331FF;
    #1;
    check(d.valid == 1'b0, "SB CRm=1 must be rejected");
    check(d.exc == 1'b1, "SB CRm=1 must raise UDEF");
    check(d.exc_code == lcvex_pkg::EXC_UDEF, "SB CRm=1 UDEF code");

    // SB with CRm=15 (0xD5033FFF) also must be UDEF.
    insn = 32'hD5033FFF;
    #1;
    check(d.valid == 1'b0, "SB CRm=15 must be rejected");
    check(d.exc == 1'b1, "SB CRm=15 must raise UDEF");
    check(d.exc_code == lcvex_pkg::EXC_UDEF, "SB CRm=15 UDEF code");

    // CLREX remains its own system instruction, not a barrier.
    insn = 32'hD5033F5F;
    #1;
    check(d.valid == 1'b1, "CLREX must decode valid");
    check(d.exc == 1'b0, "CLREX no exception");
    check(d.sys_op == lcvex_pkg::SYS_NONE, "CLREX is not SYS_BARRIER");
    check(d.is_clrex == 1'b1, "CLREX is_clrex");

    $display("PASS: lcvex_b3_sys_decode_tb (barrier DSB/DMB/ISB/SB encoding semantics)");
    $finish;
  end
endmodule
