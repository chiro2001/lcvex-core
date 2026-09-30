// P7-4 FP scalar FMA/conversion directed SystemVerilog testbench。
// 参考值全部来自 A76/QEMU 11.1 实测 raw bits；只比较 raw bits 和 FPSR
// sticky flags，不转换为 host float、不使用 epsilon。

`timescale 1ns/1ps
/* verilator lint_off UNUSEDSIGNAL */

module lcvex_fp_scalar_p7_4_tb;
  import lcvex_pkg::*;

  logic        valid;
  fp_op_t      op;
  logic        is_double;
  logic [63:0] operand_a;
  logic [63:0] operand_b;
  logic [63:0] operand_c;
  logic [63:0] conv_int;
  logic [6:0]  conv_shift;
  logic        conv_is_32;
  logic [31:0] fpcr;
  logic        compare_zero;
  logic        signal_all_nans;
  logic        clk;
  logic        rst_n;
  logic        div_busy;
  logic        div_done;
  logic [63:0] result;
  logic [63:0] int_result;
  logic [31:0] fpsr_flags;
  logic [3:0]  cmp_nzcv;

  lcvex_fp_scalar dut (
      .clk(clk), .rst_n(rst_n),
      .valid(valid), .op(op), .is_double(is_double),
      .is_half(1'b0), .fcvt_dst_half(1'b0), .rint_mode(3'd0),
      .operand_a(operand_a), .operand_b(operand_b),
      .operand_c(operand_c), .conv_int(conv_int),
      .conv_shift(conv_shift), .conv_is_32(conv_is_32), .fpcr(fpcr),
      .compare_zero(compare_zero), .signal_all_nans(signal_all_nans),
      .iter_kill(1'b0), .iter_pause(1'b0),
      .result(result), .int_result(int_result),
      .fpsr_flags(fpsr_flags), .cmp_nzcv(cmp_nzcv),
      .div_busy(div_busy), .div_done(div_done)
  );

  task automatic check_fma(
      input fp_op_t      op_i,
      input logic        dbl_i,
      input logic [63:0] a_i,
      input logic [63:0] b_i,
      input logic [63:0] c_i,
      input logic [31:0] fpcr_i,
      input logic [63:0] want_bits,
      input logic [31:0] want_flags,
      input string       name);
    begin
      valid = 1'b1;
      op = op_i;
      is_double = dbl_i;
      operand_a = a_i;
      operand_b = b_i;
      operand_c = c_i;
      conv_int = 64'd0;
      conv_shift = 7'd0;
      conv_is_32 = 1'b0;
      fpcr = fpcr_i;
      compare_zero = 1'b0;
      signal_all_nans = 1'b0;
      #1;
      if (result !== want_bits || fpsr_flags !== want_flags ||
          int_result !== 64'd0) begin
        $fatal(1, "%s raw mismatch: got bits=%016h flags=%08h int=%016h want bits=%016h flags=%08h",
               name, result, fpsr_flags, int_result, want_bits, want_flags);
      end
      $display("PASS %s bits=%016h flags=%08h", name, result, fpsr_flags);
    end
  endtask

  task automatic check_conv(
      input fp_op_t      op_i,
      input logic        dbl_i,
      input logic [63:0] a_i,
      input logic [63:0] int_i,
      input logic [6:0]  shift_i,
      input logic        is32_i,
      input logic [31:0] fpcr_i,
      input logic [63:0] want_bits,
      input logic [63:0] want_int,
      input logic [31:0] want_flags,
      input string       name);
    begin
      valid = 1'b1;
      op = op_i;
      is_double = dbl_i;
      operand_a = a_i;
      operand_b = 64'd0;
      operand_c = 64'd0;
      conv_int = int_i;
      conv_shift = shift_i;
      conv_is_32 = is32_i;
      fpcr = fpcr_i;
      compare_zero = 1'b0;
      signal_all_nans = 1'b0;
      #1;
      if (result !== want_bits || int_result !== want_int ||
          fpsr_flags !== want_flags) begin
        $fatal(1, "%s raw mismatch: got bits=%016h int=%016h flags=%08h want bits=%016h int=%016h flags=%08h",
               name, result, int_result, fpsr_flags,
               want_bits, want_int, want_flags);
      end
      $display("PASS %s bits=%016h int=%016h flags=%08h",
               name, result, int_result, fpsr_flags);
    end
  endtask

  initial begin
    clk = 1'b0;
    rst_n = 1'b0;
    #5 rst_n = 1'b1;
    forever #5 clk = ~clk;
  end

  initial begin
    valid = 1'b0;
    op = FP_OP_NONE;
    is_double = 1'b0;
    operand_a = 64'd0;
    operand_b = 64'd0;
    operand_c = 64'd0;
    conv_int = 64'd0;
    conv_shift = 7'd0;
    conv_is_32 = 1'b0;
    fpcr = 32'd0;
    compare_zero = 1'b0;
    signal_all_nans = 1'b0;

    // ---- FMA 四族基本语义（QEMU 实测：2*3+10 等）----
    check_fma(FP_OP_FMADD, 1'b0, 64'h4000_0000, 64'h4040_0000,
              64'h4120_0000, 0, 64'h0000_0000_4180_0000, 0,
              "FMADD.S 2*3+10");
    check_fma(FP_OP_FMSUB, 1'b0, 64'h4000_0000, 64'h4040_0000,
              64'h4120_0000, 0, 64'h0000_0000_4080_0000, 0,
              "FMSUB.S 10-2*3");
    check_fma(FP_OP_FNMADD, 1'b0, 64'h4000_0000, 64'h4040_0000,
              64'h4120_0000, 0, 64'h0000_0000_c180_0000, 0,
              "FNMADD.S -(2*3+10)");
    check_fma(FP_OP_FNMSUB, 1'b0, 64'h4000_0000, 64'h4040_0000,
              64'h4120_0000, 0, 64'h0000_0000_c080_0000, 0,
              "FNMSUB.S 2*3-10");
    check_fma(FP_OP_FMADD, 1'b1, 64'h4000_0000_0000_0000,
              64'h4008_0000_0000_0000, 64'h4024_0000_0000_0000, 0,
              64'h4030_0000_0000_0000, 0, "FMADD.D 2*3+10");
    check_fma(FP_OP_FMSUB, 1'b1, 64'h4000_0000_0000_0000,
              64'h4008_0000_0000_0000, 64'h4024_0000_0000_0000, 0,
              64'h4010_0000_0000_0000, 0, "FMSUB.D 10-2*3");
    check_fma(FP_OP_FNMADD, 1'b1, 64'h4000_0000_0000_0000,
              64'h4008_0000_0000_0000, 64'h4024_0000_0000_0000, 0,
              64'hc030_0000_0000_0000, 0, "FNMADD.D -(2*3+10)");
    check_fma(FP_OP_FNMSUB, 1'b1, 64'h4000_0000_0000_0000,
              64'h4008_0000_0000_0000, 64'h4024_0000_0000_0000, 0,
              64'hc010_0000_0000_0000, 0, "FNMSUB.D 2*3-10");

    // fused：一次舍入（D 的 a=1+2^-52，b=1，c=-1 -> 精确 2^-52）。
    check_fma(FP_OP_FMADD, 1'b1, 64'h3ff0_0000_0000_0001,
              64'h3ff0_0000_0000_0000, 64'hbff0_0000_0000_0000, 0,
              64'h3cb0_0000_0000_0000, 0, "FMADD.D fused exact");
    // 不精确：S a=1+2^-23, b=1, c=-1 -> 2^-23 精确无 flags；FN* 的
    // 相反数组合产生 IXC。
    check_fma(FP_OP_FMADD, 1'b0, 64'h3f80_0001, 64'h3f80_0000,
              64'hbf80_0000, 0, 64'h0000_0000_3400_0000, 0,
              "FMADD.S 1+2^-23-1");
    check_fma(FP_OP_FMSUB, 1'b0, 64'h3f80_0001, 64'h3f80_0000,
              64'hbf80_0000, 0, 64'h0000_0000_c000_0000,
              32'h0000_0010, "FMSUB.S -(2+2^-23) inexact");
    check_fma(FP_OP_FNMADD, 1'b0, 64'h3f80_0001, 64'h3f80_0000,
              64'hbf80_0000, 0, 64'h0000_0000_b400_0000, 0,
              "FNMADD.S -2^-23");
    check_fma(FP_OP_FNMSUB, 1'b0, 64'h3f80_0001, 64'h3f80_0000,
              64'hbf80_0000, 0, 64'h0000_0000_4000_0000,
              32'h0000_0010, "FNMSUB.S 2+2^-23 inexact");

    // NaN 优先级：C、A、B；SNaN 先于 QNaN；inf*0 无效。
    check_fma(FP_OP_FMADD, 1'b0, 64'h7fc1_1111, 64'h7fc2_2222,
              64'h7fc3_3333, 0, 64'h0000_0000_7fc3_3333, 0,
              "FMADD.S qNaN c,a,b");
    check_fma(FP_OP_FMADD, 1'b0, 64'h7fa1_1111, 64'h7fc2_2222,
              64'h7fc3_3333, 0, 64'h0000_0000_7fe1_1111,
              32'h0000_0001, "FMADD.S sNaN A wins");
    check_fma(FP_OP_FMADD, 1'b0, 64'h7f80_0000, 64'h0000_0000,
              64'h3f80_0000, 0, 64'h0000_0000_7fc0_0000,
              32'h0000_0001, "FMADD.S inf*0+1");
    check_fma(FP_OP_FMADD, 1'b0, 64'h7f80_0000, 64'h7f80_0000,
              64'hff80_0000, 0, 64'h0000_0000_7fc0_0000,
              32'h0000_0001, "FMADD.S inf-inf");
    check_fma(FP_OP_FMADD, 1'b0, 64'h7f80_0000, 64'hff80_0000,
              64'h3f80_0000, 0, 64'h0000_0000_ff80_0000, 0,
              "FMADD.S -inf+1");

    // 零符号：0-0 只在 round toward -Inf 为 -0。
    check_fma(FP_OP_FMADD, 1'b0, 64'h0000_0000, 64'h8000_0000,
              64'h8000_0000, 0, 64'h0000_0000_8000_0000, 0,
              "FMADD.S +0*-0-0");
    check_fma(FP_OP_FMADD, 1'b0, 64'h0000_0000, 64'h0000_0000,
              64'h8000_0000, 0, 64'h0000_0000_0000_0000, 0,
              "FMADD.S +0*+0-0 RN");
    check_fma(FP_OP_FMADD, 1'b0, 64'h0000_0000, 64'h0000_0000,
              64'h8000_0000, 32'h0080_0000, 64'h0000_0000_8000_0000, 0,
              "FMADD.S +0*+0-0 RM");

    // FZ flush 输入 subnormal -> IDC；溢出 -> Inf + OFC|IXC。
    check_fma(FP_OP_FMADD, 1'b0, 64'h0000_0001, 64'h3f80_0000,
              64'h3f80_0000, 32'h0100_0000, 64'h0000_0000_3f80_0000,
              32'h0000_0080, "FMADD.S FZ sub input");
    check_fma(FP_OP_FMADD, 1'b0, 64'h7f7f_ffff, 64'h7f7f_ffff,
              64'h3f80_0000, 0, 64'h0000_0000_7f80_0000,
              32'h0000_0014, "FMADD.S overflow");

    // ---- 整数/定点 -> FP ----
    check_conv(FP_OP_SCVTF, 1'b0, 0, 64'h0000_0000_0000_0003, 7'd1,
               1'b1, 0, 64'h0000_0000_3fc0_0000, 64'd0, 0,
               "SCVTF.S 3,#1 -> 1.5");
    check_conv(FP_OP_UCVTF, 1'b0, 0, 64'h0000_0000_ffff_ffff, 7'd32,
               1'b1, 0, 64'h0000_0000_3f80_0000, 64'd0,
               32'h0000_0010, "UCVTF.S 0xffffffff,#32 -> 1.0 IXC");
    check_conv(FP_OP_SCVTF, 1'b1, 0, 64'h8000_0000_0000_0000, 7'd0,
               1'b0, 0, 64'hc3e0_0000_0000_0000, 64'd0, 0,
               "SCVTF.D int64 min");
    check_conv(FP_OP_UCVTF, 1'b1, 0, 64'hffff_ffff_ffff_ffff, 7'd0,
               1'b0, 0, 64'h43f0_0000_0000_0000, 64'd0,
               32'h0000_0010, "UCVTF.D uint64 max -> 2^64 IXC");

    // ---- FP -> 整数/定点 ----
    check_conv(FP_OP_FCVTZS, 1'b0, 64'h4000_0000, 0, 7'd3, 1'b1, 0,
               64'd0, 64'd16, 0, "FCVTZS.S 2.0,#3");
    check_conv(FP_OP_FCVTZS, 1'b0, 64'h3f00_0000, 0, 7'd3, 1'b1, 0,
               64'd0, 64'd4, 0, "FCVTZS.S 0.5,#3");
    check_conv(FP_OP_FCVTZS, 1'b0, 64'h3fc0_0000, 0, 7'd0, 1'b1, 0,
               64'd0, 64'd1, 32'h0000_0010, "FCVTZS.S 1.5 IXC");
    check_conv(FP_OP_FCVTZS, 1'b0, 64'hcf00_0000, 0, 7'd0, 1'b1, 0,
               64'd0, 64'h0000_0000_8000_0000, 0, "FCVTZS.S -2^31");
    check_conv(FP_OP_FCVTZS, 1'b0, 64'h4f00_0000, 0, 7'd0, 1'b1, 0,
               64'd0, 64'h0000_0000_7fff_ffff, 32'h0000_0001,
               "FCVTZS.S 2^31 sat");
    check_conv(FP_OP_FCVTZU, 1'b0, 64'h4f80_0000, 0, 7'd0, 1'b1, 0,
               64'd0, 64'h0000_0000_ffff_ffff, 32'h0000_0001,
               "FCVTZU.S 2^32 sat");
    check_conv(FP_OP_FCVTZU, 1'b0, 64'hbf80_0000, 0, 7'd32, 1'b1, 0,
               64'd0, 64'd0, 32'h0000_0001, "FCVTZU.S -1.0,#32 sat");
    check_conv(FP_OP_FCVTZS, 1'b1, 64'h7ff0_0000_0000_0000, 0, 7'd63,
               1'b0, 0, 64'd0, 64'h7fff_ffff_ffff_ffff,
               32'h0000_0001, "FCVTZS.D inf,#63 sat");
    check_conv(FP_OP_FCVTZS, 1'b1, 64'h43f0_0000_0000_0000, 0, 7'd0,
               1'b0, 0, 64'd0, 64'h7fff_ffff_ffff_ffff,
               32'h0000_0001, "FCVTZS.D 2^64 sat");
    check_conv(FP_OP_FCVTZS, 1'b0, 64'h7fc0_0001, 0, 7'd0, 1'b1, 0,
               64'd0, 64'd0, 32'h0000_0001, "FCVTZS.S NaN -> 0 IOC");
    check_conv(FP_OP_FCVTZS, 1'b0, 64'h0000_0001, 0, 7'd0, 1'b1,
               32'h0100_0000, 64'd0, 64'd0, 32'h0000_0080,
               "FCVTZS.S FZ sub -> 0 IDC");

    // ---- FCVT S<->D ----
    check_conv(FP_OP_FCVT, 1'b1, 64'h0000_0001, 0, 7'd0, 1'b0, 0,
               64'h36a0_0000_0000_0000, 64'd0, 0, "FCVT.D min S sub");
    check_conv(FP_OP_FCVT, 1'b0, 64'h0000_0000_0000_0001, 0, 7'd0,
               1'b0, 0, 64'h0000_0000_0000_0000, 64'd0,
               32'h0000_0018, "FCVT.S min D sub UFC|IXC");
    check_conv(FP_OP_FCVT, 1'b0, 64'h0000_0000_0000_0001, 0, 7'd0,
               1'b0, 32'h0100_0000, 64'h0000_0000_0000_0000, 64'd0,
               32'h0000_0080, "FCVT.S FZ min D sub IDC");
    check_conv(FP_OP_FCVT, 1'b0, 64'h7ff8_1234_5678_9abc, 0, 7'd0,
               1'b0, 0, 64'h0000_0000_7fc0_91a2, 64'd0, 0,
               "FCVT.S D qNaN payload");
    check_conv(FP_OP_FCVT, 1'b1, 64'h7f81_2345, 0, 7'd0, 1'b0, 0,
               64'h7ff8_2468_a000_0000, 64'd0, 32'h0000_0001,
               "FCVT.D S sNaN quiet IOC");
    check_conv(FP_OP_FCVT, 1'b0, 64'h7ff0_1234_5678_9abc, 0, 7'd0,
               1'b0, 0, 64'h0000_0000_7fc0_91a2, 64'd0,
               32'h0000_0001, "FCVT.S D sNaN quiet IOC");
    check_conv(FP_OP_FCVT, 1'b0, 64'h7ff8_1234_5678_9abc, 0, 7'd0,
               1'b0, 32'h0200_0000, 64'h0000_0000_7fc0_0000, 64'd0, 0,
               "FCVT.S DN");

    $display("PASS: P7-4 FP scalar FMA/conversion raw-bit vectors");
    $finish;
  end
endmodule
