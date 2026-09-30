// lcvex_b1_decode_tb.sv
// B1 标量闭合的解码器级定向测试：logical shifted-register ROR 接受，
// ADD/SUB shifted-register ROR 保持保留/UDEF。
// 只例化 lcvex_decode，避免完整 SoC 重编译；核心级路径由
// sim/cocotb/test_b1_logic_ror.py 覆盖。

`timescale 1ns/1ps

/* verilator lint_off UNUSEDSIGNAL */
module lcvex_b1_decode_tb;
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
      $fatal(1, "lcvex_b1_decode_tb failed");
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

    // ORR X4, X1, X1, ROR #1: logical shifted-register ROR accepted.
    insn = 32'hAAC10424;
    #1;
    check(d.valid == 1'b1, "logical ROR must decode valid");
    check(d.exc == 1'b0, "logical ROR must not raise decode exception");
    check(d.shift_type == 2'd3, "logical ROR shift_type must be 3");
    check(d.alu_op == lcvex_pkg::ALU_ORR, "logical ROR ORR opcode");
    check(d.wb_we == 1'b1, "logical ROR must write back");

    // EON X9, X1, X1, ROR #1: inverted logical ROR accepted.
    insn = 32'hCAE10429;
    #1;
    check(d.valid == 1'b1, "EON ROR must decode valid");
    check(d.inv_b == 1'b1, "EON ROR must set inv_b");
    check(d.alu_op == lcvex_pkg::ALU_EOR, "EON ROR opcode");

    // XZR semantics in logical shifted-register ROR.
    gpr[1] = 64'h8000000000000001;
    sp = 64'h200;
    // ORR X15, XZR, X1, ROR #1
    insn = 32'hAAC107EF;
    #1;
    check(d.valid == 1'b1, "logical ROR XZR source valid");
    check(d.operand_a == 64'd0, "XZR source reads zero");
    // AND X16, X1, XZR, ROR #1
    insn = 32'h8ADF0430;
    #1;
    check(d.valid == 1'b1, "logical ROR XZR second source valid");
    check(d.operand_b == 64'd0, "XZR second source reads zero");
    // ORR XZR, X1, X1, ROR #1
    insn = 32'hAAC1043F;
    #1;
    check(d.valid == 1'b1, "logical ROR XZR destination valid");
    check(d.wb_we == 1'b0, "logical ROR XZR destination does not write");

    // XZR in adjacent ADD/SUB shifted-register.
    // ADD X17, XZR, X1, LSL #0
    insn = 32'h8B0103F1;
    #1;
    check(d.valid == 1'b1, "add shifted-register XZR source valid");
    check(d.operand_a == 64'd0, "add shifted-register XZR source zero");
    // ADD X18, X1, XZR, LSL #0
    insn = 32'h8B1F0032;
    #1;
    check(d.valid == 1'b1, "add shifted-register XZR operand valid");
    check(d.operand_b == 64'd0, "add shifted-register XZR operand zero");
    // ADD XZR, X1, X1, LSL #0
    insn = 32'h8B01003F;
    #1;
    check(d.valid == 1'b1, "add shifted-register XZR dest valid");
    check(d.wb_we == 1'b0, "add shifted-register XZR dest no write");

    // SP semantics in ADD/SUB immediate.
    // ADD X19, SP, #0x123
    insn = 32'h91048FF3;
    #1;
    check(d.valid == 1'b1, "add immediate SP source valid");
    check(d.operand_a == 64'h200, "add immediate reads SP");
    // ADD SP, SP, #0x10
    insn = 32'h910043FF;
    #1;
    check(d.valid == 1'b1, "add immediate SP dest valid");
    check(d.sp_we == 1'b1, "add immediate non-S Rd=31 writes SP");
    check(d.wb_we == 1'b0, "add immediate non-S Rd=31 does not GPR-write");
    // ADDS XZR, SP, #0
    insn = 32'hB10003FF;
    #1;
    check(d.valid == 1'b1, "adds immediate SP dest valid");
    check(d.sp_we == 1'b0, "adds immediate S=1 Rd=31 discards SP write");
    check(d.wb_we == 1'b0, "adds immediate S=1 Rd=31 discards GPR write");

    // ADD X20, X1, X1, ROR #1: reserved shifted-register ROR -> UDEF.
    insn = 32'h8BC10434;
    #1;
    check(d.valid == 1'b0, "ADD shifted-register ROR must be rejected");
    check(d.exc == 1'b1, "ADD shifted-register ROR must raise UDEF");
    check(d.exc_code == lcvex_pkg::EXC_UDEF, "ADD shifted-register ROR UDEF code");

    // B2a：标量 FP16 FMA 解码（FMADD h0,h1,h2,h3）。
    insn = 32'h1fc20c20;
    #1;
    check(d.valid == 1'b1, "scalar H FMADD must decode valid");
    check(d.exc == 1'b0, "scalar H FMADD no UDEF");
    check(d.fp_valid == 1'b1, "scalar H FMADD fp_valid");
    check(d.fp_op == lcvex_pkg::FP_OP_FMADD, "scalar H FMADD op");
    check(d.fp_is_half == 1'b1, "scalar H FMADD is_half");
    check(d.fp_is_double == 1'b0, "scalar H FMADD is_double");
    check(d.fp_wb_we == 1'b1, "scalar H FMADD writes V");
    check(d.fp_rn == 5'd1 && d.fp_rm == 5'd2 && d.fp_ra == 5'd3,
          "scalar H FMADD register fields");

    // B2a：向量 4H FMLA 解码（FMLA v4.4h, v0.4h, v1.4h）。
    insn = 32'h0e410c04;
    #1;
    check(d.valid == 1'b1, "4H FMLA must decode valid");
    check(d.neon_valid == 1'b1 && d.neon_fp_valid == 1'b1,
          "4H FMLA neon/fp valid");
    check(d.neon_fp_op == lcvex_pkg::NEON_FP_OP_FMLA,
          "4H FMLA neon fp op");
    check(d.neon_fp_is_half == 1'b1, "4H FMLA is_half");
    check(d.neon_fp_quad == 1'b0, "4H FMLA quad=0");
    check(d.neon_fp_ra_en == 1'b1, "4H FMLA reads Vd addend");
    check(d.neon_wb_we == 1'b1, "4H FMLA writes V");

    // B2a：向量 4H FMLS 解码（FMLS v5.4h, v0.4h, v1.4h）。
    insn = 32'h0ec10c05;
    #1;
    check(d.valid == 1'b1, "4H FMLS must decode valid");
    check(d.neon_fp_op == lcvex_pkg::NEON_FP_OP_FMLS,
          "4H FMLS neon fp op");
    check(d.neon_fp_is_half == 1'b1, "4H FMLS is_half");
    check(d.neon_fp_ra_en == 1'b1, "4H FMLS reads Vd addend");

    $display("PASS: lcvex_b1_decode_tb (logical ROR accepted, ADD/SUB ROR UDEF)");
    $finish;
  end
endmodule
