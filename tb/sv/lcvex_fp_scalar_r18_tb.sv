// R18 FP scalar prescan-cut focused test.
//
// This test is intentionally a direct FP_ITER scalar probe.  It observes the
// non-architectural state only to prove that the new scan/classification
// register boundary exists; all functional checks remain raw-bit/flag checks.
// The owner and integrator run this focused test with Verilator.  QEMU and
// physical validation remain separate integration stages.

`timescale 1ns/1ps
/* verilator lint_off UNUSEDSIGNAL */

module lcvex_fp_scalar_r18_tb;
  import lcvex_pkg::*;

  localparam logic [3:0] STATE_PREP      = 4'd3;
  localparam logic [3:0] STATE_PACK_SCAN = 4'd10;
  localparam logic [3:0] STATE_PACK_PRE  = 4'd11;
  localparam logic [3:0] STATE_PACK      = 4'd12;
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

  // Packed mirrors of the module-private function payloads.  They let this
  // pure-function equivalence test call round_pack_scan without driving the
  // state machine's pp_pre/pack_scan registers from a second process.
  typedef struct packed {
    logic [63:0] bits;
    logic [31:0] flags;
    logic [3:0]  nzcv;
  } fp_special_probe_t;

  typedef struct packed {
    logic         is_special;
    fp_special_probe_t special;
    logic         need_round;
    logic         sign;
    logic [255:0] sig;
    integer       exp2;
    logic [31:0]  input_flags;
    logic [1:0]   fmt;
    logic         flush_zero;
    logic [1:0]   rmode;
    logic         ahp;
    logic [7:0]   lead;
    logic         lead_valid;
  } fp_pre_probe_t;

  typedef struct packed {
    logic         is_special;
    logic [63:0]  special_bits;
    logic [31:0]  special_flags;
    logic [31:0]  input_flags;
    logic         sign;
    logic [255:0] sig;
    logic [7:0]   lead;
    logic         lead_valid;
    logic         is_zero;
    integer       exp2;
    integer       e;
    logic [1:0]   fmt;
    logic         flush_zero;
    logic [1:0]   rmode;
    logic         ahp;
  } fp_scan_probe_t;

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

  task automatic set_add(
      input logic [63:0] a_i,
      input logic [63:0] b_i);
    begin
      valid          = 1'b1;
      op             = FP_OP_ADD;
      is_double      = 1'b0;
      is_half        = 1'b0;
      fcvt_dst_half  = 1'b0;
      rint_mode      = 3'd0;
      operand_a      = a_i;
      operand_b      = b_i;
      operand_c      = 64'd0;
      conv_int       = 64'd0;
      conv_shift     = 7'd0;
      conv_is_32     = 1'b0;
      fpcr           = 32'd0;
      compare_zero   = 1'b0;
      signal_all_nans = 1'b0;
    end
  endtask

  task automatic wait_state(
      input logic [3:0] want_state,
      input integer max_cycles,
      input string name);
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

  task automatic wait_done(
      input logic [63:0] want_bits,
      input logic [31:0] want_flags,
      input string name);
    integer waited;
    begin
      waited = 0;
      while (!iter_done) begin
        @(posedge clk);
        #1;
        waited = waited + 1;
        if (waited > 400)
          $fatal(1, "%s done timeout", name);
      end
      if (result !== want_bits || fpsr_flags !== want_flags)
        $fatal(1, "%s raw mismatch: got bits=%016h flags=%08h want bits=%016h flags=%08h",
               name, result, fpsr_flags, want_bits, want_flags);
      $display("PASS %s bits=%016h flags=%08h", name, result, fpsr_flags);
    end
  endtask

  task automatic finish_and_idle;
    begin
      @(negedge clk);
      valid = 1'b0;
      @(posedge clk);
      #1;
      if (iter_busy || iter_done || dut.g_iter.it_state_r !== 4'd0)
        $fatal(1, "ordinary transaction did not return to idle");
    end
  endtask

  // Prove the full R18 sequence.  For a finite normal result, the scan
  // payload is visible in IT_PACK_SCAN, tiny/exponent metadata is visible in
  // IT_PACK_PRE, IT_PACK captures p2, and only IT_PACK_RESULT exposes
  // iter_done/result.
  task automatic normal_stage_probe;
    begin
      set_add(64'h0000_0000_3f80_0000, 64'h0000_0000_4000_0000);
      // ADD already crosses the registered ARITH/ALIGN/ADD front half before
      // IT_PREP.  Wait for that existing pipeline rather than assuming the
      // request reaches IT_PREP on its first edge.
      wait_state(STATE_PREP, 8, "normal prep");
      wait_state(STATE_PACK_SCAN, 8, "normal scan");
      if (dut.g_iter.pack_scan.lead_valid !== 1'b1 ||
          ^dut.g_iter.pack_scan.e === 1'bx)
        $fatal(1, "normal scan payload missing lead/e metadata");
      wait_state(STATE_PACK_PRE, 8, "normal classify");
      if (dut.g_iter.pack_pre.lead_valid !== 1'b1 ||
          dut.g_iter.pack_pre.is_zero !== 1'b0 ||
          dut.g_iter.pack_pre.is_tiny !== 1'b0 ||
          dut.g_iter.pack_pre.e !== dut.g_iter.pack_scan.e)
        $fatal(1, "normal classification metadata mismatch");
      wait_state(STATE_PACK, 8, "normal normalize");
      wait_state(STATE_PACK_RESULT, 8, "normal registered result");
      if (!iter_done || result !== 64'h0000_0000_4040_0000 ||
          fpsr_flags !== 32'd0)
        $fatal(1, "normal stage result mismatch: bits=%016h flags=%08h",
               result, fpsr_flags);
      finish_and_idle();
      $display("PASS R18 normal scan/classify/normalize boundary");
    end
  endtask

  task automatic tiny_stage_probe;
    begin
      set_add(64'h0000_0000_0000_0001, 64'h0000_0000_0000_0000);
      wait_state(STATE_PACK_SCAN, 16, "tiny scan");
      if (dut.g_iter.pack_scan.lead_valid !== 1'b1 ||
          dut.g_iter.pack_scan.is_zero !== 1'b0)
        $fatal(1, "tiny scan payload missing lead metadata");
      wait_state(STATE_PACK_PRE, 8, "tiny classify");
      if (dut.g_iter.pack_pre.is_tiny !== 1'b1)
        $fatal(1, "tiny classification did not cross scan register");
      wait_state(STATE_PACK, 8, "tiny normalize");
      wait_state(STATE_PACK_RESULT, 8, "tiny registered result");
      if (!iter_done || result !== 64'h0000_0000_0000_0001 ||
          fpsr_flags !== 32'd0)
        $fatal(1, "tiny stage result mismatch: bits=%016h flags=%08h",
               result, fpsr_flags);
      finish_and_idle();
      $display("PASS R18 tiny raw-bit/flags path");
    end
  endtask

  // Pause in the new scan state must hold the registered payload and must not
  // re-read live operands when the pause is released.
  task automatic pause_scan_probe;
    begin
      set_add(64'h0000_0000_3f80_0000, 64'h0000_0000_3380_0000);
      fpcr = 32'h0040_0000; // toward +Inf: original result is 1.0000001
      wait_state(STATE_PACK_SCAN, 16, "pause scan");
      @(negedge clk);
      iter_pause = 1'b1;
      operand_a = 64'h0000_0000_4000_0000;
      operand_b = 64'h0000_0000_4040_0000;
      repeat (2) begin
        @(posedge clk);
        #1;
        if (dut.g_iter.it_state_r !== STATE_PACK_SCAN || iter_done ||
            result !== 64'd0 || fpsr_flags !== 32'd0)
          $fatal(1, "pause changed/consumed scan payload");
      end
      @(negedge clk);
      iter_pause = 1'b0;
      wait_state(STATE_PACK_PRE, 8, "pause release classify");
      wait_state(STATE_PACK, 8, "pause release normalize");
      wait_state(STATE_PACK_RESULT, 8, "pause release registered result");
      if (!iter_done || result !== 64'h0000_0000_3f80_0001 ||
          fpsr_flags !== 32'h0000_0010)
        $fatal(1, "pause scan release mismatch: bits=%016h flags=%08h",
               result, fpsr_flags);
      finish_and_idle();
      $display("PASS R18 IT_PACK_SCAN pause/hold/release");
    end
  endtask

  // Kill has priority over pause at the new boundary; the replacement
  // transaction must not observe any stale scan/pre/mid payload.
  task automatic kill_reissue_probe;
    begin
      set_add(64'h0000_0000_3f80_0000, 64'h0000_0000_4000_0000);
      wait_state(STATE_PACK_SCAN, 16, "kill scan");
      @(negedge clk);
      valid = 1'b0;
      iter_pause = 1'b1;
      iter_kill = 1'b1;
      @(posedge clk);
      #1;
      iter_kill = 1'b0;
      iter_pause = 1'b0;
      if (iter_busy || iter_done || result !== 64'd0 ||
          dut.g_iter.it_state_r !== 4'd0 ||
          dut.g_iter.pack_scan.lead_valid !== 1'b0)
        $fatal(1, "kill did not clear scan state/payload");

      @(negedge clk);
      set_add(64'h0000_0000_4000_0000, 64'h0000_0000_4040_0000);
      wait_done(64'h0000_0000_40a0_0000, 32'd0,
                "kill replacement add");
      finish_and_idle();
      $display("PASS R18 IT_PACK_SCAN kill/reissue");
    end
  endtask

  // Reset while IT_PACK_PRE is active must clear both the new scan register
  // and the existing classification/normalization payload before reissue.
  task automatic reset_reissue_probe;
    begin
      set_add(64'h0000_0000_3f80_0000, 64'h0000_0000_4000_0000);
      wait_state(STATE_PACK_PRE, 16, "reset classify");
      @(negedge clk);
      valid = 1'b0;
      rst_n = 1'b0;
      #1;
      if (iter_busy || iter_done || result !== 64'd0 ||
          dut.g_iter.it_state_r !== 4'd0 ||
          dut.g_iter.pack_scan.lead_valid !== 1'b0 ||
          dut.g_iter.pack_pre.lead_valid !== 1'b0)
        $fatal(1, "reset did not clear R18 payload");
      rst_n = 1'b1;
      @(negedge clk);
      set_add(64'h0000_0000_4000_0000, 64'h0000_0000_4040_0000);
      wait_done(64'h0000_0000_40a0_0000, 32'd0,
                "reset replacement add");
      finish_and_idle();
      $display("PASS R18 scan/classify reset/reissue");
    end
  endtask

  // Valid-drop is checked at IT_PACK_SCAN specifically.  DIV/SQRT are not
  // sent through this state; their nominal latency remains the registered
  // 261/518 (DIV S/D/H) and 69/70 (SQRT S/D/H) contract documented in the
  // task handoff.
  task automatic valid_drop_reissue_probe;
    begin
      set_add(64'h0000_0000_3f80_0000, 64'h0000_0000_4000_0000);
      wait_state(STATE_PACK_SCAN, 16, "drop scan");
      @(negedge clk);
      valid = 1'b0;
      @(posedge clk);
      #1;
      if (iter_busy || iter_done || result !== 64'd0 ||
          dut.g_iter.it_state_r !== 4'd0 ||
          dut.g_iter.pack_scan.lead_valid !== 1'b0)
        $fatal(1, "valid drop did not clear R18 scan payload");
      @(negedge clk);
      set_add(64'h0000_0000_4000_0000, 64'h0000_0000_4040_0000);
      wait_done(64'h0000_0000_40a0_0000, 32'd0,
                "valid-drop replacement add");
      finish_and_idle();
      $display("PASS R18 IT_PACK_SCAN valid-drop/reissue");
    end
  endtask

  // Exercise the round18 scan function directly so every possible leading
  // bit is checked independently of the arithmetic producer.  The function
  // is pure metadata construction; packed mirrors of its private payload
  // types compare the balanced encoder without adding a test-only RTL port or
  // changing the transaction latency.
  task automatic balanced_scan_equivalence;
    logic [255:0] value;
    fp_pre_probe_t pre;
    fp_scan_probe_t scan;
    integer       pos;
    integer       fmt_i;
    integer       expected_e;
    begin
      // All-zero input must remain a zero classification with no lead/e.
      pre = '0;
      pre.is_special = 1'b0;
      pre.exp2 = 17;
      pre.sig = 256'd0;
      pre.lead_valid = 1'b0;
      scan = dut.round_pack_scan(pre);
      if (scan.lead_valid !== 1'b0 ||
          scan.is_zero !== 1'b1 ||
          scan.lead !== 8'd0 ||
          scan.e !== 0 ||
          scan.exp2 !== 17)
        $fatal(1, "balanced scan zero mismatch: lead_valid=%b zero=%b lead=%0d e=%0d exp2=%0d",
               scan.lead_valid, scan.is_zero, scan.lead, scan.e, scan.exp2);

      // Special results bypass the magnitude scan even when sig is nonzero.
      pre = '0;
      pre.is_special = 1'b1;
      pre.special.bits = 64'h0123_4567_89ab_cdef;
      pre.special.flags = 32'h0000_0011;
      pre.sig = 256'h1;
      pre.exp2 = -9;
      scan = dut.round_pack_scan(pre);
      if (scan.lead_valid !== 1'b0 ||
          scan.is_zero !== 1'b0 ||
          scan.e !== 0 ||
          scan.special_bits !== 64'h0123_4567_89ab_cdef ||
          scan.special_flags !== 32'h0000_0011)
        $fatal(1, "balanced scan special bypass mismatch");

      // A predecoded iterative lead must continue to bypass the new encoder.
      pre = '0;
      pre.is_special = 1'b0;
      pre.sig = 256'h8;
      pre.exp2 = -10;
      pre.lead = 8'd200;
      pre.lead_valid = 1'b1;
      scan = dut.round_pack_scan(pre);
      if (scan.lead_valid !== 1'b1 ||
          scan.lead !== 8'd200 ||
          scan.e !== 190)
        $fatal(1, "balanced scan predecoded lead mismatch: lead=%0d e=%0d",
               scan.lead, scan.e);

      // Repeat all 256 leading positions for H, S and D metadata.  Each vector
      // also sets the immediately lower bit, exercising highest-bit priority
      // when more than one group/bit is valid.  A paired H operation invokes
      // this same function once per lane, so the checks remain lane-local and
      // do not change the paired latency.
      for (fmt_i = 0; fmt_i < 3; fmt_i = fmt_i + 1) begin
        for (pos = 0; pos < 256; pos = pos + 1) begin
          value = 256'd0;
          value[pos] = 1'b1;
          if (pos > 0)
            value[pos - 1] = 1'b1;
          pre = '0;
          pre.is_special = 1'b0;
          pre.sig = value;
          pre.exp2 = -37;
          pre.sign = pos[0];
          pre.lead_valid = 1'b0;
          case (fmt_i)
            0: pre.fmt = 2'd0;
            1: pre.fmt = 2'd1;
            default: pre.fmt = 2'd2;
          endcase
          scan = dut.round_pack_scan(pre);
          expected_e = -37 + pos;
          if (scan.lead_valid !== 1'b1 ||
              scan.is_zero !== 1'b0 ||
              scan.lead !== pos[7:0] ||
              scan.e !== expected_e ||
              scan.exp2 !== -37 ||
              scan.sign !== pos[0] ||
              scan.sig !== value ||
              scan.fmt !== pre.fmt)
            $fatal(1, "balanced scan lead mismatch fmt=%0d pos=%0d lead=%0d e=%0d",
                   fmt_i, pos, scan.lead, scan.e);
        end
      end
      $display("PASS R19 balanced scan zero/special/predecoded/all-leads H-S-D");
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
    normal_stage_probe();
    tiny_stage_probe();
    pause_scan_probe();
    kill_reissue_probe();
    reset_reissue_probe();
    valid_drop_reissue_probe();
    balanced_scan_equivalence();
    $display("PASS: R18 FP scalar prescan-cut focused vectors");
    $finish;
  end
endmodule
