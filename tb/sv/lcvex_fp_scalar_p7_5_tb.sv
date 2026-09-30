// P7-5 FP scalar FP16/sqrt/minmax/frint/FCVT directed SystemVerilog testbench.
// 期望值来自 QEMU A76 实测 raw bits 与 IEEE-754 half 精确语义；只比较 raw
// bits 和 FPSR sticky flags，不使用 host float 舍入作为 oracle。

`timescale 1ns/1ps
/* verilator lint_off UNUSEDSIGNAL */

module lcvex_fp_scalar_p7_5_tb;
  import lcvex_pkg::*;

  logic        valid;
  fp_op_t      op;
  logic        is_double;
  logic        is_half;
  logic        fcvt_dst_half;
  logic [2:0]  rint_mode;
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
      .is_half(is_half), .fcvt_dst_half(fcvt_dst_half),
      .rint_mode(rint_mode),
      .operand_a(operand_a), .operand_b(operand_b),
      .operand_c(operand_c), .conv_int(conv_int),
      .conv_shift(conv_shift), .conv_is_32(conv_is_32), .fpcr(fpcr),
      .compare_zero(compare_zero), .signal_all_nans(signal_all_nans),
      .iter_kill(1'b0), .iter_pause(1'b0),
      .result(result), .int_result(int_result),
      .fpsr_flags(fpsr_flags), .cmp_nzcv(cmp_nzcv),
      .div_busy(div_busy), .div_done(div_done)
  );

  task automatic check(
      input fp_op_t      op_i,
      input logic        half_i,
      input logic        dbl_i,
      input logic        dst_half_i,
      input logic [2:0]  rint_i,
      input logic [63:0] a_i,
      input logic [63:0] b_i,
      input logic [31:0] fpcr_i,
      input logic [63:0] want_bits,
      input logic [31:0] want_flags,
      input string       name);
    begin
      valid = 1'b1;
      op = op_i;
      is_half = half_i;
      is_double = dbl_i;
      fcvt_dst_half = dst_half_i;
      rint_mode = rint_i;
      operand_a = a_i;
      operand_b = b_i;
      operand_c = 64'd0;
      conv_int = 64'd0;
      conv_shift = 7'd0;
      conv_is_32 = 1'b0;
      fpcr = fpcr_i;
      compare_zero = 1'b0;
      signal_all_nans = 1'b0;
      #1;
      if (op_i == FP_OP_DIV) begin
        while (div_busy || div_done) #1;
        #1;
        while (!div_done) #1;
        #1;
      end
      if (result !== want_bits || fpsr_flags !== want_flags) begin
        $fatal(1, "%s raw mismatch: got bits=%016h flags=%08h want bits=%016h flags=%08h",
               name, result, fpsr_flags, want_bits, want_flags);
      end
      $display("PASS %s bits=%016h flags=%08h", name, result, fpsr_flags);
    end
  endtask

  // B2a：标量 FP16 FMA 四族（低 16 位是架构 H 寄存器，高 16 位仅作向量
  // 32-bit 槽配套；这里直接检查低 lane raw 结果）。
  task automatic check_fma_h(
      input fp_op_t      op_i,
      input logic [15:0] a_i,
      input logic [15:0] b_i,
      input logic [15:0] c_i,
      input logic [31:0] fpcr_i,
      input logic [63:0] want_bits,
      input logic [31:0] want_flags,
      input string       name);
    begin
      valid = 1'b1;
      op = op_i;
      is_half = 1'b1;
      is_double = 1'b0;
      fcvt_dst_half = 1'b0;
      rint_mode = 3'd0;
      operand_a = {48'd0, a_i};
      operand_b = {48'd0, b_i};
      operand_c = {48'd0, c_i};
      conv_int = 64'd0;
      conv_shift = 7'd0;
      conv_is_32 = 1'b0;
      fpcr = fpcr_i;
      compare_zero = 1'b0;
      signal_all_nans = 1'b0;
      #1;
      // 标量 H 的架构写回只取低 16 位；高 16 位是 32-bit 槽中的非架构
      // lane（FMA 精确零点符号可能产生 -0），此处只认可低 lane。
      if (result[15:0] !== want_bits[15:0] || fpsr_flags !== want_flags) begin
        $fatal(1, "%s raw mismatch: got bits=%016h flags=%08h want bits=%016h flags=%08h",
               name, result, fpsr_flags, want_bits, want_flags);
      end
      $display("PASS %s bits=%016h flags=%08h", name, result, fpsr_flags);
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
    is_half = 1'b0;
    is_double = 1'b0;
    fcvt_dst_half = 1'b0;
    rint_mode = 3'd0;
    operand_a = 64'd0;
    operand_b = 64'd0;
    operand_c = 64'd0;
    conv_int = 64'd0;
    conv_shift = 7'd0;
    conv_is_32 = 1'b0;
    fpcr = 32'd0;
    compare_zero = 1'b0;
    signal_all_nans = 1'b0;

    // ---- FP16 算术（双 16-bit lane，打包在 result[31:0]）----
    // 低 lane = FADD 1.0h + 2.0h = 3.0h；高 lane = 1.0h + 0.25h = 1.25h
    check(FP_OP_ADD, 1'b1, 1'b0, 1'b0, 3'd0,
          64'h3c00_3c00, 64'h3400_4000, 32'd0,
          64'h0000_0000_3d00_4200, 32'd0, "FADD.H 1+2 / 1+0.25");
    // FMUL.H 1.5*2.0=3.0（高 lane 2.0*2.0=4.0）
    check(FP_OP_MUL, 1'b1, 1'b0, 1'b0, 3'd0,
          64'h4000_3e00, 64'h4000_4000, 32'd0,
          64'h0000_0000_4400_4200, 32'd0, "FMUL.H 1.5*2 / 2*2");
    // FSUB.H 3.0-1.0=2.0（高 lane 1.0-0.5=0.5=0x3800）
    check(FP_OP_SUB, 1'b1, 1'b0, 1'b0, 3'd0,
          64'h3c00_4200, 64'h3800_3c00, 32'd0,
          64'h0000_0000_3800_4000, 32'd0, "FSUB.H 3-1 / 1-0.5");
    // FDIV.H 3.0/2.0=1.5（高 lane 2.0/2.0=1.0）
    check(FP_OP_DIV, 1'b1, 1'b0, 1'b0, 3'd0,
          64'h4000_4200, 64'h4000_4000, 32'd0,
          64'h0000_0000_3c00_3e00, 32'd0, "FDIV.H 3/2 / 2/2");

    // ---- B2a：FP16 标量 fused multiply-add 四族 ----
    check_fma_h(FP_OP_FMADD, 16'h4000, 16'h4200, 16'h4900, 0,
                64'h0000_0000_0000_4c00, 32'd0, "FMADD.H 2*3+10=16");
    check_fma_h(FP_OP_FMSUB, 16'h4000, 16'h4200, 16'h4900, 0,
                64'h0000_0000_0000_4400, 32'd0, "FMSUB.H 10-2*3=4");
    check_fma_h(FP_OP_FNMADD, 16'h4000, 16'h4200, 16'h4900, 0,
                64'h0000_0000_0000_cc00, 32'd0, "FNMADD.H -(2*3+10)=-16");
    check_fma_h(FP_OP_FNMSUB, 16'h4000, 16'h4200, 16'h4900, 0,
                64'h0000_0000_0000_c400, 32'd0, "FNMSUB.H 2*3-10=-4");
    // SNaN A -> quiet + IOC；四种变体的符号位按 QEMU do_fmadd 负号规则。
    check_fma_h(FP_OP_FMADD, 16'h7d01, 16'h3c00, 16'h3c00, 0,
                64'h0000_0000_0000_7f01, 32'h0000_0001, "FMADD.H SNaN A");
    check_fma_h(FP_OP_FMSUB, 16'h7d01, 16'h3c00, 16'h3c00, 0,
                64'h0000_0000_0000_ff01, 32'h0000_0001, "FMSUB.H SNaN A neg");
    check_fma_h(FP_OP_FNMADD, 16'h7d01, 16'h3c00, 16'h3c00, 0,
                64'h0000_0000_0000_ff01, 32'h0000_0001, "FNMADD.H SNaN A neg");
    check_fma_h(FP_OP_FNMSUB, 16'h7d01, 16'h3c00, 16'h3c00, 0,
                64'h0000_0000_0000_7f01, 32'h0000_0001, "FNMSUB.H SNaN A");
    // 0*Inf 无效 -> default NaN + IOC。
    check_fma_h(FP_OP_FMADD, 16'h7c00, 16'h0000, 16'h3c00, 0,
                64'h0000_0000_0000_7e00, 32'h0000_0001, "FMADD.H inf*0+1");
    // 精确 -0 保留：+0 * -0 + -0 = -0。
    check_fma_h(FP_OP_FMADD, 16'h0000, 16'h8000, 16'h8000, 0,
                64'h0000_0000_0000_8000, 32'd0, "FMADD.H signed zero");

    // ---- FP16 单操作数（低 lane 有效）----
    // FSQRT.H 4.0 -> 2.0
    check(FP_OP_SQRT, 1'b1, 1'b0, 1'b0, 3'd0,
          64'h0000_0000_0000_4400, 64'd0, 32'd0,
          64'h0000_0000_0000_4000, 32'd0, "FSQRT.H sqrt(4)=2");
    // FMIN.H min(2,3)=2
    check(FP_OP_FMIN, 1'b1, 1'b0, 1'b0, 3'd0,
          64'h0000_0000_0000_4200, 64'h0000_0000_0000_4000, 32'd0,
          64'h0000_0000_0000_4000, 32'd0, "FMIN.H min(2,3)=2");
    // FMAX.H max(2,3)=3
    check(FP_OP_FMAX, 1'b1, 1'b0, 1'b0, 3'd0,
          64'h0000_0000_0000_4200, 64'h0000_0000_0000_4000, 32'd0,
          64'h0000_0000_0000_4200, 32'd0, "FMAX.H max(2,3)=3");
    // FMINNM.H min(2,3)=2（数值优先）
    check(FP_OP_FMINNM, 1'b1, 1'b0, 1'b0, 3'd0,
          64'h0000_0000_0000_4200, 64'h0000_0000_0000_4000, 32'd0,
          64'h0000_0000_0000_4000, 32'd0, "FMINNM.H min(2,3)=2");

    // ---- FRINT*（低 lane；rint_mode: 0=N 1=P 2=M 3=Z 4=A 5=X 6=I）----
    // FRINTZ.H 1.5 -> 1.0（向零）
    check(FP_OP_FRINT, 1'b1, 1'b0, 1'b0, 3'd3,
          64'h0000_0000_0000_3e00, 64'd0, 32'd0,
          64'h0000_0000_0000_3c00, 32'd0, "FRINTZ.H 1.5->1");
    // FRINTN.H 1.5 -> 2.0（ties-to-even）
    check(FP_OP_FRINT, 1'b1, 1'b0, 1'b0, 3'd0,
          64'h0000_0000_0000_3e00, 64'd0, 32'd0,
          64'h0000_0000_0000_4000, 32'd0, "FRINTN.H 1.5->2");
    // FRINTP.H 1.5 -> 2.0（向上）
    check(FP_OP_FRINT, 1'b1, 1'b0, 1'b0, 3'd1,
          64'h0000_0000_0000_3e00, 64'd0, 32'd0,
          64'h0000_0000_0000_4000, 32'd0, "FRINTP.H 1.5->2");
    // FRINTM.H 1.5 -> 1.0（向下）
    check(FP_OP_FRINT, 1'b1, 1'b0, 1'b0, 3'd2,
          64'h0000_0000_0000_3e00, 64'd0, 32'd0,
          64'h0000_0000_0000_3c00, 32'd0, "FRINTM.H 1.5->1");
    // FRINTA.H 1.5 -> 2.0（向最近且远离零）
    check(FP_OP_FRINT, 1'b1, 1'b0, 1'b0, 3'd4,
          64'h0000_0000_0000_3e00, 64'd0, 32'd0,
          64'h0000_0000_0000_4000, 32'd0, "FRINTA.H 1.5->2");

    // ---- FCVT H<->S / H<->D ----
    // H->S：1.0h -> 1.0f（is_half=1, fcvt_dst_half=0, is_double=0）
    check(FP_OP_FCVT, 1'b1, 1'b0, 1'b0, 3'd0,
          64'h0000_0000_0000_3c00, 64'd0, 32'd0,
          64'h0000_0000_3f80_0000, 32'd0, "FCVT H->S 1.0");
    // H->D：1.0h -> 1.0d（is_half=1, is_double=1）
    check(FP_OP_FCVT, 1'b1, 1'b1, 1'b0, 3'd0,
          64'h0000_0000_0000_3c00, 64'd0, 32'd0,
          64'h3ff0_0000_0000_0000, 32'd0, "FCVT H->D 1.0");
    // H->S NaN 0x7E12 -> 0x7FC24000（P7-5 off-by-one 修复验证）
    check(FP_OP_FCVT, 1'b1, 1'b0, 1'b0, 3'd0,
          64'h0000_0000_0000_7e12, 64'd0, 32'd0,
          64'h0000_0000_7fc2_4000, 32'd0, "FCVT H->S NaN 7E12");
    // H->D NaN 0x7E12 -> 0x7FF8480000000000
    check(FP_OP_FCVT, 1'b1, 1'b1, 1'b0, 3'd0,
          64'h0000_0000_0000_7e12, 64'd0, 32'd0,
          64'h7ff8_4800_0000_0000, 32'd0, "FCVT H->D NaN 7E12");
    // S->H：1.0f -> 1.0h（is_half=0, fcvt_dst_half=1）
    check(FP_OP_FCVT, 1'b0, 1'b0, 1'b1, 3'd0,
          64'h0000_0000_3f80_0000, 64'd0, 32'd0,
          64'h0000_0000_0000_3c00, 32'd0, "FCVT S->H 1.0");
    // D->H：1.0d -> 1.0h（is_half=0, is_double=1, fcvt_dst_half=1）
    check(FP_OP_FCVT, 1'b0, 1'b1, 1'b1, 3'd0,
          64'h3ff0_0000_0000_0000, 64'd0, 32'd0,
          64'h0000_0000_0000_3c00, 32'd0, "FCVT D->H 1.0");

    // ---- AHP=1 的 FCVT：H 无 NaN/Inf（NaN -> +0 + IOC）----
    // S(qNaN 0x7fc01234) -> H with AHP: NaN -> +0 + IOC
    check(FP_OP_FCVT, 1'b0, 1'b0, 1'b1, 3'd0,
          64'h0000_0000_7fc0_1234, 64'd0, 32'h0400_0000,
          64'h0000_0000_0000_0000, 32'h0000_0001, "FCVT S->H AHP NaN -> +0 IOC");

    $display("PASS: P7-5 FP scalar H/sqrt/minmax/frint/fcvt raw-bit vectors");
    $finish;
  end
endmodule
