// R20 FP scalar arithmetic-route closure focused test.
//
// This direct FP_ITER probe observes the private route state so that every
// supported non-half IT_ARITH operation is checked against its dedicated
// pipeline state.  Functional checks still compare raw IEEE bits/flags only;
// no host floating-point value is used as an oracle.

`timescale 1ns/1ps
/* verilator lint_off UNUSEDSIGNAL */
/* The illegal-route probe intentionally forces one private field. */
/* verilator lint_off MULTIDRIVEN */

module lcvex_fp_scalar_r20_route_tb;
  import lcvex_pkg::*;

  localparam logic [3:0] STATE_IDLE  = 4'd0;
  localparam logic [3:0] STATE_ARITH = 4'd4;
  localparam logic [3:0] STATE_PREP  = 4'd3;
  localparam logic [3:0] STATE_MUL   = 4'd6;
  localparam logic [3:0] STATE_ALIGN = 4'd8;

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

  task automatic set_request(
      input fp_op_t      op_i,
      input logic        half_i,
      input logic        dbl_i,
      input logic [63:0] a_i,
      input logic [63:0] b_i,
      input logic [63:0] c_i,
      input logic [63:0] conv_i,
      input logic [6:0]  shift_i);
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
      conv_int        = conv_i;
      conv_shift      = shift_i;
      conv_is_32      = 1'b0;
      fpcr            = 32'd0;
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

  task automatic wait_done(
      input logic [63:0] want_bits,
      input logic [31:0] want_flags,
      input string       name);
    integer waited;
    begin
      waited = 0;
      while (!iter_done) begin
        @(posedge clk);
        #1;
        waited = waited + 1;
        if (waited > 64)
          $fatal(1, "%s done timeout", name);
      end
      if (result !== want_bits || fpsr_flags !== want_flags ||
          int_result !== 64'd0)
        $fatal(1,
               "%s raw mismatch: got bits=%016h flags=%08h int=%016h want bits=%016h flags=%08h",
               name, result, fpsr_flags, int_result, want_bits, want_flags);
    end
  endtask

  task automatic finish_and_idle;
    begin
      @(negedge clk);
      valid      = 1'b0;
      iter_pause = 1'b0;
      iter_kill  = 1'b0;
      @(posedge clk);
      #1;
      if (iter_busy || iter_done || dut.g_iter.it_state_r !== STATE_IDLE ||
          result !== 64'd0 || fpsr_flags !== 32'd0)
        $fatal(1, "transaction did not return to idle cleanly");
    end
  endtask

  // These nine entries are the complete non-half IT_ARITH input set.  The
  // route check below doubles as an executable exhaustive table: any missing
  // operation leaves route_seen incomplete and fails the test.
  logic [8:0] route_seen;

  task automatic mark_route(input fp_op_t op_i);
    begin
      case (op_i)
        FP_OP_ADD:    route_seen[0] = 1'b1;
        FP_OP_SUB:    route_seen[1] = 1'b1;
        FP_OP_MUL:    route_seen[2] = 1'b1;
        FP_OP_FMADD:  route_seen[3] = 1'b1;
        FP_OP_FMSUB:  route_seen[4] = 1'b1;
        FP_OP_FNMADD: route_seen[5] = 1'b1;
        FP_OP_FNMSUB: route_seen[6] = 1'b1;
        FP_OP_SCVTF:  route_seen[7] = 1'b1;
        FP_OP_UCVTF:  route_seen[8] = 1'b1;
        default:      $fatal(1, "unexpected op in exhaustive route table: %0d", op_i);
      endcase
    end
  endtask

  task automatic check_nonhalf_route(
      input fp_op_t      op_i,
      input logic [3:0]  want_route,
      input logic [63:0] a_i,
      input logic [63:0] b_i,
      input logic [63:0] c_i,
      input logic [63:0] conv_i,
      input logic [6:0]  shift_i,
      input logic [63:0] want_bits,
      input logic [31:0] want_flags,
      input string       name);
    begin
      set_request(op_i, 1'b0, 1'b0, a_i, b_i, c_i, conv_i, shift_i);
      wait_state(STATE_ARITH, 8, {name, " arith"});
      if (dut.g_iter.ap_pre.op !== op_i || dut.g_iter.ap_pre.fmt !== 2'd1)
        $fatal(1, "%s did not capture the requested non-half operation", name);
      @(posedge clk);
      #1;
      if (dut.g_iter.it_state_r !== want_route)
        $fatal(1, "%s route mismatch: got=%0d want=%0d", name,
               dut.g_iter.it_state_r, want_route);
      mark_route(op_i);
      wait_done(want_bits, want_flags, name);
      finish_and_idle();
    end
  endtask

  // The half implementation must remain on its existing two-lane path and
  // must not be captured by the non-half case below it.
  task automatic half_path_probe;
    begin
      set_request(FP_OP_ADD, 1'b1, 1'b0,
                  64'h0000_0000_3c00_3c00,
                  64'h0000_0000_3400_4000,
                  64'd0, 64'd0, 7'd0);
      wait_state(STATE_ARITH, 8, "half add arith");
      if (dut.g_iter.ap_pre_lo.op !== FP_OP_ADD ||
          dut.g_iter.ap_pre_hi.op !== FP_OP_ADD)
        $fatal(1, "half ADD did not preserve both captured lane operations");
      @(posedge clk);
      #1;
      if (dut.g_iter.it_state_r !== STATE_ALIGN ||
          dut.g_iter.add_align_lo === '0 || dut.g_iter.add_align_hi === '0)
        $fatal(1, "half ADD left the existing two-lane alignment route");
      wait_done(64'h0000_0000_3d00_4200, 32'd0, "half add");
      finish_and_idle();

      set_request(FP_OP_FMADD, 1'b1, 1'b0,
                  64'h0000_0000_4000_4000,
                  64'h0000_0000_4200_4200,
                  64'h0000_0000_4900_4900,
                  64'd0, 7'd0);
      wait_state(STATE_ARITH, 8, "half fma arith");
      @(posedge clk);
      #1;
      if (dut.g_iter.it_state_r !== STATE_MUL)
        $fatal(1, "half FMA left the existing multiplier route");
      wait_done(64'h0000_0000_4c00_4c00, 32'd0, "half fma");
      finish_and_idle();
    end
  endtask

  // Pause at IT_ARITH must hold the captured operand payload and delay the
  // route transition; changing live operands while paused must not matter.
  task automatic pause_probe;
    logic [63:0] held_a;
    begin
      set_request(FP_OP_ADD, 1'b0, 1'b0,
                  64'h0000_0000_3f80_0000,
                  64'h0000_0000_4000_0000,
                  64'd0, 64'd0, 7'd0);
      wait_state(STATE_ARITH, 8, "pause arith");
      held_a = dut.g_iter.ap_pre.a_bits;
      @(negedge clk);
      iter_pause = 1'b1;
      operand_a = 64'h0000_0000_4040_0000;
      operand_b = 64'h0000_0000_4080_0000;
      repeat (2) begin
        @(posedge clk);
        #1;
        if (dut.g_iter.it_state_r !== STATE_ARITH || iter_done ||
            dut.g_iter.ap_pre.a_bits !== held_a)
          $fatal(1, "IT_ARITH pause changed route or captured payload");
      end
      @(negedge clk);
      iter_pause = 1'b0;
      @(posedge clk);
      #1;
      if (dut.g_iter.it_state_r !== STATE_ALIGN)
        $fatal(1, "IT_ARITH pause release did not select ADD/SUB route");
      wait_done(64'h0000_0000_4040_0000, 32'd0, "pause add release");
      finish_and_idle();
    end
  endtask

  task automatic kill_probe;
    begin
      set_request(FP_OP_MUL, 1'b0, 1'b0,
                  64'h0000_0000_4000_0000,
                  64'h0000_0000_4040_0000,
                  64'd0, 64'd0, 7'd0);
      wait_state(STATE_ARITH, 8, "kill arith");
      @(negedge clk);
      valid      = 1'b0;
      iter_pause = 1'b1;
      iter_kill  = 1'b1;
      @(posedge clk);
      #1;
      iter_kill  = 1'b0;
      iter_pause = 1'b0;
      if (iter_busy || iter_done || dut.g_iter.it_state_r !== STATE_IDLE ||
          result !== 64'd0 || fpsr_flags !== 32'd0 ||
          dut.g_iter.ap_pre !== '0)
        $fatal(1, "IT_ARITH kill did not clear state/payload");

      @(negedge clk);
      set_request(FP_OP_MUL, 1'b0, 1'b0,
                  64'h0000_0000_4000_0000,
                  64'h0000_0000_4040_0000,
                  64'd0, 64'd0, 7'd0);
      wait_done(64'h0000_0000_40c0_0000, 32'd0, "kill replacement mul");
      finish_and_idle();
    end
  endtask

  task automatic reset_probe;
    begin
      set_request(FP_OP_SUB, 1'b0, 1'b0,
                  64'h0000_0000_4040_0000,
                  64'h0000_0000_3f80_0000,
                  64'd0, 64'd0, 7'd0);
      wait_state(STATE_ARITH, 8, "reset arith");
      @(negedge clk);
      valid = 1'b0;
      rst_n = 1'b0;
      #1;
      if (iter_busy || iter_done || dut.g_iter.it_state_r !== STATE_IDLE ||
          result !== 64'd0 || fpsr_flags !== 32'd0 ||
          dut.g_iter.ap_pre !== '0)
        $fatal(1, "IT_ARITH reset did not clear state/payload");
      rst_n = 1'b1;

      @(negedge clk);
      set_request(FP_OP_SUB, 1'b0, 1'b0,
                  64'h0000_0000_4040_0000,
                  64'h0000_0000_3f80_0000,
                  64'd0, 64'd0, 7'd0);
      wait_done(64'h0000_0000_4000_0000, 32'd0, "reset replacement sub");
      finish_and_idle();
    end
  endtask

  task automatic valid_drop_probe;
    begin
      set_request(FP_OP_SCVTF, 1'b0, 1'b0,
                  64'd0, 64'd0, 64'd0, 64'd3, 7'd1);
      wait_state(STATE_ARITH, 8, "valid-drop arith");
      @(negedge clk);
      valid = 1'b0;
      @(posedge clk);
      #1;
      if (iter_busy || iter_done || dut.g_iter.it_state_r !== STATE_IDLE ||
          result !== 64'd0 || fpsr_flags !== 32'd0)
        $fatal(1, "IT_ARITH valid drop produced stale completion");

      @(negedge clk);
      set_request(FP_OP_SCVTF, 1'b0, 1'b0,
                  64'd0, 64'd0, 64'd0, 64'd3, 7'd1);
      wait_done(64'h0000_0000_3fc0_0000, 32'd0,
                "valid-drop replacement SCVTF");
      finish_and_idle();
    end
  endtask

  // Force an impossible captured operation after a valid request has entered
  // IT_ARITH.  The route default must preserve the IT_PREP boundary without
  // doing arithmetic, with a known zero payload and the existing invalid-op
  // completion behavior.
  task automatic illegal_default_probe;
    begin
      set_request(FP_OP_ADD, 1'b0, 1'b0,
                  64'h0000_0000_3f80_0000,
                  64'h0000_0000_4000_0000,
                  64'd0, 64'd0, 7'd0);
      wait_state(STATE_ARITH, 8, "default arith");
      @(negedge clk);
      op = FP_OP_NONE;
      force dut.g_iter.ap_pre.op = FP_OP_NONE;
      @(posedge clk);
      #1;
      release dut.g_iter.ap_pre.op;
      if (dut.g_iter.it_state_r !== STATE_PREP || !iter_busy || iter_done ||
          result !== 64'd0 || fpsr_flags !== 32'd0 ||
          dut.g_iter.pp_pre !== '0)
        $fatal(1, "illegal IT_ARITH default did not preserve prep/zero");
      @(posedge clk);
      #1;
      if (iter_busy || !iter_done || dut.g_iter.it_state_r !== STATE_IDLE ||
          result !== 64'd0 || fpsr_flags !== 32'd0)
        $fatal(1, "illegal IT_ARITH default did not finish deterministic zero");
      finish_and_idle();
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
    route_seen      = 9'd0;

    repeat (2) @(posedge clk);
    #1;
    rst_n = 1'b1;
    @(negedge clk);

    // ADD/SUB -> IT_ALIGN.
    check_nonhalf_route(FP_OP_ADD, STATE_ALIGN,
                        64'h0000_0000_3f80_0000,
                        64'h0000_0000_4000_0000,
                        64'd0, 64'd0, 7'd0,
                        64'h0000_0000_4040_0000, 32'd0, "non-half ADD");
    check_nonhalf_route(FP_OP_SUB, STATE_ALIGN,
                        64'h0000_0000_4040_0000,
                        64'h0000_0000_3f80_0000,
                        64'd0, 64'd0, 7'd0,
                        64'h0000_0000_4000_0000, 32'd0, "non-half SUB");

    // MUL/FMA -> IT_MUL.
    check_nonhalf_route(FP_OP_MUL, STATE_MUL,
                        64'h0000_0000_4000_0000,
                        64'h0000_0000_4040_0000,
                        64'd0, 64'd0, 7'd0,
                        64'h0000_0000_40c0_0000, 32'd0, "non-half MUL");
    check_nonhalf_route(FP_OP_FMADD, STATE_MUL,
                        64'h0000_0000_4000_0000,
                        64'h0000_0000_4040_0000,
                        64'h0000_0000_4120_0000, 64'd0, 7'd0,
                        64'h0000_0000_4180_0000, 32'd0, "non-half FMADD");
    check_nonhalf_route(FP_OP_FMSUB, STATE_MUL,
                        64'h0000_0000_4000_0000,
                        64'h0000_0000_4040_0000,
                        64'h0000_0000_4120_0000, 64'd0, 7'd0,
                        64'h0000_0000_4080_0000, 32'd0, "non-half FMSUB");
    check_nonhalf_route(FP_OP_FNMADD, STATE_MUL,
                        64'h0000_0000_4000_0000,
                        64'h0000_0000_4040_0000,
                        64'h0000_0000_4120_0000, 64'd0, 7'd0,
                        64'h0000_0000_c180_0000, 32'd0, "non-half FNMADD");
    check_nonhalf_route(FP_OP_FNMSUB, STATE_MUL,
                        64'h0000_0000_4000_0000,
                        64'h0000_0000_4040_0000,
                        64'h0000_0000_4120_0000, 64'd0, 7'd0,
                        64'h0000_0000_c080_0000, 32'd0, "non-half FNMSUB");

    // SCVTF/UCVTF -> IT_PREP.
    check_nonhalf_route(FP_OP_SCVTF, STATE_PREP,
                        64'd0, 64'd0, 64'd0, 64'd3, 7'd1,
                        64'h0000_0000_3fc0_0000, 32'd0, "non-half SCVTF");
    check_nonhalf_route(FP_OP_UCVTF, STATE_PREP,
                        64'd0, 64'd0, 64'd0, 64'd3, 7'd0,
                        64'h0000_0000_4040_0000, 32'd0, "non-half UCVTF");

    if (route_seen !== 9'b1_1111_1111)
      $fatal(1, "non-half IT_ARITH route set incomplete: seen=%b", route_seen);

    half_path_probe();
    pause_probe();
    kill_probe();
    reset_probe();
    valid_drop_probe();
    illegal_default_probe();

    $display("PASS: R20 scalar non-half route closure/half preservation/default/control probes");
    $finish;
  end
endmodule
/* verilator lint_on MULTIDRIVEN */
