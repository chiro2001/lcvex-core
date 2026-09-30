// P7-5 NEON FP16/sqrt/minmax/rint directed SystemVerilog testbench。
// 参考值来自 A76/QEMU 11.1 实测；只比较 raw bits 与 FPSR sticky flags。

`timescale 1ns/1ps
/* verilator lint_off UNUSEDSIGNAL */

module lcvex_neon_fp_p7_5_tb;
  import lcvex_pkg::*;

  logic                 valid;
  neon_fp_op_t          op;
  logic                 is_double;
  logic                 is_half;
  logic                 quad;
  logic [2:0]           rint_mode;
  logic [127:0]         operand_a;
  logic [127:0]         operand_b;
  logic [127:0]         operand_c;
  logic [31:0]          fpcr;
  logic [127:0]         result;
  logic [31:0]          fpsr_flags;

  lcvex_neon_fp dut (
      .valid(valid), .op(op), .is_double(is_double), .is_half(is_half),
      .quad(quad), .rint_mode(rint_mode),
      .operand_a(operand_a), .operand_b(operand_b),
      .operand_c(operand_c), .fpcr(fpcr),
      .result(result), .fpsr_flags(fpsr_flags)
  );

  task automatic check(
      input neon_fp_op_t  t_op,
      input logic         t_half,
      input logic         t_double,
      input logic         t_quad,
      input logic [2:0]   t_rint,
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
      is_half = t_half;
      is_double = t_double;
      quad = t_quad;
      rint_mode = t_rint;
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
    is_half = 1'b0;
    is_double = 1'b0;
    quad = 1'b0;
    rint_mode = 3'd0;
    operand_a = 128'd0;
    operand_b = 128'd0;
    operand_c = 128'd0;
    fpcr = 32'd0;

    // ---- 4H FADD：lane{1,2,0.5,0.25}+{2,3,0.25,0.5} ----
    check(NEON_FP_OP_FADD, 1'b1, 1'b0, 1'b0, 3'd0,
          128'h00000000000000003400380040003c00, 128'h00000000000000003800340042004000, 128'd0, 0,
          128'h00000000000000003a003a0045004200, 0, "FADD 4H");
    // ---- 8H FMUL：lane{2,1.5,1,3,0.5,2,4,2}*{1,2,1,2,0.5,2,1,1} ----
    check(NEON_FP_OP_FMUL, 1'b1, 1'b0, 1'b1, 3'd0,
          128'h400044004000380042003c003e004000, 128'h3c003c004000380040003c0040003c00, 128'd0, 0,
          128'h400044004400340046003c0042004000, 0, "FMUL 8H");
    // ---- 4H FCMEQ：{2,2,2,2}=={2,3,1,2} -> {ffff,0,0,ffff} ----
    check(NEON_FP_OP_FCMEQ, 1'b1, 1'b0, 1'b0, 3'd0,
          128'h00000000000000004000400040004000, 128'h000000000000000040003c0042004000, 128'd0, 0,
          128'h0000000000000000ffff00000000ffff, 0, "FCMEQ 4H");

    // ---- B2a：4H FMLA/FMLS（低位到高位：lane0..lane3）----
    // lane0: 2*3+10=16; lane1: 3*2+0=6; lane2: 4*1-1=3; lane3: 5*1+2=7
    check(NEON_FP_OP_FMLA, 1'b1, 1'b0, 1'b0, 3'd0,
          128'h0000_0000_0000_0000_4500_4400_4200_4000,
          128'h0000_0000_0000_0000_3c00_3c00_4000_4200,
          128'h0000_0000_0000_0000_4000_bc00_0000_4900,
          0,
          128'h0000_0000_0000_0000_4700_4200_4600_4c00,
          0, "FMLA 4H");
    // FMLS：10-2*3=4; 0-3*2=-6; -1-4*1=-5; 2-5*1=-3
    check(NEON_FP_OP_FMLS, 1'b1, 1'b0, 1'b0, 3'd0,
          128'h0000_0000_0000_0000_4500_4400_4200_4000,
          128'h0000_0000_0000_0000_3c00_3c00_4000_4200,
          128'h0000_0000_0000_0000_4000_bc00_0000_4900,
          0,
          128'h0000_0000_0000_0000_c200_c500_c600_4400,
          0, "FMLS 4H");

    // ---- 2S FSQRT：{4.0,9.0}->{2.0,3.0} ----
    check(NEON_FP_OP_SQRT, 1'b0, 1'b0, 1'b0, 3'd0,
          128'h00000000000000004110000040800000, 128'd0, 128'd0, 0,
          128'h00000000000000004040000040000000, 0, "FSQRT 2S");
    // ---- 4S FMIN：{2,3,4,5} min {5,4,3,2} ----
    check(NEON_FP_OP_FMIN, 1'b0, 1'b0, 1'b1, 3'd0,
          128'h40a00000408000004040000040000000, 128'h40000000404000004080000040a00000, 128'd0, 0,
          128'h40000000404000004040000040000000, 0, "FMIN 4S");
    // ---- 2D FRINTZ：{1.5,2.5}->{1.0,2.0}（向零）----
    check(NEON_FP_OP_FRINT, 1'b0, 1'b1, 1'b1, 3'd3,
          128'h40040000000000003ff8000000000000, 128'd0, 128'd0, 0,
          128'h40000000000000003ff0000000000000, 0, "FRINTZ 2D");

    $display("PASS: P7-5 NEON FP16/sqrt/minmax/frint raw-bit vectors");
    $finish;
  end
endmodule
