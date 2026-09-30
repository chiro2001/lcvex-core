// P7-3 vector FP raw-bit unit testbench。
// 只比较固定宽度 IEEE raw bits 和 FPSR sticky flags，不转换为 host float。

`timescale 1ns/1ps

module lcvex_neon_fp_tb;
  import lcvex_pkg::*;

  logic                 valid;
  neon_fp_op_t          op;
  logic                 is_double;
  logic                 quad;
  logic [127:0]         operand_a;
  logic [127:0]         operand_b;
  logic [31:0]          fpcr;
  logic [127:0]         result;
  logic [31:0]          fpsr_flags;

  lcvex_neon_fp dut (
      .valid(valid), .op(op), .is_double(is_double), .is_half(1'b0),
      .quad(quad), .rint_mode(3'd0),
      .operand_a(operand_a), .operand_b(operand_b), .operand_c(128'd0),
      .fpcr(fpcr),
      .result(result), .fpsr_flags(fpsr_flags)
  );

  task automatic check(
      input neon_fp_op_t  t_op,
      input logic         t_double,
      input logic         t_quad,
      input logic [127:0] t_a,
      input logic [127:0] t_b,
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
    fpcr = 32'd0;
    #1;

    // 2S: low D view is written and Vd[127:64] is architecturally zero.
    check(NEON_FP_OP_FADD, 1'b0, 1'b0,
          128'hffff_ffff_ffff_ffff_4080_0000_3f80_0000,
          128'h1234_5678_9abc_def0_4040_0000_4000_0000,
          32'd0,
          128'h0000_0000_0000_0000_40e0_0000_4040_0000,
          32'd0, "FADD.2S");

    // 4S subtraction across all lanes.
    check(NEON_FP_OP_FSUB, 1'b0, 1'b1,
          128'h4120_0000_4100_0000_40c0_0000_4080_0000,
          128'h4080_0000_4040_0000_4000_0000_3f80_0000,
          32'd0,
          128'h40c0_0000_40a0_0000_4080_0000_4040_0000,
          32'd0, "FSUB.4S");

    // 2D multiplication: 1.5*2.0=3.0 and -2.0*4.0=-8.0.
    check(NEON_FP_OP_FMUL, 1'b1, 1'b1,
          128'hc000_0000_0000_0000_3ff8_0000_0000_0000,
          128'h4010_0000_0000_0000_4000_0000_0000_0000,
          32'd0,
          128'hc020_0000_0000_0000_4008_0000_0000_0000,
          32'd0, "FMUL.2D");

    // FCMEQ is quiet for qNaN, unordered for sNaN (IOC sticky), and treats
    // +0/-0 as equal. Lane mask is all ones for equal.
    check(NEON_FP_OP_FCMEQ, 1'b0, 1'b1,
          128'h7fa0_1234_7fc0_1234_8000_0000_3f80_0000,
          128'h3f80_0000_7fc0_1234_0000_0000_3f80_0000,
          32'd0,
          128'h0000_0000_0000_0000_ffff_ffff_ffff_ffff,
          32'h0000_0001, "FCMEQ.4S NaN/zero");

    // DN applies to arithmetic NaN propagation; FZ consumes subnormal inputs
    // and reports IDC; RMode=+Inf rounds 1+2^-24 upward and sets IXC.
    check(NEON_FP_OP_FADD, 1'b0, 1'b0,
          128'h0000_0000_0000_0000_7fc0_0000_7fc0_0000,
          128'h0000_0000_0000_0000_3f80_0000_3f80_0000,
          32'h0200_0000,
          128'h0000_0000_0000_0000_7fc0_0000_7fc0_0000,
          32'd0, "FADD.2S DN");
    check(NEON_FP_OP_FADD, 1'b0, 1'b0,
          128'h0000_0000_0000_0000_0000_0001_0000_0001,
          128'h0000_0000_0000_0000_0000_0000_0000_0000,
          32'h0100_0000,
          128'h0000_0000_0000_0000_0000_0000_0000_0000,
          32'h0000_0080, "FADD.2S FZ");
    check(NEON_FP_OP_FADD, 1'b0, 1'b0,
          128'h0000_0000_0000_0000_3f80_0000_3f80_0000,
          128'h0000_0000_0000_0000_3380_0000_3380_0000,
          32'h0040_0000,
          128'h0000_0000_0000_0000_3f80_0001_3f80_0001,
          32'h0000_0010, "FADD.2S RMode+Inf");

    $display("PASS: P7-3 NEON FP raw unit");
    $finish;
  end
endmodule
