// lcvex_b3_atomic_barrier_tb.sv
// B3 剩余标量编码闭合：LSE 单寄存器原子、CAS、exclusive 和 barrier 的
// 解码器级定向矩阵。全部使用默认 Verilator 优化构建。
// 不修改 QEMU/L2 共享协议；只验证 core 解码/执行层语义。

`timescale 1ns/1ps

/* verilator lint_off UNUSEDSIGNAL */
module lcvex_b3_atomic_barrier_tb;
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

  function automatic logic [31:0] enc_lse(
      input logic [1:0] size, input logic [3:0] op,
      input logic [4:0] rt, input logic [4:0] rs,
      input logic [4:0] rn, input logic acquire, input logic rel);
    enc_lse = ({30'd0, size} << 30) | 32'h3820_0000 |
              ({31'd0, acquire} << 23) | ({31'd0, rel} << 22) |
              ({27'd0, rs} << 16) | ({28'd0, op} << 12) |
              ({27'd0, rn} << 5) | {27'd0, rt};
  endfunction

  function automatic logic [31:0] enc_cas(
      input logic [1:0] size, input logic [4:0] rs,
      input logic [4:0] rt, input logic [4:0] rn,
      input logic acquire, input logic rel);
    enc_cas = ({30'd0, size} << 30) | 32'h08A0_7C00 |
              ({31'd0, acquire} << 22) | ({31'd0, rel} << 15) |
              ({27'd0, rs} << 16) | ({27'd0, rn} << 5) | {27'd0, rt};
  endfunction

  function automatic logic [31:0] enc_ldxr(
      input logic [1:0] size, input logic [4:0] rt,
      input logic [4:0] rn, input logic lasr);
    enc_ldxr = ({30'd0, size} << 30) | 32'h085F_7C00 |
               ({31'd0, lasr} << 15) | ({27'd0, rn} << 5) | {27'd0, rt};
  endfunction

  function automatic logic [31:0] enc_stxr(
      input logic [1:0] size, input logic [4:0] rs,
      input logic [4:0] rt, input logic [4:0] rn, input logic lasr);
    enc_stxr = ({30'd0, size} << 30) | 32'h0800_7C00 |
               ({27'd0, rs} << 16) | ({31'd0, lasr} << 15) |
               ({27'd0, rn} << 5) | {27'd0, rt};
  endfunction

  task automatic check(input logic cond, input string msg);
    if (!cond) begin
      $display("FAIL: %s", msg);
      $fatal(1, "lcvex_b3_atomic_barrier_tb failed");
    end
  endtask

  initial begin
    pc = 64'h44000000;
    for (int i = 0; i < 31; i++) gpr[i] = 64'd0;
    for (int i = 0; i < 32; i++) v[i] = 128'd0;
    sp = 64'd0; nzcv = 4'd0;
    el = 1'b1; sp_sel = 1'b1;
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
    gpr[3] = 64'hABCDEF;
    gpr[4] = 64'h0000_0000_4400_1000;

    // LSE LDADD W [X4], X3, X2 with acquire+release (LDADDAL).
    insn = enc_lse(2'd2, 4'd0, 5'd2, 5'd3, 5'd4, 1'b1, 1'b1);
    #1;
    check(d.valid == 1'b1, "LSE LDADDAL W valid");
    check(d.is_atomic == 1'b1, "LSE LDADDAL W is_atomic");
    check(d.atomic_op == lcvex_pkg::ATOMIC_ADD, "LSE LDADDAL W op");
    check(d.mem_size == 2'd2 && d.is_32 == 1'b1, "LSE LDADDAL W size");
    check(d.is_load == 1'b1 && d.is_store == 1'b1, "LSE LDADDAL W load/store");
    check(d.wb_we == 1'b1 && d.wb_rd == 5'd2, "LSE LDADDAL W writeback");

    // LSE STADD X alias: rt=31, no readback.
    insn = enc_lse(2'd3, 4'd0, 5'd31, 5'd3, 5'd4, 1'b0, 1'b0);
    #1;
    check(d.valid == 1'b1, "LSE STADD X valid");
    check(d.is_atomic == 1'b1, "LSE STADD X is_atomic");
    check(d.is_load == 1'b0 && d.is_store == 1'b1, "LSE STADD X store alias");
    check(d.wb_we == 1'b0, "LSE STADD X no writeback");

    // LSE SWP for all four sizes.
    for (int sz = 0; sz < 4; sz++) begin
      insn = enc_lse(sz[1:0], 4'd8, 5'd2, 5'd3, 5'd4, 1'b0, 1'b0);
      #1;
      check(d.valid == 1'b1, $sformatf("LSE SWP size %0d valid", sz));
      check(d.atomic_op == lcvex_pkg::ATOMIC_SWP,
            $sformatf("LSE SWP size %0d op", sz));
      check(d.mem_size == sz[1:0], $sformatf("LSE SWP size %0d mem_size", sz));
    end

    // CAS/CASA/CASL/CASAL W and B.
    insn = enc_cas(2'd2, 5'd3, 5'd2, 5'd4, 1'b1, 1'b1);
    #1;
    check(d.valid == 1'b1, "CASAL W valid");
    check(d.is_atomic == 1'b1 && d.atomic_op == lcvex_pkg::ATOMIC_CAS,
          "CASAL W atomic");
    check(d.mem_size == 2'd2, "CASAL W size");
    check(d.is_load == 1'b1 && d.is_store == 1'b1, "CASAL W load/store");

    insn = enc_cas(2'd0, 5'd3, 5'd2, 5'd4, 1'b0, 1'b0);
    #1;
    check(d.valid == 1'b1, "CASB valid");
    check(d.mem_size == 2'd0, "CASB size");

    // Exclusive load/store non-pair, including acquire variants.
    insn = enc_ldxr(2'd2, 5'd2, 5'd4, 1'b0);
    #1;
    check(d.valid == 1'b1, "LDXR W valid");
    check(d.is_ldxr == 1'b1, "LDXR W is_ldxr");
    check(d.mem_size == 2'd2, "LDXR W size");

    insn = enc_ldxr(2'd3, 5'd2, 5'd4, 1'b1);
    #1;
    check(d.valid == 1'b1, "LDAXR X valid");
    check(d.is_ldxr == 1'b1, "LDAXR X is_ldxr");

    insn = enc_stxr(2'd2, 5'd1, 5'd2, 5'd4, 1'b0);
    #1;
    check(d.valid == 1'b1, "STXR W valid");
    check(d.is_stxr == 1'b1, "STXR W is_stxr");

    insn = enc_stxr(2'd3, 5'd1, 5'd2, 5'd4, 1'b1);
    #1;
    check(d.valid == 1'b1, "STLXR X valid");
    check(d.is_stxr == 1'b1, "STLXR X is_stxr");

    // Barriers available at EL0 as well.
    el = 1'b0;
    insn = 32'hD5033FBF;  // DMB sy
    #1; check(d.valid == 1'b1 && d.sys_op == lcvex_pkg::SYS_BARRIER,
              "EL0 DMB sy barrier");
    insn = 32'hD5033F9F;  // DSB sy
    #1; check(d.valid == 1'b1 && d.sys_op == lcvex_pkg::SYS_BARRIER,
              "EL0 DSB sy barrier");
    insn = 32'hD5033FDF;  // ISB sy
    #1; check(d.valid == 1'b1 && d.sys_op == lcvex_pkg::SYS_BARRIER,
              "EL0 ISB sy barrier");
    insn = 32'hD50330FF;  // SB
    #1; check(d.valid == 1'b1 && d.sys_op == lcvex_pkg::SYS_BARRIER,
              "EL0 SB barrier");

    // Reserved LSE opcode 4'd9 is not an atomic op -> UDEF.
    el = 1'b1;
    insn = enc_lse(2'd3, 4'd9, 5'd2, 5'd3, 5'd4, 1'b0, 1'b0);
    #1;
    check(d.valid == 1'b0, "reserved LSE op UDEF");
    check(d.exc == 1'b1 && d.exc_code == lcvex_pkg::EXC_UDEF,
          "reserved LSE op UDEF code");

    $display("PASS: lcvex_b3_atomic_barrier_tb (LSE/CAS/exclusive/barrier scalar matrix)");
    $finish;
  end
endmodule
