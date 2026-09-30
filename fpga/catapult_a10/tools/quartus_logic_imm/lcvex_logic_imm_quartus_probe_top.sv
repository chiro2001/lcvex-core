// T-20260920-023 minimal Quartus-visible cone.
//
// The two instruction inputs are deliberately top-level ports so synthesis
// cannot constant-fold the exact firmware cases away.  The wrapper exposes
// the decoder mask and the architectural AND result; a post-map simulation,
// when the installed Quartus/EDA simulator supports one, can therefore drive
// the same A43F vectors as the behavioral oracle.

`timescale 1ns/1ps

module lcvex_logic_imm_quartus_probe_top (
    input  wire [31:0] probe_insn0,
    input  wire [31:0] probe_insn1,
    input  wire [63:0] probe_gpr0,
    output wire        probe_valid0,
    output wire        probe_valid1,
    output wire        probe_exc0,
    output wire        probe_exc1,
    output wire [63:0] probe_mask0,
    output wire [63:0] probe_mask1,
    output wire [63:0] probe_result0,
    output wire [63:0] probe_result1,
    output wire [4:0]  probe_wb_rd0,
    output wire [4:0]  probe_wb_rd1
);
  import lcvex_pkg::*;

  wire [63:0] zero64 = 64'd0;
  wire [31:0] zero32 = 32'd0;
  wire [3:0]  zero4 = 4'd0;
  wire        one = 1'b1;
  wire        zero = 1'b0;

  logic [63:0] gpr0 [0:30];
  logic [63:0] gpr1 [0:30];
  logic [127:0] v0 [0:31];
  logic [127:0] v1 [0:31];
  genvar g;
  generate
    for (g = 0; g < 31; g = g + 1) begin : gen_gpr
      if (g == 0) begin : gen_gpr0
        assign gpr0[g] = probe_gpr0;
        assign gpr1[g] = probe_gpr0;
      end else begin : gen_gprz
        assign gpr0[g] = zero64;
        assign gpr1[g] = zero64;
      end
    end
    for (g = 0; g < 32; g = g + 1) begin : gen_v
      assign v0[g] = 128'd0;
      assign v1[g] = 128'd0;
    end
  endgenerate

  decoded_insn_t d0;
  decoded_insn_t d1;

  lcvex_decode decode0 (
    .insn(probe_insn0), .pc(64'h44000000), .gpr(gpr0), .v(v0),
    .sp(zero64), .nzcv(zero4), .el(one), .sp_sel(one), .dit(zero),
    .ssbs(zero), .uao(zero), .pan(zero), .tco(zero), .allint(zero),
    .vbar_el1(zero64), .elr_el1(zero64), .spsr_el1(zero64),
    .sctlr_el1(64'h0000000000c50838), .tcr_el1(zero64),
    .ttbr0_el1(zero64), .ttbr1_el1(zero64), .mair_el1(zero64),
    .esr_el1(zero32), .far_el1(zero64), .sp_el0(zero64),
    .cpacr_el1(zero64), .fpcr_read_data(zero32),
    .fpsr_read_data(zero32), .fp_access_allowed(one),
    .mdscr_el1(zero64), .pmuserenr_el0(zero64), .cntkctl_el1(zero64),
    .tpidr_el0(zero64), .tpidrro_el0(zero64), .tpidr_el1(zero64),
    .contextidr_el1(zero64), .tcr2_el1(zero64), .pir_el1(zero64),
    .pire0_el1(zero64), .par_el1(zero64), .daif(zero4),
    .zcr_el1(zero64), .smcr_el1(zero64), .csselr_el1(zero64),
    .mmu_en(zero), .d(d0)
  );

  lcvex_decode decode1 (
    .insn(probe_insn1), .pc(64'h44000000), .gpr(gpr1), .v(v1),
    .sp(zero64), .nzcv(zero4), .el(one), .sp_sel(one), .dit(zero),
    .ssbs(zero), .uao(zero), .pan(zero), .tco(zero), .allint(zero),
    .vbar_el1(zero64), .elr_el1(zero64), .spsr_el1(zero64),
    .sctlr_el1(64'h0000000000c50838), .tcr_el1(zero64),
    .ttbr0_el1(zero64), .ttbr1_el1(zero64), .mair_el1(zero64),
    .esr_el1(zero32), .far_el1(zero64), .sp_el0(zero64),
    .cpacr_el1(zero64), .fpcr_read_data(zero32),
    .fpsr_read_data(zero32), .fp_access_allowed(one),
    .mdscr_el1(zero64), .pmuserenr_el0(zero64), .cntkctl_el1(zero64),
    .tpidr_el0(zero64), .tpidrro_el0(zero64), .tpidr_el1(zero64),
    .contextidr_el1(zero64), .tcr2_el1(zero64), .pir_el1(zero64),
    .pire0_el1(zero64), .par_el1(zero64), .daif(zero4),
    .zcr_el1(zero64), .smcr_el1(zero64), .csselr_el1(zero64),
    .mmu_en(zero), .d(d1)
  );

  assign probe_valid0 = d0.valid;
  assign probe_valid1 = d1.valid;
  assign probe_exc0 = d0.exc;
  assign probe_exc1 = d1.exc;
  assign probe_mask0 = d0.operand_b;
  assign probe_mask1 = d1.operand_b;
  assign probe_wb_rd0 = d0.wb_rd;
  assign probe_wb_rd1 = d1.wb_rd;
  assign probe_result0 = d0.is_32 ?
      {32'd0, (d0.operand_a[31:0] & d0.operand_b[31:0])} :
      (d0.operand_a & d0.operand_b);
  assign probe_result1 = d1.is_32 ?
      {32'd0, (d1.operand_a[31:0] & d1.operand_b[31:0])} :
      (d1.operand_a & d1.operand_b);
endmodule
