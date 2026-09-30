// P7-4 NEON FMA/conversion raw-bit directed SystemVerilog testbench。
// 参考值来自 A76/QEMU 11.1 实测；只比较 raw bits 与 FPSR sticky flags。

`timescale 1ns/1ps
/* verilator lint_off UNUSEDSIGNAL */

module lcvex_neon_fp_p7_4_tb;
  import lcvex_pkg::*;

  logic                 valid;
  neon_fp_op_t          op;
  logic                 is_double;
  logic                 quad;
  logic [127:0]         operand_a;
  logic [127:0]         operand_b;
  logic [127:0]         operand_c;
  logic [31:0]          fpcr;
  logic [127:0]         result;
  logic [31:0]          fpsr_flags;

  lcvex_neon_fp dut (
      .valid(valid), .op(op), .is_double(is_double), .is_half(1'b0),
      .quad(quad), .rint_mode(3'd0),
      .operand_a(operand_a), .operand_b(operand_b),
      .operand_c(operand_c), .fpcr(fpcr),
      .result(result), .fpsr_flags(fpsr_flags)
  );

  task automatic check(
      input neon_fp_op_t  t_op,
      input logic         t_double,
      input logic         t_quad,
      input logic [127:0] t_a,
      input logic [127:0] t_b,
      input logic [127:0] t_c,
      input logic [31:0]  t_fpcr,
      input logic [127:0] t_want,
      input logic [31:0]  t_flags,
      input string        name);
    begin
      valid = 1'b1;
      op = t_op;
      is_double = t_double;
      quad = t_quad;
      operand_a = t_a;
      operand_b = t_b;
      operand_c = t_c;
      fpcr = t_fpcr;
      #1;
      if (result !== t_want || fpsr_flags !== t_flags) begin
        $display("FAIL %s result=%032x want=%032x flags=%08x want=%08x",
                 name, result, t_want, fpsr_flags, t_flags);
        $fatal(1);
      end
      $display("PASS %s result=%032x flags=%08x", name, result, fpsr_flags);
    end
  endtask

  initial begin
    valid = 1'b0;
    op = NEON_FP_OP_NONE;
    is_double = 1'b0;
    quad = 1'b0;
    operand_a = 128'd0;
    operand_b = 128'd0;
    operand_c = 128'd0;
    fpcr = 32'd0;

    // ---- FMLA/FMLS ----
    // 2S：lane={2,2}*{4,4}+{10,10} = 18=0x41900000。
    check(NEON_FP_OP_FMLA, 1'b0, 1'b0,
          128'h4000_0000_4000_0000, 128'h4080_0000_4080_0000,
          128'h4120_0000_4120_0000, 0,
          128'h0000_0000_0000_0000_4190_0000_4190_0000, 0,
          "FMLA 2S");
    // 2S FMLS：20-3*5=5=0x40a00000。
    check(NEON_FP_OP_FMLS, 1'b0, 1'b0,
          128'h4040_0000_4040_0000, 128'h40a0_0000_40a0_0000,
          128'h41a0_0000_41a0_0000, 0,
          128'h0000_0000_0000_0000_40a0_0000_40a0_0000, 0,
          "FMLS 2S");
    // 4S：{2,2,2,2}*{4,4,4,4}+{10,10,10,10}。
    check(NEON_FP_OP_FMLA, 1'b0, 1'b1,
          128'h4000_0000_4000_0000_4000_0000_4000_0000,
          128'h4080_0000_4080_0000_4080_0000_4080_0000,
          128'h4120_0000_4120_0000_4120_0000_4120_0000, 0,
          128'h4190_0000_4190_0000_4190_0000_4190_0000, 0,
          "FMLA 4S");
    // 2D：2*4+10=18=0x4032000000000000。
    check(NEON_FP_OP_FMLA, 1'b1, 1'b1,
          128'h4000_0000_0000_0000_4000_0000_0000_0000,
          128'h4010_0000_0000_0000_4010_0000_0000_0000,
          128'h4024_0000_0000_0000_4024_0000_0000_0000, 0,
          128'h4032_0000_0000_0000_4032_0000_0000_0000, 0,
          "FMLA 2D");
    // 2D FMLS：10-2*3=4=0x4010000000000000。
    check(NEON_FP_OP_FMLS, 1'b1, 1'b1,
          128'h4000_0000_0000_0000_4000_0000_0000_0000,
          128'h4008_0000_0000_0000_4008_0000_0000_0000,
          128'h4024_0000_0000_0000_4024_0000_0000_0000, 0,
          128'h4010_0000_0000_0000_4010_0000_0000_0000, 0,
          "FMLS 2D");
    // 2S SNaN lane：lane0 = dest 0 + snan*1 -> quiet 0x7fe11111；
    // lane1 = dest qnan + 0*1 -> 保留 qnan 0x7fc33333。
    check(NEON_FP_OP_FMLA, 1'b0, 1'b0,
          128'h0000_0000_0000_0000_0000_0000_7fa1_1111,
          128'h3f80_0000_3f80_0000,
          128'h0000_0000_0000_0000_7fc3_3333_0000_0000, 0,
          128'h0000_0000_0000_0000_7fc3_3333_7fe1_1111,
          32'h0000_0001, "FMLA 2S snan lane");
    // 2S FMLS：v1 qNaN 被取负（FMLS 语义），lane0 = 0 + (-qnan)*1 ->
    // 0xffc11111；lane1 = dest qnan + 0 -> 0x7fc33333。
    check(NEON_FP_OP_FMLS, 1'b0, 1'b0,
          128'h0000_0000_0000_0000_0000_0000_7fc1_1111,
          128'h3f80_0000_3f80_0000,
          128'h0000_0000_0000_0000_7fc3_3333_0000_0000, 0,
          128'h0000_0000_0000_0000_7fc3_3333_ffc1_1111, 0,
          "FMLS 2S negated qnan");

    // ---- 向量整数转换 ----
    // SCVTF 2S {1,-2} -> {0x3f800000, 0xc0000000}。
    check(NEON_FP_OP_SCVTF, 1'b0, 1'b0,
          128'hffff_fffe_0000_0001, 0, 0, 0,
          128'h0000_0000_0000_0000_c000_0000_3f80_0000, 0,
          "SCVTF 2S");
    // UCVTF 2S {0xffffffff,3} -> {0x4f800000, 0x40400000} IXC。
    check(NEON_FP_OP_UCVTF, 1'b0, 1'b0,
          128'h0000_0003_ffff_ffff, 0, 0, 0,
          128'h0000_0000_0000_0000_4040_0000_4f80_0000,
          32'h0000_0010, "UCVTF 2S IXC");
    // SCVTF 4S {1,-2,3,-4}。
    check(NEON_FP_OP_SCVTF, 1'b0, 1'b1,
          128'hffff_fffc_0000_0003_ffff_fffe_0000_0001, 0, 0, 0,
          128'hc080_0000_4040_0000_c000_0000_3f80_0000, 0,
          "SCVTF 4S");
    // SCVTF 2D {int64 max, 1} -> {2^63=0x43e0..., 1.0} IXC。
    check(NEON_FP_OP_SCVTF, 1'b1, 1'b1,
          128'h0000_0000_0000_0001_7fff_ffff_ffff_ffff, 0, 0, 0,
          128'h3ff0_0000_0000_0000_43e0_0000_0000_0000,
          32'h0000_0010, "SCVTF 2D IXC");
    // FCVTZS 2S {2.5,-2.5} -> {2, -2} IXC。
    check(NEON_FP_OP_FCVTZS, 1'b0, 1'b0,
          128'hc020_0000_4020_0000, 0, 0, 0,
          128'h0000_0000_0000_0000_ffff_fffe_0000_0002,
          32'h0000_0010, "FCVTZS 2S IXC");
    // FCVTZU 2S {-1, 2^31} -> {0, 0x80000000} IOC。
    check(NEON_FP_OP_FCVTZU, 1'b0, 1'b0,
          128'h4f00_0000_bf80_0000, 0, 0, 0,
          128'h0000_0000_0000_0000_8000_0000_0000_0000,
          32'h0000_0001, "FCVTZU 2S IOC");
    // FCVTZS 2D {2^63, -1.5} -> {INT64_MAX, -1} IOC|IXC。
    check(NEON_FP_OP_FCVTZS, 1'b1, 1'b1,
          128'hbff8_0000_0000_0000_43e0_0000_0000_0000, 0, 0, 0,
          128'hffff_ffff_ffff_ffff_7fff_ffff_ffff_ffff,
          32'h0000_0011, "FCVTZS 2D IOC|IXC");
    // FCVTZU 2D {-1, 2^64} -> {0, UINT64_MAX} IOC。
    check(NEON_FP_OP_FCVTZU, 1'b1, 1'b1,
          128'h43f0_0000_0000_0000_bff0_0000_0000_0000, 0, 0, 0,
          128'hffff_ffff_ffff_ffff_0000_0000_0000_0000,
          32'h0000_0001, "FCVTZU 2D IOC");

    $display("PASS: P7-4 NEON FMA/conversion raw-bit vectors");
    $finish;
  end
endmodule
