// R21 iterative round-pack metadata focused test.
//
// DIV/SQRT finish already registers the quotient leading-one index.  This
// probe checks that round_pack_iter_p1 treats that metadata as authoritative,
// preserves the round/GRS payload for H/S/D, and keeps the existing iterative
// finish route's result behavior.  The deliberately contradictory zero probe
// catches any reintroduced magnitude scan: lead_valid=0 must remain the
// registered zero classification even when sig has a set bit.

`timescale 1ns/1ps
/* verilator lint_off UNUSEDSIGNAL */

module lcvex_fp_scalar_r21_iter_round_tb;
  import lcvex_pkg::*;

  localparam logic [3:0] STATE_IDLE = 4'd0;
  localparam logic [3:0] STATE_FIN  = 4'd7;
  localparam logic [3:0] STATE_PACK = 4'd12;
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

  typedef struct packed {
    logic [63:0] bits;
    logic [31:0] flags;
    logic [3:0]  nzcv;
  } fp_calc_probe_t;

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
    logic         is_zero;
    logic         is_tiny;
    logic         sign;
    logic [255:0] mant;
    logic         guard;
    logic         sticky;
    logic         discarded;
    integer       e;
    logic [1:0]   fmt;
    logic         flush_zero;
    logic [1:0]   rmode;
    logic         ahp;
  } fp_round_mid_probe_t;

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

  task automatic check_mid_metadata(
      input fp_round_mid_probe_t mid,
      input logic                want_zero,
      input logic                want_tiny,
      input logic                want_sign,
      input integer              want_e,
      input logic                want_guard,
      input logic                want_sticky,
      input logic                want_discarded,
      input string               name);
    begin
      if (mid.is_special !== 1'b0 ||
          mid.is_zero !== want_zero ||
          mid.is_tiny !== want_tiny ||
          mid.sign !== want_sign ||
          mid.e !== want_e ||
          mid.guard !== want_guard ||
          mid.sticky !== want_sticky ||
          mid.discarded !== want_discarded)
        $fatal(1,
               "%s metadata mismatch: special=%b zero=%b tiny=%b sign=%b e=%0d G=%b S=%b D=%b",
               name, mid.is_special, mid.is_zero, mid.is_tiny, mid.sign,
               mid.e, mid.guard, mid.sticky, mid.discarded);
    end
  endtask

  // Check the p1 payload directly.  For H/S/D, the same predecoded h=30
  // places the leading bit at the format's hidden-bit position only for S;
  // use per-format h below so all three normal paths are exercised.
  task automatic predecoded_normal_vectors;
    fp_pre_probe_t       pre;
    fp_round_mid_probe_t mid;
    integer              fmt_i;
    integer              h_i;
    integer              p_i;
    integer              exp_i;
    integer              shift_i;
    logic [255:0]        sig_i;
    begin
      for (fmt_i = 0; fmt_i < 3; fmt_i = fmt_i + 1) begin
        case (fmt_i)
          0: begin h_i = 14; p_i = 11; exp_i = -14; end
          1: begin h_i = 30; p_i = 24; exp_i = -30; end
          default: begin h_i = 59; p_i = 53; exp_i = -59; end
        endcase
        shift_i = h_i - (p_i - 1);
        sig_i = 256'd0;
        sig_i[h_i] = 1'b1;
        sig_i[shift_i - 1] = 1'b1; // guard
        sig_i[shift_i - 3] = 1'b1; // sticky below guard
        pre = '0;
        pre.sign = fmt_i[0];
        pre.sig = sig_i;
        pre.exp2 = exp_i;
        pre.fmt = fmt_i[1:0];
        pre.lead = h_i[7:0];
        pre.lead_valid = 1'b1;
        mid = dut.round_pack_iter_p1(pre);
        check_mid_metadata(mid, 1'b0, 1'b0, fmt_i[0], 0,
                           1'b1, 1'b1, 1'b1,
                           (fmt_i == 0) ? "H predecoded normal" :
                           (fmt_i == 1) ? "S predecoded normal" :
                                           "D predecoded normal");
        if (mid.mant !== (sig_i >> shift_i) ||
            mid.fmt !== fmt_i[1:0] ||
            mid.input_flags !== 32'd0)
          $fatal(1, "predecoded normal payload mismatch fmt=%0d", fmt_i);
      end
      $display("PASS R21 H/S/D predecoded normal GRS metadata");
    end
  endtask

  // lead_valid is the producer contract.  A set bit in sig with a cleared
  // validity bit must not be rediscovered by a second priority scan.
  task automatic zero_metadata_vectors;
    fp_pre_probe_t       pre;
    fp_round_mid_probe_t mid;
    fp_calc_probe_t      calc;
    integer              fmt_i;
    begin
      for (fmt_i = 0; fmt_i < 3; fmt_i = fmt_i + 1) begin
        pre = '0;
        pre.sign = 1'b1;
        pre.sig = 256'h1; // intentionally contradictory to lead_valid=0
        pre.exp2 = 0;
        pre.fmt = fmt_i[1:0];
        pre.lead = 8'hff;
        pre.lead_valid = 1'b0;
        mid = dut.round_pack_iter_p1(pre);
        check_mid_metadata(mid, 1'b1, 1'b0, 1'b1, 0,
                           1'b0, 1'b0, 1'b0,
                           (fmt_i == 0) ? "H metadata zero" :
                           (fmt_i == 1) ? "S metadata zero" :
                                           "D metadata zero");
        calc = dut.round_pack_p2(mid);
        case (fmt_i)
          0: if (calc.bits !== 64'h0000_0000_0000_8000) $fatal(1, "H zero sign mismatch");
          1: if (calc.bits !== 64'h0000_0000_8000_0000) $fatal(1, "S zero sign mismatch");
          default: if (calc.bits !== 64'h8000_0000_0000_0000) $fatal(1, "D zero sign mismatch");
        endcase
      end
      $display("PASS R21 lead_valid=0 authoritative zero/no fallback scan");
    end
  endtask

  task automatic special_vectors;
    fp_pre_probe_t       pre;
    fp_round_mid_probe_t mid;
    fp_calc_probe_t      calc;
    integer              fmt_i;
    begin
      for (fmt_i = 0; fmt_i < 3; fmt_i = fmt_i + 1) begin
        pre = '0;
        pre.is_special = 1'b1;
        pre.special.bits = 64'h0000_0000_0000_7e01;
        pre.special.flags = 32'h0000_0001;
        pre.input_flags = 32'h0000_0010;
        pre.sig = 256'h1; // special path must bypass magnitude metadata
        pre.fmt = fmt_i[1:0];
        mid = dut.round_pack_iter_p1(pre);
        if (mid.is_special !== 1'b1 ||
            mid.special_bits !== pre.special.bits ||
            mid.special_flags !== pre.special.flags ||
            mid.input_flags !== pre.input_flags)
          $fatal(1, "special metadata mismatch fmt=%0d", fmt_i);
        calc = dut.round_pack_p2(mid);
        if (calc.bits !== pre.special.bits ||
            calc.flags !== (pre.special.flags | pre.input_flags))
          $fatal(1, "special final mismatch fmt=%0d bits=%016h flags=%08h",
                 fmt_i, calc.bits, calc.flags);
      end
      $display("PASS R21 H/S/D special bypass and input flags");
    end
  endtask

  task automatic tiny_and_rounding_vectors;
    fp_pre_probe_t       pre;
    fp_round_mid_probe_t mid;
    fp_calc_probe_t      calc;
    begin
      // S tiny: e=-154 is below emin=-126.  The predecoded lead is used to
      // classify tiny, and a discarded low bit is retained for UFC|IXC.
      pre = '0;
      pre.sig = 256'h0000_0000_0000_0000_0000_0000_0000_0000_0000_0000_0000_0000_0000_0000_0000_0040;
      pre.exp2 = -160;
      pre.fmt = 2'd1;
      pre.lead = 8'd6;
      pre.lead_valid = 1'b1;
      mid = dut.round_pack_iter_p1(pre);
      check_mid_metadata(mid, 1'b0, 1'b1, 1'b0, -154,
                         1'b0, 1'b1, 1'b1, "S tiny sticky");
      calc = dut.round_pack_p2(mid);
      if (calc.bits !== 64'h0000_0000_0000_0000 ||
          calc.flags !== 32'h0000_0018)
        $fatal(1, "S tiny sticky mismatch bits=%016h flags=%08h",
               calc.bits, calc.flags);

      // S normal round-to-nearest tie with odd retained mantissa.  h=30 and
      // shift=7: bit 7 makes mantissa LSB odd, bit 6 is guard, no lower bits
      // are set, so p2 must increment once and set IXC.
      pre = '0;
      pre.sig = 256'h0000_0000_0000_0000_0000_0000_0000_0000_0000_0000_0000_0000_0000_0000_4000_00c0;
      pre.exp2 = -30;
      pre.fmt = 2'd1;
      pre.lead = 8'd30;
      pre.lead_valid = 1'b1;
      mid = dut.round_pack_iter_p1(pre);
      check_mid_metadata(mid, 1'b0, 1'b0, 1'b0, 0,
                         1'b1, 1'b0, 1'b1, "S normal tie rounding");
      if (mid.mant[0] !== 1'b1)
        $fatal(1, "S tie vector did not retain odd mantissa");
      calc = dut.round_pack_p2(mid);
      if (calc.bits !== 64'h0000_0000_3f80_0002 ||
          calc.flags !== 32'h0000_0010)
        $fatal(1, "S tie rounding mismatch bits=%016h flags=%08h",
               calc.bits, calc.flags);
      $display("PASS R21 tiny/sticky/rounding p1->p2 behavior");
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

  task automatic start_iter(
      input fp_op_t      op_i,
      input logic        half_i,
      input logic        dbl_i,
      input logic [63:0] a_i,
      input logic [63:0] b_i);
    begin
      valid = 1'b1;
      op = op_i;
      is_half = half_i;
      is_double = dbl_i;
      fcvt_dst_half = 1'b0;
      rint_mode = 3'd0;
      operand_a = a_i;
      operand_b = b_i;
      operand_c = 64'd0;
      conv_int = 64'd0;
      conv_shift = 7'd0;
      conv_is_32 = 1'b0;
      fpcr = 32'd0;
      compare_zero = 1'b0;
      signal_all_nans = 1'b0;
      iter_kill = 1'b0;
      iter_pause = 1'b0;
    end
  endtask

  task automatic iterative_finish_metadata_probe;
    begin
      // 2.0 / 1.0: a finite normal DIV must carry a registered lead into
      // IT_FIN, and p1 must classify the captured payload as nonzero.
      start_iter(FP_OP_DIV, 1'b0, 1'b0,
                 64'h0000_0000_4000_0000,
                 64'h0000_0000_3f80_0000);
      wait_state(STATE_FIN, 400, "DIV finish metadata");
      if (dut.g_iter.div_pre.is_special !== 1'b0 ||
          dut.g_iter.div_pre.lead_valid !== 1'b1 ||
          (|dut.g_iter.div_pre.sig) !== 1'b1)
        $fatal(1, "DIV finish did not register normal lead metadata");
      wait_state(STATE_PACK, 8, "DIV iterative p1");
      if (dut.g_iter.it_fin_mid_r.is_special !== 1'b0 ||
          dut.g_iter.it_fin_mid_r.is_zero !== 1'b0 ||
          dut.g_iter.it_fin_mid_r.is_tiny !== 1'b0)
        $fatal(1, "DIV p1 metadata changed normal classification");
      wait_state(STATE_PACK_RESULT, 8, "DIV result boundary");
      if (!iter_done || result !== 64'h0000_0000_4000_0000 ||
          fpsr_flags !== 32'd0)
        $fatal(1, "DIV result mismatch bits=%016h flags=%08h", result,
               fpsr_flags);
      valid = 1'b0;
      @(posedge clk);
      #1;
      if (dut.g_iter.it_state_r !== STATE_IDLE || iter_done)
        $fatal(1, "DIV finish probe did not return idle exactly once");

      // sqrt(1.0), sqrt(4.0) in paired H lanes must each carry independent
      // predecoded metadata through the same p1 function.
      start_iter(FP_OP_SQRT, 1'b1, 1'b0,
                 64'h0000_0000_3c00_4400, 64'd0);
      wait_state(STATE_FIN, 160, "SQRT H finish metadata");
      if (dut.g_iter.sqrt_pre_lo.is_special !== 1'b0 ||
          dut.g_iter.sqrt_pre_hi.is_special !== 1'b0 ||
          dut.g_iter.sqrt_pre_lo.lead_valid !== 1'b1 ||
          dut.g_iter.sqrt_pre_hi.lead_valid !== 1'b1)
        $fatal(1, "SQRT H finish did not register both lead metadata lanes");
      wait_state(STATE_PACK, 8, "SQRT H iterative p1");
      if (dut.g_iter.it_fin_mid_lo.is_zero !== 1'b0 ||
          dut.g_iter.it_fin_mid_hi.is_zero !== 1'b0)
        $fatal(1, "SQRT H p1 metadata changed normal classification");
      wait_state(STATE_PACK_RESULT, 8, "SQRT H result boundary");
      if (!iter_done || result !== 64'h0000_0000_3c00_4000 ||
          fpsr_flags !== 32'd0)
        $fatal(1, "SQRT H result mismatch bits=%016h flags=%08h", result,
               fpsr_flags);
      valid = 1'b0;
      @(posedge clk);
      #1;
      if (dut.g_iter.it_state_r !== STATE_IDLE || iter_done)
        $fatal(1, "SQRT H finish probe did not return idle exactly once");
      $display("PASS R21 DIV/SQRT finish lead metadata and latency route");
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

    predecoded_normal_vectors();
    zero_metadata_vectors();
    special_vectors();
    tiny_and_rounding_vectors();

    #12;
    rst_n = 1'b1;
    @(negedge clk);
    iterative_finish_metadata_probe();
    $display("PASS: R21 iterative round-pack metadata focused vectors");
    $finish;
  end
endmodule
