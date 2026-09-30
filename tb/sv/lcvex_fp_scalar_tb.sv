// P7-1 FP scalar unit directed SystemVerilog testbench.
// 只比较 raw IEEE bits、FPSR sticky flags 和 FCMP NZCV，不把任何值转换为
// real/host float，也不使用 epsilon。

`timescale 1ns/1ps
/* verilator lint_off UNUSEDSIGNAL */

module lcvex_fp_scalar_tb;
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

  task automatic check_result(
      input fp_op_t op_i,
      input logic dbl_i,
      input logic [63:0] a_i,
      input logic [63:0] b_i,
      input logic [31:0] fpcr_i,
      input logic cmp0_i,
      input logic [63:0] want_bits,
      input logic [31:0] want_flags,
      input logic [3:0] want_nzcv,
      input string name);
    begin
      valid = 1'b1;
      op = op_i;
      is_double = dbl_i;
      operand_a = a_i;
      operand_b = b_i;
      fpcr = fpcr_i;
      compare_zero = cmp0_i;
      signal_all_nans = 1'b0;
      #1;
      if (op_i == FP_OP_DIV) begin
        // Wait for any previous FDIV to be fully idle before starting the
        // next one; otherwise a stale done pulse can be mistaken for this
        // division's completion.
        while (div_busy || div_done) #1;
        #1;
        while (!div_done) #1;
        #1;
      end
      if (result !== want_bits || fpsr_flags !== want_flags ||
          cmp_nzcv !== want_nzcv) begin
        $fatal(1, "%s raw mismatch: got bits=%016h flags=%08h nzcv=%x want bits=%016h flags=%08h nzcv=%x",
               name, result, fpsr_flags, cmp_nzcv,
               want_bits, want_flags, want_nzcv);
      end
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

    check_result(FP_OP_MOV, 1'b0, 64'h0000_0000_7fc1_2345, 0, 0, 0,
                 64'h0000_0000_7fc1_2345, 0, 0, "FMOV.S raw");
    check_result(FP_OP_MOV, 1'b1, 64'h7ff1_2345_6789_abcd, 0, 0, 0,
                 64'h7ff1_2345_6789_abcd, 0, 0, "FMOV.D raw");
    check_result(FP_OP_ADD, 1'b0, 64'h3f80_0000, 64'h4000_0000, 0, 0,
                 64'h0000_0000_4040_0000, 0, 0, "FADD.S");
    check_result(FP_OP_SUB, 1'b0, 64'h3fc0_0000, 64'h4000_0000, 0, 0,
                 64'h0000_0000_bf00_0000, 0, 0, "FSUB.S");
    check_result(FP_OP_MUL, 1'b0, 64'h3fc0_0000, 64'h4000_0000, 0, 0,
                 64'h0000_0000_4040_0000, 0, 0, "FMUL.S");
    check_result(FP_OP_DIV, 1'b0, 64'h3f80_0000, 64'h4000_0000, 0, 0,
                 64'h0000_0000_3f00_0000, 0, 0, "FDIV.S");
    // exponent=0 with FZ=0: the raw minimum subnormal is exactly 2^-149.
    check_result(FP_OP_ADD, 1'b0, 64'h0000_0001, 64'h0000_0000, 0, 0,
                 64'h0000_0000_0000_0001, 0, 0, "FADD.S min-subnormal");
    check_result(FP_OP_MUL, 1'b0, 64'h0000_0001, 64'h3f80_0000, 0, 0,
                 64'h0000_0000_0000_0001, 0, 0, "FMUL.S min-subnormal");
    check_result(FP_OP_DIV, 1'b0, 64'h0000_0001, 64'h3f80_0000, 0, 0,
                 64'h0000_0000_0000_0001, 0, 0, "FDIV.S min-subnormal");
    check_result(FP_OP_ADD, 1'b1, 64'h3ff0_0000_0000_0000,
                 64'h4000_0000_0000_0000, 0, 0,
                 64'h4008_0000_0000_0000, 0, 0, "FADD.D");
    // FP64 minimum subnormal is exactly 2^-1074.
    check_result(FP_OP_ADD, 1'b1, 64'h0000_0000_0000_0001,
                 64'h0000_0000_0000_0000, 0, 0,
                 64'h0000_0000_0000_0001, 0, 0, "FADD.D min-subnormal");
    check_result(FP_OP_MUL, 1'b1, 64'h0000_0000_0000_0001,
                 64'h3ff0_0000_0000_0000, 0, 0,
                 64'h0000_0000_0000_0001, 0, 0, "FMUL.D min-subnormal");
    check_result(FP_OP_DIV, 1'b1, 64'h0000_0000_0000_0001,
                 64'h3ff0_0000_0000_0000, 0, 0,
                 64'h0000_0000_0000_0001, 0, 0, "FDIV.D min-subnormal");
    check_result(FP_OP_DIV, 1'b1, 64'h7ff0_0000_0000_0000, 0, 0, 0,
                 64'h7ff0_0000_0000_0000, 0, 0, "FDIV.D Inf/0");
    check_result(FP_OP_DIV, 1'b0, 64'h3f80_0000, 64'h0000_0000, 0, 0,
                 64'h0000_0000_7f80_0000, 32'h0000_0002, 0,
                 "FDIV.S finite/0");
    check_result(FP_OP_DIV, 1'b0, 64'h7f80_0000, 64'h0000_0000, 0, 0,
                 64'h0000_0000_7f80_0000, 0, 0, "FDIV.S Inf/0");
    check_result(FP_OP_DIV, 1'b0, 64'h0000_0000, 64'h0000_0000, 0, 0,
                 64'h0000_0000_7fc0_0000, 32'h0000_0001, 0,
                 "FDIV.S 0/0");
    check_result(FP_OP_DIV, 1'b1, 64'h3ff0_0000_0000_0000,
                 64'h0000_0000_0000_0000, 0, 0,
                 64'h7ff0_0000_0000_0000, 32'h0000_0002, 0,
                 "FDIV.D finite/0");
    check_result(FP_OP_DIV, 1'b1, 64'h0000_0000_0000_0000,
                 64'h0000_0000_0000_0000, 0, 0,
                 64'h7ff8_0000_0000_0000, 32'h0000_0001, 0,
                 "FDIV.D 0/0");
    check_result(FP_OP_ADD, 1'b0, 64'h7f80_0000, 64'hff80_0000, 0, 0,
                 64'h0000_0000_7fc0_0000, 32'h0000_0001, 0, "FADD.S inf invalid");
    check_result(FP_OP_ADD, 1'b0, 64'h7fc1_2345, 64'h3f80_0000, 0, 0,
                 64'h0000_0000_7fc1_2345, 0, 0, "FADD.S qNaN payload");
    check_result(FP_OP_ADD, 1'b0, 64'h7fa1_2345, 64'h3f80_0000, 0, 0,
                 64'h0000_0000_7fe1_2345, 32'h0000_0001, 0, "FADD.S sNaN quiet");
    check_result(FP_OP_ADD, 1'b0, 64'h7fc1_2345, 64'h3f80_0000,
                 32'h0200_0000, 0,
                 64'h0000_0000_7fc0_0000, 0, 0, "FADD.S DN");
    check_result(FP_OP_CMP, 1'b0, 64'hbf80_0000, 64'h3f80_0000, 0, 0,
                 0, 0, 4'b1000, "FCMP.S less");
    check_result(FP_OP_CMP, 1'b1, 64'h0000_0000_0000_0000, 0, 0, 1,
                 0, 0, 4'b0110, "FCMP.D zero equal");
    check_result(FP_OP_CMP, 1'b0, 64'h7fc0_0001, 0, 0, 1,
                 0, 0, 4'b0011, "FCMP.S qNaN unordered");
    check_result(FP_OP_CMP, 1'b0, 64'h7fa0_0001, 0, 0, 1,
                 0, 32'h0000_0001, 4'b0011, "FCMP.S sNaN invalid");

    // FPCR.FZ: input denormal is flushed and records IDC. The resulting zero
    // is still an architectural raw signed zero.
    check_result(FP_OP_ADD, 1'b0, 64'h0000_0001, 64'h0000_0000,
                 32'h0100_0000, 0,
                 64'h0000_0000_0000_0000, 32'h0000_0080, 0,
                 "FADD.S FZ input");

    $display("PASS: P7-1 FP scalar raw-bit directed vectors");
    $finish;
  end
endmodule
