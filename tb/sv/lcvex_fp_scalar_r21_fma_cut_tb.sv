// R21 FMA residual-alignment register-cut focused test.
//
// This direct FP_ITER probe checks the private IT_MUL -> IT_FMA boundary and
// exercises the raw-bit FMA result/flag paths around it.  It intentionally
// does not use host floating-point arithmetic as an oracle.

`timescale 1ns/1ps
/* verilator lint_off UNUSEDSIGNAL */

module lcvex_fp_scalar_r21_fma_cut_tb;
  import lcvex_pkg::*;

  localparam logic [3:0] STATE_IDLE = 4'd0;
  localparam logic [3:0] STATE_MUL  = 4'd6;
  localparam logic [3:0] STATE_PREP = 4'd3;
  localparam logic [3:0] STATE_FMA  = 4'd14;
  localparam logic [3:0] STATE_PACK_RESULT = 4'd13;

  logic        clk;
  logic        rst_n;
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
  logic        iter_kill;
  logic        iter_pause;
  logic        iter_busy;
  logic        iter_done;
  logic [63:0] result;
  logic [63:0] int_result;
  logic [31:0] fpsr_flags;
  logic [3:0]  cmp_nzcv;
  logic        div_busy;
  logic        div_done;

  lcvex_fp_scalar #(.FP_ITER(1'b1)) dut (
      .clk            (clk),
      .rst_n          (rst_n),
      .valid          (valid),
      .op             (op),
      .is_double      (is_double),
      .is_half        (is_half),
      .fcvt_dst_half  (fcvt_dst_half),
      .rint_mode      (rint_mode),
      .operand_a      (operand_a),
      .operand_b      (operand_b),
      .operand_c      (operand_c),
      .conv_int       (conv_int),
      .conv_shift     (conv_shift),
      .conv_is_32     (conv_is_32),
      .fpcr           (fpcr),
      .compare_zero   (compare_zero),
      .signal_all_nans(signal_all_nans),
      .iter_kill      (iter_kill),
      .iter_pause     (iter_pause),
      .iter_busy      (iter_busy),
      .iter_done      (iter_done),
      .result         (result),
      .int_result     (int_result),
      .fpsr_flags     (fpsr_flags),
      .cmp_nzcv       (cmp_nzcv),
      .div_busy       (div_busy),
      .div_done       (div_done)
  );

  initial begin
    clk = 1'b0;
    forever #5 clk = ~clk;
  end

  task automatic set_fma(
      input fp_op_t      op_i,
      input logic        half_i,
      input logic        dbl_i,
      input logic [63:0] a_i,
      input logic [63:0] b_i,
      input logic [63:0] c_i,
      input logic [31:0] fpcr_i);
    begin
      valid           = 1'b1;
      op              = op_i;
      is_half         = half_i;
      is_double       = dbl_i;
      fcvt_dst_half   = 1'b0;
      rint_mode       = 3'd0;
      operand_a       = a_i;
      operand_b       = b_i;
      operand_c       = c_i;
      conv_int        = 64'd0;
      conv_shift      = 7'd0;
      conv_is_32      = 1'b0;
      fpcr            = fpcr_i;
      compare_zero    = 1'b0;
      signal_all_nans = 1'b0;
      iter_kill       = 1'b0;
      iter_pause      = 1'b0;
    end
  endtask

  task automatic wait_state(
      input logic [3:0] want_state,
      input integer     max_cycles,
      input string      name);
    integer waited;
    begin
      waited = 0;
      while (dut.g_iter.it_state_r !== want_state) begin
        @(posedge clk);
        #1;
        waited = waited + 1;
        if (waited > max_cycles)
          $fatal(1, "%s state timeout: got=%0d want=%0d", name,
                 dut.g_iter.it_state_r, want_state);
      end
    end
  endtask

  task automatic expect_once(
      input logic [63:0] want_bits,
      input logic [31:0] want_flags,
      input integer      max_cycles,
      input string       name);
    integer waited;
    begin
      waited = 0;
      while (!iter_done) begin
        @(posedge clk);
        #1;
        waited = waited + 1;
        if (waited > max_cycles)
          $fatal(1, "%s done timeout", name);
      end
      if (dut.g_iter.it_state_r !== STATE_PACK_RESULT ||
          !dut.g_iter.pack_result_valid_r || result !== want_bits ||
          fpsr_flags !== want_flags || int_result !== 64'd0)
        $fatal(1,
               "%s mismatch: state=%0d pack_valid=%0b bits=%016h flags=%08h int=%016h want bits=%016h flags=%08h",
               name, dut.g_iter.it_state_r, dut.g_iter.pack_result_valid_r,
               result, fpsr_flags, int_result, want_bits, want_flags);

      // The result window is exactly one cycle and must not repeat.
      @(posedge clk);
      #1;
      if (iter_done || iter_busy || dut.g_iter.it_state_r !== STATE_IDLE)
        $fatal(1, "%s repeated completion: state=%0d done=%0b busy=%0b",
               name, dut.g_iter.it_state_r, iter_done, iter_busy);
      valid = 1'b0;
      if (result !== 64'd0 || fpsr_flags !== 32'd0)
        $fatal(1, "%s stale output after valid drop", name);
      $display("PASS %s bits=%016h flags=%08h", name, want_bits, want_flags);
    end
  endtask

  task automatic check_fma_route(
      input fp_op_t      op_i,
      input logic        half_i,
      input logic        dbl_i,
      input logic [63:0] a_i,
      input logic [63:0] b_i,
      input logic [63:0] c_i,
      input logic [63:0] want_bits,
      input logic [31:0] want_flags,
      input string       name);
    begin
      set_fma(op_i, half_i, dbl_i, a_i, b_i, c_i, 32'd0);
      wait_state(STATE_MUL, 8, {name, " mul"});
      if (dut.g_iter.pm_pre === '0)
        $fatal(1, "%s product register was not populated", name);
      @(posedge clk);
      #1;
      if (dut.g_iter.it_state_r !== STATE_FMA)
        $fatal(1, "%s did not enter FMA-only state: got=%0d", name,
               dut.g_iter.it_state_r);
      if (half_i) begin
        if (dut.g_iter.fma_align_lo === '0 || dut.g_iter.fma_align_hi === '0)
          $fatal(1, "%s half alignment payload was not captured", name);
      end else if (dut.g_iter.fma_align === '0) begin
        $fatal(1, "%s alignment payload was not captured", name);
      end
      expect_once(want_bits, want_flags, 64, name);
    end
  endtask

  task automatic normal_sign_variants;
    begin
      // Existing QEMU/RTL operation encoding: FMSUB and FNMADD negate the
      // product, while FNMADD and FNMSUB negate the addend.
      check_fma_route(FP_OP_FMADD, 1'b0, 1'b0,
                      64'h0000_0000_4000_0000,
                      64'h0000_0000_4040_0000,
                      64'h0000_0000_4120_0000,
                      64'h0000_0000_4180_0000, 32'd0, "FMADD S");
      check_fma_route(FP_OP_FMSUB, 1'b0, 1'b0,
                      64'h0000_0000_4000_0000,
                      64'h0000_0000_4040_0000,
                      64'h0000_0000_4120_0000,
                      64'h0000_0000_4080_0000, 32'd0, "FMSUB S");
      check_fma_route(FP_OP_FNMADD, 1'b0, 1'b0,
                      64'h0000_0000_4000_0000,
                      64'h0000_0000_4040_0000,
                      64'h0000_0000_4120_0000,
                      64'h0000_0000_c180_0000, 32'd0, "FNMADD S");
      check_fma_route(FP_OP_FNMSUB, 1'b0, 1'b0,
                      64'h0000_0000_4000_0000,
                      64'h0000_0000_4040_0000,
                      64'h0000_0000_4120_0000,
                      64'h0000_0000_c080_0000, 32'd0, "FNMSUB S");

      check_fma_route(FP_OP_FMADD, 1'b0, 1'b1,
                      64'h4000_0000_0000_0000,
                      64'h4008_0000_0000_0000,
                      64'h4024_0000_0000_0000,
                      64'h4030_0000_0000_0000, 32'd0, "FMADD D");

      // Two packed H lanes prove that the private alignment boundary is
      // duplicated per lane and that both lanes reach one result window.
      check_fma_route(FP_OP_FMADD, 1'b1, 1'b0,
                      64'h0000_0000_3e00_4000,
                      64'h0000_0000_4000_4200,
                      64'h0000_0000_3800_4900,
                      64'h0000_0000_4300_4c00, 32'd0, "FMADD H pair");
    end
  endtask

  task automatic subnormal_and_flags;
    begin
      check_fma_route(FP_OP_FMADD, 1'b0, 1'b0,
                      64'h0000_0000_0000_0001,
                      64'h0000_0000_3f80_0000,
                      64'd0, 64'h0000_0000_0000_0001, 32'd0,
                      "FMADD S subnormal");
      check_fma_route(FP_OP_FMADD, 1'b0, 1'b1,
                      64'h0000_0000_0000_0001,
                      64'h3ff0_0000_0000_0000,
                      64'd0, 64'h0000_0000_0000_0001, 32'd0,
                      "FMADD D subnormal");
      check_fma_route(FP_OP_FMADD, 1'b1, 1'b0,
                      64'h0000_0000_0000_0001,
                      64'h0000_0000_3c00_3c00,
                      64'd0, 64'h0000_0000_0000_0001, 32'd0,
                      "FMADD H subnormal pair");

      // FZ input flushes the S subnormal and reports IDC.
      set_fma(FP_OP_FMADD, 1'b0, 1'b0,
              64'h0000_0000_0000_0001,
              64'h0000_0000_3f80_0000, 64'd0, 32'h0100_0000);
      wait_state(STATE_FMA, 16, "FMADD S FZ");
      expect_once(64'd0, 32'h0000_0080, 64, "FMADD S FZ");

      // A non-representable residual exercises the registered flags path.
      check_fma_route(FP_OP_FMADD, 1'b0, 1'b0,
                      64'h0000_0000_3f80_0000,
                      64'h0000_0000_3f80_0000,
                      64'h0000_0000_3300_0000,
                      64'h0000_0000_3f80_0000, 32'h0000_0010,
                      "FMADD S inexact");
    end
  endtask

  task automatic special_vectors;
    begin
      // QNaN addend is propagated without IOC; SNaN addend is quieted and
      // raises IOC. DN overrides the payload while preserving SNaN IOC.
      check_fma_route(FP_OP_FMADD, 1'b0, 1'b0,
                      64'h0000_0000_4000_0000,
                      64'h0000_0000_4040_0000,
                      64'h0000_0000_7fc1_2345,
                      64'h0000_0000_7fc1_2345, 32'd0, "FMADD S QNaN");
      check_fma_route(FP_OP_FMADD, 1'b0, 1'b0,
                      64'h0000_0000_4000_0000,
                      64'h0000_0000_4040_0000,
                      64'h0000_0000_7f81_2345,
                      64'h0000_0000_7fc1_2345, 32'h0000_0001,
                      "FMADD S SNaN");

      set_fma(FP_OP_FMADD, 1'b0, 1'b0,
              64'h0000_0000_4000_0000,
              64'h0000_0000_4040_0000,
              64'h0000_0000_7f81_2345, 32'h0200_0000);
      wait_state(STATE_FMA, 16, "FMADD S DN");
      expect_once(64'h0000_0000_7fc0_0000, 32'h0000_0001, 64,
                  "FMADD S DN");

      // Inf * zero is invalid even with an otherwise finite addend.
      check_fma_route(FP_OP_FMADD, 1'b0, 1'b0,
                      64'h0000_0000_7f80_0000, 64'd0,
                      64'h0000_0000_3f80_0000,
                      64'h0000_0000_7fc0_0000, 32'h0000_0001,
                      "FMADD S InfTimesZero");
    end
  endtask

  task automatic cancellation_vectors;
    begin
      // FMSUB is -a*b+c in the established RTL encoding: 6-6 cancels to +0
      // under round-to-nearest and to -0 under round-toward-minus-infinity.
      check_fma_route(FP_OP_FMSUB, 1'b0, 1'b0,
                      64'h0000_0000_4000_0000,
                      64'h0000_0000_4040_0000,
                      64'h0000_0000_40c0_0000,
                      64'h0000_0000_0000_0000, 32'd0,
                      "FMSUB S cancellation RN");
      set_fma(FP_OP_FMSUB, 1'b0, 1'b0,
              64'h0000_0000_4000_0000,
              64'h0000_0000_4040_0000,
              64'h0000_0000_40c0_0000, 32'h0080_0000);
      wait_state(STATE_FMA, 16, "FMSUB S cancellation RM");
      expect_once(64'h0000_0000_8000_0000, 32'd0, 64,
                  "FMSUB S cancellation RM");
    end
  endtask

  task automatic control_vectors;
    logic [255:0] held_payload;
    begin
      // Pause must hold the alignment payload and the FMA-only state.
      set_fma(FP_OP_FMADD, 1'b0, 1'b0,
              64'h0000_0000_4000_0000,
              64'h0000_0000_4040_0000,
              64'h0000_0000_4120_0000, 32'd0);
      wait_state(STATE_FMA, 16, "pause FMA");
      held_payload = dut.g_iter.fma_align.product_ext;
      @(negedge clk);
      iter_pause = 1'b1;
      operand_a = 64'h0000_0000_3f80_0000;
      operand_b = 64'h0000_0000_4000_0000;
      operand_c = 64'h0000_0000_3f80_0000;
      repeat (2) begin
        @(posedge clk);
        #1;
        if (dut.g_iter.it_state_r !== STATE_FMA || iter_done ||
            dut.g_iter.fma_align.product_ext !== held_payload)
          $fatal(1, "FMA pause changed state or alignment payload");
      end
      @(negedge clk);
      iter_pause = 1'b0;
      // Restore only the controls used by the registered pre payload before
      // release; result must be from the original request.
      op = FP_OP_FMADD;
      is_half = 1'b0;
      is_double = 1'b0;
      operand_a = 64'h0000_0000_4000_0000;
      operand_b = 64'h0000_0000_4040_0000;
      operand_c = 64'h0000_0000_4120_0000;
      @(posedge clk);
      #1;
      if (dut.g_iter.it_state_r !== STATE_PREP)
        $fatal(1, "FMA pause release did not enter pack prep");
      expect_once(64'h0000_0000_4180_0000, 32'd0, 64,
                  "FMA pause release");

      // Valid drop while IT_FMA must abandon the private payload.
      set_fma(FP_OP_FMADD, 1'b0, 1'b0,
              64'h0000_0000_4000_0000,
              64'h0000_0000_4040_0000,
              64'h0000_0000_4120_0000, 32'd0);
      wait_state(STATE_FMA, 16, "valid-drop FMA");
      @(negedge clk);
      valid = 1'b0;
      @(posedge clk);
      #1;
      if (iter_busy || iter_done || dut.g_iter.it_state_r !== STATE_IDLE ||
          dut.g_iter.fma_align !== '0 || result !== 64'd0 ||
          fpsr_flags !== 32'd0)
        $fatal(1, "FMA valid drop retained stale completion/payload");

      // Kill and asynchronous reset each clear the FMA-only payload.
      set_fma(FP_OP_FMADD, 1'b0, 1'b0,
              64'h0000_0000_4000_0000,
              64'h0000_0000_4040_0000,
              64'h0000_0000_4120_0000, 32'd0);
      wait_state(STATE_FMA, 16, "kill FMA");
      @(negedge clk);
      iter_kill = 1'b1;
      valid = 1'b0;
      @(posedge clk);
      #1;
      iter_kill = 1'b0;
      if (iter_busy || iter_done || dut.g_iter.it_state_r !== STATE_IDLE ||
          dut.g_iter.fma_align !== '0)
        $fatal(1, "FMA kill did not clear state/payload");

      set_fma(FP_OP_FMADD, 1'b0, 1'b0,
              64'h0000_0000_4000_0000,
              64'h0000_0000_4040_0000,
              64'h0000_0000_4120_0000, 32'd0);
      wait_state(STATE_FMA, 16, "reset FMA");
      @(negedge clk);
      valid = 1'b0;
      rst_n = 1'b0;
      #1;
      if (iter_busy || iter_done || dut.g_iter.it_state_r !== STATE_IDLE ||
          dut.g_iter.fma_align !== '0)
        $fatal(1, "FMA reset did not clear state/payload");
      rst_n = 1'b1;
    end
  endtask

  initial begin
    valid           = 1'b0;
    rst_n           = 1'b0;
    op              = FP_OP_NONE;
    is_double       = 1'b0;
    is_half         = 1'b0;
    fcvt_dst_half   = 1'b0;
    rint_mode       = 3'd0;
    operand_a       = 64'd0;
    operand_b       = 64'd0;
    operand_c       = 64'd0;
    conv_int        = 64'd0;
    conv_shift      = 7'd0;
    conv_is_32      = 1'b0;
    fpcr            = 32'd0;
    compare_zero    = 1'b0;
    signal_all_nans = 1'b0;
    iter_kill       = 1'b0;
    iter_pause      = 1'b0;

    repeat (2) @(posedge clk);
    #1;
    rst_n = 1'b1;
    @(negedge clk);

    normal_sign_variants();
    subnormal_and_flags();
    special_vectors();
    cancellation_vectors();
    control_vectors();

    $display("PASS: R21 FMA alignment register cut, raw semantics and control probes");
    $finish;
  end
endmodule
/* verilator lint_on UNUSEDSIGNAL */
