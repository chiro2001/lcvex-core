// R20 final round-pack result-boundary directed test.
//
// This is an independent FP_ITER probe.  It checks that both ordinary
// pack_mid and iterative DIV/SQRT finishes cross IT_PACK_RESULT before
// iter_done/result/fpsr_flags are exposed.  The test intentionally observes
// only private state needed to prove the boundary; all functional checks use
// raw IEEE bits and FPSR flags.

`timescale 1ns/1ps
/* verilator lint_off UNUSEDSIGNAL */

module lcvex_fp_scalar_r20_pack_tb;
  import lcvex_pkg::*;

  localparam logic [3:0] STATE_IDLE        = 4'd0;
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

  task automatic start_op(
      input fp_op_t      op_i,
      input logic        half_i,
      input logic        dbl_i,
      input logic [63:0] a_i,
      input logic [63:0] b_i,
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
      operand_c       = 64'd0;
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

  // Wait for the registered result window and consume it exactly once.  The
  // state must be IT_PACK_RESULT, and the edge after the observation must
  // remove iter_done even if valid was held high for that edge.
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
          !dut.g_iter.pack_result_valid_r)
        $fatal(1, "%s done was not sourced by IT_PACK_RESULT", name);
      if (result !== want_bits || fpsr_flags !== want_flags)
        $fatal(1, "%s mismatch: got bits=%016h flags=%08h want bits=%016h flags=%08h",
               name, result, fpsr_flags, want_bits, want_flags);

      // The caller samples this one-cycle window on the following edge.
      @(posedge clk);
      #1;
      if (iter_done || iter_busy || dut.g_iter.it_state_r !== STATE_IDLE)
        $fatal(1,
               "%s repeated/not-idle: done=%0b busy=%0b state=%0d pack_valid=%0b div_busy=%0b div_done=%0b",
               name, iter_done, iter_busy, dut.g_iter.it_state_r,
               dut.g_iter.pack_result_valid_r, div_busy, div_done);
      valid = 1'b0;
      if (result !== 64'd0 || fpsr_flags !== 32'd0)
        $fatal(1, "%s stale output remained after valid drop", name);
      $display("PASS %s bits=%016h flags=%08h", name, want_bits, want_flags);
    end
  endtask

  task automatic ordinary_vectors;
    begin
      // S normal finite result.
      start_op(FP_OP_ADD, 1'b0, 1'b0,
               64'h0000_0000_3f80_0000,
               64'h0000_0000_4000_0000, 32'd0);
      expect_once(64'h0000_0000_4040_0000, 32'd0, 32,
                  "ordinary S normal");

      // S halfway rounding toward +Inf: result and IXC must cross the
      // registered p2 result boundary together.
      start_op(FP_OP_ADD, 1'b0, 1'b0,
               64'h0000_0000_3f80_0000,
               64'h0000_0000_3380_0000, 32'h0040_0000);
      expect_once(64'h0000_0000_3f80_0001, 32'h0000_0010, 32,
                  "ordinary S rounding flags");

      // S minimum subnormal remains exact; FZ converts it to signed zero +
      // IDC in a separate transaction.
      start_op(FP_OP_ADD, 1'b0, 1'b0,
               64'h0000_0000_0000_0001, 64'd0, 32'd0);
      expect_once(64'h0000_0000_0000_0001, 32'd0, 32,
                  "ordinary S subnormal");
      start_op(FP_OP_ADD, 1'b0, 1'b0,
               64'h0000_0000_0000_0001, 64'd0, 32'h0100_0000);
      expect_once(64'd0, 32'h0000_0080, 32,
                  "ordinary S FZ flags");

      // S overflow takes the p2 overflow/flag path.
      start_op(FP_OP_ADD, 1'b0, 1'b0,
               64'h0000_0000_7f7f_ffff,
               64'h0000_0000_7f7f_ffff, 32'd0);
      expect_once(64'h0000_0000_7f80_0000, 32'h0000_0014, 32,
                  "ordinary S overflow");

      // D normal and minimum-subnormal paths exercise the wider format.
      start_op(FP_OP_ADD, 1'b0, 1'b1,
               64'h3ff0_0000_0000_0000,
               64'h4000_0000_0000_0000, 32'd0);
      expect_once(64'h4008_0000_0000_0000, 32'd0, 32,
                  "ordinary D normal");
      start_op(FP_OP_ADD, 1'b0, 1'b1,
               64'h0000_0000_0000_0001, 64'd0, 32'd0);
      expect_once(64'h0000_0000_0000_0001, 32'd0, 32,
                  "ordinary D subnormal");

      // H uses the paired lane result registers: low 1+2=3, high
      // 0.5+0.25=0.75.  IDC is intentionally masked for H.
      start_op(FP_OP_ADD, 1'b1, 1'b0,
               64'h0000_0000_3800_3c00,
               64'h0000_0000_3400_4000, 32'd0);
      expect_once(64'h0000_0000_3a00_4200, 32'd0, 32,
                  "ordinary H paired normal");
      start_op(FP_OP_ADD, 1'b1, 1'b0,
               64'h0000_0000_0000_0001, 64'd0, 32'd0);
      expect_once(64'h0000_0000_0000_0001, 32'd0, 32,
                  "ordinary H subnormal");
      start_op(FP_OP_ADD, 1'b1, 1'b0,
               64'h0000_0000_0000_0001, 64'd0, 32'h0008_0000);
      expect_once(64'h0000_0000_0000_0000, 32'd0, 32,
                  "ordinary H FZ flags masked");
      start_op(FP_OP_ADD, 1'b1, 1'b0,
               64'h0000_0000_0000_7bff,
               64'h0000_0000_0000_7bff, 32'd0);
      expect_once(64'h0000_0000_0000_7c00, 32'h0000_0014, 32,
                  "ordinary H overflow");
    end
  endtask

  task automatic fcvt_vectors;
    begin
      // S -> D and D -> S both use the single registered result payload.
      start_op(FP_OP_FCVT, 1'b0, 1'b1,
               64'h0000_0000_3f80_0000, 64'd0, 32'd0);
      expect_once(64'h3ff0_0000_0000_0000, 32'd0, 32,
                  "FCVT S to D");
      start_op(FP_OP_FCVT, 1'b0, 1'b0,
               64'h3ff0_0000_0000_0000, 64'd0, 32'd0);
      expect_once(64'h0000_0000_3f80_0000, 32'd0, 32,
                  "FCVT D to S");

      // H source and H destination are scalar conversions, not paired H
      // arithmetic. They must use pack_result_r rather than the lo/hi pair.
      start_op(FP_OP_FCVT, 1'b1, 1'b0,
               64'h0000_0000_0000_3c00, 64'd0, 32'd0);
      expect_once(64'h0000_0000_3f80_0000, 32'd0, 32,
                  "FCVT H to S");
      start_op(FP_OP_FCVT, 1'b0, 1'b0,
               64'h0000_0000_3f80_0000, 64'd0, 32'd0);
      fcvt_dst_half = 1'b1;
      expect_once(64'h0000_0000_0000_3c00, 32'd0, 32,
                  "FCVT S to H");
      fcvt_dst_half = 1'b0;
    end
  endtask

  task automatic iterative_vectors;
    begin
      // Normal DIV, inexact DIV, and special DIV all use the same final
      // IT_PACK -> IT_PACK_RESULT result boundary.
      start_op(FP_OP_DIV, 1'b0, 1'b0,
               64'h0000_0000_4000_0000,
               64'h0000_0000_3f80_0000, 32'd0);
      expect_once(64'h0000_0000_4000_0000, 32'd0, 400,
                  "iterative S DIV finish");
      start_op(FP_OP_DIV, 1'b0, 1'b0,
               64'h0000_0000_3f80_0000,
               64'h0000_0000_4040_0000, 32'd0);
      expect_once(64'h0000_0000_3eaa_aaab, 32'h0000_0010, 400,
                  "iterative S DIV flags");
      start_op(FP_OP_DIV, 1'b0, 1'b0,
               64'h0000_0000_3f80_0000, 64'd0, 32'd0);
      expect_once(64'h0000_0000_7f80_0000, 32'h0000_0002, 400,
                  "iterative S DIV special");

      start_op(FP_OP_SQRT, 1'b0, 1'b0,
               64'h0000_0000_4080_0000, 64'd0, 32'd0);
      expect_once(64'h0000_0000_4000_0000, 32'd0, 160,
                  "iterative S SQRT finish");
      start_op(FP_OP_SQRT, 1'b0, 1'b1,
               64'h4010_0000_0000_0000, 64'd0, 32'd0);
      expect_once(64'h4000_0000_0000_0000, 32'd0, 160,
                  "iterative D SQRT finish");
      start_op(FP_OP_SQRT, 1'b1, 1'b0,
               64'h0000_0000_3c00_4400, 64'd0, 32'd0);
      expect_once(64'h0000_0000_3c00_4000, 32'd0, 160,
                  "iterative H SQRT finish");
    end
  endtask

  task automatic pause_result_probe(
      input fp_op_t      op_i,
      input logic        half_i,
      input logic        dbl_i,
      input logic [63:0] a_i,
      input logic [63:0] b_i,
      input logic [31:0] fpcr_i,
      input logic [63:0] changed_a,
      input logic [63:0] changed_b,
      input logic [63:0] want_bits,
      input logic [31:0] want_flags,
      input integer      max_cycles,
      input string       name);
    begin
      start_op(op_i, half_i, dbl_i, a_i, b_i, fpcr_i);
      wait_state(STATE_PACK_RESULT, max_cycles, name);
      if (!dut.g_iter.pack_result_valid_r || result !== want_bits ||
          fpsr_flags !== want_flags ||
          dut.g_iter.pack_result_half_r !==
              (half_i && (op_i != FP_OP_FCVT)))
        $fatal(1, "%s result register mismatch before pause", name);

      // Pause is sampled synchronously.  No done edge may be observed while
      // the final registered payload is held, even if live inputs change.
      @(negedge clk);
      iter_pause = 1'b1;
      operand_a = changed_a;
      operand_b = changed_b;
      op = FP_OP_NONE;
      is_half = ~half_i;
      is_double = ~dbl_i;
      fcvt_dst_half = 1'b1;
      repeat (2) begin
        @(posedge clk);
        #1;
        if (dut.g_iter.it_state_r !== STATE_PACK_RESULT || !iter_busy ||
            iter_done || result !== want_bits || fpsr_flags !== want_flags)
          $fatal(1, "%s pause changed final result/state", name);
      end

      @(negedge clk);
      iter_pause = 1'b0;
      #1;
      if (!iter_done || result !== want_bits || fpsr_flags !== want_flags)
        $fatal(1, "%s pause release did not expose held result", name);
      // Consume this result window.  The deliberately changed live op above
      // must not be presented as a new request after the capture edge.
      valid = 1'b0;
      @(posedge clk);
      #1;
      if (iter_done || iter_busy || dut.g_iter.it_state_r !== STATE_IDLE)
        $fatal(1, "%s pause release repeated done", name);
      $display("PASS %s pause/hold/release", name);
    end
  endtask

  task automatic kill_result_probe;
    begin
      start_op(FP_OP_ADD, 1'b0, 1'b0,
               64'h0000_0000_3f80_0000,
               64'h0000_0000_4000_0000, 32'd0);
      wait_state(STATE_PACK_RESULT, 32, "kill result");
      @(negedge clk);
      valid = 1'b0;
      iter_pause = 1'b1;
      iter_kill = 1'b1;
      @(posedge clk);
      #1;
      iter_kill = 1'b0;
      iter_pause = 1'b0;
      if (iter_busy || iter_done || result !== 64'd0 ||
          dut.g_iter.it_state_r !== STATE_IDLE ||
          dut.g_iter.pack_result_valid_r !== 1'b0)
        $fatal(1, "iter_kill did not clear final result boundary");

      start_op(FP_OP_ADD, 1'b0, 1'b0,
               64'h0000_0000_4000_0000,
               64'h0000_0000_4040_0000, 32'd0);
      expect_once(64'h0000_0000_40a0_0000, 32'd0, 32,
                  "kill replacement");
    end
  endtask

  task automatic valid_drop_result_probe;
    begin
      start_op(FP_OP_SQRT, 1'b0, 1'b0,
               64'h0000_0000_4080_0000, 64'd0, 32'd0);
      wait_state(STATE_PACK_RESULT, 160, "valid-drop result");
      if (!dut.g_iter.pack_result_valid_r)
        $fatal(1, "valid-drop probe did not reach final result register");
      @(negedge clk);
      iter_pause = 1'b1;
      valid = 1'b0;
      @(posedge clk);
      #1;
      if (iter_busy || iter_done || result !== 64'd0 ||
          dut.g_iter.it_state_r !== STATE_IDLE ||
          dut.g_iter.pack_result_valid_r !== 1'b0)
        $fatal(1, "valid drop committed stale final result");
      iter_pause = 1'b0;

      start_op(FP_OP_ADD, 1'b0, 1'b0,
               64'h0000_0000_3f80_0000,
               64'h0000_0000_4000_0000, 32'd0);
      expect_once(64'h0000_0000_4040_0000, 32'd0, 32,
                  "valid-drop replacement");
    end
  endtask

  task automatic reset_result_probe;
    begin
      start_op(FP_OP_DIV, 1'b0, 1'b0,
               64'h0000_0000_4000_0000,
               64'h0000_0000_3f80_0000, 32'd0);
      wait_state(STATE_PACK_RESULT, 400, "reset result");
      @(negedge clk);
      valid = 1'b0;
      iter_pause = 1'b1;
      rst_n = 1'b0;
      #2;
      if (iter_busy || iter_done || result !== 64'd0 ||
          dut.g_iter.it_state_r !== STATE_IDLE ||
          dut.g_iter.pack_result_valid_r !== 1'b0)
        $fatal(1, "reset did not clear final result boundary");
      rst_n = 1'b1;
      iter_pause = 1'b0;
      @(negedge clk);
      if (iter_busy || iter_done || result !== 64'd0)
        $fatal(1, "reset release left final result payload");

      start_op(FP_OP_SQRT, 1'b0, 1'b0,
               64'h0000_0000_4080_0000, 64'd0, 32'd0);
      expect_once(64'h0000_0000_4000_0000, 32'd0, 160,
                  "reset replacement");
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

    #12;
    rst_n = 1'b1;
    @(negedge clk);

    ordinary_vectors();
    fcvt_vectors();
    iterative_vectors();
    pause_result_probe(FP_OP_ADD, 1'b0, 1'b0,
                       64'h0000_0000_3f80_0000,
                       64'h0000_0000_3380_0000, 32'h0040_0000,
                       64'h0000_0000_4000_0000,
                       64'h0000_0000_4040_0000,
                       64'h0000_0000_3f80_0001, 32'h0000_0010,
                       32, "ordinary IT_PACK_RESULT");
    pause_result_probe(FP_OP_SQRT, 1'b0, 1'b0,
                       64'h0000_0000_4080_0000, 64'd0, 32'd0,
                       64'h0000_0000_4000_0000, 64'd0,
                       64'h0000_0000_4000_0000, 32'd0,
                       160, "iterative IT_PACK_RESULT");
    kill_result_probe();
    valid_drop_result_probe();
    reset_result_probe();

    $display("PASS: R20 final round-pack result boundary H/S/D DIV/SQRT pause/kill/reset/valid");
    $finish;
  end
endmodule
