// T-20260920-023: directed and reference-backed logical-immediate regression.
//
// This bench deliberately instantiates the production decoder.  The Quartus
// probe uses the same decoder through lcvex_logic_imm_quartus_probe_top.sv;
// this file is only the executable behavioral oracle and is never used as a
// production expected-result registry.

`timescale 1ns/1ps

/* verilator lint_off UNUSEDSIGNAL */
module lcvex_logic_imm_quartus_tb;
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
    .insn(insn), .pc(pc), .gpr(gpr), .v(v), .sp(sp), .nzcv(nzcv),
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
    .contextidr_el1(64'd0), .tcr2_el1(tcr2_el1), .pir_el1(pir_el1),
    .pire0_el1(pire0_el1), .par_el1(par_el1), .daif(daif),
    .zcr_el1(zcr_el1), .smcr_el1(smcr_el1), .csselr_el1(csselr_el1),
    .mmu_en(mmu_en), .d(d)
  );

  task automatic check(input logic condition, input string message);
    // Treat X/Z as a failure too; exhaustive enumeration must not silently
    // accept an unknown decoder bit as a Boolean false/true.
    if (condition !== 1'b1) begin
      $display("LOGIC_IMM_TB_FAIL %s insn=%08x valid=%b exc=%b mask=%016x a=%016x",
               message, insn, d.valid, d.exc, d.operand_b, d.operand_a);
      $fatal(1, "logical-immediate behavioral oracle failed");
    end
  endtask

  // Independent reference for AArch64 DecodeBitMasks.  It returns {valid,
  // mask}; unlike the RTL under test, it has no output argument and no
  // shared helper.  len=1..5 are element sizes up to 32 bits and len=6 is
  // the 64-bit element size.  sf and N are kept separate: X-form N=0 is
  // legal for <=32-bit masks, while W-form N=1 is reserved by the ISA.
  function automatic [64:0] reference_mask(
      input logic       sf,
      input logic       immn,
      input logic [5:0] immr,
      input logic [5:0] imms);
    integer len;
    integer e;
    integer levels;
    integer s;
    integer r;
    integer i;
    reg [6:0] search;
    reg [63:0] element;
    reg [63:0] rotated;
    reg [63:0] mask;
    begin
      search = {immn, ~imms};
      len = -1;
      for (i = 6; i >= 0; i = i - 1) begin
        if ((len < 0) && search[i]) begin
          len = i;
        end
      end
      // A 32-bit instruction has N=0; its largest element is 32 bits.
      if ((!sf && immn) || (len < 1) || (len > 6)) begin
        reference_mask = 65'd0;
      end else begin
        e = 1 << len;
        levels = e - 1;
        s = imms & levels;
        r = immr & levels;
        if (s == levels) begin
          reference_mask = 65'd0;
        end else begin
          element = 64'd0;
          for (i = 0; i <= s; i = i + 1) begin
            element[i] = 1'b1;
          end
          if (r == 0) begin
            rotated = element;
          end else begin
            rotated = (element >> r) | (element << (e - r));
          end
          mask = 64'd0;
          for (i = 0; i < 64; i = i + 1) begin
            mask[i] = rotated[i % e];
          end
          reference_mask = {1'b1, mask};
        end
      end
    end
  endfunction

  function automatic [31:0] encode_logic_imm(
      input logic       sf,
      input logic       immn,
      input logic [1:0] opc,
      input logic [5:0] immr,
      input logic [5:0] imms,
      input logic [4:0] rn,
      input logic [4:0] rd);
    begin
      encode_logic_imm = 32'd0;
      encode_logic_imm[31] = sf;
      encode_logic_imm[30:29] = opc;
      encode_logic_imm[28:23] = 6'b100100;
      encode_logic_imm[22] = immn;
      encode_logic_imm[21:16] = immr;
      encode_logic_imm[15:10] = imms;
      encode_logic_imm[9:5] = rn;
      encode_logic_imm[4:0] = rd;
    end
  endfunction

  integer sf_i;
  integer n_i;
  integer immr_i;
  integer imms_i;
  integer exhaustive_total;
  integer exhaustive_valid;
  integer exhaustive_reserved;

  // One task invocation is one complete (sf,N,immr,imms) encoding.  The
  // reference is evaluated independently, then every legal output field
  // relevant to this cone is compared.  Reserved entries must take the
  // decoder's UDEF path and are intentionally not allowed to match by mask.
  task automatic check_exhaustive_case(
      input logic       sf,
      input logic       immn,
      input logic [5:0] immr,
      input logic [5:0] imms);
    reg [64:0] reference;
    reg [63:0] expected_mask;
    begin
      insn = encode_logic_imm(sf, immn, 2'd0, immr, imms, 5'd0, 5'd6);
      #1;
      reference = reference_mask(sf, immn, immr, imms);
      exhaustive_total = exhaustive_total + 1;
      if (reference[64] === 1'b1) begin
        exhaustive_valid = exhaustive_valid + 1;
        expected_mask = reference[63:0];
        check(d.valid === 1'b1,
              $sformatf("exhaustive legal valid sf=%0d N=%0d immr=%0d imms=%0d",
                        sf, immn, immr, imms));
        check(d.exc === 1'b0,
              $sformatf("exhaustive legal exc sf=%0d N=%0d immr=%0d imms=%0d",
                        sf, immn, immr, imms));
        check(d.operand_b === expected_mask,
              $sformatf("exhaustive legal mask sf=%0d N=%0d immr=%0d imms=%0d",
                        sf, immn, immr, imms));
        check(d.is_32 === !sf,
              $sformatf("exhaustive legal width sf=%0d N=%0d immr=%0d imms=%0d",
                        sf, immn, immr, imms));
      end else begin
        exhaustive_reserved = exhaustive_reserved + 1;
        check(d.valid === 1'b0,
              $sformatf("exhaustive reserved valid sf=%0d N=%0d immr=%0d imms=%0d",
                        sf, immn, immr, imms));
        check(d.exc === 1'b1,
              $sformatf("exhaustive reserved UDEF sf=%0d N=%0d immr=%0d imms=%0d",
                        sf, immn, immr, imms));
      end
    end
  endtask

  initial begin
    pc = 64'h44000000;
    for (integer i = 0; i < 31; i = i + 1) gpr[i] = 64'd0;
    for (integer j = 0; j < 32; j = j + 1) v[j] = 128'd0;
    sp = 64'd0;
    nzcv = 4'd0;
    el = 1'b1;
    sp_sel = 1'b1;
    dit = 1'b0; ssbs = 1'b0; uao = 1'b0; pan = 1'b0; tco = 1'b0;
    allint = 1'b0;
    vbar_el1 = 64'd0; elr_el1 = 64'd0; spsr_el1 = 64'd0;
    sctlr_el1 = 64'hC50838; tcr_el1 = 64'd0;
    ttbr0_el1 = 64'd0; ttbr1_el1 = 64'd0; mair_el1 = 64'd0;
    esr_el1 = 32'd0; far_el1 = 64'd0; sp_el0 = 64'd0;
    cpacr_el1 = 64'd0; fpcr_read_data = 32'd0; fpsr_read_data = 32'd0;
    fp_access_allowed = 1'b1;
    mdscr_el1 = 64'd0; pmuserenr_el0 = 64'd0; cntkctl_el1 = 64'd0;
    tpidr_el0 = 64'd0; tpidrro_el0 = 64'd0; tpidr_el1 = 64'd0;
    tcr2_el1 = 64'd0; pir_el1 = 64'd0; pire0_el1 = 64'd0;
    par_el1 = 64'd0; daif = 4'hf; zcr_el1 = 64'd0;
    smcr_el1 = 64'd0; csselr_el1 = 64'd0; mmu_en = 1'b0;

    // Exact firmware instructions from T-021.  The first mask is 0xffff
    // (W6=A43F); the second is 0xff (W0=3F).
    insn = 32'h12003c06;
    gpr[0] = 64'h0000a43f;
    #1;
    check(d.valid == 1'b1, "exact 0x12003C06 valid");
    check(d.exc == 1'b0, "exact 0x12003C06 no exception");
    check(d.is_32 == 1'b1, "exact 0x12003C06 W form");
    check(d.operand_a == 64'h0000a43f, "exact 0x12003C06 W0 input");
    check(d.operand_b == 64'h0000ffff0000ffff,
          "exact 0x12003C06 mask");
    check({32'd0, (d.operand_a[31:0] & d.operand_b[31:0])} ==
          64'h000000000000a43f, "exact 0x12003C06 result W6=A43F");

    insn = 32'h12001c00;
    #1;
    check(d.valid == 1'b1, "exact 0x12001C00 valid");
    check(d.exc == 1'b0, "exact 0x12001C00 no exception");
    check(d.operand_a == 64'h0000a43f, "exact 0x12001C00 W0 input");
    check(d.operand_b == 64'h000000ff000000ff,
          "exact 0x12001C00 mask");
    check({32'd0, (d.operand_a[31:0] & d.operand_b[31:0])} ==
          64'h000000000000003f, "exact 0x12001C00 result W0=3F");

    // Complete architectural encoding space: sf=0/1, N=0/1, immr=0..63,
    // imms=0..63.  This is 2*2*64*64 = 16,384 independent comparisons.
    exhaustive_total = 0;
    exhaustive_valid = 0;
    exhaustive_reserved = 0;
    for (sf_i = 0; sf_i < 2; sf_i = sf_i + 1) begin
      for (n_i = 0; n_i < 2; n_i = n_i + 1) begin
        for (immr_i = 0; immr_i < 64; immr_i = immr_i + 1) begin
          for (imms_i = 0; imms_i < 64; imms_i = imms_i + 1) begin
            check_exhaustive_case(sf_i[0], n_i[0], immr_i[5:0], imms_i[5:0]);
          end
        end
      end
    end
    check(exhaustive_total == 16384, "exhaustive total count");
    check(exhaustive_valid == 11328, "exhaustive legal count");
    check(exhaustive_reserved == 5056, "exhaustive reserved count");
    $display("LOGIC_IMM_BEHAVIORAL_ORACLE_PASS exact=A43F/3F exhaustive=16384 legal=11328 reserved=5056");
    $finish;
  end
endmodule
