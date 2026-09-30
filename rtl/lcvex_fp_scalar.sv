// lcvex_fp_scalar.sv
//
// P7-1 的受限 FP32/FP64 标量执行单元。输入、输出和异常结果全部按
// IEEE-754 编码的 raw bits 处理；模块内没有 real/shortreal、host float
// 或容差比较。实现使用固定宽度整数中间值，便于综合和独立 RTL 测试。
//
// 支持：FMOV（寄存器/立即数由上游展开）、FADD、FSUB、FMUL、FDIV、FCMP、
// FMADD/FMSUB/FNMADD/FNMSUB（P7-4 fused FMA 四族）、SCVTF/UCVTF、
// FCVTZS/FCVTZU（整数/定点）、FCVT S<->D、FP16（H）算术、FSQRT、
// FMIN/FMAX/FMINNM/FMAXNM 与 FRINTN/Z/P/M/A/I/X。
// 不支持：estimate、NEON/SVE 以及 FP exception enable trap。
// FP16 向量按 32-bit 槽承载两个 16-bit lane：is_half=1 时 ADD/SUB/MUL/
// DIV/compare/sqrt/min/max/rint 对 operand_a/b 的低 32 位执行两个独立
// 半精度运算，结果打包在 result[31:0]；FCVT/MOV 仍只处理低位 lane。

`timescale 1ns/1ps

/* The architectural FPCR is intentionally a full 32-bit port. P7-1 only
 * consumes the documented DN/FZ/RMode bits; the remaining reserved/exception
 * enable fields are preserved by lcvex_fp_state but not implemented here. */
/* verilator lint_off UNUSEDSIGNAL */

module lcvex_fp_scalar #(
    // FP_ITER=1 selects the release shared-lane iterative sqrt/div path.
    // FP_ITER=0 preserves the legacy combinational/reference formatter path
    // used by standalone raw-bit NEON tests.
    parameter bit FP_ITER = 1'b0
) (
    input  logic                  clk,
    input  logic                  rst_n,
    input  logic                  valid,
    input  lcvex_pkg::fp_op_t     op,
    input  logic                  is_double,
    input  logic                  is_half,
    input  logic                  fcvt_dst_half,  // FCVT 目的为 H
    input  logic [2:0]            rint_mode,      // 0=N 1=P 2=M 3=Z 4=A 5=X 6=I
    input  logic [63:0]           operand_a,
    input  logic [63:0]           operand_b,
    input  logic [63:0]           operand_c,   // FMA addend（Ra/Sa）
    input  logic [63:0]           conv_int,    // 整数/定点 -> FP 的整数源
    input  logic [6:0]            conv_shift,  // 定点 scale 0..64
    input  logic                  conv_is_32,  // W 形式饱和/零扩展
    input  logic [31:0]           fpcr,
    input  logic                  compare_zero,
    input  logic                  signal_all_nans,
    // FP-ITER control/output. Only meaningful when FP_ITER=1. Legacy
    // FP_ITER=0 callers may leave these unused ports unconnected because the
    // iterative generate block is not elaborated; every FP_ITER=1 caller
    // connects both controls explicitly.
    input  logic                  iter_kill,
    input  logic                  iter_pause,
    output logic                  iter_busy,
    output logic                  iter_done,
    output logic [63:0]           result,
    output logic [63:0]           int_result,  // FP -> 整数结果（W 零扩展）
    output logic [31:0]           fpsr_flags,
    output logic [3:0]            cmp_nzcv,
    output logic                  div_busy,
    output logic                  div_done
);

  import lcvex_pkg::*;

  typedef enum logic [1:0] {
    FMT_HALF   = 2'd0,
    FMT_SINGLE = 2'd1,
    FMT_DOUBLE = 2'd2
  } fp_fmt_t;

  localparam integer FP_W = 256;
  // Addition retains substantially more than the p-bit significand. This is
  // important for cancellation: three GRS bits alone are insufficient when
  // two close operands have different exponents.
  localparam integer ADD_EXTRA = 128;
  localparam integer DIV_EXTRA = 128;

  localparam logic [31:0] FPSR_IOC = 32'h0000_0001;
  localparam logic [31:0] FPSR_DZC = 32'h0000_0002;
  localparam logic [31:0] FPSR_OFC = 32'h0000_0004;
  localparam logic [31:0] FPSR_UFC = 32'h0000_0008;
  localparam logic [31:0] FPSR_IXC = 32'h0000_0010;
  localparam logic [31:0] FPSR_IDC = 32'h0000_0080;

  typedef struct packed {
    logic [63:0] bits;
    logic [31:0] flags;
    logic [3:0]  nzcv;
  } fp_calc_t;

  // FP-P3T: pre-round pipeline intermediate.  For arithmetic operations that
  // use round_pack, the first pipeline stage computes the exact magnitude and
  // exponent (plus special-value handling), and the second stage performs only
  // round_pack.  Ordinary pp_pre producers add a leading-one scan boundary
  // and a subsequent classification/normalization boundary before
  // round_pack_p1; iterative DIV/SQRT retains its two-stage round/pack path.
  // This breaks the unpack/align/arithmetic ->
  // round/pack chain that was the A10 signoff critical path while keeping
  // raw-bit semantics.
  typedef struct packed {
    logic         is_special;
    fp_calc_t     special;
    logic         need_round;
    logic         sign;
    logic [255:0] sig;
    integer       exp2;
    logic [31:0]  input_flags;
    fp_fmt_t      fmt;
    logic         flush_zero;
    logic [1:0]   rmode;
    logic         ahp;
    // FP-P3T round7: predecoded leading-one index for iterative DIV/SQRT
    // round_pack.  Set only by div_finish_pre/sqrt_finish_pre; other producers
    // keep lead_valid=0 and finish_pre falls back to the original scan.
    logic [7:0]   lead;
    logic         lead_valid;
  } fp_pre_t;

  // FP-P3T round8/round16: two-stage round_pack intermediate.  Stage A
  // computes the shifted/rounded significand and sticky information; stage B
  // completes increment/overflow/subnormal/pack.  The same payload is used by
  // iterative DIV/SQRT and by ordinary pp_pre after the IT_PACK_PRE boundary.
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
    fp_fmt_t      fmt;
    logic         flush_zero;
    logic [1:0]   rmode;
    logic         ahp;
  } fp_round_mid_t;

  // FP-P3T round18: registered leading-one/zero scan metadata for ordinary
  // pp_pre producers.  The wide 256-bit priority scan and the derived exact
  // exponent are captured before tiny classification reaches pack_pre.  This
  // is a real register boundary; it is intentionally not folded into
  // round_pack_pre.  Iterative DIV/SQRT keeps its existing
  // div_pre/sqrt_pre -> IT_FIN path and does not consume this boundary.
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
    fp_fmt_t      fmt;
    logic         flush_zero;
    logic [1:0]   rmode;
    logic         ahp;
  } fp_round_scan_t;

  // FP-P3T round17/round18: registered leading-one/normalization metadata
  // for ordinary pp_pre producers.  IT_PREP captures the scan payload;
  // IT_PACK_SCAN derives tiny/normal classification from that payload, and
  // IT_PACK_PRE performs the wide significand shift and GRS construction in
  // round_pack_p1.
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
    logic         is_tiny;
    integer       exp2;
    integer       e;
    fp_fmt_t      fmt;
    logic         flush_zero;
    logic [1:0]   rmode;
    logic         ahp;
  } fp_round_pre_t;

  typedef struct packed {
    logic         sign;
    logic         nan;
    logic         snan;
    logic         inf;
    logic         zero;
    logic         sub;
    logic [10:0]  exp_field;
    logic [51:0]  frac;
    logic signed [31:0] exp2;
    logic [255:0] sig;
  } fp_parts_t;

  // FP-P3T round2: unpacked-operand pipeline intermediate for the remaining
  // scalar operations (CMP/MINMAX/FRINT/FP-to-int) that were not split by the
  // first-round pre-round cuts. Stage 1 captures the format, raw bits and
  // unpacked/flushed FP parts; stage 2 completes only the per-operation result.
  typedef struct packed {
    fp_fmt_t      fmt;
    logic         flush_zero;
    logic         dn;
    logic [1:0]   rmode;
    logic [2:0]   rint_mode;
    logic         cmp_zero;
    logic         signal_nans;
    logic         conv_is_32;
    integer       conv_shift;
    logic [63:0]  a_bits;
    logic [63:0]  b_bits;
    fp_parts_t    pa;
    fp_parts_t    pb;
    logic         a_flushed;
    logic         b_flushed;
    logic [31:0]  input_flags;
  } fp_other_pre_t;

  // FP-P3T round4: second-stage intermediate for the remaining pp_other
  // operations (MIN/MAX, FRINT, FP->int).  Stage 2 computes the expensive
  // compare/shift/saturate portion and writes this register; stage 3 performs
  // only the final select/normalize/pack.  This breaks the long
  // pp_other -> finish -> slot_result cone without changing FP semantics.
  typedef struct packed {
    logic [31:0]   flags;
    // MIN/MAX/NM selection intermediate (decision captured, mux deferred).
    logic [63:0]   mm_a_out;
    logic [63:0]   mm_b_out;
    logic          mm_use_a;
    logic          mm_is_special;
    logic [63:0]   mm_bits;
    // FRINT integerization intermediate (shifted q + round control captured,
    // normalize/pack deferred).
    logic          fr_is_special;
    logic          fr_direct;
    logic [63:0]   fr_bits;
    logic [255:0]  fr_q;
    logic          fr_inc;
    logic          fr_inexact;
    logic          fr_sign;
    fp_fmt_t       fr_fmt;
    logic [2:0]    fr_mode;
    // FP->int intermediate (magnitude/sticky/saturate captured, final
    // value selection deferred).
    logic [255:0]  i_mag;
    logic          i_sticky;
    logic          i_saturate;
    logic          i_zero;
    logic          i_sign;
    logic          i_is_32;
    logic          i_is_signed;
  } fp_other_mid_t;

  // FP-P3T round3: unpacked/flushed operand pipeline intermediate for the
  // pre-round arithmetic path.  Stage 1 captures format/raw bits and the
  // unpacked (and FZ-flushed) parts; stage 2 performs only the align /
  // effective-add / multiply work that feeds pp_pre.  This breaks the
  // slot mux -> unpack -> align/mult -> pp_pre long combinational cone.
  typedef struct packed {
    fp_op_t      op;
    fp_fmt_t     fmt;
    logic        dn;
    logic        fz;
    logic [1:0]  rmode;
    logic [63:0] a_bits;
    logic [63:0] b_bits;
    logic [63:0] c_bits;
    logic [63:0] conv_int;
    integer      conv_shift;
    logic        conv_is_32;
    fp_parts_t   pa;
    fp_parts_t   pb;
    fp_parts_t   pc;
    logic [31:0] input_flags;
  } fp_arith_pre_t;

  // FP-P3T round9: ADD/SUB alignment intermediate.  The unpacked operands
  // are already captured in ap_pre*.  Registering the wide sticky shifts
  // before the effective add/sub keeps the exponent/align path from driving
  // pp_pre*.  This state is only used by ADD/SUB; MUL/FMA retain their
  // existing multiplier-product stage and conversions retain IT_ARITH.
  typedef struct packed {
    logic [255:0]      a_ext;
    logic [255:0]      b_ext;
    logic signed [31:0] common_exp2;
  } fp_add_align_t;

  // FP-P3T round10: effective ADD/SUB result after alignment.  This is an
  // independent register payload rather than an fp_pre_t alias: IT_ALIGN
  // resolves the wide compare/add/sub and cancellation sign, while IT_ADD
  // resolves special/zero cases and translates this value into the existing
  // pp_pre format.  The payload is not architectural state and is cleared on
  // reset or kill.
  typedef struct packed {
    logic [255:0]  magnitude;
    logic          sign;
    logic signed [31:0] exp2;
    logic          b_num_sign;
    logic          dn;
    logic [63:0]   a_bits;
    logic [63:0]   b_bits;
    logic          a_nan;
    logic          a_snan;
    logic          a_inf;
    logic          a_zero;
    logic          a_sign;
    logic          b_nan;
    logic          b_snan;
    logic          b_inf;
    logic          b_zero;
    logic          b_sign;
    logic [31:0]   input_flags;
    fp_fmt_t       fmt;
    logic          flush_zero;
    logic [1:0]    rmode;
  } fp_add_mid_t;

  // FP-P3T round21: FMA product/addend alignment payload.  IT_MUL captures
  // only the exponent-dependent sticky shifts into this private register;
  // the following FMA-only state performs the wide compare/add/sub.  Special
  // results are carried in the same payload so NaN/Inf/zero handling remains
  // on the identical registered route.
  typedef struct packed {
    logic               is_special;
    logic [63:0]        special_bits;
    logic [31:0]        special_flags;
    logic [255:0]       product_ext;
    logic [255:0]       c_ext;
    logic               product_sign;
    logic               c_sign;
    logic signed [31:0] common_exp2;
  } fp_fma_align_t;

  typedef struct packed {
    logic [63:0] value;
    logic [31:0] flags;
  } fp_int_calc_t;

  function automatic logic [255:0] shr_sticky(
      input logic [255:0] value, input integer amount);
    logic [255:0] shifted;
    logic discarded;
    integer i;
    begin
      shifted = 256'd0;
      discarded = 1'b0;
      if (amount <= 0) begin
        shifted = value;
      end else if (amount >= FP_W) begin
        shifted[0] = |value;
      end else begin
        shifted = value >> amount;
        for (i = 0; i < FP_W; i = i + 1) begin
          if (i < amount && value[i])
            discarded = 1'b1;
        end
        shifted[0] = shifted[0] | discarded;
      end
      shr_sticky = shifted;
    end
  endfunction

  function automatic logic any_low_bits(
      input logic [255:0] value, input integer count);
    logic found;
    integer i;
    begin
      found = 1'b0;
      for (i = 0; i < FP_W; i = i + 1) begin
        if (i < count && value[i])
          found = 1'b1;
      end
      any_low_bits = found;
    end
  endfunction

  function automatic logic round_increment(
      input logic sign,
      input logic [1:0] rmode,
      input logic guard,
      input logic sticky,
      input logic lsb);
    logic discarded;
    begin
      discarded = guard | sticky;
      unique case (rmode)
        2'b00: round_increment = guard && (sticky | lsb); // nearest-even
        2'b01: round_increment = !sign && discarded;      // toward +Inf
        2'b10: round_increment = sign && discarded;       // toward -Inf
        default: round_increment = 1'b0;                  // toward zero
      endcase
    end
  endfunction

  function automatic logic [63:0] default_nan(input fp_fmt_t fmt);
    begin
      unique case (fmt)
        FMT_HALF:   default_nan = 64'h0000_0000_0000_7e00;
        FMT_SINGLE: default_nan = 64'h0000_0000_7fc0_0000;
        default:    default_nan = 64'h7ff8_0000_0000_0000;
      endcase
    end
  endfunction

  function automatic logic [63:0] quiet_nan(
      input logic [63:0] value, input fp_fmt_t fmt);
    logic [63:0] q;
    begin
      q = 64'd0;
      unique case (fmt)
        FMT_HALF: begin
          q[15:0] = value[15:0];
          q[14:10] = 5'h1f;
          q[9] = 1'b1;
        end
        FMT_SINGLE: begin
          q[31:0] = value[31:0];
          q[30:23] = 8'hff;
          q[22] = 1'b1;
        end
        default: begin
          q = value;
          q[62:52] = 11'h7ff;
          q[51] = 1'b1;
        end
      endcase
      quiet_nan = q;
    end
  endfunction

  // P7 canonical A76/FPST_A64 uses the default ARM rule: signaling NaN wins,
  // then operand A wins. A signaling operand is quieted and raises IOC.
  function automatic logic [63:0] propagate_nan(
      input logic [63:0] a,
      input logic [63:0] b,
      input fp_fmt_t      fmt,
      input logic a_nan,
      input logic a_snan,
      input logic b_snan,
      input logic dn);
    logic [63:0] selected;
    begin
      if (dn) begin
        propagate_nan = default_nan(fmt);
      end else begin
        if (a_snan)
          selected = a;
        else if (b_snan)
          selected = b;
        else if (a_nan)
          selected = a;
        else
          selected = b;
        propagate_nan = (a_snan && selected == a) ||
                        (b_snan && selected == b)
                        ? quiet_nan(selected, fmt) : selected;
      end
    end
  endfunction

  // FP-P3T round7: leading-one index predecode for the iterative DIV/SQRT
  // final round.  The 256-bit quotient already has its highest set bit scanned
  // when div_pre/sqrt_pre is captured; the remaining round_pack stage can then
  // use this registered index instead of re-running the wide priority encoder
  // from div_pre.sig to slot_result_r.
  function automatic logic [7:0] leading_one_index(input logic [255:0] sig);
    integer i;
    integer h;
    begin
      h = -1;
      for (i = FP_W - 1; i >= 0; i = i - 1) begin
        if (h < 0 && sig[i])
          h = i;
      end
      leading_one_index = (h < 0) ? 8'd0 : h[7:0];
    end
  endfunction

  // Round a positive finite magnitude represented as sig * 2^exp2. sig may
  // contain an arbitrary number of low guard bits; this variant receives the
  // already-computed leading-one index h_in/h_valid and performs the exact
  // integer GRS rounding step without the 256-bit priority scan.
  function automatic fp_calc_t round_pack_h(
      input logic         sign,
      input logic [255:0] sig,
      input integer       exp2,
      input logic [7:0]   h_in,
      input logic         h_valid,
      input fp_fmt_t      fmt,
      input logic         flush_to_zero,
      input logic [1:0]   rmode,
      input logic         ahp_mode);
    fp_calc_t r;
    logic [255:0] mant;
    logic [255:0] q;
    logic guard;
    logic sticky;
    logic discarded;
    logic inc;
    logic q_high;
    integer p;
    integer frac_bits;
    integer bias;
    integer emin;
    integer emax;
    integer h;
    integer e;
    integer shift;
    integer sub_exp2;
    integer delta;
    logic [10:0] exp_field;
    integer i;
    begin
      r = '0;
      unique case (fmt)
        FMT_HALF:   begin p = 11; frac_bits = 10; bias = 15;  end
        FMT_SINGLE: begin p = 24; frac_bits = 23; bias = 127; end
        default:    begin p = 53; frac_bits = 52; bias = 1023; end
      endcase
      emin = 1 - bias;
      // AHP 半精度把 e=31 也当作正常指数（无 NaN/Inf）。
      emax = ahp_mode ? (2 * bias + 1) : bias;
      h = h_valid ? 32'(h_in) : -1;

      if (h < 0) begin
        unique case (fmt)
          FMT_HALF:   r.bits = {48'd0, sign, 5'd0, 10'd0};
          FMT_SINGLE: r.bits = {32'd0, sign, 8'd0, 23'd0};
          default:    r.bits = {sign, 11'd0, 52'd0};
        endcase
      end else begin
        e = exp2 + h;
        if (e >= emin) begin
          // Normal result. Move the leading bit to p-1 and retain all
          // discarded bits for the selected architectural rounding mode.
          shift = h - (p - 1);
          if (shift > 0) begin
            mant = sig >> shift;
            guard = sig[shift - 1];
            sticky = any_low_bits(sig, shift - 1);
          end else begin
            mant = sig << (-shift);
            guard = 1'b0;
            sticky = 1'b0;
          end
          discarded = guard | sticky;
          inc = round_increment(sign, rmode, guard,
                                sticky, mant[0]);
          if (inc)
            mant = mant + 256'd1;
          if (mant[p]) begin
            mant = mant >> 1;
            e = e + 1;
          end
          if (e > emax) begin
            if (ahp_mode) begin
              // AHP 目的格式无 Inf：溢出返回 max normal 并置 IOC。
              r.bits = {48'd0, sign, 5'h1e, 10'h3ff};
              r.flags = FPSR_IOC;
            end else begin
              r.flags = FPSR_OFC | FPSR_IXC;
              if (round_increment(sign, rmode, 1'b1, 1'b1, 1'b0)) begin
                unique case (fmt)
                  FMT_HALF:   r.bits = {48'd0, sign, 5'h1f, 10'd0};
                  FMT_SINGLE: r.bits = {32'd0, sign, 8'hff, 23'd0};
                  default:    r.bits = {sign, 11'h7ff, 52'd0};
                endcase
              end else begin
                unique case (fmt)
                  FMT_HALF:   r.bits = {48'd0, sign, 5'h1e, 10'h3ff};
                  FMT_SINGLE: r.bits = {32'd0, sign, 8'hfe, 23'h7f_ffff};
                  default:    r.bits = {sign, 11'h7fe, 52'hf_ffff_ffff_ffff};
                endcase
              end
            end
          end else begin
            exp_field = ahp_mode && (e > bias) ? 11'(e) : 11'(e + bias);
            unique case (fmt)
              FMT_HALF:   r.bits = {48'd0, sign, exp_field[4:0], mant[9:0]};
              FMT_SINGLE: r.bits = {32'd0, sign, exp_field[7:0], mant[22:0]};
              default:    r.bits = {sign, exp_field[10:0], mant[51:0]};
            endcase
            if (discarded)
              r.flags = FPSR_IXC;
          end
        end else begin
          // Tiny result. Round directly to the minimum-subnormal quantum.
          // QEMU's A64 default uses tininess-before-rounding. Consequently an
          // inexact tiny result raises UFC even if it rounds to min-normal.
          sub_exp2 = emin - frac_bits;
          delta = exp2 - sub_exp2;
          if (delta >= 0) begin
            q = sig << delta;
            guard = 1'b0;
            sticky = 1'b0;
          end else begin
            shift = -delta;
            if (shift >= FP_W) begin
              q = 256'd0;
              guard = 1'b0;
              sticky = |sig;
            end else begin
              q = sig >> shift;
              guard = sig[shift - 1];
              sticky = any_low_bits(sig, shift - 1);
            end
          end
          discarded = guard | sticky;
          inc = round_increment(sign, rmode, guard,
                                sticky, q[0]);
          if (inc)
            q = q + 256'd1;
          q_high = 1'b0;
          // Use a constant trip count (Quartus 21.4 rejects a non-constant
          // loop start). The condition preserves the original "any bit above
          // the architectural frac_bits" semantics for every format.
          for (i = 0; i < FP_W; i = i + 1) begin
            if (i > frac_bits && q[i])
              q_high = 1'b1;
          end
          if (q_high || q[frac_bits]) begin
            // Rounded across the normal boundary.
            unique case (fmt)
              FMT_HALF:   r.bits = {48'd0, sign, 5'd1, 10'd0};
              FMT_SINGLE: r.bits = {32'd0, sign, 8'd1, 23'd0};
              default:    r.bits = {sign, 11'd1, 52'd0};
            endcase
          end else if (flush_to_zero && (|q || discarded)) begin
            // FPCR.FZ uses the architectural output-denormal-flushed event.
            // In the QEMU A64 mapping this contributes UFC, not IXC.
            unique case (fmt)
              FMT_HALF:   r.bits = {48'd0, sign, 5'd0, 10'd0};
              FMT_SINGLE: r.bits = {32'd0, sign, 8'd0, 23'd0};
              default:    r.bits = {sign, 11'd0, 52'd0};
            endcase
            r.flags = FPSR_UFC;
          end else begin
            unique case (fmt)
              FMT_HALF:   r.bits = {48'd0, sign, 5'd0, q[9:0]};
              FMT_SINGLE: r.bits = {32'd0, sign, 8'd0, q[22:0]};
              default:    r.bits = {sign, 11'd0, q[51:0]};
            endcase
            if (discarded)
              r.flags = FPSR_UFC | FPSR_IXC;
          end
        end
      end
      round_pack_h = r;
    end
  endfunction

  // Public entry point: find the leading one and delegate to the predecoded
  // round_pack_h.  Keeping this wrapper lets all existing callers continue to
  // use the same exact rounding semantics.
  function automatic fp_calc_t round_pack(
      input logic         sign,
      input logic [255:0] sig,
      input integer       exp2,
      input fp_fmt_t      fmt,
      input logic         flush_to_zero,
      input logic [1:0]   rmode,
      input logic         ahp_mode);
    fp_calc_t r;
    integer h;
    integer i;
    begin
      h = -1;
      for (i = FP_W - 1; i >= 0; i = i - 1) begin
        if (h < 0 && sig[i])
          h = i;
      end
      r = round_pack_h(sign, sig, exp2,
                       (h < 0) ? 8'd0 : h[7:0],
                       (h >= 0),
                       fmt, flush_to_zero, rmode, ahp_mode);
      round_pack = r;
    end
  endfunction

  // FP-P3T: complete a pre-round fp_pre_t by performing the architectural
  // round_pack stage.  Special values already resolved in the first stage are
  // returned unchanged (with any input flags ORed in).
  function automatic fp_calc_t finish_pre(input fp_pre_t pre);
    fp_calc_t r;
    begin
      r = '0;
      if (pre.is_special) begin
        r = pre.special;
      end else if (pre.lead_valid) begin
        r = round_pack_h(pre.sign, pre.sig, pre.exp2, pre.lead, 1'b1,
                         pre.fmt, pre.flush_zero, pre.rmode, pre.ahp);
      end else begin
        r = round_pack(pre.sign, pre.sig, pre.exp2, pre.fmt,
                       pre.flush_zero, pre.rmode, pre.ahp);
      end
      r.flags = r.flags | pre.input_flags;
      finish_pre = r;
    end
  endfunction

  // FP-P3T round8/round16: iterative DIV/SQRT first half of the round_pack
  // split.  This captures the shifted/rounded significand and sticky
  // information plus all special-value bypass data; the second half only
  // completes increment/overflow/subnormal decision and final packing.
  // Ordinary pp_pre producers use round_pack_pre -> round_pack_p1 below so
  // their leading-one scan is separated by an additional register boundary.
  function automatic fp_round_mid_t round_pack_iter_p1(input fp_pre_t pre);
    fp_round_mid_t m;
    integer p;
    integer frac_bits;
    integer bias;
    integer emin;
    integer emax;
    integer h;
    integer e;
    integer shift;
    integer sub_exp2;
    integer delta;
    begin
      m = '0;
      m.fmt = pre.fmt;
      m.flush_zero = pre.flush_zero;
      m.rmode = pre.rmode;
      m.ahp = pre.ahp;
      m.input_flags = pre.input_flags;
      if (pre.is_special) begin
        m.is_special = 1'b1;
        m.special_bits = pre.special.bits;
        m.special_flags = pre.special.flags;
      end else begin
        unique case (pre.fmt)
          FMT_HALF:   begin p = 11; frac_bits = 10; bias = 15;  end
          FMT_SINGLE: begin p = 24; frac_bits = 23; bias = 127; end
          default:    begin p = 53; frac_bits = 52; bias = 1023; end
        endcase
        emin = 1 - bias;
        emax = pre.ahp ? (2 * bias + 1) : bias;
        // DIV/SQRT finish predecodes the quotient leading-one index before
        // this register boundary.  lead_valid=0 is the registered zero
        // classification; do not reconstruct it with another 256-bit scan.
        h = pre.lead_valid ? 32'(pre.lead) : -1;
        m.sign = pre.sign;
        if (h < 0) begin
          m.is_zero = 1'b1;
        end else begin
          e = pre.exp2 + h;
          m.e = e;
          if (e >= emin) begin
            // Normal path: shift the leading bit to p-1 and retain GRS.
            shift = h - (p - 1);
            if (shift > 0) begin
              m.mant = pre.sig >> shift;
              m.guard = pre.sig[shift - 1];
              m.sticky = any_low_bits(pre.sig, shift - 1);
            end else begin
              m.mant = pre.sig << (-shift);
              m.guard = 1'b0;
              m.sticky = 1'b0;
            end
            m.discarded = m.guard | m.sticky;
          end else begin
            // Tiny path: round directly to the minimum-subnormal quantum.
            m.is_tiny = 1'b1;
            sub_exp2 = emin - frac_bits;
            delta = pre.exp2 - sub_exp2;
            if (delta >= 0) begin
              m.mant = pre.sig << delta;
              m.guard = 1'b0;
              m.sticky = 1'b0;
            end else begin
              shift = -delta;
              if (shift >= FP_W) begin
                m.mant = 256'd0;
                m.guard = 1'b0;
                m.sticky = |pre.sig;
              end else begin
                m.mant = pre.sig >> shift;
                m.guard = pre.sig[shift - 1];
                m.sticky = any_low_bits(pre.sig, shift - 1);
              end
            end
            m.discarded = m.guard | m.sticky;
          end
        end
      end
      round_pack_iter_p1 = m;
    end
  endfunction

  // The round18 scan consumes a 256-bit magnitude.  Keep the priority
  // encoder explicit and hierarchical so synthesis does not infer the
  // 256-deep "first set bit" chain used by the old descending loop.  The
  // sixteen 16-bit group reductions are followed by a 4-way group tree; the
  // selected group then uses a four-level 16-bit tree.  Unknown bits are
  // treated as not-set by the procedural tests, matching the old
  // h<0 && sig[i] scan for all known input vectors.
  function automatic logic [8:0] leading_one_balanced(
      input logic [255:0] sig);
    logic [15:0] group_valid;
    logic [3:0]  quad_valid;
    logic [3:0]  group_sel;
    logic [15:0] group_bits;
    logic [3:0]  bit_sel;
    logic        any_valid;
    begin
      // Level 0: sixteen independent 16-bit reductions.
      group_valid[0]  = |sig[15:0];
      group_valid[1]  = |sig[31:16];
      group_valid[2]  = |sig[47:32];
      group_valid[3]  = |sig[63:48];
      group_valid[4]  = |sig[79:64];
      group_valid[5]  = |sig[95:80];
      group_valid[6]  = |sig[111:96];
      group_valid[7]  = |sig[127:112];
      group_valid[8]  = |sig[143:128];
      group_valid[9]  = |sig[159:144];
      group_valid[10] = |sig[175:160];
      group_valid[11] = |sig[191:176];
      group_valid[12] = |sig[207:192];
      group_valid[13] = |sig[223:208];
      group_valid[14] = |sig[239:224];
      group_valid[15] = |sig[255:240];

      // Level 1: four independent 4-group reductions.
      quad_valid[0] = |group_valid[3:0];
      quad_valid[1] = |group_valid[7:4];
      quad_valid[2] = |group_valid[11:8];
      quad_valid[3] = |group_valid[15:12];

      // Level 2: select the highest non-empty 4-group quadrant, then the
      // highest non-empty group inside that quadrant.  Procedural if/else
      // keeps X bits from becoming a spurious priority hit, as before.
      group_sel = 4'd0;
      any_valid = 1'b0;
      if (quad_valid[3]) begin
        any_valid = 1'b1;
        if (group_valid[15])
          group_sel = 4'd15;
        else if (group_valid[14])
          group_sel = 4'd14;
        else if (group_valid[13])
          group_sel = 4'd13;
        else
          group_sel = 4'd12;
      end else if (quad_valid[2]) begin
        any_valid = 1'b1;
        if (group_valid[11])
          group_sel = 4'd11;
        else if (group_valid[10])
          group_sel = 4'd10;
        else if (group_valid[9])
          group_sel = 4'd9;
        else
          group_sel = 4'd8;
      end else if (quad_valid[1]) begin
        any_valid = 1'b1;
        if (group_valid[7])
          group_sel = 4'd7;
        else if (group_valid[6])
          group_sel = 4'd6;
        else if (group_valid[5])
          group_sel = 4'd5;
        else
          group_sel = 4'd4;
      end else begin
        if (quad_valid[0])
          any_valid = 1'b1;
        if (group_valid[3])
          group_sel = 4'd3;
        else if (group_valid[2])
          group_sel = 4'd2;
        else if (group_valid[1])
          group_sel = 4'd1;
        else
          group_sel = 4'd0;
      end

      // Select the chosen 16-bit group without a variable wide part-select.
      // This form is friendly to older Quartus versions and leaves the
      // group-local encoder below independent of the upper tree.
      case (group_sel)
        4'd0:  group_bits = sig[15:0];
        4'd1:  group_bits = sig[31:16];
        4'd2:  group_bits = sig[47:32];
        4'd3:  group_bits = sig[63:48];
        4'd4:  group_bits = sig[79:64];
        4'd5:  group_bits = sig[95:80];
        4'd6:  group_bits = sig[111:96];
        4'd7:  group_bits = sig[127:112];
        4'd8:  group_bits = sig[143:128];
        4'd9:  group_bits = sig[159:144];
        4'd10: group_bits = sig[175:160];
        4'd11: group_bits = sig[191:176];
        4'd12: group_bits = sig[207:192];
        4'd13: group_bits = sig[223:208];
        4'd14: group_bits = sig[239:224];
        4'd15: group_bits = sig[255:240];
        default: group_bits = 16'd0;
      endcase

      // Level 3: balanced 16-bit priority selection.  Each branch first
      // chooses one nibble, then one pair, then one bit.
      bit_sel = 4'd0;
      if (|group_bits[15:12]) begin
        bit_sel[3:2] = 2'b11;
        if (|group_bits[15:14]) begin
          bit_sel[1] = 1'b1;
          bit_sel[0] = 1'b0;
          if (group_bits[15])
            bit_sel[0] = 1'b1;
        end else begin
          bit_sel[1] = 1'b0;
          bit_sel[0] = 1'b0;
          if (group_bits[13])
            bit_sel[0] = 1'b1;
        end
      end else if (|group_bits[11:8]) begin
        bit_sel[3:2] = 2'b10;
        if (|group_bits[11:10]) begin
          bit_sel[1] = 1'b1;
          bit_sel[0] = 1'b0;
          if (group_bits[11])
            bit_sel[0] = 1'b1;
        end else begin
          bit_sel[1] = 1'b0;
          bit_sel[0] = 1'b0;
          if (group_bits[9])
            bit_sel[0] = 1'b1;
        end
      end else if (|group_bits[7:4]) begin
        bit_sel[3:2] = 2'b01;
        if (|group_bits[7:6]) begin
          bit_sel[1] = 1'b1;
          bit_sel[0] = 1'b0;
          if (group_bits[7])
            bit_sel[0] = 1'b1;
        end else begin
          bit_sel[1] = 1'b0;
          bit_sel[0] = 1'b0;
          if (group_bits[5])
            bit_sel[0] = 1'b1;
        end
      end else begin
        bit_sel[3:2] = 2'b00;
        if (|group_bits[3:2]) begin
          bit_sel[1] = 1'b1;
          bit_sel[0] = 1'b0;
          if (group_bits[3])
            bit_sel[0] = 1'b1;
        end else begin
          bit_sel[1] = 1'b0;
          bit_sel[0] = 1'b0;
          if (group_bits[1])
            bit_sel[0] = 1'b1;
        end
      end
      leading_one_balanced = {any_valid, group_sel, bit_sel};
    end
  endfunction

  // FP-P3T round18 stage A: scan the registered ordinary pp_pre magnitude and
  // capture the leading-one/zero result plus the derived exact exponent.  No
  // tiny classification or normalization is performed here; all of the
  // payload leaves this function through the pack_scan register in IT_PREP.
  function automatic fp_round_scan_t round_pack_scan(input fp_pre_t pre);
    fp_round_scan_t s;
    integer h;
    logic [8:0] lead_scan;
    begin
      s = '0;
      s.is_special = pre.is_special;
      s.special_bits = pre.special.bits;
      s.special_flags = pre.special.flags;
      s.input_flags = pre.input_flags;
      s.sign = pre.sign;
      s.sig = pre.sig;
      s.exp2 = pre.exp2;
      s.fmt = pre.fmt;
      s.flush_zero = pre.flush_zero;
      s.rmode = pre.rmode;
      s.ahp = pre.ahp;
      if (pre.is_special) begin
        s.lead_valid = 1'b0;
      end else begin
        h = -1;
        if (pre.lead_valid) begin
          h = 32'(pre.lead);
        end else begin
          lead_scan = leading_one_balanced(pre.sig);
          if (lead_scan[8])
            h = 32'(lead_scan[7:0]);
        end
        if (h < 0) begin
          s.is_zero = 1'b1;
        end else begin
          s.lead = h[7:0];
          s.lead_valid = 1'b1;
          s.e = pre.exp2 + h;
        end
      end
      round_pack_scan = s;
    end
  endfunction

  // FP-P3T round18 stage B: classify the registered scan result as normal or
  // tiny and carry the metadata into the existing normalization stage.  The
  // leading-one scan and exponent add have already completed on the other
  // side of the pack_scan register; this function contains no 256-bit scan.
  function automatic fp_round_pre_t round_pack_pre(input fp_round_scan_t scan);
    fp_round_pre_t p;
    integer bias;
    integer emin;
    begin
      p = '0;
      p.is_special = scan.is_special;
      p.special_bits = scan.special_bits;
      p.special_flags = scan.special_flags;
      p.input_flags = scan.input_flags;
      p.sign = scan.sign;
      p.sig = scan.sig;
      p.lead = scan.lead;
      p.lead_valid = scan.lead_valid;
      p.is_zero = scan.is_zero;
      p.exp2 = scan.exp2;
      p.e = scan.e;
      p.fmt = scan.fmt;
      p.flush_zero = scan.flush_zero;
      p.rmode = scan.rmode;
      p.ahp = scan.ahp;
      if (!scan.is_special && scan.lead_valid && !scan.is_zero) begin
        unique case (scan.fmt)
          FMT_HALF:   bias = 15;
          FMT_SINGLE: bias = 127;
          default:    bias = 1023;
        endcase
        emin = 1 - bias;
        p.is_tiny = (scan.e < emin);
      end
      round_pack_pre = p;
    end
  endfunction

  // FP-P3T round18 stage C: normalize the registered magnitude and construct
  // the exact GRS payload consumed by round_pack_p2.  No leading-one scan is
  // present on this side of the new register boundary.
  function automatic fp_round_mid_t round_pack_p1(input fp_round_pre_t pre);
    fp_round_mid_t m;
    integer p;
    integer frac_bits;
    integer bias;
    integer emin;
    integer h;
    integer shift;
    integer sub_exp2;
    integer delta;
    begin
      m = '0;
      m.fmt = pre.fmt;
      m.flush_zero = pre.flush_zero;
      m.rmode = pre.rmode;
      m.ahp = pre.ahp;
      m.input_flags = pre.input_flags;
      m.sign = pre.sign;
      if (pre.is_special) begin
        m.is_special = 1'b1;
        m.special_bits = pre.special_bits;
        m.special_flags = pre.special_flags;
      end else if (pre.is_zero || !pre.lead_valid) begin
        m.is_zero = 1'b1;
      end else begin
        unique case (pre.fmt)
          FMT_HALF:   begin p = 11; frac_bits = 10; bias = 15;  end
          FMT_SINGLE: begin p = 24; frac_bits = 23; bias = 127; end
          default:    begin p = 53; frac_bits = 52; bias = 1023; end
        endcase
        emin = 1 - bias;
        m.e = pre.e;
        if (!pre.is_tiny) begin
          // Normal path: shift the leading bit to p-1 and retain GRS.
          h = 32'(pre.lead);
          shift = h - (p - 1);
          if (shift > 0) begin
            m.mant = pre.sig >> shift;
            m.guard = pre.sig[shift - 1];
            m.sticky = any_low_bits(pre.sig, shift - 1);
          end else begin
            m.mant = pre.sig << (-shift);
            m.guard = 1'b0;
            m.sticky = 1'b0;
          end
          m.discarded = m.guard | m.sticky;
        end else begin
          // Tiny path: round directly to the minimum-subnormal quantum.
          m.is_tiny = 1'b1;
          sub_exp2 = emin - frac_bits;
          delta = pre.exp2 - sub_exp2;
          if (delta >= 0) begin
            m.mant = pre.sig << delta;
            m.guard = 1'b0;
            m.sticky = 1'b0;
          end else begin
            shift = -delta;
            if (shift >= FP_W) begin
              m.mant = 256'd0;
              m.guard = 1'b0;
              m.sticky = |pre.sig;
            end else begin
              m.mant = pre.sig >> shift;
              m.guard = pre.sig[shift - 1];
              m.sticky = any_low_bits(pre.sig, shift - 1);
            end
          end
          m.discarded = m.guard | m.sticky;
        end
      end
      round_pack_p1 = m;
    end
  endfunction

  // FP-P3T round8/round16/round18: final half of the round_pack split.
  function automatic fp_calc_t round_pack_p2(input fp_round_mid_t m);
    fp_calc_t r;
    logic [255:0] val;
    logic inc;
    logic q_high;
    integer p;
    integer frac_bits;
    integer bias;
    integer emin;
    integer emax;
    integer e;
    logic [10:0] exp_field;
    integer i;
    begin
      r = '0;
      if (m.is_special) begin
        r.bits = m.special_bits;
        r.flags = m.special_flags | m.input_flags;
      end else begin
        unique case (m.fmt)
          FMT_HALF:   begin p = 11; frac_bits = 10; bias = 15;  end
          FMT_SINGLE: begin p = 24; frac_bits = 23; bias = 127; end
          default:    begin p = 53; frac_bits = 52; bias = 1023; end
        endcase
        emin = 1 - bias;
        emax = m.ahp ? (2 * bias + 1) : bias;
        if (m.is_zero) begin
          unique case (m.fmt)
            FMT_HALF:   r.bits = {48'd0, m.sign, 5'd0, 10'd0};
            FMT_SINGLE: r.bits = {32'd0, m.sign, 8'd0, 23'd0};
            default:    r.bits = {m.sign, 11'd0, 52'd0};
          endcase
        end else if (!m.is_tiny) begin
          val = m.mant;
          inc = round_increment(m.sign, m.rmode, m.guard, m.sticky, val[0]);
          if (inc)
            val = val + 256'd1;
          if (val[p]) begin
            val = val >> 1;
            e = m.e + 1;
          end else begin
            e = m.e;
          end
          if (e > emax) begin
            if (m.ahp) begin
              r.bits = {48'd0, m.sign, 5'h1e, 10'h3ff};
              r.flags = FPSR_IOC;
            end else begin
              r.flags = FPSR_OFC | FPSR_IXC;
              if (round_increment(m.sign, m.rmode, 1'b1, 1'b1, 1'b0)) begin
                unique case (m.fmt)
                  FMT_HALF:   r.bits = {48'd0, m.sign, 5'h1f, 10'd0};
                  FMT_SINGLE: r.bits = {32'd0, m.sign, 8'hff, 23'd0};
                  default:    r.bits = {m.sign, 11'h7ff, 52'd0};
                endcase
              end else begin
                unique case (m.fmt)
                  FMT_HALF:   r.bits = {48'd0, m.sign, 5'h1e, 10'h3ff};
                  FMT_SINGLE: r.bits = {32'd0, m.sign, 8'hfe, 23'h7f_ffff};
                  default:    r.bits = {m.sign, 11'h7fe, 52'hf_ffff_ffff_ffff};
                endcase
              end
            end
          end else begin
            exp_field = m.ahp && (e > bias) ? 11'(e) : 11'(e + bias);
            unique case (m.fmt)
              FMT_HALF:   r.bits = {48'd0, m.sign, exp_field[4:0], val[9:0]};
              FMT_SINGLE: r.bits = {32'd0, m.sign, exp_field[7:0], val[22:0]};
              default:    r.bits = {m.sign, exp_field[10:0], val[51:0]};
            endcase
            if (m.discarded)
              r.flags = FPSR_IXC;
          end
        end else begin
          val = m.mant;
          inc = round_increment(m.sign, m.rmode, m.guard, m.sticky, val[0]);
          if (inc)
            val = val + 256'd1;
          q_high = 1'b0;
          for (i = 0; i < FP_W; i = i + 1) begin
            if (i > frac_bits && val[i])
              q_high = 1'b1;
          end
          if (q_high || val[frac_bits]) begin
            unique case (m.fmt)
              FMT_HALF:   r.bits = {48'd0, m.sign, 5'd1, 10'd0};
              FMT_SINGLE: r.bits = {32'd0, m.sign, 8'd1, 23'd0};
              default:    r.bits = {m.sign, 11'd1, 52'd0};
            endcase
          end else if (m.flush_zero && (|val || m.discarded)) begin
            unique case (m.fmt)
              FMT_HALF:   r.bits = {48'd0, m.sign, 5'd0, 10'd0};
              FMT_SINGLE: r.bits = {32'd0, m.sign, 8'd0, 23'd0};
              default:    r.bits = {m.sign, 11'd0, 52'd0};
            endcase
            r.flags = FPSR_UFC;
          end else begin
            unique case (m.fmt)
              FMT_HALF:   r.bits = {48'd0, m.sign, 5'd0, val[9:0]};
              FMT_SINGLE: r.bits = {32'd0, m.sign, 8'd0, val[22:0]};
              default:    r.bits = {m.sign, 11'd0, val[51:0]};
            endcase
            if (m.discarded)
              r.flags = FPSR_UFC | FPSR_IXC;
          end
        end
        r.flags = r.flags | m.input_flags;
      end
      round_pack_p2 = r;
    end
  endfunction

  // FP-P3T: operations whose scalar path is split into pre-round + round_pack.
  function automatic logic uses_pre_round(input fp_op_t operation);
    begin
      uses_pre_round = (operation == FP_OP_ADD) || (operation == FP_OP_SUB) ||
                       (operation == FP_OP_MUL) ||
                       (operation == FP_OP_SCVTF) || (operation == FP_OP_UCVTF);
    end
  endfunction

  // All paths that write an fp_pre_t payload must cross the same registered
  // round_pack boundary.  Keeping this predicate separate from
  // uses_pre_round also covers FMA and FCVT, whose pre-round payloads are
  // produced by dedicated helpers in the iterative state machine.
  function automatic logic uses_round_pack_pre(input fp_op_t operation);
    begin
      uses_round_pack_pre = uses_pre_round(operation) ||
                            (operation == FP_OP_FMADD) ||
                            (operation == FP_OP_FMSUB) ||
                            (operation == FP_OP_FNMADD) ||
                            (operation == FP_OP_FNMSUB) ||
                            (operation == FP_OP_FCVT);
    end
  endfunction

  function automatic logic [63:0] pack_inf(
      input logic sign, input fp_fmt_t fmt);
    begin
      unique case (fmt)
        FMT_HALF:   pack_inf = {48'd0, sign, 5'h1f, 10'd0};
        FMT_SINGLE: pack_inf = {32'd0, sign, 8'hff, 23'd0};
        default:    pack_inf = {sign, 11'h7ff, 52'd0};
      endcase
    end
  endfunction

  function automatic logic [63:0] pack_zero(
      input logic sign, input fp_fmt_t fmt);
    begin
      unique case (fmt)
        FMT_HALF:   pack_zero = {48'd0, sign, 5'd0, 10'd0};
        FMT_SINGLE: pack_zero = {32'd0, sign, 8'd0, 23'd0};
        default:    pack_zero = {sign, 11'd0, 52'd0};
      endcase
    end
  endfunction

  function automatic fp_calc_t binary_op(
      input fp_op_t       operation,
      input fp_fmt_t      fmt,
      input logic [63:0]  a_bits,
      input logic [63:0]  b_bits,
      input logic         default_nan_mode,
      input logic         flush_to_zero,
      input logic [1:0]   rmode);
    fp_calc_t r;
    logic a_sign;
    logic b_sign;
    logic b_num_sign;
    logic [10:0] a_exp_field;
    logic [10:0] b_exp_field;
    logic [51:0] a_frac;
    logic [51:0] b_frac;
    logic a_nan;
    logic b_nan;
    logic a_snan;
    logic b_snan;
    logic a_inf;
    logic b_inf;
    logic a_zero;
    logic b_zero;
    logic a_sub;
    logic b_sub;
    logic [255:0] a_sig;
    logic [255:0] b_sig;
    logic [255:0] a_ext;
    logic [255:0] b_ext;
    logic [255:0] magnitude;
    logic [255:0] product;
    logic [255:0] numerator;
    logic [255:0] quotient;
    logic [255:0] remainder;
    integer a_exp2;
    integer b_exp2;
    integer common_exp2;
    integer div_scale;
    logic result_sign;
    logic [31:0] input_flags;
    begin
      r = '0;
      unique case (fmt)
        FMT_HALF: begin
          a_sign = a_bits[15];
          b_sign = b_bits[15];
          a_exp_field = {6'd0, a_bits[14:10]};
          b_exp_field = {6'd0, b_bits[14:10]};
          a_frac = {42'd0, a_bits[9:0]};
          b_frac = {42'd0, b_bits[9:0]};
          a_exp2 = 32'(a_exp_field);
          b_exp2 = 32'(b_exp_field);
          a_exp2 = (a_exp_field == 0) ? (1 - 15 - 10)
                                      : (a_exp2 - 15 - 10);
          b_exp2 = (b_exp_field == 0) ? (1 - 15 - 10)
                                      : (b_exp2 - 15 - 10);
          a_sig = (a_exp_field != 0) ? {245'd0, 1'b1, a_frac[9:0]}
                                     : {246'd0, a_frac[9:0]};
          b_sig = (b_exp_field != 0) ? {245'd0, 1'b1, b_frac[9:0]}
                                     : {246'd0, b_frac[9:0]};
        end
        FMT_SINGLE: begin
          a_sign = a_bits[31];
          b_sign = b_bits[31];
          a_exp_field = {3'd0, a_bits[30:23]};
          b_exp_field = {3'd0, b_bits[30:23]};
          a_frac = {29'd0, a_bits[22:0]};
          b_frac = {29'd0, b_bits[22:0]};
          a_exp2 = 32'(a_exp_field);
          b_exp2 = 32'(b_exp_field);
          a_exp2 = (a_exp_field == 0) ? (1 - 127 - 23)
                                      : (a_exp2 - 127 - 23);
          b_exp2 = (b_exp_field == 0) ? (1 - 127 - 23)
                                      : (b_exp2 - 127 - 23);
          a_sig = (a_exp_field != 0) ? {232'd0, 1'b1, a_frac[22:0]}
                                     : {233'd0, a_frac[22:0]};
          b_sig = (b_exp_field != 0) ? {232'd0, 1'b1, b_frac[22:0]}
                                     : {233'd0, b_frac[22:0]};
        end
        default: begin
          a_sign = a_bits[63];
          b_sign = b_bits[63];
          a_exp_field = a_bits[62:52];
          b_exp_field = b_bits[62:52];
          a_frac = a_bits[51:0];
          b_frac = b_bits[51:0];
          a_exp2 = 32'(a_exp_field);
          b_exp2 = 32'(b_exp_field);
          a_exp2 = (a_exp_field == 0) ? (1 - 1023 - 52)
                                      : (a_exp2 - 1023 - 52);
          b_exp2 = (b_exp_field == 0) ? (1 - 1023 - 52)
                                      : (b_exp2 - 1023 - 52);
          a_sig = (a_exp_field != 0) ? {203'd0, 1'b1, a_frac}
                                     : {204'd0, a_frac};
          b_sig = (b_exp_field != 0) ? {203'd0, 1'b1, b_frac}
                                     : {204'd0, b_frac};
        end
      endcase
      unique case (fmt)
        FMT_HALF: begin
          a_nan = (a_exp_field == 11'h1f) && (|a_frac);
          b_nan = (b_exp_field == 11'h1f) && (|b_frac);
          a_snan = a_nan && !a_frac[9];
          b_snan = b_nan && !b_frac[9];
          a_inf = (a_exp_field == 11'h1f) && !(|a_frac);
          b_inf = (b_exp_field == 11'h1f) && !(|b_frac);
        end
        FMT_SINGLE: begin
          a_nan = (a_exp_field[7:0] == 8'hff) && (|a_frac);
          b_nan = (b_exp_field[7:0] == 8'hff) && (|b_frac);
          a_snan = a_nan && !a_frac[22];
          b_snan = b_nan && !b_frac[22];
          a_inf = (a_exp_field[7:0] == 8'hff) && !(|a_frac);
          b_inf = (b_exp_field[7:0] == 8'hff) && !(|b_frac);
        end
        default: begin
          a_nan = (a_exp_field == 11'h7ff) && (|a_frac);
          b_nan = (b_exp_field == 11'h7ff) && (|b_frac);
          a_snan = a_nan && !a_frac[51];
          b_snan = b_nan && !b_frac[51];
          a_inf = (a_exp_field == 11'h7ff) && !(|a_frac);
          b_inf = (b_exp_field == 11'h7ff) && !(|b_frac);
        end
      endcase
      a_zero = (a_exp_field == 0) && !(|a_frac);
      b_zero = (b_exp_field == 0) && !(|b_frac);
      a_sub = (a_exp_field == 0) && (|a_frac);
      b_sub = (b_exp_field == 0) && (|b_frac);
      input_flags = 32'd0;

      // FPCR.FZ flushes arithmetic inputs, but FMOV is bitwise and never
      // enters this function. QEMU reports this as FPSR.IDC.
      if (flush_to_zero && a_sub) begin
        a_zero = 1'b1;
        a_sub = 1'b0;
        a_sig = 256'd0;
        input_flags = input_flags | FPSR_IDC;
      end
      if (flush_to_zero && b_sub) begin
        b_zero = 1'b1;
        b_sub = 1'b0;
        b_sig = 256'd0;
        input_flags = input_flags | FPSR_IDC;
      end

      if (a_nan || b_nan) begin
        r.bits = propagate_nan(a_bits, b_bits, fmt, a_nan,
                               a_snan, b_snan, default_nan_mode);
        r.flags = input_flags | ((a_snan || b_snan) ? FPSR_IOC : 32'd0);
      end else if (operation == FP_OP_ADD || operation == FP_OP_SUB) begin
        b_num_sign = b_sign ^ (operation == FP_OP_SUB);
        if (a_inf || b_inf) begin
          if (a_inf && b_inf && (a_sign != b_num_sign)) begin
            r.bits = default_nan(fmt);
            r.flags = input_flags | FPSR_IOC;
          end else if (a_inf) begin
            r.bits = pack_inf(a_sign, fmt);
            r.flags = input_flags;
          end else begin
            r.bits = pack_inf(b_num_sign, fmt);
            r.flags = input_flags;
          end
        end else if (a_zero && b_zero) begin
          // Exact zero sign follows IEEE roundTowardNegative for a
          // cancellation; otherwise preserve a common zero sign.
          result_sign = (a_sign == b_num_sign) ? a_sign
                                                : (rmode == 2'b10);
          r.bits = pack_zero(result_sign, fmt);
          r.flags = input_flags;
        end else begin
          common_exp2 = (a_exp2 > b_exp2) ? a_exp2 : b_exp2;
          a_ext = shr_sticky(a_sig << ADD_EXTRA, common_exp2 - a_exp2);
          b_ext = shr_sticky(b_sig << ADD_EXTRA, common_exp2 - b_exp2);
          if (a_sign == b_num_sign) begin
            magnitude = a_ext + b_ext;
            result_sign = a_sign;
          end else if (a_ext >= b_ext) begin
            magnitude = a_ext - b_ext;
            result_sign = a_sign;
          end else begin
            magnitude = b_ext - a_ext;
            result_sign = b_num_sign;
          end
          if (magnitude == 0) begin
            result_sign = (rmode == 2'b10);
            r.bits = pack_zero(result_sign, fmt);
            r.flags = input_flags;
          end else begin
            r = round_pack(result_sign, magnitude,
                           common_exp2 - ADD_EXTRA, fmt, flush_to_zero,
                           rmode, 1'b0);
            r.flags = r.flags | input_flags;
          end
        end
      end else if (operation == FP_OP_MUL) begin
        result_sign = a_sign ^ b_sign;
        if ((a_inf && b_zero) || (b_inf && a_zero)) begin
          r.bits = default_nan(fmt);
          r.flags = input_flags | FPSR_IOC;
        end else if (a_inf || b_inf) begin
          r.bits = pack_inf(result_sign, fmt);
          r.flags = input_flags;
        end else if (a_zero || b_zero) begin
          r.bits = pack_zero(result_sign, fmt);
          r.flags = input_flags;
        end else begin
          product = a_sig * b_sig;
          r = round_pack(result_sign, product, a_exp2 + b_exp2,
                         fmt, flush_to_zero, rmode, 1'b0);
          r.flags = r.flags | input_flags;
        end
      end else begin
        // FP_OP_DIV is not computed inside binary_op. The top-level
        // always_comb routes finite division through the multi-cycle
        // lcvex_fp_divider units below.
        r = '0;
      end
      binary_op = r;
    end
  endfunction

  // FP-P3T: binary add/sub/mul pre-round stage.  This is a pipelined variant
  // of binary_op that stops before round_pack and records the exact magnitude
  // and exponent, or records an already-resolved special result.
  function automatic fp_pre_t binary_pre(
      input fp_op_t       operation,
      input fp_fmt_t      fmt,
      input logic [63:0]  a_bits,
      input logic [63:0]  b_bits,
      input logic         default_nan_mode,
      input logic         flush_to_zero,
      input logic [1:0]   rmode);
    fp_pre_t p;
    fp_parts_t pa;
    fp_parts_t pb;
    logic b_num_sign;
    logic [255:0] a_ext;
    logic [255:0] b_ext;
    logic [255:0] magnitude;
    logic [255:0] product;
    integer common_exp2;
    logic result_sign;
    logic [31:0] input_flags;
    begin
      p = '0;
      pa = unpack_fp(fmt, a_bits);
      pb = unpack_fp(fmt, b_bits);
      input_flags = 32'd0;
      if (flush_to_zero && pa.sub) begin
        pa.zero = 1'b1;
        pa.sub = 1'b0;
        pa.sig = 256'd0;
        input_flags = input_flags | FPSR_IDC;
      end
      if (flush_to_zero && pb.sub) begin
        pb.zero = 1'b1;
        pb.sub = 1'b0;
        pb.sig = 256'd0;
        input_flags = input_flags | FPSR_IDC;
      end

      if (pa.nan || pb.nan) begin
        p.is_special = 1'b1;
        p.special.bits = propagate_nan(a_bits, b_bits, fmt, pa.nan,
                                       pa.snan, pb.snan, default_nan_mode);
        p.special.flags = input_flags |
                          ((pa.snan || pb.snan) ? FPSR_IOC : 32'd0);
      end else if (operation == FP_OP_ADD || operation == FP_OP_SUB) begin
        b_num_sign = pb.sign ^ (operation == FP_OP_SUB);
        if (pa.inf || pb.inf) begin
          p.is_special = 1'b1;
          if (pa.inf && pb.inf && (pa.sign != b_num_sign)) begin
            p.special.bits = default_nan(fmt);
            p.special.flags = input_flags | FPSR_IOC;
          end else if (pa.inf) begin
            p.special.bits = pack_inf(pa.sign, fmt);
            p.special.flags = input_flags;
          end else begin
            p.special.bits = pack_inf(b_num_sign, fmt);
            p.special.flags = input_flags;
          end
        end else if (pa.zero && pb.zero) begin
          result_sign = (pa.sign == b_num_sign) ? pa.sign
                                                : (rmode == 2'b10);
          p.is_special = 1'b1;
          p.special.bits = pack_zero(result_sign, fmt);
          p.special.flags = input_flags;
        end else begin
          common_exp2 = (pa.exp2 > pb.exp2) ? pa.exp2 : pb.exp2;
          a_ext = shr_sticky(pa.sig << ADD_EXTRA, common_exp2 - pa.exp2);
          b_ext = shr_sticky(pb.sig << ADD_EXTRA, common_exp2 - pb.exp2);
          if (pa.sign == b_num_sign) begin
            magnitude = a_ext + b_ext;
            result_sign = pa.sign;
          end else if (a_ext >= b_ext) begin
            magnitude = a_ext - b_ext;
            result_sign = pa.sign;
          end else begin
            magnitude = b_ext - a_ext;
            result_sign = b_num_sign;
          end
          if (magnitude == 0) begin
            result_sign = (rmode == 2'b10);
            p.is_special = 1'b1;
            p.special.bits = pack_zero(result_sign, fmt);
            p.special.flags = input_flags;
          end else begin
            p.is_special = 1'b0;
            p.need_round = 1'b1;
            p.sign = result_sign;
            p.sig = magnitude;
            p.exp2 = common_exp2 - ADD_EXTRA;
            p.input_flags = input_flags;
            p.fmt = fmt;
            p.flush_zero = flush_to_zero;
            p.rmode = rmode;
            p.ahp = 1'b0;
          end
        end
      end else if (operation == FP_OP_MUL) begin
        result_sign = pa.sign ^ pb.sign;
        if ((pa.inf && pb.zero) || (pb.inf && pa.zero)) begin
          p.is_special = 1'b1;
          p.special.bits = default_nan(fmt);
          p.special.flags = input_flags | FPSR_IOC;
        end else if (pa.inf || pb.inf) begin
          p.is_special = 1'b1;
          p.special.bits = pack_inf(result_sign, fmt);
          p.special.flags = input_flags;
        end else if (pa.zero || pb.zero) begin
          p.is_special = 1'b1;
          p.special.bits = pack_zero(result_sign, fmt);
          p.special.flags = input_flags;
        end else begin
          product = pa.sig * pb.sig;
          p.is_special = 1'b0;
          p.need_round = 1'b1;
          p.sign = result_sign;
          p.sig = product;
          p.exp2 = pa.exp2 + pb.exp2;
          p.input_flags = input_flags;
          p.fmt = fmt;
          p.flush_zero = flush_to_zero;
          p.rmode = rmode;
          p.ahp = 1'b0;
        end
      end
      binary_pre = p;
    end
  endfunction

  // FP-P3T round3: stage-1 capture for the pre-round arithmetic path.  This
  // only unpacks and FZ-flushes the operands; the heavy align/multiply work
  // is deferred to the next pipeline stage (binary_pre_parts/fma_pre_parts).
  function automatic fp_arith_pre_t arith_pre(
      input fp_op_t       operation,
      input fp_fmt_t      fmt,
      input logic [63:0]  a_bits,
      input logic [63:0]  b_bits,
      input logic [63:0]  c_bits,
      input logic [63:0]  src_conv_int,
      input integer       src_conv_shift,
      input logic         src_conv_is_32,
      input logic         default_nan_mode,
      input logic         flush_to_zero,
      input logic [1:0]   rmode);
    fp_arith_pre_t p;
    begin
      p = '0;
      p.op = operation;
      p.fmt = fmt;
      p.dn = default_nan_mode;
      p.fz = flush_to_zero;
      p.rmode = rmode;
      p.a_bits = a_bits;
      p.b_bits = b_bits;
      p.c_bits = c_bits;
      p.conv_int = src_conv_int;
      p.conv_shift = src_conv_shift;
      p.conv_is_32 = src_conv_is_32;
      p.pa = unpack_fp(fmt, a_bits);
      p.pb = unpack_fp(fmt, b_bits);
      p.pc = unpack_fp(fmt, c_bits);
      if (flush_to_zero && p.pa.sub) begin
        p.pa.zero = 1'b1;
        p.pa.sub = 1'b0;
        p.pa.sig = 256'd0;
        p.input_flags = p.input_flags | FPSR_IDC;
      end
      if (flush_to_zero && p.pb.sub) begin
        p.pb.zero = 1'b1;
        p.pb.sub = 1'b0;
        p.pb.sig = 256'd0;
        p.input_flags = p.input_flags | FPSR_IDC;
      end
      if (flush_to_zero && p.pc.sub) begin
        p.pc.zero = 1'b1;
        p.pc.sub = 1'b0;
        p.pc.sig = 256'd0;
        p.input_flags = p.input_flags | FPSR_IDC;
      end
      arith_pre = p;
    end
  endfunction

  // FP-P3T round3: complete the binary add/sub/mul pre-round stage from
  // already-unpacked/FZ-flushed parts.  This contains only the align /
  // effective-add / multiply cone that feeds pp_pre.
  function automatic fp_pre_t binary_pre_parts(
      input fp_op_t       operation,
      input fp_fmt_t      fmt,
      input logic [63:0]  a_bits,
      input logic [63:0]  b_bits,
      input fp_parts_t    pa,
      input fp_parts_t    pb,
      input logic [31:0]  input_flags,
      input logic         default_nan_mode,
      input logic         flush_to_zero,
      input logic [1:0]   rmode);
    fp_pre_t p;
    logic b_num_sign;
    logic [255:0] a_ext;
    logic [255:0] b_ext;
    logic [255:0] magnitude;
    logic [255:0] product;
    integer common_exp2;
    logic result_sign;
    begin
      p = '0;
      if (pa.nan || pb.nan) begin
        p.is_special = 1'b1;
        p.special.bits = propagate_nan(a_bits, b_bits, fmt, pa.nan,
                                       pa.snan, pb.snan, default_nan_mode);
        p.special.flags = input_flags |
                          ((pa.snan || pb.snan) ? FPSR_IOC : 32'd0);
      end else if (operation == FP_OP_ADD || operation == FP_OP_SUB) begin
        b_num_sign = pb.sign ^ (operation == FP_OP_SUB);
        if (pa.inf || pb.inf) begin
          p.is_special = 1'b1;
          if (pa.inf && pb.inf && (pa.sign != b_num_sign)) begin
            p.special.bits = default_nan(fmt);
            p.special.flags = input_flags | FPSR_IOC;
          end else if (pa.inf) begin
            p.special.bits = pack_inf(pa.sign, fmt);
            p.special.flags = input_flags;
          end else begin
            p.special.bits = pack_inf(b_num_sign, fmt);
            p.special.flags = input_flags;
          end
        end else if (pa.zero && pb.zero) begin
          result_sign = (pa.sign == b_num_sign) ? pa.sign
                                                : (rmode == 2'b10);
          p.is_special = 1'b1;
          p.special.bits = pack_zero(result_sign, fmt);
          p.special.flags = input_flags;
        end else begin
          common_exp2 = (pa.exp2 > pb.exp2) ? pa.exp2 : pb.exp2;
          a_ext = shr_sticky(pa.sig << ADD_EXTRA, common_exp2 - pa.exp2);
          b_ext = shr_sticky(pb.sig << ADD_EXTRA, common_exp2 - pb.exp2);
          if (pa.sign == b_num_sign) begin
            magnitude = a_ext + b_ext;
            result_sign = pa.sign;
          end else if (a_ext >= b_ext) begin
            magnitude = a_ext - b_ext;
            result_sign = pa.sign;
          end else begin
            magnitude = b_ext - a_ext;
            result_sign = b_num_sign;
          end
          if (magnitude == 0) begin
            result_sign = (rmode == 2'b10);
            p.is_special = 1'b1;
            p.special.bits = pack_zero(result_sign, fmt);
            p.special.flags = input_flags;
          end else begin
            p.is_special = 1'b0;
            p.need_round = 1'b1;
            p.sign = result_sign;
            p.sig = magnitude;
            p.exp2 = common_exp2 - ADD_EXTRA;
            p.input_flags = input_flags;
            p.fmt = fmt;
            p.flush_zero = flush_to_zero;
            p.rmode = rmode;
            p.ahp = 1'b0;
          end
        end
      end else if (operation == FP_OP_MUL) begin
        result_sign = pa.sign ^ pb.sign;
        if ((pa.inf && pb.zero) || (pb.inf && pa.zero)) begin
          p.is_special = 1'b1;
          p.special.bits = default_nan(fmt);
          p.special.flags = input_flags | FPSR_IOC;
        end else if (pa.inf || pb.inf) begin
          p.is_special = 1'b1;
          p.special.bits = pack_inf(result_sign, fmt);
          p.special.flags = input_flags;
        end else if (pa.zero || pb.zero) begin
          p.is_special = 1'b1;
          p.special.bits = pack_zero(result_sign, fmt);
          p.special.flags = input_flags;
        end else begin
          product = pa.sig * pb.sig;
          p.is_special = 1'b0;
          p.need_round = 1'b1;
          p.sign = result_sign;
          p.sig = product;
          p.exp2 = pa.exp2 + pb.exp2;
          p.input_flags = input_flags;
          p.fmt = fmt;
          p.flush_zero = flush_to_zero;
          p.rmode = rmode;
          p.ahp = 1'b0;
        end
      end
      binary_pre_parts = p;
    end
  endfunction

  // FP-P3T round10: resolve ADD/SUB effective magnitude from the registered
  // aligned operands.  IT_ALIGN deliberately performs no magnitude-zero test
  // or special-result mux; those decisions stay in the following IT_ADD
  // stage.  Classification and original bits cross this boundary so the
  // special priority remains NaN -> Inf -> double-zero -> finite cancel.
  function automatic fp_add_mid_t binary_add_mid_from_align(
      input fp_arith_pre_t pre,
      input fp_add_align_t  aligned);
    fp_add_mid_t m;
    logic [255:0] magnitude;
    logic result_sign;
    begin
      m = '0;
      m.a_bits = pre.a_bits;
      m.b_bits = pre.b_bits;
      m.a_nan = pre.pa.nan;
      m.a_snan = pre.pa.snan;
      m.a_inf = pre.pa.inf;
      m.a_zero = pre.pa.zero;
      m.a_sign = pre.pa.sign;
      m.b_nan = pre.pb.nan;
      m.b_snan = pre.pb.snan;
      m.b_inf = pre.pb.inf;
      m.b_zero = pre.pb.zero;
      m.b_sign = pre.pb.sign;
      m.dn = pre.dn;
      m.input_flags = pre.input_flags;
      m.fmt = pre.fmt;
      m.flush_zero = pre.fz;
      m.rmode = pre.rmode;
      m.b_num_sign = pre.pb.sign ^ (pre.op == FP_OP_SUB);
      m.exp2 = aligned.common_exp2 - ADD_EXTRA;
      if (pre.pa.sign == m.b_num_sign) begin
        magnitude = aligned.a_ext + aligned.b_ext;
        result_sign = pre.pa.sign;
      end else if (aligned.a_ext >= aligned.b_ext) begin
        magnitude = aligned.a_ext - aligned.b_ext;
        result_sign = pre.pa.sign;
      end else begin
        magnitude = aligned.b_ext - aligned.a_ext;
        result_sign = m.b_num_sign;
      end
      m.magnitude = magnitude;
      m.sign = result_sign;
      binary_add_mid_from_align = m;
    end
  endfunction

  // FP-P3T round10: construct the existing pre-round payload from the
  // registered effective result.  Special handling is intentionally here,
  // after the add_mid register, so IT_ALIGN remains only the effective
  // compare/add/sub stage and IT_ADD -> pp_pre has no alignment cone.
  function automatic fp_pre_t binary_pre_from_add_mid(
      input fp_add_mid_t mid);
    fp_pre_t p;
    logic result_sign;
    begin
      p = '0;
      p.input_flags = mid.input_flags;
      p.fmt = mid.fmt;
      p.flush_zero = mid.flush_zero;
      p.rmode = mid.rmode;
      if (mid.a_nan || mid.b_nan) begin
        p.is_special = 1'b1;
        p.special.bits = propagate_nan(mid.a_bits, mid.b_bits, mid.fmt,
                                       mid.a_nan, mid.a_snan, mid.b_snan,
                                       mid.dn);
        p.special.flags = mid.input_flags |
                          ((mid.a_snan || mid.b_snan) ? FPSR_IOC : 32'd0);
      end else if (mid.a_inf || mid.b_inf) begin
        p.is_special = 1'b1;
        if (mid.a_inf && mid.b_inf && (mid.a_sign != mid.b_num_sign)) begin
          p.special.bits = default_nan(mid.fmt);
          p.special.flags = mid.input_flags | FPSR_IOC;
        end else if (mid.a_inf) begin
          p.special.bits = pack_inf(mid.a_sign, mid.fmt);
          p.special.flags = mid.input_flags;
        end else begin
          p.special.bits = pack_inf(mid.b_num_sign, mid.fmt);
          p.special.flags = mid.input_flags;
        end
      end else if (mid.a_zero && mid.b_zero) begin
        result_sign = (mid.a_sign == mid.b_num_sign) ? mid.a_sign
                                                      : (mid.rmode == 2'b10);
        p.is_special = 1'b1;
        p.special.bits = pack_zero(result_sign, mid.fmt);
        p.special.flags = mid.input_flags;
      end else if (mid.magnitude == 0) begin
        result_sign = (mid.rmode == 2'b10);
        p.is_special = 1'b1;
        p.special.bits = pack_zero(result_sign, mid.fmt);
        p.special.flags = mid.input_flags;
      end else begin
        p.is_special = 1'b0;
        p.need_round = 1'b1;
        p.sign = mid.sign;
        p.sig = mid.magnitude;
        p.exp2 = mid.exp2;
        p.ahp = 1'b0;
      end
      binary_pre_from_add_mid = p;
    end
  endfunction

  // FP-P3T round9: capture the wide exponent-dependent alignment only.  The
  // caller invokes this for ADD/SUB after arith_pre has performed unpack/FZ;
  // special values are harmlessly represented by zero intermediates; their
  // classification and original bits are carried through add_mid for the
  // following IT_ADD special-resolution stage.
  function automatic fp_add_align_t binary_align_parts(
      input fp_arith_pre_t pre);
    fp_add_align_t m;
    integer common_exp2;
    begin
      m = '0;
      common_exp2 = (pre.pa.exp2 > pre.pb.exp2) ? pre.pa.exp2 : pre.pb.exp2;
      m.common_exp2 = common_exp2;
      m.a_ext = shr_sticky(pre.pa.sig << ADD_EXTRA,
                           common_exp2 - pre.pa.exp2);
      m.b_ext = shr_sticky(pre.pb.sig << ADD_EXTRA,
                           common_exp2 - pre.pb.exp2);
      binary_align_parts = m;
    end
  endfunction

  function automatic fp_calc_t compare_op(
      input fp_fmt_t      fmt,
      input logic [63:0]  a_bits,
      input logic [63:0]  b_bits,
      input logic         flush_to_zero,
      input logic         cmp_zero,
      input logic         signal_nans);
    fp_calc_t r;
    logic a_sign;
    logic b_sign;
    logic [10:0] a_exp;
    logic [10:0] b_exp;
    logic [51:0] a_frac;
    logic [51:0] b_frac;
    logic a_nan;
    logic b_nan;
    logic a_snan;
    logic b_snan;
    logic a_zero;
    logic b_zero;
    logic less_mag;
    logic greater_mag;
    logic less_value;
    logic greater_value;
    begin
      r = '0;
      unique case (fmt)
        FMT_HALF: begin
          a_sign = a_bits[15];
          b_sign = b_bits[15];
          a_exp = {6'd0, a_bits[14:10]};
          b_exp = {6'd0, b_bits[14:10]};
          a_frac = {42'd0, a_bits[9:0]};
          b_frac = {42'd0, b_bits[9:0]};
        end
        FMT_SINGLE: begin
          a_sign = a_bits[31];
          b_sign = b_bits[31];
          a_exp = {3'd0, a_bits[30:23]};
          b_exp = {3'd0, b_bits[30:23]};
          a_frac = {29'd0, a_bits[22:0]};
          b_frac = {29'd0, b_bits[22:0]};
        end
        default: begin
          a_sign = a_bits[63];
          b_sign = b_bits[63];
          a_exp = a_bits[62:52];
          b_exp = b_bits[62:52];
          a_frac = a_bits[51:0];
          b_frac = b_bits[51:0];
        end
      endcase
      unique case (fmt)
        FMT_HALF: begin
          a_nan = (a_exp == 11'h1f) && (|a_frac);
          b_nan = (b_exp == 11'h1f) && (|b_frac);
          a_snan = a_nan && !a_frac[9];
          b_snan = b_nan && !b_frac[9];
        end
        FMT_SINGLE: begin
          a_nan = (a_exp[7:0] == 8'hff) && (|a_frac);
          b_nan = (b_exp[7:0] == 8'hff) && (|b_frac);
          a_snan = a_nan && !a_frac[22];
          b_snan = b_nan && !b_frac[22];
        end
        default: begin
          a_nan = (a_exp == 11'h7ff) && (|a_frac);
          b_nan = (b_exp == 11'h7ff) && (|b_frac);
          a_snan = a_nan && !a_frac[51];
          b_snan = b_nan && !b_frac[51];
        end
      endcase
      a_zero = (a_exp == 0) && !(|a_frac);
      b_zero = (b_exp == 0) && !(|b_frac);
      less_mag = 1'b0;
      greater_mag = 1'b0;
      less_value = 1'b0;
      greater_value = 1'b0;
      // FCMP #0 has no second V source. Its zero is positive zero.
      if (cmp_zero) begin
        b_sign = 1'b0;
        b_exp = 11'd0;
        b_frac = 52'd0;
        b_nan = 1'b0;
        b_snan = 1'b0;
        b_zero = 1'b1;
      end
      if (flush_to_zero && a_exp == 0 && (|a_frac)) begin
        a_zero = 1'b1;
        r.flags = r.flags | FPSR_IDC;
      end
      if (!cmp_zero && flush_to_zero && b_exp == 0 && (|b_frac)) begin
        b_zero = 1'b1;
        r.flags = r.flags | FPSR_IDC;
      end

      if (a_nan || b_nan) begin
        // FCMP is quiet for QNaN; FCMPE (not part of the first P7-1 matrix)
        // can request signaling of all NaNs through signal_nans.
        if (signal_nans || a_snan || b_snan)
          r.flags = r.flags | FPSR_IOC;
        r.nzcv = 4'b0011; // unordered: N=0 Z=0 C=1 V=1
      end else if (a_zero && b_zero) begin
        r.nzcv = 4'b0110; // equal
      end else if (a_sign != b_sign) begin
        less_value = a_sign;
        r.nzcv = less_value ? 4'b1000 : 4'b0010;
      end else begin
        if (a_exp < b_exp)
          less_mag = 1'b1;
        else if (a_exp > b_exp)
          greater_mag = 1'b1;
        else if (a_frac < b_frac)
          less_mag = 1'b1;
        else if (a_frac > b_frac)
          greater_mag = 1'b1;
        else begin
          less_mag = 1'b0;
          greater_mag = 1'b0;
        end
        // A negative comparison reverses the unsigned magnitude order.
        less_value = a_sign ? greater_mag : less_mag;
        greater_value = a_sign ? less_mag : greater_mag;
        r.nzcv = less_value ? 4'b1000
                 : greater_value ? 4'b0010 : 4'b0110;
      end
      compare_op = r;
    end
  endfunction

  // ---- P7-4/P7-5：FP 解包（H/S/D 通用，供 FMA/转换/sqrt/minmax 复用）----
  function automatic fp_parts_t unpack_fp(
      input fp_fmt_t fmt, input logic [63:0] bits);
    fp_parts_t p;
    integer e;
    begin
      p = '0;
      unique case (fmt)
        FMT_HALF: begin
          p.sign = bits[15];
          p.exp_field = {6'd0, bits[14:10]};
          p.frac = {42'd0, bits[9:0]};
          e = 32'(p.exp_field);
          p.exp2 = (p.exp_field == 0) ? (1 - 15 - 10)
                                      : (e - 15 - 10);
          p.sig = (p.exp_field != 0) ? {245'd0, 1'b1, p.frac[9:0]}
                                     : {246'd0, p.frac[9:0]};
        end
        FMT_SINGLE: begin
          p.sign = bits[31];
          p.exp_field = {3'd0, bits[30:23]};
          p.frac = {29'd0, bits[22:0]};
          e = 32'(p.exp_field);
          p.exp2 = (p.exp_field == 0) ? (1 - 127 - 23)
                                      : (e - 127 - 23);
          p.sig = (p.exp_field != 0) ? {232'd0, 1'b1, p.frac[22:0]}
                                     : {233'd0, p.frac[22:0]};
        end
        default: begin
          p.sign = bits[63];
          p.exp_field = bits[62:52];
          p.frac = bits[51:0];
          e = 32'(p.exp_field);
          p.exp2 = (p.exp_field == 0) ? (1 - 1023 - 52)
                                      : (e - 1023 - 52);
          p.sig = (p.exp_field != 0) ? {203'd0, 1'b1, p.frac}
                                     : {204'd0, p.frac};
        end
      endcase
      unique case (fmt)
        FMT_HALF: begin
          p.nan = (p.exp_field == 11'h1f) && (|p.frac);
          p.snan = p.nan && !p.frac[9];
          p.inf = (p.exp_field == 11'h1f) && !(|p.frac);
        end
        FMT_SINGLE: begin
          p.nan = (p.exp_field[7:0] == 8'hff) && (|p.frac);
          p.snan = p.nan && !p.frac[22];
          p.inf = (p.exp_field[7:0] == 8'hff) && !(|p.frac);
        end
        default: begin
          p.nan = (p.exp_field == 11'h7ff) && (|p.frac);
          p.snan = p.nan && !p.frac[51];
          p.inf = (p.exp_field == 11'h7ff) && !(|p.frac);
        end
      endcase
      p.zero = (p.exp_field == 0) && !(|p.frac);
      p.sub = (p.exp_field == 0) && (|p.frac);
      unpack_fp = p;
    end
  endfunction

  // 用指定 sign 位替换 raw bits 的符号位（S 输入高 32 位恒为零）。
  function automatic logic [63:0] with_sign(
      input logic sign, input logic [63:0] bits, input fp_fmt_t fmt);
    begin
      unique case (fmt)
        FMT_HALF:   with_sign = {48'd0, sign, bits[14:0]};
        FMT_SINGLE: with_sign = {bits[63:32], sign, bits[30:0]};
        default:    with_sign = {sign, bits[62:0]};
      endcase
    end
  endfunction

  // ---- P7-1/P7-5：FDIV 结果装配 ----
  // 由多周期 lcvex_fp_divider 提供 floor(N/D) 商和 remainder!=0 的 sticky，
  // 本函数只做边界/NaN/Inf/zero/舍入，不再包含 >64-bit '/' 或 '%'。
  function automatic fp_calc_t div_finish(
      input fp_fmt_t         fmt,
      input logic [63:0]     a_bits,
      input logic [63:0]     b_bits,
      input logic [FP_W-1:0] quotient,
      input logic            remainder_sticky,
      input logic            default_nan_mode,
      input logic            flush_to_zero,
      input logic [1:0]      rmode);
    fp_calc_t r;
    fp_parts_t pa;
    fp_parts_t pb;
    logic [31:0] input_flags;
    logic [FP_W-1:0] q;
    logic result_sign;
    begin
      r = '0;
      pa = unpack_fp(fmt, a_bits);
      pb = unpack_fp(fmt, b_bits);
      input_flags = 32'd0;
      if (flush_to_zero && pa.sub) begin
        pa.zero = 1'b1;
        pa.sub = 1'b0;
        pa.sig = '0;
        input_flags = input_flags | FPSR_IDC;
      end
      if (flush_to_zero && pb.sub) begin
        pb.zero = 1'b1;
        pb.sub = 1'b0;
        pb.sig = '0;
        input_flags = input_flags | FPSR_IDC;
      end

      if (pa.nan || pb.nan) begin
        r.bits = propagate_nan(a_bits, b_bits, fmt, pa.nan,
                               pa.snan, pb.snan, default_nan_mode);
        r.flags = input_flags | ((pa.snan || pb.snan) ? FPSR_IOC : 32'd0);
      end else if ((pa.inf && pb.inf) || (pa.zero && pb.zero)) begin
        r.bits = default_nan(fmt);
        r.flags = input_flags | FPSR_IOC;
      end else if (pb.zero && !pa.inf && !pa.zero) begin
        result_sign = pa.sign ^ pb.sign;
        r.bits = pack_inf(result_sign, fmt);
        r.flags = input_flags | FPSR_DZC;
      end else if (pa.inf) begin
        result_sign = pa.sign ^ pb.sign;
        r.bits = pack_inf(result_sign, fmt);
        r.flags = input_flags;
      end else if (pa.zero) begin
        result_sign = pa.sign ^ pb.sign;
        r.bits = pack_zero(result_sign, fmt);
        r.flags = input_flags;
      end else if (pb.inf) begin
        result_sign = pa.sign ^ pb.sign;
        r.bits = pack_zero(result_sign, fmt);
        r.flags = input_flags;
      end else begin
        q = quotient;
        if (remainder_sticky)
          q[0] = 1'b1; // quotient bit zero becomes the sticky bit
        result_sign = pa.sign ^ pb.sign;
        r = round_pack(result_sign, q,
                       pa.exp2 - pb.exp2 - DIV_EXTRA, fmt,
                       flush_to_zero, rmode, 1'b0);
        r.flags = r.flags | input_flags;
      end
      div_finish = r;
    end
  endfunction

  // FP-P3T round6: pre-round intermediate for the iterative FDIV finish.
  // This captures the unpacked/special-value decision and the final quotient
  // (plus sticky) in one cycle, leaving only round_pack for the next cycle.
  function automatic fp_pre_t div_finish_pre(
      input fp_fmt_t         fmt,
      input logic [63:0]     a_bits,
      input logic [63:0]     b_bits,
      input logic [FP_W-1:0] quotient,
      input logic            remainder_sticky,
      input logic            default_nan_mode,
      input logic            flush_to_zero,
      input logic [1:0]      rmode);
    fp_pre_t p;
    fp_parts_t pa;
    fp_parts_t pb;
    logic [31:0] input_flags;
    logic [FP_W-1:0] q;
    logic result_sign;
    begin
      p = '0;
      pa = unpack_fp(fmt, a_bits);
      pb = unpack_fp(fmt, b_bits);
      input_flags = 32'd0;
      if (flush_to_zero && pa.sub) begin
        pa.zero = 1'b1;
        pa.sub = 1'b0;
        pa.sig = '0;
        input_flags = input_flags | FPSR_IDC;
      end
      if (flush_to_zero && pb.sub) begin
        pb.zero = 1'b1;
        pb.sub = 1'b0;
        pb.sig = '0;
        input_flags = input_flags | FPSR_IDC;
      end

      if (pa.nan || pb.nan) begin
        p.is_special = 1'b1;
        p.special.bits = propagate_nan(a_bits, b_bits, fmt, pa.nan,
                                       pa.snan, pb.snan, default_nan_mode);
        p.special.flags = input_flags | ((pa.snan || pb.snan) ? FPSR_IOC : 32'd0);
      end else if ((pa.inf && pb.inf) || (pa.zero && pb.zero)) begin
        p.is_special = 1'b1;
        p.special.bits = default_nan(fmt);
        p.special.flags = input_flags | FPSR_IOC;
      end else if (pb.zero && !pa.inf && !pa.zero) begin
        result_sign = pa.sign ^ pb.sign;
        p.is_special = 1'b1;
        p.special.bits = pack_inf(result_sign, fmt);
        p.special.flags = input_flags | FPSR_DZC;
      end else if (pa.inf) begin
        result_sign = pa.sign ^ pb.sign;
        p.is_special = 1'b1;
        p.special.bits = pack_inf(result_sign, fmt);
        p.special.flags = input_flags;
      end else if (pa.zero) begin
        result_sign = pa.sign ^ pb.sign;
        p.is_special = 1'b1;
        p.special.bits = pack_zero(result_sign, fmt);
        p.special.flags = input_flags;
      end else if (pb.inf) begin
        result_sign = pa.sign ^ pb.sign;
        p.is_special = 1'b1;
        p.special.bits = pack_zero(result_sign, fmt);
        p.special.flags = input_flags;
      end else begin
        q = quotient;
        if (remainder_sticky)
          q[0] = 1'b1; // quotient bit zero becomes the sticky bit
        result_sign = pa.sign ^ pb.sign;
        p.is_special = 1'b0;
        p.need_round = 1'b1;
        p.sign = result_sign;
        p.sig = q;
        p.lead = leading_one_index(q);
        p.lead_valid = (|q != 1'b0);
        p.exp2 = pa.exp2 - pb.exp2 - DIV_EXTRA;
        p.fmt = fmt;
        p.flush_zero = flush_to_zero;
        p.rmode = rmode;
        p.ahp = 1'b0;
        p.input_flags = input_flags;
      end
      div_finish_pre = p;
    end
  endfunction

  // ---- P7-4：fused multiply-add ----
  // QEMU A64 muladd = a*b + c。四种标量 FMA 与 NEON FMLA/FMLS 都复用本
  // 函数；负号按 QEMU do_fmadd 的 neg_a/neg_n 在输入上翻转，因此输入 NaN
  // 的符号位与参考行为一致。NaN 优先级按 QEMU 的 float_3nan_prop_s_cab
  // （先 SNaN，扫描顺序 C、A、B；DN=1 时 default NaN）。
  function automatic fp_calc_t fma_op(
      input fp_op_t       operation,
      input fp_fmt_t      fmt,
      input logic [63:0]  a_bits,
      input logic [63:0]  b_bits,
      input logic [63:0]  c_bits,
      input logic         default_nan_mode,
      input logic         flush_to_zero,
      input logic [1:0]   rmode);
    fp_calc_t r;
    fp_parts_t pa;
    fp_parts_t pb;
    fp_parts_t pc;
    logic neg_a;
    logic neg_c;
    logic p_sign;
    logic any_snan;
    logic infzero;
    logic nan_is_snan;
    logic [63:0] nan_bits;
    logic [31:0] input_flags;
    logic [255:0] product;
    logic [255:0] product_ext;
    logic [255:0] c_ext;
    logic [255:0] magnitude;
    integer common_exp2;
    begin
      r = '0;
      pa = unpack_fp(fmt, a_bits);
      pb = unpack_fp(fmt, b_bits);
      pc = unpack_fp(fmt, c_bits);
      // FMADD=F F / FMSUB=F T / FNMADD=T T / FNMSUB=T F（neg_a, neg_n）
      neg_a = (operation == FP_OP_FMSUB) || (operation == FP_OP_FNMADD);
      neg_c = (operation == FP_OP_FNMADD) || (operation == FP_OP_FNMSUB);
      if (neg_a)
        pa.sign = !pa.sign;
      if (neg_c)
        pc.sign = !pc.sign;

      input_flags = 32'd0;
      if (flush_to_zero && pa.sub) begin
        pa.zero = 1'b1;
        pa.sub = 1'b0;
        pa.sig = 256'd0;
        input_flags = input_flags | FPSR_IDC;
      end
      if (flush_to_zero && pb.sub) begin
        pb.zero = 1'b1;
        pb.sub = 1'b0;
        pb.sig = 256'd0;
        input_flags = input_flags | FPSR_IDC;
      end
      if (flush_to_zero && pc.sub) begin
        pc.zero = 1'b1;
        pc.sub = 1'b0;
        pc.sig = 256'd0;
        input_flags = input_flags | FPSR_IDC;
      end

      if (pa.nan || pb.nan || pc.nan) begin
        any_snan = pa.snan || pb.snan || pc.snan;
        infzero = ((pa.inf && pb.zero) || (pa.zero && pb.inf));
        if (default_nan_mode) begin
          r.bits = default_nan(fmt);
          r.flags = input_flags | (any_snan ? FPSR_IOC : 32'd0);
        end else if (infzero) begin
          // QEMU float_infzeronan_dnan_if_qnan：QNaN addend -> default NaN；
          // SNaN addend 保留（quiet），非 NaN addend 仍因 inf*0 无效。
          if (pc.nan && !pc.snan)
            r.bits = default_nan(fmt);
          else if (pc.nan)
            r.bits = quiet_nan(with_sign(pc.sign, c_bits, fmt), fmt);
          else
            r.bits = with_sign(pc.sign, c_bits, fmt);
          r.flags = input_flags | FPSR_IOC;
        end else begin
          nan_is_snan = 1'b0;
          if (pc.snan) begin
            nan_bits = with_sign(pc.sign, c_bits, fmt);
            nan_is_snan = 1'b1;
          end else if (pa.snan) begin
            nan_bits = with_sign(pa.sign, a_bits, fmt);
            nan_is_snan = 1'b1;
          end else if (pb.snan) begin
            nan_bits = b_bits;
            nan_is_snan = 1'b1;
          end else if (pc.nan) begin
            nan_bits = with_sign(pc.sign, c_bits, fmt);
          end else if (pa.nan) begin
            nan_bits = with_sign(pa.sign, a_bits, fmt);
          end else begin
            nan_bits = b_bits;
          end
          r.bits = nan_is_snan ? quiet_nan(nan_bits, fmt) : nan_bits;
          r.flags = input_flags | (any_snan ? FPSR_IOC : 32'd0);
        end
      end else if ((pa.inf && pb.zero) || (pa.zero && pb.inf)) begin
        r.bits = default_nan(fmt);
        r.flags = input_flags | FPSR_IOC;
      end else if (pa.inf || pb.inf) begin
        p_sign = pa.sign ^ pb.sign;
        if (pc.inf && (p_sign != pc.sign)) begin
          r.bits = default_nan(fmt);
          r.flags = input_flags | FPSR_IOC;
        end else begin
          r.bits = pack_inf(p_sign, fmt);
          r.flags = input_flags;
        end
      end else if (pc.inf) begin
        r.bits = pack_inf(pc.sign, fmt);
        r.flags = input_flags;
      end else if (pa.zero || pb.zero) begin
        p_sign = pa.sign ^ pb.sign;
        if (pc.zero) begin
          if (p_sign == pc.sign) begin
            r.bits = pack_zero(pc.sign, fmt);
          end else begin
            r.bits = pack_zero(rmode == 2'b10, fmt);
          end
          r.flags = input_flags;
        end else begin
          // 0 * b + c == c 精确；只保留输入 flush 的 IDC。
          r.bits = with_sign(pc.sign, c_bits, fmt);
          r.flags = input_flags;
        end
      end else begin
        p_sign = pa.sign ^ pb.sign;
        product = pa.sig * pb.sig;
        common_exp2 = (pa.exp2 + pb.exp2 > pc.exp2)
                      ? (pa.exp2 + pb.exp2) : pc.exp2;
        product_ext = shr_sticky(product << ADD_EXTRA,
                                 common_exp2 - (pa.exp2 + pb.exp2));
        c_ext = shr_sticky(pc.sig << ADD_EXTRA,
                           common_exp2 - pc.exp2);
        if (p_sign == pc.sign) begin
          magnitude = product_ext + c_ext;
          r = round_pack(p_sign, magnitude, common_exp2 - ADD_EXTRA,
                         fmt, flush_to_zero, rmode, 1'b0);
        end else if (product_ext >= c_ext) begin
          magnitude = product_ext - c_ext;
          r = round_pack(p_sign, magnitude, common_exp2 - ADD_EXTRA,
                         fmt, flush_to_zero, rmode, 1'b0);
        end else begin
          magnitude = c_ext - product_ext;
          r = round_pack(pc.sign, magnitude, common_exp2 - ADD_EXTRA,
                         fmt, flush_to_zero, rmode, 1'b0);
        end
        if (magnitude == 0) begin
          // 精确相消：QEMU 0-0 符号规则（round toward -Inf 才为 -0）。
          r.bits = pack_zero(rmode == 2'b10, fmt);
        end
        r.flags = r.flags | input_flags;
      end
      fma_op = r;
    end
  endfunction

  // FP-P3T: fused multiply-add pre-round stage.  The finite path computes the
  // exact aligned sum/difference magnitude and defers round_pack to the next
  // pipeline stage; special values are resolved immediately.
  function automatic fp_pre_t fma_pre(
      input fp_op_t       operation,
      input fp_fmt_t      fmt,
      input logic [63:0]  a_bits,
      input logic [63:0]  b_bits,
      input logic [63:0]  c_bits,
      input logic         default_nan_mode,
      input logic         flush_to_zero,
      input logic [1:0]   rmode);
    fp_pre_t p;
    fp_parts_t pa;
    fp_parts_t pb;
    fp_parts_t pc;
    logic neg_a;
    logic neg_c;
    logic p_sign;
    logic any_snan;
    logic infzero;
    logic nan_is_snan;
    logic [63:0] nan_bits;
    logic [31:0] input_flags;
    logic [255:0] product;
    logic [255:0] product_ext;
    logic [255:0] c_ext;
    logic [255:0] magnitude;
    integer common_exp2;
    begin
      p = '0;
      pa = unpack_fp(fmt, a_bits);
      pb = unpack_fp(fmt, b_bits);
      pc = unpack_fp(fmt, c_bits);
      neg_a = (operation == FP_OP_FMSUB) || (operation == FP_OP_FNMADD);
      neg_c = (operation == FP_OP_FNMADD) || (operation == FP_OP_FNMSUB);
      if (neg_a)
        pa.sign = !pa.sign;
      if (neg_c)
        pc.sign = !pc.sign;

      input_flags = 32'd0;
      if (flush_to_zero && pa.sub) begin
        pa.zero = 1'b1;
        pa.sub = 1'b0;
        pa.sig = 256'd0;
        input_flags = input_flags | FPSR_IDC;
      end
      if (flush_to_zero && pb.sub) begin
        pb.zero = 1'b1;
        pb.sub = 1'b0;
        pb.sig = 256'd0;
        input_flags = input_flags | FPSR_IDC;
      end
      if (flush_to_zero && pc.sub) begin
        pc.zero = 1'b1;
        pc.sub = 1'b0;
        pc.sig = 256'd0;
        input_flags = input_flags | FPSR_IDC;
      end

      if (pa.nan || pb.nan || pc.nan) begin
        any_snan = pa.snan || pb.snan || pc.snan;
        infzero = ((pa.inf && pb.zero) || (pa.zero && pb.inf));
        p.is_special = 1'b1;
        if (default_nan_mode) begin
          p.special.bits = default_nan(fmt);
          p.special.flags = input_flags | (any_snan ? FPSR_IOC : 32'd0);
        end else if (infzero) begin
          if (pc.nan && !pc.snan)
            p.special.bits = default_nan(fmt);
          else if (pc.nan)
            p.special.bits = quiet_nan(with_sign(pc.sign, c_bits, fmt), fmt);
          else
            p.special.bits = with_sign(pc.sign, c_bits, fmt);
          p.special.flags = input_flags | FPSR_IOC;
        end else begin
          nan_is_snan = 1'b0;
          if (pc.snan) begin
            nan_bits = with_sign(pc.sign, c_bits, fmt);
            nan_is_snan = 1'b1;
          end else if (pa.snan) begin
            nan_bits = with_sign(pa.sign, a_bits, fmt);
            nan_is_snan = 1'b1;
          end else if (pb.snan) begin
            nan_bits = b_bits;
            nan_is_snan = 1'b1;
          end else if (pc.nan) begin
            nan_bits = with_sign(pc.sign, c_bits, fmt);
          end else if (pa.nan) begin
            nan_bits = with_sign(pa.sign, a_bits, fmt);
          end else begin
            nan_bits = b_bits;
          end
          p.special.bits = nan_is_snan ? quiet_nan(nan_bits, fmt) : nan_bits;
          p.special.flags = input_flags | (any_snan ? FPSR_IOC : 32'd0);
        end
      end else if ((pa.inf && pb.zero) || (pa.zero && pb.inf)) begin
        p.is_special = 1'b1;
        p.special.bits = default_nan(fmt);
        p.special.flags = input_flags | FPSR_IOC;
      end else if (pa.inf || pb.inf) begin
        p_sign = pa.sign ^ pb.sign;
        p.is_special = 1'b1;
        if (pc.inf && (p_sign != pc.sign)) begin
          p.special.bits = default_nan(fmt);
          p.special.flags = input_flags | FPSR_IOC;
        end else begin
          p.special.bits = pack_inf(p_sign, fmt);
          p.special.flags = input_flags;
        end
      end else if (pc.inf) begin
        p.is_special = 1'b1;
        p.special.bits = pack_inf(pc.sign, fmt);
        p.special.flags = input_flags;
      end else if (pa.zero || pb.zero) begin
        p_sign = pa.sign ^ pb.sign;
        p.is_special = 1'b1;
        if (pc.zero) begin
          if (p_sign == pc.sign)
            p.special.bits = pack_zero(pc.sign, fmt);
          else
            p.special.bits = pack_zero(rmode == 2'b10, fmt);
          p.special.flags = input_flags;
        end else begin
          p.special.bits = with_sign(pc.sign, c_bits, fmt);
          p.special.flags = input_flags;
        end
      end else begin
        p_sign = pa.sign ^ pb.sign;
        product = pa.sig * pb.sig;
        common_exp2 = (pa.exp2 + pb.exp2 > pc.exp2)
                      ? (pa.exp2 + pb.exp2) : pc.exp2;
        product_ext = shr_sticky(product << ADD_EXTRA,
                                 common_exp2 - (pa.exp2 + pb.exp2));
        c_ext = shr_sticky(pc.sig << ADD_EXTRA,
                           common_exp2 - pc.exp2);
        if (p_sign == pc.sign) begin
          magnitude = product_ext + c_ext;
          p.sign = p_sign;
        end else if (product_ext >= c_ext) begin
          magnitude = product_ext - c_ext;
          p.sign = p_sign;
        end else begin
          magnitude = c_ext - product_ext;
          p.sign = pc.sign;
        end
        if (magnitude == 0) begin
          p.is_special = 1'b1;
          p.special.bits = pack_zero(rmode == 2'b10, fmt);
          p.special.flags = input_flags;
        end else begin
          p.is_special = 1'b0;
          p.need_round = 1'b1;
          p.sig = magnitude;
          p.exp2 = common_exp2 - ADD_EXTRA;
          p.input_flags = input_flags;
          p.fmt = fmt;
          p.flush_zero = flush_to_zero;
          p.rmode = rmode;
          p.ahp = 1'b0;
        end
      end
      fma_pre = p;
    end
  endfunction

  // FP-P3T round3: complete the fused multiply-add pre-round stage from
  // already-unpacked/FZ-flushed parts.  This contains only product + aligned
  // add/sub cone that feeds pp_pre.
  function automatic fp_pre_t fma_pre_parts(
      input fp_op_t       operation,
      input fp_fmt_t      fmt,
      input logic [63:0]  a_bits,
      input logic [63:0]  b_bits,
      input logic [63:0]  c_bits,
      input fp_parts_t    pa,
      input fp_parts_t    pb,
      input fp_parts_t    pc,
      input logic [31:0]  input_flags,
      input logic         default_nan_mode,
      input logic         flush_to_zero,
      input logic [1:0]   rmode);
    fp_pre_t p;
    fp_parts_t xa;
    fp_parts_t xb;
    fp_parts_t xc;
    logic neg_a;
    logic neg_c;
    logic p_sign;
    logic any_snan;
    logic infzero;
    logic nan_is_snan;
    logic [63:0] nan_bits;
    logic [255:0] product;
    logic [255:0] product_ext;
    logic [255:0] c_ext;
    logic [255:0] magnitude;
    integer common_exp2;
    begin
      p = '0;
      xa = pa;
      xb = pb;
      xc = pc;
      neg_a = (operation == FP_OP_FMSUB) || (operation == FP_OP_FNMADD);
      neg_c = (operation == FP_OP_FNMADD) || (operation == FP_OP_FNMSUB);
      if (neg_a)
        xa.sign = !xa.sign;
      if (neg_c)
        xc.sign = !xc.sign;

      if (xa.nan || xb.nan || xc.nan) begin
        any_snan = xa.snan || xb.snan || xc.snan;
        infzero = ((xa.inf && xb.zero) || (xa.zero && xb.inf));
        p.is_special = 1'b1;
        if (default_nan_mode) begin
          p.special.bits = default_nan(fmt);
          p.special.flags = input_flags | (any_snan ? FPSR_IOC : 32'd0);
        end else if (infzero) begin
          if (xc.nan && !xc.snan)
            p.special.bits = default_nan(fmt);
          else if (xc.nan)
            p.special.bits = quiet_nan(with_sign(xc.sign, c_bits, fmt), fmt);
          else
            p.special.bits = with_sign(xc.sign, c_bits, fmt);
          p.special.flags = input_flags | FPSR_IOC;
        end else begin
          nan_is_snan = 1'b0;
          if (xc.snan) begin
            nan_bits = with_sign(xc.sign, c_bits, fmt);
            nan_is_snan = 1'b1;
          end else if (xa.snan) begin
            nan_bits = with_sign(xa.sign, a_bits, fmt);
            nan_is_snan = 1'b1;
          end else if (xb.snan) begin
            nan_bits = b_bits;
            nan_is_snan = 1'b1;
          end else if (xc.nan) begin
            nan_bits = with_sign(xc.sign, c_bits, fmt);
          end else if (xa.nan) begin
            nan_bits = with_sign(xa.sign, a_bits, fmt);
          end else begin
            nan_bits = b_bits;
          end
          p.special.bits = nan_is_snan ? quiet_nan(nan_bits, fmt) : nan_bits;
          p.special.flags = input_flags | (any_snan ? FPSR_IOC : 32'd0);
        end
      end else if ((xa.inf && xb.zero) || (xa.zero && xb.inf)) begin
        p.is_special = 1'b1;
        p.special.bits = default_nan(fmt);
        p.special.flags = input_flags | FPSR_IOC;
      end else if (xa.inf || xb.inf) begin
        p_sign = xa.sign ^ xb.sign;
        p.is_special = 1'b1;
        if (xc.inf && (p_sign != xc.sign)) begin
          p.special.bits = default_nan(fmt);
          p.special.flags = input_flags | FPSR_IOC;
        end else begin
          p.special.bits = pack_inf(p_sign, fmt);
          p.special.flags = input_flags;
        end
      end else if (xc.inf) begin
        p.is_special = 1'b1;
        p.special.bits = pack_inf(xc.sign, fmt);
        p.special.flags = input_flags;
      end else if (xa.zero || xb.zero) begin
        p_sign = xa.sign ^ xb.sign;
        p.is_special = 1'b1;
        if (xc.zero) begin
          if (p_sign == xc.sign)
            p.special.bits = pack_zero(xc.sign, fmt);
          else
            p.special.bits = pack_zero(rmode == 2'b10, fmt);
          p.special.flags = input_flags;
        end else begin
          p.special.bits = with_sign(xc.sign, c_bits, fmt);
          p.special.flags = input_flags;
        end
      end else begin
        p_sign = xa.sign ^ xb.sign;
        product = xa.sig * xb.sig;
        common_exp2 = (xa.exp2 + xb.exp2 > xc.exp2)
                      ? (xa.exp2 + xb.exp2) : xc.exp2;
        product_ext = shr_sticky(product << ADD_EXTRA,
                                 common_exp2 - (xa.exp2 + xb.exp2));
        c_ext = shr_sticky(xc.sig << ADD_EXTRA,
                           common_exp2 - xc.exp2);
        if (p_sign == xc.sign) begin
          magnitude = product_ext + c_ext;
          p.sign = p_sign;
        end else if (product_ext >= c_ext) begin
          magnitude = product_ext - c_ext;
          p.sign = p_sign;
        end else begin
          magnitude = c_ext - product_ext;
          p.sign = xc.sign;
        end
        if (magnitude == 0) begin
          p.is_special = 1'b1;
          p.special.bits = pack_zero(rmode == 2'b10, fmt);
          p.special.flags = input_flags;
        end else begin
          p.is_special = 1'b0;
          p.need_round = 1'b1;
          p.sig = magnitude;
          p.exp2 = common_exp2 - ADD_EXTRA;
          p.input_flags = input_flags;
          p.fmt = fmt;
          p.flush_zero = flush_to_zero;
          p.rmode = rmode;
          p.ahp = 1'b0;
        end
      end
      fma_pre_parts = p;
    end
  endfunction

  // FP-P3T round5: stage-2 product capture for MUL/FMA.  This contains only
  // the multiplier product, product sign and product exponent; the remaining
  // alignment/adds and pp_pre write are deferred to the next pipeline stage.
  function automatic fp_pre_t mul_product_pre(input fp_arith_pre_t pre);
    fp_pre_t p;
    logic neg_a;
    begin
      p = '0;
      p.need_round = 1'b1;
      p.sign = pre.pa.sign ^ pre.pb.sign;
      neg_a = (pre.op == FP_OP_FMSUB) || (pre.op == FP_OP_FNMADD);
      if (neg_a)
        p.sign = !p.sign;
      p.sig = pre.pa.sig * pre.pb.sig;
      p.exp2 = pre.pa.exp2 + pre.pb.exp2;
      p.input_flags = pre.input_flags;
      p.fmt = pre.fmt;
      p.flush_zero = pre.fz;
      p.rmode = pre.rmode;
      p.ahp = 1'b0;
      mul_product_pre = p;
    end
  endfunction

  // FP-P3T round5: complete a finite FMUL pre-round stage from the captured
  // multiplier product.  Special-value handling is identical to
  // binary_pre_parts and is done from the still-valid ap_pre operands.
  function automatic fp_pre_t mul_pre_from_product(
      input fp_arith_pre_t pre,
      input fp_pre_t       prod);
    fp_pre_t p;
    begin
      p = '0;
      if (pre.pa.nan || pre.pb.nan) begin
        p.is_special = 1'b1;
        p.special.bits = propagate_nan(pre.a_bits, pre.b_bits, pre.fmt,
                                       pre.pa.nan, pre.pa.snan,
                                       pre.pb.snan, pre.dn);
        p.special.flags = pre.input_flags |
                          ((pre.pa.snan || pre.pb.snan) ? FPSR_IOC : 32'd0);
      end else if ((pre.pa.inf && pre.pb.zero) ||
                  (pre.pb.inf && pre.pa.zero)) begin
        p.is_special = 1'b1;
        p.special.bits = default_nan(pre.fmt);
        p.special.flags = pre.input_flags | FPSR_IOC;
      end else if (pre.pa.inf || pre.pb.inf) begin
        p.is_special = 1'b1;
        p.special.bits = pack_inf(pre.pa.sign ^ pre.pb.sign, pre.fmt);
        p.special.flags = pre.input_flags;
      end else if (pre.pa.zero || pre.pb.zero) begin
        p.is_special = 1'b1;
        p.special.bits = pack_zero(pre.pa.sign ^ pre.pb.sign, pre.fmt);
        p.special.flags = pre.input_flags;
      end else begin
        p.is_special = 1'b0;
        p.need_round = 1'b1;
        p.sign = prod.sign;
        p.sig = prod.sig;
        p.exp2 = prod.exp2;
        p.input_flags = prod.input_flags;
        p.fmt = prod.fmt;
        p.flush_zero = prod.flush_zero;
        p.rmode = prod.rmode;
        p.ahp = prod.ahp;
      end
      mul_pre_from_product = p;
    end
  endfunction

  // FP-P3T round21: capture the FMA product/addend alignment payload after
  // the multiplier-product register.  The finite path stops after the two
  // wide sticky shifts; the wide compare/add/sub is deliberately deferred to
  // fma_pre_from_product in IT_FMA.  Special-value resolution is captured
  // here so the extra cycle does not alter NaN/Inf/zero semantics.
  function automatic fp_fma_align_t fma_align_from_product(
      input fp_arith_pre_t pre,
      input fp_pre_t       prod);
    fp_fma_align_t m;
    fp_parts_t xa;
    fp_parts_t xb;
    fp_parts_t xc;
    logic neg_a;
    logic neg_c;
    logic p_sign;
    logic any_snan;
    logic infzero;
    logic nan_is_snan;
    logic [63:0] nan_bits;
    integer product_exp2;
    integer common_exp2;
    begin
      m = '0;
      xa = pre.pa;
      xb = pre.pb;
      xc = pre.pc;
      neg_a = (pre.op == FP_OP_FMSUB) || (pre.op == FP_OP_FNMADD);
      neg_c = (pre.op == FP_OP_FNMADD) || (pre.op == FP_OP_FNMSUB);
      if (neg_a)
        xa.sign = !xa.sign;
      if (neg_c)
        xc.sign = !xc.sign;

      if (xa.nan || xb.nan || xc.nan) begin
        any_snan = xa.snan || xb.snan || xc.snan;
        infzero = ((xa.inf && xb.zero) || (xa.zero && xb.inf));
        m.is_special = 1'b1;
        if (pre.dn) begin
          m.special_bits = default_nan(pre.fmt);
          m.special_flags = pre.input_flags |
                            (any_snan ? FPSR_IOC : 32'd0);
        end else if (infzero) begin
          if (xc.nan && !xc.snan)
            m.special_bits = default_nan(pre.fmt);
          else if (xc.nan)
            m.special_bits = quiet_nan(
                with_sign(xc.sign, pre.c_bits, pre.fmt), pre.fmt);
          else
            m.special_bits = with_sign(xc.sign, pre.c_bits, pre.fmt);
          m.special_flags = pre.input_flags | FPSR_IOC;
        end else begin
          nan_is_snan = 1'b0;
          if (xc.snan) begin
            nan_bits = with_sign(xc.sign, pre.c_bits, pre.fmt);
            nan_is_snan = 1'b1;
          end else if (xa.snan) begin
            nan_bits = with_sign(xa.sign, pre.a_bits, pre.fmt);
            nan_is_snan = 1'b1;
          end else if (xb.snan) begin
            nan_bits = pre.b_bits;
            nan_is_snan = 1'b1;
          end else if (xc.nan) begin
            nan_bits = with_sign(xc.sign, pre.c_bits, pre.fmt);
          end else if (xa.nan) begin
            nan_bits = with_sign(xa.sign, pre.a_bits, pre.fmt);
          end else begin
            nan_bits = pre.b_bits;
          end
          m.special_bits = nan_is_snan ? quiet_nan(nan_bits, pre.fmt)
                                       : nan_bits;
          m.special_flags = pre.input_flags |
                            (any_snan ? FPSR_IOC : 32'd0);
        end
      end else if ((xa.inf && xb.zero) || (xa.zero && xb.inf)) begin
        m.is_special = 1'b1;
        m.special_bits = default_nan(pre.fmt);
        m.special_flags = pre.input_flags | FPSR_IOC;
      end else if (xa.inf || xb.inf) begin
        p_sign = prod.sign;
        m.is_special = 1'b1;
        if (xc.inf && (p_sign != xc.sign)) begin
          m.special_bits = default_nan(pre.fmt);
          m.special_flags = pre.input_flags | FPSR_IOC;
        end else begin
          m.special_bits = pack_inf(p_sign, pre.fmt);
          m.special_flags = pre.input_flags;
        end
      end else if (xc.inf) begin
        m.is_special = 1'b1;
        m.special_bits = pack_inf(xc.sign, pre.fmt);
        m.special_flags = pre.input_flags;
      end else if (xa.zero || xb.zero) begin
        p_sign = prod.sign;
        m.is_special = 1'b1;
        if (xc.zero) begin
          if (p_sign == xc.sign)
            m.special_bits = pack_zero(xc.sign, pre.fmt);
          else
            m.special_bits = pack_zero(pre.rmode == 2'b10, pre.fmt);
          m.special_flags = pre.input_flags;
        end else begin
          m.special_bits = with_sign(xc.sign, pre.c_bits, pre.fmt);
          m.special_flags = pre.input_flags;
        end
      end else begin
        product_exp2 = prod.exp2;
        common_exp2 = (product_exp2 > xc.exp2)
                      ? product_exp2 : xc.exp2;
        m.is_special = 1'b0;
        m.product_sign = prod.sign;
        m.c_sign = xc.sign;
        m.common_exp2 = common_exp2;
        m.product_ext = shr_sticky(prod.sig << ADD_EXTRA,
                                   common_exp2 - product_exp2);
        m.c_ext = shr_sticky(xc.sig << ADD_EXTRA,
                             common_exp2 - xc.exp2);
      end
      fma_align_from_product = m;
    end
  endfunction

  // FP-P3T round21: finish the FMA pre-round payload from the registered
  // alignment operands.  This helper contains the remaining wide compare and
  // add/sub only; it never re-enters the multiplier or exponent-dependent
  // sticky shifts.
  function automatic fp_pre_t fma_pre_from_product(
      input fp_arith_pre_t pre,
      input fp_fma_align_t aligned);
    fp_pre_t p;
    logic [255:0] magnitude;
    begin
      p = '0;
      if (aligned.is_special) begin
        p.is_special = 1'b1;
        p.special.bits = aligned.special_bits;
        p.special.flags = aligned.special_flags;
      end else begin
        if (aligned.product_sign == aligned.c_sign) begin
          magnitude = aligned.product_ext + aligned.c_ext;
          p.sign = aligned.product_sign;
        end else if (aligned.product_ext >= aligned.c_ext) begin
          magnitude = aligned.product_ext - aligned.c_ext;
          p.sign = aligned.product_sign;
        end else begin
          magnitude = aligned.c_ext - aligned.product_ext;
          p.sign = aligned.c_sign;
        end
        if (magnitude == 0) begin
          p.is_special = 1'b1;
          p.special.bits = pack_zero(pre.rmode == 2'b10, pre.fmt);
          p.special.flags = pre.input_flags;
        end else begin
          p.is_special = 1'b0;
          p.need_round = 1'b1;
          p.sig = magnitude;
          p.exp2 = aligned.common_exp2 - ADD_EXTRA;
          p.input_flags = pre.input_flags;
          p.fmt = pre.fmt;
          p.flush_zero = pre.fz;
          p.rmode = pre.rmode;
          p.ahp = 1'b0;
        end
      end
      fma_pre_from_product = p;
    end
  endfunction

  // ---- P7-4：FP -> 整数/定点（round toward zero + saturate）----
  // NaN -> 0 + IOC；超出目的范围 -> 饱和 + IOC；截断丢弃非零低位 -> IXC；
  // FZ 冲洗输入 subnormal -> IDC。与 QEMU softfloat float*_to_*_scalbn
  // 的 A64 行为一致（不产生 UFC/OFC）。
  function automatic fp_int_calc_t fp_to_int_op(
      input logic         dbl,
      input logic [63:0]  a_bits,
      input integer       shift,
      input logic         is_32,
      input logic         is_signed,
      input logic         flush_to_zero);
    fp_int_calc_t rc;
    fp_parts_t p;
    logic [255:0] mag;
    logic sticky;
    logic saturate;
    integer delta;
    integer h;
    integer i;
    begin
      rc = '0;
      p = unpack_fp(dbl ? FMT_DOUBLE : FMT_SINGLE, a_bits);
      if (flush_to_zero && p.sub) begin
        p.zero = 1'b1;
        p.sub = 1'b0;
        p.sig = 256'd0;
        rc.flags = FPSR_IDC;
      end
      if (p.nan) begin
        rc.value = 64'd0;
        rc.flags = rc.flags | FPSR_IOC;
      end else if (p.zero) begin
        // 零输入结果零、无标志。
      end else begin
      h = -1;
      for (i = FP_W - 1; i >= 0; i = i - 1) begin
        if (h < 0 && p.sig[i])
          h = i;
      end
      delta = p.exp2 + shift;
      mag = 256'd0;
      sticky = 1'b0;
      saturate = 1'b0;
      if (delta >= FP_W - h) begin
        // 值 >= 2^256，必然饱和。
        saturate = 1'b1;
      end else if (delta >= 0) begin
        mag = p.sig << delta;
      end else begin
        if (-delta >= FP_W) begin
          mag = 256'd0;
          sticky = |p.sig;
        end else begin
          mag = p.sig >> (-delta);
          sticky = any_low_bits(p.sig, -delta);
        end
      end

      // 无符号转换遇到负值（截断后仍非零）饱和到 0 + IOC。
      if (!is_signed && p.sign && (|mag))
        saturate = 1'b1;

      if (!saturate) begin
        if (is_signed) begin
          if (is_32) begin
            if (|mag[255:32] || (mag[31] && (|mag[30:0])) ||
                (mag[31] && !p.sign))
              saturate = 1'b1;
          end else begin
            if (|mag[255:64] || (mag[63] && (|mag[62:0])) ||
                (mag[63] && !p.sign))
              saturate = 1'b1;
          end
        end else begin
          if (is_32) begin
            if (|mag[255:32])
              saturate = 1'b1;
          end else begin
            if (|mag[255:64])
              saturate = 1'b1;
          end
        end
      end

      if (saturate) begin
        rc.flags = rc.flags | FPSR_IOC;
        if (is_signed) begin
          if (is_32)
            rc.value = p.sign ? 64'h0000_0000_8000_0000
                              : 64'h0000_0000_7fff_ffff;
          else
            rc.value = p.sign ? 64'h8000_0000_0000_0000
                              : 64'h7fff_ffff_ffff_ffff;
        end else begin
          if (p.sign)
            rc.value = 64'd0;
          else
            rc.value = is_32 ? 64'h0000_0000_ffff_ffff
                             : 64'hffff_ffff_ffff_ffff;
        end
      end else begin
        if (is_signed) begin
          if (is_32)
            rc.value = p.sign ? -64'(mag[31:0]) : 64'(mag[31:0]);
          else
            rc.value = p.sign ? -mag[63:0] : mag[63:0];
        end else begin
          rc.value = is_32 ? {32'd0, mag[31:0]} : mag[63:0];
        end
        if (sticky)
          rc.flags = rc.flags | FPSR_IXC;
      end
      // W 形式结果在 GPR 中零扩展（QEMU do_fcvt_g ext32u）。
      if (is_32)
        rc.value = {32'd0, rc.value[31:0]};
      end
      fp_to_int_op = rc;
    end
  endfunction

  // ---- P7-4：整数/定点 -> FP ----
  // 值 = int * 2^-scale，按当前 FPCR RMode 舍入；tiny 输出/舍入标志与
  // 算术共用 round_pack。输入是整数，不产生 IDC。
  function automatic fp_calc_t int_to_fp_op(
      input logic         dbl,
      input logic [63:0]  int_bits,
      input integer       shift,
      input logic         is_signed,
      input logic         flush_to_zero,
      input logic [1:0]   rmode);
    fp_calc_t r;
    logic [63:0] mag;
    logic sign;
    begin
      sign = is_signed && int_bits[63];
      mag = is_signed ? (int_bits[63] ? -int_bits : int_bits) : int_bits;
      r = round_pack(sign, {192'd0, mag}, -shift,
                     dbl ? FMT_DOUBLE : FMT_SINGLE,
                     flush_to_zero, rmode, 1'b0);
      int_to_fp_op = r;
    end
  endfunction

  // FP-P3T: integer/point -> FP pre-round stage.  Only the sign/magnitude and
  // scale need to be carried; round_pack is performed by the next stage.
  function automatic fp_pre_t int_to_fp_pre(
      input logic         dbl,
      input logic [63:0]  int_bits,
      input integer       shift,
      input logic         is_signed,
      input logic         flush_to_zero,
      input logic [1:0]   rmode);
    fp_pre_t p;
    logic [63:0] mag;
    begin
      p = '0;
      p.need_round = 1'b1;
      p.sign = is_signed && int_bits[63];
      mag = is_signed ? (int_bits[63] ? -int_bits : int_bits) : int_bits;
      p.sig = {192'd0, mag};
      p.exp2 = -shift;
      p.fmt = dbl ? FMT_DOUBLE : FMT_SINGLE;
      p.flush_zero = flush_to_zero;
      p.rmode = rmode;
      p.ahp = 1'b0;
      int_to_fp_pre = p;
    end
  endfunction

  // ---- P7-5：整数平方根（128-bit 输入 -> 64-bit floor，restoring）----
  function automatic logic [63:0] isqrt64(input logic [127:0] x);
    logic [255:0] rem;
    logic [63:0]  q;
    integer i;
    begin
      rem = 256'd0;
      q = 64'd0;
      for (i = 63; i >= 0; i = i - 1) begin
        rem = (rem << 2) | 256'(x[2*i + 1 -: 2]);
        q = q << 1;
        if (rem >= 256'({q, 1'b1})) begin
          rem = rem - 256'({q, 1'b1});
          q = q + 64'd1;
        end
      end
      isqrt64 = q;
    end
  endfunction

  // ---- P7-5：FSQRT（H/S/D）----
  // NaN 输入按 return_nan（SNaN quiet+IOC，DN=1 default NaN）；-0 返回
  // -0；负非零（含 -Inf）default NaN + IOC；+Inf 原样。subnormal 输入按
  // FZ/FZ16 flush（S/D 置 IDC；F16 的 IDC 由调用方屏蔽）。结果用
  // floor(sqrt(sig<<72)) + remainder 的 GRS 精确舍入，tininess-before-
  // rounding 与 round_pack 共用。
  function automatic fp_calc_t sqrt_op(
      input fp_fmt_t      fmt,
      input logic [63:0]  a_bits,
      input logic         default_nan_mode,
      input logic         flush_to_zero,
      input logic [1:0]   rmode);
    fp_calc_t r;
    fp_parts_t p;
    logic [31:0] input_flags;
    logic [127:0] s;
    logic [63:0]  q;
    logic [127:0] qsq;
    logic [255:0] q_sig;
    integer exp2e;
    integer h;
    integer shift;
    integer i;
    begin
      r = '0;
      p = unpack_fp(fmt, a_bits);
      input_flags = 32'd0;
      if (flush_to_zero && p.sub) begin
        p.zero = 1'b1;
        p.sub = 1'b0;
        p.sig = 256'd0;
        input_flags = FPSR_IDC;   // F16 由调用方屏蔽
      end
      if (p.nan) begin
        r.bits = default_nan_mode ? default_nan(fmt)
                                  : (p.snan ? quiet_nan(a_bits, fmt)
                                            : a_bits);
        r.flags = input_flags | (p.snan ? FPSR_IOC : 32'd0);
      end else if (p.zero) begin
        // FZ/FZ16 flush 过的 subnormal 输入必须返回 ±0（不是原 bits）。
        if (input_flags[7])
          r.bits = pack_zero(p.sign, fmt);
        else
          r.bits = a_bits;        // +0/-0 原样
        r.flags = input_flags;
      end else if (p.sign) begin
        r.bits = default_nan(fmt);
        r.flags = input_flags | FPSR_IOC;
      end else if (p.inf) begin
        r.bits = a_bits;
      end else begin
        exp2e = p.exp2;
        if (exp2e % 2 != 0) begin
          p.sig = p.sig << 1;
          exp2e = exp2e - 1;
        end
        // 把 radicand 缩放到使 q 始终有约 63-64 个有效位：subnormal 的
        // sig 前导位较低，固定 72-bit 左移会损失目标精度。
        h = -1;
        for (i = FP_W - 1; i >= 0; i = i - 1) begin
          if (h < 0 && p.sig[i])
            h = i;
        end
        if (h < 0)
          h = 0;
        shift = 126 - (h & ~1);
        if (shift < 0)
          shift = 0;
        s = p.sig[127:0] << shift;
        q = isqrt64(s);
        qsq = q * q;
        q_sig = 256'(q);
        if (qsq != s)
          q_sig[0] = 1'b1;        // remainder -> sticky
        r = round_pack(1'b0, q_sig, exp2e/2 - shift/2, fmt,
                       flush_to_zero, rmode, 1'b0);
        r.flags = r.flags | input_flags;
      end
      sqrt_op = r;
    end
  endfunction

  // ---- P7-5：FMIN/FMAX/FMINNM/FMAXNM（H/S/D）----
  // 语义与 QEMU parts64_minmax 对齐：
  // - FMIN/FMAX 任一 NaN -> pick_nan（SNaN 优先再 A；quiet+IOC；DN default）
  // - NM 族单侧 QNaN + 数值 -> 数值（不置 IOC，只保留数值侧 flush 标志）
  // - 双 NaN 或含 SNaN -> pick_nan
  // - 零符号 FMIN(+0,-0)=-0、FMAX(+0,-0)=+0；相等同号返回任一（raw 相同）
  // - FZ/FZ16 flush 输入 subnormal（S/D 置 IDC；F16 由调用方屏蔽）
  function automatic fp_calc_t minmax_op(
      input fp_op_t      operation,
      input fp_fmt_t     fmt,
      input logic [63:0] a_bits,
      input logic [63:0] b_bits,
      input logic        default_nan_mode,
      input logic        flush_to_zero);
    fp_calc_t r;
    fp_parts_t pa;
    fp_parts_t pb;
    logic a_flushed;
    logic b_flushed;
    logic a_nm;
    logic mag_less;
    logic a_less;
    logic signed [31:0] a_cmp_exp;
    logic signed [31:0] b_cmp_exp;
    logic [63:0] a_out;
    logic [63:0] b_out;
    begin
      r = '0;
      pa = unpack_fp(fmt, a_bits);
      pb = unpack_fp(fmt, b_bits);
      a_flushed = flush_to_zero && pa.sub;
      b_flushed = flush_to_zero && pb.sub;
      if (a_flushed) begin
        pa.zero = 1'b1;
        pa.sub = 1'b0;
        pa.sig = 256'd0;
      end
      if (b_flushed) begin
        pb.zero = 1'b1;
        pb.sub = 1'b0;
        pb.sig = 256'd0;
      end
      a_out = a_flushed ? pack_zero(pa.sign, fmt) : a_bits;
      b_out = b_flushed ? pack_zero(pb.sign, fmt) : b_bits;
      a_nm = operation inside {FP_OP_FMINNM, FP_OP_FMAXNM};
      if (pa.nan || pb.nan) begin
        if (a_nm && pa.nan && !pb.nan && !pa.snan) begin
          r.bits = b_out;
          r.flags = b_flushed ? FPSR_IDC : 32'd0;
        end else if (a_nm && pb.nan && !pa.nan && !pb.snan) begin
          r.bits = a_out;
          r.flags = a_flushed ? FPSR_IDC : 32'd0;
        end else begin
          if (pa.snan || pb.snan)
            r.flags = FPSR_IOC;
          if (default_nan_mode) begin
            r.bits = default_nan(fmt);
          end else if (pa.snan) begin
            r.bits = quiet_nan(a_bits, fmt);
          end else if (pb.snan) begin
            r.bits = quiet_nan(b_bits, fmt);
          end else if (pa.nan) begin
            r.bits = a_bits;
          end else begin
            r.bits = b_bits;
          end
        end
      end else begin
        r.flags = (a_flushed ? FPSR_IDC : 32'd0) |
                  (b_flushed ? FPSR_IDC : 32'd0);
        a_cmp_exp = pa.inf ? 32'sd1_073_741_824
                   : pa.zero ? -32'sd1_073_741_824 : 32'(pa.exp2);
        b_cmp_exp = pb.inf ? 32'sd1_073_741_824
                   : pb.zero ? -32'sd1_073_741_824 : 32'(pb.exp2);
        if (a_cmp_exp != b_cmp_exp)
          mag_less = a_cmp_exp < b_cmp_exp;
        else if (pa.sig != pb.sig)
          mag_less = pa.sig < pb.sig;
        else
          mag_less = 1'b0;
        a_less = pa.sign ? !mag_less : mag_less;
        if (operation == FP_OP_FMIN || operation == FP_OP_FMINNM)
          r.bits = a_less ? a_out : b_out;
        else
          r.bits = a_less ? b_out : a_out;
      end
      minmax_op = r;
    end
  endfunction

  // ---- P7-5：FRINT（round to integral，H/S/D）----
  // rint_mode：0=N 1=P 2=M 3=Z 4=A 5=X 6=I。N/P/M/Z/A 用固定 RMode，
  // X/I 用 FPCR.RMode；I 抑制 IXC（QEMU rinth/rints/rintd），X 保留。
  // NaN 按 return_nan；±Inf/±0 原样；subnormal 输入按 FZ/FZ16 flush
  // （S/D 置 IDC，F16 由调用方屏蔽）。结果恒为整数（normal 或 ±0）。
  function automatic fp_calc_t frint_op(
      input fp_fmt_t      fmt,
      input logic [63:0]  a_bits,
      input logic [2:0]   mode,
      input logic         default_nan_mode,
      input logic         flush_to_zero,
      input logic [1:0]   fpcr_rmode);
    fp_calc_t r;
    fp_parts_t p;
    logic [1:0] rmode;
    logic [255:0] q;
    logic guard;
    logic sticky;
    logic inc;
    logic inexact;
    integer frac_bits;
    integer bias;
    integer s;
    integer h;
    integer exp2f;
    integer i;
    logic [10:0] expf;
    begin
      r = '0;
      p = unpack_fp(fmt, a_bits);
      if (p.nan) begin
        r.bits = default_nan_mode ? default_nan(fmt)
                                  : (p.snan ? quiet_nan(a_bits, fmt)
                                            : a_bits);
        r.flags = p.snan ? FPSR_IOC : 32'd0;
      end else if (p.inf || p.zero) begin
        r.bits = a_bits;
      end else if (flush_to_zero && p.sub) begin
        r.bits = pack_zero(p.sign, fmt);
        r.flags = FPSR_IDC;       // F16 由调用方屏蔽
      end else begin
        unique case (fmt)
          FMT_HALF:   frac_bits = 10;
          FMT_SINGLE: frac_bits = 23;
          default:    frac_bits = 52;
        endcase
        unique case (fmt)
          FMT_HALF:   bias = 15;
          FMT_SINGLE: bias = 127;
          default:    bias = 1023;
        endcase
        // 整数位移量是二进制小数点位置：value = sig * 2^exp2，
        // 整数部分 = sig >> (-exp2)。不能用 frac_bits - exp2（会把
        // 归一化 sig 的隐式位位置重复计入）。
        s = -p.exp2;
        if (s <= 0) begin
          r.bits = a_bits;        // 已是整数
        end else begin
          unique case (mode)
            3'd0: rmode = 2'b00;
            3'd1: rmode = 2'b01;
            3'd2: rmode = 2'b10;
            3'd3: rmode = 2'b11;
            default: rmode = fpcr_rmode;   // X/I 用当前 RMode
          endcase
          if (s >= FP_W) begin
            q = 256'd0;
            guard = 1'b0;
            sticky = |p.sig;
          end else begin
            q = p.sig >> s;
            guard = p.sig[s - 1];
            sticky = any_low_bits(p.sig, s - 1);
          end
          inexact = guard | sticky;
          if (mode == 3'd4)
            inc = guard;                    // ties-away
          else
            inc = round_increment(p.sign, rmode, guard, sticky, q[0]);
          if (inc)
            q = q + 256'd1;
          if (q == 0) begin
            r.bits = pack_zero(p.sign, fmt);
          end else begin
            h = -1;
            for (i = FP_W - 1; i >= 0; i = i - 1) begin
              if (h < 0 && q[i])
                h = i;
            end
            exp2f = h;
            if (h > frac_bits) begin
              // carry 进位到 2^(frac_bits+1)（只可能发生在 h==frac_bits+1）
              q = 256'(1) << frac_bits;
              exp2f = h;
            end else begin
              q = q << (frac_bits - h);
            end
            expf = 11'(exp2f + bias);
            unique case (fmt)
              FMT_HALF:   r.bits = {48'd0, p.sign, expf[4:0], q[9:0]};
              FMT_SINGLE: r.bits = {32'd0, p.sign, expf[7:0], q[22:0]};
              default:    r.bits = {p.sign, expf[10:0], q[51:0]};
            endcase
          end
          // 仅 FRINTX（mode=5）保留 IXC；N/P/M/Z/A/I 由 QEMU
          // rinth/rints/rintd helper 抑制 inexact。
          if (inexact && mode == 3'd5)
            r.flags = FPSR_IXC;
        end
      end
      frint_op = r;
    end
  endfunction

  // ---- P7-5：单个 FP16 lane 运算（标量/向量 H 复用）----
  function automatic fp_calc_t half_lane_calc(
      input fp_op_t       operation,
      input logic [15:0]  a16,
      input logic [15:0]  b16,
      input logic [15:0]  c16,
      input logic         dn,
      input logic         fz16,
      input logic [1:0]   rmode,
      input logic [2:0]   rint_mode_arg,
      input logic         cmp_zero);
    fp_calc_t r;
    begin
      r = '0;
      unique case (operation)
        FP_OP_ADD, FP_OP_SUB, FP_OP_MUL:
          r = binary_op(operation, FMT_HALF, {48'd0, a16}, {48'd0, b16},
                        dn, fz16, rmode);
        FP_OP_DIV:
          r = '0; // FDIV.H is routed through the multi-cycle divider path
        FP_OP_CMP:
          r = compare_op(FMT_HALF, {48'd0, a16}, {48'd0, b16}, fz16,
                         cmp_zero, 1'b0);
        FP_OP_FMADD, FP_OP_FMSUB, FP_OP_FNMADD, FP_OP_FNMSUB:
          r = fma_op(operation, FMT_HALF, {48'd0, a16}, {48'd0, b16},
                     {48'd0, c16}, dn, fz16, rmode);
        FP_OP_SQRT:
          r = sqrt_op(FMT_HALF, {48'd0, a16}, dn, fz16, rmode);
        FP_OP_FMIN, FP_OP_FMAX, FP_OP_FMINNM, FP_OP_FMAXNM:
          r = minmax_op(operation, FMT_HALF, {48'd0, a16}, {48'd0, b16},
                        dn, fz16);
        FP_OP_FRINT:
          r = frint_op(FMT_HALF, {48'd0, a16}, rint_mode_arg, dn, fz16,
                       rmode);
        default: r = '0;
      endcase
      half_lane_calc = r;
    end
  endfunction

  // ---- P7-5：FCVT（H<->S、H<->D、S<->D）----
  // NaN payload 按 QEMU frac_shift 映射：
  //   H->S hfrac<<13（sNaN 再置 quiet bit22）；H->D hfrac<<42（置 bit51）
  //   S->D sfrac<<29；D->S dfrac>>29
  //   S->H {1, sfrac[21:13]}；D->H {1, dfrac[50:42]}
  // S/D 的 FZ 输入/输出 flush 保留；H 参与的转换 QEMU helper squash
  // src=H 的输入 flush 与 dst=H 的输出 flush，故 flush_inputs/flush_outputs
  // 分开传入。AHP=1 时 H 无 NaN/Inf：NaN->±0、Inf->max normal 并 IOC；
  // H 输入按 e=11111 为正常指数解释。
  function automatic fp_calc_t fcvt_op2(
      input fp_fmt_t      dst,
      input fp_fmt_t      src,
      input logic [63:0]  a_bits,
      input logic         default_nan_mode,
      input logic         flush_inputs,
      input logic         flush_outputs,
      input logic [1:0]   rmode,
      input logic         ahp);
    fp_calc_t r;
    fp_calc_t rr;
    fp_parts_t p;
    logic [31:0] input_flags;
    logic [63:0] nan_bits;
    logic [10:0] hfrac11;
    begin
      r = '0;
      p = unpack_fp(src, a_bits);
      input_flags = 32'd0;
      if (flush_inputs && p.sub) begin
        p.zero = 1'b1;
        p.sub = 1'b0;
        p.sig = 256'd0;
        input_flags = FPSR_IDC;
      end
      if (ahp && src == FMT_HALF) begin
        // AHP H 输入：e=11111 是正常指数，无 NaN/Inf。
        p.nan = 1'b0;
        p.snan = 1'b0;
        p.inf = 1'b0;
        rr = round_pack(p.sign, p.sig, p.exp2, dst, 1'b0, rmode, 1'b1);
        r = rr;
        r.flags = rr.flags | input_flags;
      end else if (ahp && dst == FMT_HALF) begin
        if (p.nan) begin
          r.bits = pack_zero(p.sign, FMT_HALF);
          r.flags = input_flags | FPSR_IOC;
        end else if (p.inf) begin
          r.bits = {48'd0, p.sign, 5'h1e, 10'h3ff};
          r.flags = input_flags | FPSR_IOC;
        end else begin
          rr = round_pack(p.sign, p.sig, p.exp2, FMT_HALF,
                          flush_outputs, rmode, 1'b1);
          r = rr;
          r.flags = rr.flags | input_flags;
        end
      end else if (p.nan) begin
        if (default_nan_mode) begin
          r.bits = default_nan(dst);
        end else begin
          nan_bits = 64'd0;
          if (dst == FMT_DOUBLE) begin
            if (src == FMT_HALF)
              nan_bits = {p.sign, 11'h7ff, 1'b1, a_bits[8:0], 42'd0};
            else
              nan_bits = {p.sign, 11'h7ff, 1'b1, a_bits[21:0], 29'd0};
          end else if (dst == FMT_SINGLE) begin
            // 1(sign) + 8(exp) + 1(quiet) + 9(hfrac[8:0]) + 13(zero) = 32。
            if (src == FMT_HALF)
              nan_bits = {32'd0, p.sign, 8'hff, 1'b1,
                          a_bits[8:0], 13'd0};
            else
              nan_bits = {32'd0, p.sign, 8'hff, 1'b1, a_bits[50:29]};
          end else begin
            // dst == H：只保留源 frac 的高 9 位 + quiet 位。
            if (src == FMT_SINGLE)
              hfrac11 = {2'b01, a_bits[21:13]};
            else
              hfrac11 = {2'b01, a_bits[50:42]};
            nan_bits = {48'd0, p.sign, 5'h1f, hfrac11[9:0]};
          end
          r.bits = nan_bits;
        end
        r.flags = input_flags | (p.snan ? FPSR_IOC : 32'd0);
      end else if (p.inf) begin
        // 非 AHP：Inf 原样跨格式（H->S/D、S/D->H）。
        r.bits = pack_inf(p.sign, dst);
        r.flags = input_flags;
      end else if (p.zero) begin
        r.bits = pack_zero(p.sign, dst);
        r.flags = input_flags;
      end else begin
        rr = round_pack(p.sign, p.sig, p.exp2, dst,
                        flush_outputs, rmode, 1'b0);
        r = rr;
        r.flags = rr.flags | input_flags;
      end
      fcvt_op2 = r;
    end
  endfunction

  // FP-P3T: FCVT pre-round stage.  This mirrors fcvt_op2 but carries finite
  // values through to the next round_pack stage instead of rounding here.
  function automatic fp_pre_t fcvt_pre(
      input fp_fmt_t      dst,
      input fp_fmt_t      src,
      input logic [63:0]  a_bits,
      input logic         default_nan_mode,
      input logic         flush_inputs,
      input logic         flush_outputs,
      input logic [1:0]   rmode,
      input logic         ahp);
    fp_pre_t p;
    fp_parts_t pa;
    logic [31:0] input_flags;
    logic [63:0] nan_bits;
    logic [10:0] hfrac11;
    begin
      p = '0;
      pa = unpack_fp(src, a_bits);
      input_flags = 32'd0;
      if (flush_inputs && pa.sub) begin
        pa.zero = 1'b1;
        pa.sub = 1'b0;
        pa.sig = 256'd0;
        input_flags = FPSR_IDC;
      end
      if (ahp && src == FMT_HALF) begin
        pa.nan = 1'b0;
        pa.snan = 1'b0;
        pa.inf = 1'b0;
        p.is_special = 1'b0;
        p.need_round = 1'b1;
        p.sign = pa.sign;
        p.sig = pa.sig;
        p.exp2 = pa.exp2;
        p.fmt = dst;
        p.flush_zero = 1'b0;
        p.rmode = rmode;
        p.ahp = 1'b1;
        p.input_flags = input_flags;
      end else if (ahp && dst == FMT_HALF) begin
        p.is_special = 1'b1;
        if (pa.nan) begin
          p.special.bits = pack_zero(pa.sign, FMT_HALF);
          p.special.flags = input_flags | FPSR_IOC;
        end else if (pa.inf) begin
          p.special.bits = {48'd0, pa.sign, 5'h1e, 10'h3ff};
          p.special.flags = input_flags | FPSR_IOC;
        end else begin
          p.is_special = 1'b0;
          p.need_round = 1'b1;
          p.sign = pa.sign;
          p.sig = pa.sig;
          p.exp2 = pa.exp2;
          p.fmt = FMT_HALF;
          p.flush_zero = flush_outputs;
          p.rmode = rmode;
          p.ahp = 1'b1;
          p.input_flags = input_flags;
        end
      end else if (pa.nan) begin
        p.is_special = 1'b1;
        if (default_nan_mode) begin
          p.special.bits = default_nan(dst);
        end else begin
          nan_bits = 64'd0;
          if (dst == FMT_DOUBLE) begin
            if (src == FMT_HALF)
              nan_bits = {pa.sign, 11'h7ff, 1'b1, a_bits[8:0], 42'd0};
            else
              nan_bits = {pa.sign, 11'h7ff, 1'b1, a_bits[21:0], 29'd0};
          end else if (dst == FMT_SINGLE) begin
            if (src == FMT_HALF)
              nan_bits = {32'd0, pa.sign, 8'hff, 1'b1,
                          a_bits[8:0], 13'd0};
            else
              nan_bits = {32'd0, pa.sign, 8'hff, 1'b1, a_bits[50:29]};
          end else begin
            if (src == FMT_SINGLE)
              hfrac11 = {2'b01, a_bits[21:13]};
            else
              hfrac11 = {2'b01, a_bits[50:42]};
            nan_bits = {48'd0, pa.sign, 5'h1f, hfrac11[9:0]};
          end
          p.special.bits = nan_bits;
        end
        p.special.flags = input_flags | (pa.snan ? FPSR_IOC : 32'd0);
      end else if (pa.inf) begin
        p.is_special = 1'b1;
        p.special.bits = pack_inf(pa.sign, dst);
        p.special.flags = input_flags;
      end else if (pa.zero) begin
        p.is_special = 1'b1;
        p.special.bits = pack_zero(pa.sign, dst);
        p.special.flags = input_flags;
      end else begin
        p.is_special = 1'b0;
        p.need_round = 1'b1;
        p.sign = pa.sign;
        p.sig = pa.sig;
        p.exp2 = pa.exp2;
        p.fmt = dst;
        p.flush_zero = flush_outputs;
        p.rmode = rmode;
        p.ahp = 1'b0;
        p.input_flags = input_flags;
      end
      fcvt_pre = p;
    end
  endfunction

  // ---- FP-P3T round2 helpers for remaining combinational ops ----
  // These operations (FCMP, min/max, FRINT, FP->int) were not covered by the
  // first register-cut pass.  Stage 1 below only unpacks/flushes the operands;
  // stage 2 completes the per-operation compare/select/round/int conversion.

  function automatic logic uses_other_pre(input fp_op_t operation);
    begin
      uses_other_pre = (operation == FP_OP_CMP) ||
                       (operation == FP_OP_FMIN) ||
                       (operation == FP_OP_FMAX) ||
                       (operation == FP_OP_FMINNM) ||
                       (operation == FP_OP_FMAXNM) ||
                       (operation == FP_OP_FRINT) ||
                       (operation == FP_OP_FCVTZS) ||
                       (operation == FP_OP_FCVTZU);
    end
  endfunction

  function automatic fp_other_pre_t other_pre(
      input fp_fmt_t      fmt,
      input logic [63:0]  a_bits,
      input logic [63:0]  b_bits,
      input integer       src_conv_shift,
      input logic         src_conv_is_32,
      input logic         flush_zero,
      input logic         dn,
      input logic [1:0]   rmode,
      input logic [2:0]   src_rint_mode,
      input logic         cmp_zero,
      input logic         signal_nans);
    fp_other_pre_t p;
    begin
      p = '0;
      p.fmt = fmt;
      p.flush_zero = flush_zero;
      p.dn = dn;
      p.rmode = rmode;
      p.rint_mode = src_rint_mode;
      p.cmp_zero = cmp_zero;
      p.signal_nans = signal_nans;
      p.conv_is_32 = src_conv_is_32;
      p.conv_shift = src_conv_shift;
      p.a_bits = a_bits;
      p.b_bits = b_bits;
      p.pa = unpack_fp(fmt, a_bits);
      p.pb = unpack_fp(fmt, b_bits);
      if (flush_zero && p.pa.sub) begin
        p.pa.zero = 1'b1;
        p.pa.sub = 1'b0;
        p.pa.sig = 256'd0;
        p.a_flushed = 1'b1;
        p.input_flags = p.input_flags | FPSR_IDC;
      end
      if (flush_zero && p.pb.sub) begin
        p.pb.zero = 1'b1;
        p.pb.sub = 1'b0;
        p.pb.sig = 256'd0;
        p.b_flushed = 1'b1;
        p.input_flags = p.input_flags | FPSR_IDC;
      end
      other_pre = p;
    end
  endfunction

  // FP-P3T round4: stage-2 helpers for the remaining pp_other operations.
  // Each helper computes only the expensive decision/shift/magnitude part and
  // writes an fp_other_mid_t; the matching *_finish_mid function performs the
  // cheap final select/normalize/pack on the next cycle.

  function automatic fp_other_mid_t minmax_mid(
      input fp_op_t      operation,
      input fp_other_pre_t p);
    fp_other_mid_t m;
    logic a_nm;
    logic mag_less;
    logic a_less;
    logic signed [31:0] a_cmp_exp;
    logic signed [31:0] b_cmp_exp;
    logic [63:0] a_out;
    logic [63:0] b_out;
    begin
      m = '0;
      m.flags = p.input_flags;
      a_out = p.a_flushed ? pack_zero(p.pa.sign, p.fmt) : p.a_bits;
      b_out = p.b_flushed ? pack_zero(p.pb.sign, p.fmt) : p.b_bits;
      m.mm_a_out = a_out;
      m.mm_b_out = b_out;
      a_nm = operation inside {FP_OP_FMINNM, FP_OP_FMAXNM};

      if (p.pa.nan || p.pb.nan) begin
        m.mm_is_special = 1'b1;
        if (a_nm && p.pa.nan && !p.pb.nan && !p.pa.snan) begin
          m.mm_bits = b_out;
          m.flags = p.input_flags;
        end else if (a_nm && p.pb.nan && !p.pa.nan && !p.pb.snan) begin
          m.mm_bits = a_out;
          m.flags = p.input_flags;
        end else begin
          m.flags = p.input_flags;
          if (p.pa.snan || p.pb.snan)
            m.flags = m.flags | FPSR_IOC;
          if (p.dn) begin
            m.mm_bits = default_nan(p.fmt);
          end else if (p.pa.snan) begin
            m.mm_bits = quiet_nan(p.a_bits, p.fmt);
          end else if (p.pb.snan) begin
            m.mm_bits = quiet_nan(p.b_bits, p.fmt);
          end else if (p.pa.nan) begin
            m.mm_bits = p.a_bits;
          end else begin
            m.mm_bits = p.b_bits;
          end
        end
      end else begin
        m.mm_is_special = 1'b0;
        a_cmp_exp = p.pa.inf ? 32'sd1_073_741_824
                   : p.pa.zero ? -32'sd1_073_741_824 : 32'(p.pa.exp2);
        b_cmp_exp = p.pb.inf ? 32'sd1_073_741_824
                   : p.pb.zero ? -32'sd1_073_741_824 : 32'(p.pb.exp2);
        if (a_cmp_exp != b_cmp_exp)
          mag_less = a_cmp_exp < b_cmp_exp;
        else if (p.pa.sig != p.pb.sig)
          mag_less = p.pa.sig < p.pb.sig;
        else
          mag_less = 1'b0;
        a_less = p.pa.sign ? !mag_less : mag_less;
        // FMIN/FMINNM pick the smaller operand; FMAX/FMAXNM pick the larger.
        m.mm_use_a = (operation == FP_OP_FMIN || operation == FP_OP_FMINNM)
                     ? a_less : !a_less;
      end
      minmax_mid = m;
    end
  endfunction

  function automatic fp_calc_t minmax_finish_mid(input fp_other_mid_t m);
    fp_calc_t r;
    begin
      r = '0;
      r.flags = m.flags;
      if (m.mm_is_special)
        r.bits = m.mm_bits;
      else
        r.bits = m.mm_use_a ? m.mm_a_out : m.mm_b_out;
      minmax_finish_mid = r;
    end
  endfunction

  function automatic fp_other_mid_t frint_mid(input fp_other_pre_t p);
    fp_other_mid_t m;
    integer s;
    integer frac_bits;
    integer bias;
    logic [1:0] rmode;
    logic [255:0] q;
    logic guard;
    logic sticky;
    logic inc;
    logic inexact;
    begin
      m = '0;
      m.flags = p.input_flags;
      m.fr_fmt = p.fmt;
      m.fr_sign = p.pa.sign;
      m.fr_mode = p.rint_mode;

      if (p.pa.nan) begin
        m.fr_is_special = 1'b1;
        m.fr_bits = p.dn ? default_nan(p.fmt)
                         : (p.pa.snan ? quiet_nan(p.a_bits, p.fmt)
                                      : p.a_bits);
        m.flags = (p.pa.snan ? FPSR_IOC : 32'd0) | p.input_flags;
      end else if (p.pa.inf || p.pa.zero) begin
        m.fr_is_special = 1'b1;
        m.fr_bits = p.a_flushed ? pack_zero(p.pa.sign, p.fmt) : p.a_bits;
        m.flags = p.input_flags;
      end else if (p.flush_zero && p.pa.sub) begin
        m.fr_is_special = 1'b1;
        m.fr_bits = pack_zero(p.pa.sign, p.fmt);
        m.flags = p.input_flags | FPSR_IDC;
      end else begin
        s = -p.pa.exp2;
        if (s <= 0) begin
          m.fr_direct = 1'b1;
          m.fr_bits = p.a_bits;
          m.flags = p.input_flags;
        end else begin
          unique case (m.fr_mode)
            3'd0: rmode = 2'b00;
            3'd1: rmode = 2'b01;
            3'd2: rmode = 2'b10;
            3'd3: rmode = 2'b11;
            default: rmode = p.rmode;
          endcase
          if (s >= FP_W) begin
            q = 256'd0;
            guard = 1'b0;
            sticky = |p.pa.sig;
          end else begin
            q = p.pa.sig >> s;
            guard = p.pa.sig[s - 1];
            sticky = any_low_bits(p.pa.sig, s - 1);
          end
          inexact = guard | sticky;
          if (m.fr_mode == 3'd4)
            inc = guard;
          else
            inc = round_increment(p.pa.sign, rmode, guard, sticky, q[0]);
          m.fr_q = q;
          m.fr_inc = inc;
          m.fr_inexact = inexact;
        end
      end
      frint_mid = m;
    end
  endfunction

  function automatic fp_calc_t frint_finish_mid(input fp_other_mid_t m);
    fp_calc_t r;
    logic [255:0] q;
    integer frac_bits;
    integer bias;
    integer h;
    integer exp2f;
    integer i;
    logic [10:0] expf;
    begin
      r = '0;
      if (m.fr_is_special || m.fr_direct) begin
        r.bits = m.fr_bits;
        r.flags = m.flags;
      end else begin
        q = m.fr_q;
        if (m.fr_inc)
          q = q + 256'd1;
        if (q == 0) begin
          r.bits = pack_zero(m.fr_sign, m.fr_fmt);
        end else begin
          h = -1;
          for (i = FP_W - 1; i >= 0; i = i - 1) begin
            if (h < 0 && q[i])
              h = i;
          end
          unique case (m.fr_fmt)
            FMT_HALF:   frac_bits = 10;
            FMT_SINGLE: frac_bits = 23;
            default:    frac_bits = 52;
          endcase
          unique case (m.fr_fmt)
            FMT_HALF:   bias = 15;
            FMT_SINGLE: bias = 127;
            default:    bias = 1023;
          endcase
          exp2f = h;
          if (h > frac_bits) begin
            q = 256'(1) << frac_bits;
            exp2f = h;
          end else begin
            q = q << (frac_bits - h);
          end
          expf = 11'(exp2f + bias);
          unique case (m.fr_fmt)
            FMT_HALF:   r.bits = {48'd0, m.fr_sign, expf[4:0], q[9:0]};
            FMT_SINGLE: r.bits = {32'd0, m.fr_sign, expf[7:0], q[22:0]};
            default:    r.bits = {m.fr_sign, expf[10:0], q[51:0]};
          endcase
        end
        r.flags = m.flags;
        if (m.fr_inexact && m.fr_mode == 3'd5)
          r.flags = m.flags | FPSR_IXC;
      end
      frint_finish_mid = r;
    end
  endfunction

  function automatic fp_other_mid_t fp_to_int_mid(
      input fp_op_t      operation,
      input fp_other_pre_t p);
    fp_other_mid_t m;
    integer h;
    integer delta;
    integer i;
    logic [255:0] mag;
    logic sticky;
    logic saturate;
    begin
      m = '0;
      m.flags = p.input_flags;
      m.i_is_32 = p.conv_is_32;
      m.i_is_signed = (operation == FP_OP_FCVTZS);
      m.i_sign = p.pa.sign;

      if (p.pa.nan) begin
        m.i_zero = 1'b1;
        m.flags = p.input_flags | FPSR_IOC;
      end else if (p.pa.zero) begin
        m.i_zero = 1'b1;
        m.flags = p.input_flags;
      end else begin
        h = -1;
        for (i = FP_W - 1; i >= 0; i = i - 1) begin
          if (h < 0 && p.pa.sig[i])
            h = i;
        end
        delta = p.pa.exp2 + p.conv_shift;
        mag = 256'd0;
        sticky = 1'b0;
        saturate = 1'b0;
        if (delta >= FP_W - h) begin
          saturate = 1'b1;
        end else if (delta >= 0) begin
          mag = p.pa.sig << delta;
        end else begin
          if (-delta >= FP_W) begin
            mag = 256'd0;
            sticky = |p.pa.sig;
          end else begin
            mag = p.pa.sig >> (-delta);
            sticky = any_low_bits(p.pa.sig, -delta);
          end
        end
        if (!m.i_is_signed && p.pa.sign && (|mag))
          saturate = 1'b1;
        if (!saturate) begin
          if (m.i_is_signed) begin
            if (p.conv_is_32) begin
              if (|mag[255:32] || (mag[31] && (|mag[30:0])) ||
                  (mag[31] && !p.pa.sign))
                saturate = 1'b1;
            end else begin
              if (|mag[255:64] || (mag[63] && (|mag[62:0])) ||
                  (mag[63] && !p.pa.sign))
                saturate = 1'b1;
            end
          end else begin
            if (p.conv_is_32) begin
              if (|mag[255:32])
                saturate = 1'b1;
            end else begin
              if (|mag[255:64])
                saturate = 1'b1;
            end
          end
        end
        m.i_mag = mag;
        m.i_sticky = sticky;
        m.i_saturate = saturate;
      end
      fp_to_int_mid = m;
    end
  endfunction

  function automatic fp_int_calc_t fp_to_int_finish_mid(input fp_other_mid_t m);
    fp_int_calc_t rc;
    logic [63:0] val;
    begin
      rc = '0;
      if (m.i_zero) begin
        rc.value = 64'd0;
        rc.flags = m.flags;
      end else if (m.i_saturate) begin
        rc.flags = m.flags | FPSR_IOC;
        if (m.i_is_signed) begin
          if (m.i_is_32)
            rc.value = m.i_sign ? 64'h0000_0000_8000_0000
                                : 64'h0000_0000_7fff_ffff;
          else
            rc.value = m.i_sign ? 64'h8000_0000_0000_0000
                                : 64'h7fff_ffff_ffff_ffff;
        end else begin
          if (m.i_sign)
            rc.value = 64'd0;
          else
            rc.value = m.i_is_32 ? 64'h0000_0000_ffff_ffff
                                 : 64'hffff_ffff_ffff_ffff;
        end
      end else begin
        if (m.i_is_signed) begin
          if (m.i_is_32)
            val = m.i_sign ? -64'(m.i_mag[31:0]) : 64'(m.i_mag[31:0]);
          else
            val = m.i_sign ? -m.i_mag[63:0] : m.i_mag[63:0];
        end else begin
          val = m.i_is_32 ? {32'd0, m.i_mag[31:0]} : m.i_mag[63:0];
        end
        if (m.i_is_32)
          val = {32'd0, val[31:0]};
        rc.value = val;
        if (m.i_sticky)
          rc.flags = m.flags | FPSR_IXC;
        else
          rc.flags = m.flags;
      end
      fp_to_int_finish_mid = rc;
    end
  endfunction

  function automatic fp_other_mid_t other_mid(
      input fp_op_t       operation,
      input fp_other_pre_t p);
    begin
      unique case (operation)
        FP_OP_FMIN, FP_OP_FMAX, FP_OP_FMINNM, FP_OP_FMAXNM:
          other_mid = minmax_mid(operation, p);
        FP_OP_FRINT:
          other_mid = frint_mid(p);
        FP_OP_FCVTZS, FP_OP_FCVTZU:
          other_mid = fp_to_int_mid(operation, p);
        default:
          other_mid = '0;
      endcase
    end
  endfunction

  function automatic fp_calc_t compare_finish_parts(
      input fp_parts_t   pa,
      input fp_parts_t   pb,
      input logic        cmp_zero,
      input logic        signal_nans,
      input logic [31:0] input_flags);
    fp_calc_t r;
    logic a_sign;
    logic b_sign;
    logic [10:0] a_exp;
    logic [10:0] b_exp;
    logic [51:0] a_frac;
    logic [51:0] b_frac;
    logic a_nan;
    logic b_nan;
    logic a_snan;
    logic b_snan;
    logic a_zero;
    logic b_zero;
    logic less_mag;
    logic greater_mag;
    logic less_value;
    logic greater_value;
    begin
      r = '0;
      a_sign = pa.sign;
      b_sign = pb.sign;
      a_exp = pa.exp_field;
      b_exp = pb.exp_field;
      a_frac = pa.frac;
      b_frac = pb.frac;
      a_nan = pa.nan;
      b_nan = pb.nan;
      a_snan = pa.snan;
      b_snan = pb.snan;
      a_zero = pa.zero;
      b_zero = pb.zero;
      if (cmp_zero) begin
        b_sign = 1'b0;
        b_exp = 11'd0;
        b_frac = 52'd0;
        b_nan = 1'b0;
        b_snan = 1'b0;
        b_zero = 1'b1;
      end
      if (a_nan || b_nan) begin
        if (signal_nans || a_snan || b_snan)
          r.flags = input_flags | FPSR_IOC;
        else
          r.flags = input_flags;
        r.nzcv = 4'b0011;
      end else if (a_zero && b_zero) begin
        r.nzcv = 4'b0110;
        r.flags = input_flags;
      end else if (a_sign != b_sign) begin
        less_value = a_sign;
        r.nzcv = less_value ? 4'b1000 : 4'b0010;
        r.flags = input_flags;
      end else begin
        if (a_exp < b_exp)
          less_mag = 1'b1;
        else if (a_exp > b_exp)
          greater_mag = 1'b1;
        else if (a_frac < b_frac)
          less_mag = 1'b1;
        else if (a_frac > b_frac)
          greater_mag = 1'b1;
        else begin
          less_mag = 1'b0;
          greater_mag = 1'b0;
        end
        less_value = a_sign ? greater_mag : less_mag;
        greater_value = a_sign ? less_mag : greater_mag;
        r.nzcv = less_value ? 4'b1000
                 : greater_value ? 4'b0010 : 4'b0110;
        r.flags = input_flags;
      end
      compare_finish_parts = r;
    end
  endfunction

  function automatic fp_calc_t minmax_finish_parts(
      input fp_op_t      operation,
      input fp_fmt_t     fmt,
      input fp_parts_t   pa,
      input fp_parts_t   pb,
      input logic [63:0] a_bits,
      input logic [63:0] b_bits,
      input logic        a_flushed,
      input logic        b_flushed,
      input logic        default_nan_mode,
      input logic [31:0] input_flags);
    fp_calc_t r;
    logic a_nm;
    logic mag_less;
    logic a_less;
    logic signed [31:0] a_cmp_exp;
    logic signed [31:0] b_cmp_exp;
    logic [63:0] a_out;
    logic [63:0] b_out;
    begin
      r = '0;
      a_out = a_flushed ? pack_zero(pa.sign, fmt) : a_bits;
      b_out = b_flushed ? pack_zero(pb.sign, fmt) : b_bits;
      a_nm = operation inside {FP_OP_FMINNM, FP_OP_FMAXNM};

      if (pa.nan || pb.nan) begin
        if (a_nm && pa.nan && !pb.nan && !pa.snan) begin
          r.bits = b_out;
          r.flags = input_flags;
        end else if (a_nm && pb.nan && !pa.nan && !pb.snan) begin
          r.bits = a_out;
          r.flags = input_flags;
        end else begin
          r.flags = input_flags;
          if (pa.snan || pb.snan)
            r.flags = r.flags | FPSR_IOC;
          if (default_nan_mode) begin
            r.bits = default_nan(fmt);
          end else if (pa.snan) begin
            r.bits = quiet_nan(a_bits, fmt);
          end else if (pb.snan) begin
            r.bits = quiet_nan(b_bits, fmt);
          end else if (pa.nan) begin
            r.bits = a_bits;
          end else begin
            r.bits = b_bits;
          end
        end
      end else begin
        r.flags = input_flags;
        a_cmp_exp = pa.inf ? 32'sd1_073_741_824
                   : pa.zero ? -32'sd1_073_741_824 : 32'(pa.exp2);
        b_cmp_exp = pb.inf ? 32'sd1_073_741_824
                   : pb.zero ? -32'sd1_073_741_824 : 32'(pb.exp2);
        if (a_cmp_exp != b_cmp_exp)
          mag_less = a_cmp_exp < b_cmp_exp;
        else if (pa.sig != pb.sig)
          mag_less = pa.sig < pb.sig;
        else
          mag_less = 1'b0;
        a_less = pa.sign ? !mag_less : mag_less;
        if (operation == FP_OP_FMIN || operation == FP_OP_FMINNM)
          r.bits = a_less ? a_out : b_out;
        else
          r.bits = a_less ? b_out : a_out;
      end
      minmax_finish_parts = r;
    end
  endfunction

  function automatic fp_calc_t frint_finish_parts(
      input fp_fmt_t     fmt,
      input fp_parts_t   pa,
      input logic [63:0] a_bits,
      input logic        a_flushed,
      input logic [2:0]  mode,
      input logic        default_nan_mode,
      input logic        flush_zero,
      input logic [1:0]  fpcr_rmode,
      input logic [31:0] input_flags);
    fp_calc_t r;
    logic [1:0] rmode;
    logic [255:0] q;
    logic guard;
    logic sticky;
    logic inc;
    logic inexact;
    integer frac_bits;
    integer bias;
    integer s;
    integer h;
    integer exp2f;
    integer i;
    logic [10:0] expf;
    begin
      r = '0;
      if (pa.nan) begin
        r.bits = default_nan_mode ? default_nan(fmt)
                                  : (pa.snan ? quiet_nan(a_bits, fmt)
                                             : a_bits);
        r.flags = (pa.snan ? FPSR_IOC : 32'd0) | input_flags;
      end else if (pa.inf || pa.zero) begin
        if (a_flushed)
          r.bits = pack_zero(pa.sign, fmt);
        else
          r.bits = a_bits;
        r.flags = input_flags;
      end else if (flush_zero && pa.sub) begin
        // Should not normally happen after stage 1, but keep for safety.
        r.bits = pack_zero(pa.sign, fmt);
        r.flags = input_flags | FPSR_IDC;
      end else begin
        unique case (fmt)
          FMT_HALF:   frac_bits = 10;
          FMT_SINGLE: frac_bits = 23;
          default:    frac_bits = 52;
        endcase
        unique case (fmt)
          FMT_HALF:   bias = 15;
          FMT_SINGLE: bias = 127;
          default:    bias = 1023;
        endcase
        s = -pa.exp2;
        if (s <= 0) begin
          r.bits = a_bits;
          r.flags = input_flags;
        end else begin
          unique case (mode)
            3'd0: rmode = 2'b00;
            3'd1: rmode = 2'b01;
            3'd2: rmode = 2'b10;
            3'd3: rmode = 2'b11;
            default: rmode = fpcr_rmode;
          endcase
          if (s >= FP_W) begin
            q = 256'd0;
            guard = 1'b0;
            sticky = |pa.sig;
          end else begin
            q = pa.sig >> s;
            guard = pa.sig[s - 1];
            sticky = any_low_bits(pa.sig, s - 1);
          end
          inexact = guard | sticky;
          if (mode == 3'd4)
            inc = guard;
          else
            inc = round_increment(pa.sign, rmode, guard, sticky, q[0]);
          if (inc)
            q = q + 256'd1;
          if (q == 0) begin
            r.bits = pack_zero(pa.sign, fmt);
          end else begin
            h = -1;
            for (i = FP_W - 1; i >= 0; i = i - 1) begin
              if (h < 0 && q[i])
                h = i;
            end
            exp2f = h;
            if (h > frac_bits) begin
              q = 256'(1) << frac_bits;
              exp2f = h;
            end else begin
              q = q << (frac_bits - h);
            end
            expf = 11'(exp2f + bias);
            unique case (fmt)
              FMT_HALF:   r.bits = {48'd0, pa.sign, expf[4:0], q[9:0]};
              FMT_SINGLE: r.bits = {32'd0, pa.sign, expf[7:0], q[22:0]};
              default:    r.bits = {pa.sign, expf[10:0], q[51:0]};
            endcase
          end
          if (inexact && mode == 3'd5)
            r.flags = input_flags | FPSR_IXC;
          else
            r.flags = input_flags;
        end
      end
      frint_finish_parts = r;
    end
  endfunction

  function automatic fp_int_calc_t fp_to_int_finish_parts(
      input fp_parts_t   pa,
      input logic        is_32,
      input logic        is_signed,
      input logic        flush_zero,
      input integer      shift,
      input logic [31:0] input_flags);
    fp_int_calc_t rc;
    logic [255:0] mag;
    logic sticky;
    logic saturate;
    integer delta;
    integer h;
    integer i;
    begin
      rc = '0;
      if (pa.nan) begin
        rc.value = 64'd0;
        rc.flags = input_flags | FPSR_IOC;
      end else if (pa.zero) begin
        rc.value = 64'd0;
        rc.flags = input_flags;
      end else begin
        h = -1;
        for (i = FP_W - 1; i >= 0; i = i - 1) begin
          if (h < 0 && pa.sig[i])
            h = i;
        end
        delta = pa.exp2 + shift;
        mag = 256'd0;
        sticky = 1'b0;
        saturate = 1'b0;
        if (delta >= FP_W - h) begin
          saturate = 1'b1;
        end else if (delta >= 0) begin
          mag = pa.sig << delta;
        end else begin
          if (-delta >= FP_W) begin
            mag = 256'd0;
            sticky = |pa.sig;
          end else begin
            mag = pa.sig >> (-delta);
            sticky = any_low_bits(pa.sig, -delta);
          end
        end
        if (!is_signed && pa.sign && (|mag))
          saturate = 1'b1;
        if (!saturate) begin
          if (is_signed) begin
            if (is_32) begin
              if (|mag[255:32] || (mag[31] && (|mag[30:0])) ||
                  (mag[31] && !pa.sign))
                saturate = 1'b1;
            end else begin
              if (|mag[255:64] || (mag[63] && (|mag[62:0])) ||
                  (mag[63] && !pa.sign))
                saturate = 1'b1;
            end
          end else begin
            if (is_32) begin
              if (|mag[255:32])
                saturate = 1'b1;
            end else begin
              if (|mag[255:64])
                saturate = 1'b1;
            end
          end
        end
        if (saturate) begin
          rc.flags = input_flags | FPSR_IOC;
          if (is_signed) begin
            if (is_32)
              rc.value = pa.sign ? 64'h0000_0000_8000_0000
                                 : 64'h0000_0000_7fff_ffff;
            else
              rc.value = pa.sign ? 64'h8000_0000_0000_0000
                                 : 64'h7fff_ffff_ffff_ffff;
          end else begin
            if (pa.sign)
              rc.value = 64'd0;
            else
              rc.value = is_32 ? 64'h0000_0000_ffff_ffff
                               : 64'hffff_ffff_ffff_ffff;
          end
        end else begin
          if (is_signed) begin
            if (is_32)
              rc.value = pa.sign ? -64'(mag[31:0]) : 64'(mag[31:0]);
            else
              rc.value = pa.sign ? -mag[63:0] : mag[63:0];
          end else begin
            rc.value = is_32 ? {32'd0, mag[31:0]} : mag[63:0];
          end
          if (sticky)
            rc.flags = input_flags | FPSR_IXC;
          else
            rc.flags = input_flags;
        end
        if (is_32)
          rc.value = {32'd0, rc.value[31:0]};
      end
      fp_to_int_finish_parts = rc;
    end
  endfunction

  // ---- FP-P3 iterative-path helpers ----
  // These are used by the FP_ITER release branch.  They deliberately avoid
  // the combinational 64-round isqrt; the integer root itself is produced by
  // lcvex_fp_iter_sqrt, while classification/round/pack stay in the shared
  // scalar functions.
  function automatic logic div_is_special(
      input fp_fmt_t fmt,
      input logic [63:0] a_bits,
      input logic [63:0] b_bits,
      input logic fz);
    fp_parts_t pa;
    fp_parts_t pb;
    begin
      pa = unpack_fp(fmt, a_bits);
      pb = unpack_fp(fmt, b_bits);
      if (fz && pa.sub) begin
        pa.zero = 1'b1;
        pa.sub = 1'b0;
        pa.sig = 256'd0;
      end
      if (fz && pb.sub) begin
        pb.zero = 1'b1;
        pb.sub = 1'b0;
        pb.sig = 256'd0;
      end
      div_is_special = pa.nan || pb.nan ||
                       ((pa.inf && pb.inf) || (pa.zero && pb.zero) ||
                        (pb.zero && !pa.inf && !pa.zero) ||
                        pa.inf || pa.zero || pb.inf);
    end
  endfunction

  function automatic logic sqrt_is_special(
      input fp_fmt_t fmt,
      input logic [63:0] a_bits,
      input logic fz);
    fp_parts_t p;
    begin
      p = unpack_fp(fmt, a_bits);
      if (fz && p.sub) begin
        p.zero = 1'b1;
        p.sub = 1'b0;
        p.sig = 256'd0;
      end
      sqrt_is_special = p.nan || p.zero || p.sign || p.inf;
    end
  endfunction

  // Assemble an iteratively computed square root.  q and sticky come from
  // lcvex_fp_iter_sqrt; this function only does the same special-value,
  // scale and round_pack work as the legacy sqrt_op without isqrt64.
  function automatic fp_calc_t sqrt_finish_iter(
      input fp_fmt_t      fmt,
      input logic [63:0]  a_bits,
      input integer       exp2e,
      input integer       shift,
      input logic [63:0]  q,
      input logic         sticky,
      input logic         default_nan_mode,
      input logic         flush_to_zero,
      input logic [1:0]   rmode);
    fp_calc_t r;
    fp_parts_t p;
    logic [31:0] input_flags;
    logic [255:0] q_sig;
    begin
      r = '0;
      p = unpack_fp(fmt, a_bits);
      input_flags = 32'd0;
      if (flush_to_zero && p.sub) begin
        p.zero = 1'b1;
        p.sub = 1'b0;
        p.sig = 256'd0;
        input_flags = FPSR_IDC;
      end
      if (p.nan) begin
        r.bits = default_nan_mode ? default_nan(fmt)
                                  : (p.snan ? quiet_nan(a_bits, fmt)
                                            : a_bits);
        r.flags = input_flags | (p.snan ? FPSR_IOC : 32'd0);
      end else if (p.zero) begin
        if (input_flags[7])
          r.bits = pack_zero(p.sign, fmt);
        else
          r.bits = a_bits;
        r.flags = input_flags;
      end else if (p.sign) begin
        r.bits = default_nan(fmt);
        r.flags = input_flags | FPSR_IOC;
      end else if (p.inf) begin
        r.bits = a_bits;
      end else begin
        q_sig = 256'(q);
        if (sticky)
          q_sig[0] = 1'b1;
        r = round_pack(1'b0, q_sig, exp2e/2 - shift/2, fmt,
                       flush_to_zero, rmode, 1'b0);
        r.flags = r.flags | input_flags;
      end
      sqrt_finish_iter = r;
    end
  endfunction

  // FP-P3T round6: pre-round intermediate for the iterative FSQRT finish.
  // This captures the unpacked/special-value decision and the scaled square
  // root quotient in one cycle, leaving only round_pack for the next cycle.
  function automatic fp_pre_t sqrt_finish_pre(
      input fp_fmt_t      fmt,
      input logic [63:0]  a_bits,
      input integer       exp2e,
      input integer       shift,
      input logic [63:0]  q,
      input logic         sticky,
      input logic         default_nan_mode,
      input logic         flush_to_zero,
      input logic [1:0]   rmode);
    fp_pre_t p;
    fp_parts_t ppar;
    logic [31:0] input_flags;
    logic [255:0] q_sig;
    begin
      p = '0;
      ppar = unpack_fp(fmt, a_bits);
      input_flags = 32'd0;
      if (flush_to_zero && ppar.sub) begin
        ppar.zero = 1'b1;
        ppar.sub = 1'b0;
        ppar.sig = 256'd0;
        input_flags = FPSR_IDC;
      end
      if (ppar.nan) begin
        p.is_special = 1'b1;
        p.special.bits = default_nan_mode ? default_nan(fmt)
                                          : (ppar.snan ? quiet_nan(a_bits, fmt)
                                                       : a_bits);
        p.special.flags = input_flags | (ppar.snan ? FPSR_IOC : 32'd0);
      end else if (ppar.zero) begin
        p.is_special = 1'b1;
        if (input_flags[7])
          p.special.bits = pack_zero(ppar.sign, fmt);
        else
          p.special.bits = a_bits;
        p.special.flags = input_flags;
      end else if (ppar.sign) begin
        p.is_special = 1'b1;
        p.special.bits = default_nan(fmt);
        p.special.flags = input_flags | FPSR_IOC;
      end else if (ppar.inf) begin
        p.is_special = 1'b1;
        p.special.bits = a_bits;
        p.special.flags = input_flags;
      end else begin
        q_sig = 256'(q);
        if (sticky)
          q_sig[0] = 1'b1;
        p.is_special = 1'b0;
        p.need_round = 1'b1;
        p.sign = 1'b0;
        p.sig = q_sig;
        p.lead = leading_one_index(q_sig);
        p.lead_valid = (|q_sig != 1'b0);
        p.exp2 = exp2e/2 - shift/2;
        p.fmt = fmt;
        p.flush_zero = flush_to_zero;
        p.rmode = rmode;
        p.ahp = 1'b0;
        p.input_flags = input_flags;
      end
      sqrt_finish_pre = p;
    end
  endfunction

  generate
    if (!FP_ITER) begin : g_legacy
  fp_calc_t calc;
  fp_calc_t calc_lo;
  fp_calc_t calc_hi;
  fp_int_calc_t ic;
  fp_fmt_t fmt;

  // Multi-cycle blocked FDIV. Two identical units let FP16 DIV handle both
  // 16-bit lanes in parallel; S/D division uses only the low unit.
  logic        div_start_lo;
  logic        div_start_hi;
  logic        div_busy_lo;
  logic        div_done_lo;
  logic        div_sticky_lo;
  logic        div_busy_hi;
  logic        div_done_hi;
  logic        div_sticky_hi;
  logic [FP_W-1:0] div_num_lo;
  logic [FP_W-1:0] div_num_hi;
  logic [FP_W-1:0] div_q_lo;
  logic [FP_W-1:0] div_q_hi;
  logic [63:0] div_den_lo;
  logic [63:0] div_den_hi;
  fp_parts_t div_pa_lo;
  fp_parts_t div_pb_lo;
  fp_parts_t div_pa_hi;
  fp_parts_t div_pb_hi;

  lcvex_fp_divider div_lo (
      .clk      (clk),
      .rst_n    (rst_n),
      .start    (div_start_lo),
      .numerator(div_num_lo),
      .divisor  (div_den_lo),
      .kill     (1'b0),
      .pause    (1'b0),
      .busy     (div_busy_lo),
      .done     (div_done_lo),
      .quotient (div_q_lo),
      .sticky   (div_sticky_lo)
  );

  lcvex_fp_divider div_hi (
      .clk      (clk),
      .rst_n    (rst_n),
      .start    (div_start_hi),
      .numerator(div_num_hi),
      .divisor  (div_den_hi),
      .kill     (1'b0),
      .pause    (1'b0),
      .busy     (div_busy_hi),
      .done     (div_done_hi),
      .quotient (div_q_hi),
      .sticky   (div_sticky_hi)
  );

  always_comb begin : fp_div_start
    div_start_lo = 1'b0;
    div_start_hi = 1'b0;
    div_num_lo = '0;
    div_num_hi = '0;
    div_den_lo = 64'd0;
    div_den_hi = 64'd0;
    div_pa_lo = '0;
    div_pb_lo = '0;
    div_pa_hi = '0;
    div_pb_hi = '0;
    if (valid && op == FP_OP_DIV && !div_busy_lo && !div_done_lo) begin
      if (is_half) begin
        div_pa_lo = unpack_fp(FMT_HALF, {48'd0, operand_a[15:0]});
        div_pb_lo = unpack_fp(FMT_HALF, {48'd0, operand_b[15:0]});
        div_num_lo = div_pa_lo.sig << DIV_EXTRA;
        div_den_lo = div_pb_lo.sig[63:0];
        div_start_lo = 1'b1;
        div_pa_hi = unpack_fp(FMT_HALF, {48'd0, operand_a[31:16]});
        div_pb_hi = unpack_fp(FMT_HALF, {48'd0, operand_b[31:16]});
        div_num_hi = div_pa_hi.sig << DIV_EXTRA;
        div_den_hi = div_pb_hi.sig[63:0];
        div_start_hi = 1'b1;
      end else begin
        div_pa_lo = unpack_fp(is_double ? FMT_DOUBLE : FMT_SINGLE, operand_a);
        div_pb_lo = unpack_fp(is_double ? FMT_DOUBLE : FMT_SINGLE, operand_b);
        div_num_lo = div_pa_lo.sig << DIV_EXTRA;
        div_den_lo = div_pb_lo.sig[63:0];
        div_start_lo = 1'b1;
      end
    end
  end

  always_comb begin
    calc = '0;
    calc_lo = '0;
    calc_hi = '0;
    ic = '0;
    int_result = 64'd0;
    fmt = FMT_SINGLE;
    result = 64'd0;
    fpsr_flags = 32'd0;
    cmp_nzcv = 4'd0;
    if (valid) begin
      // S/D -> H 的 FCVT 目的格式为 H，也走 half 数据路径（fcvt 是
      // 单 lane，不影响 is_half 双 lane 算术）。
      if (is_half || (op == FP_OP_FCVT && fcvt_dst_half)) begin
        fmt = FMT_HALF;
        if (op == FP_OP_DIV) begin
          // FDIV.H: both 16-bit lanes use parallel multi-cycle dividers.
          if (div_done_lo && div_done_hi) begin
            calc_lo = div_finish(FMT_HALF, {48'd0, operand_a[15:0]},
                                 {48'd0, operand_b[15:0]}, div_q_lo,
                                 div_sticky_lo, fpcr[25], fpcr[19],
                                 fpcr[23:22]);
            calc_hi = div_finish(FMT_HALF, {48'd0, operand_a[31:16]},
                                 {48'd0, operand_b[31:16]}, div_q_hi,
                                 div_sticky_hi, fpcr[25], fpcr[19],
                                 fpcr[23:22]);
            calc.bits = {32'd0, calc_hi.bits[15:0],
                         calc_lo.bits[15:0]};
            calc.flags = (calc_lo.flags | calc_hi.flags) & ~FPSR_IDC;
            calc.nzcv = 4'd0;
          end
        end else if (op == FP_OP_MOV) begin
          // 标量 H 写回清高 48 位（FPCR.NEP 不在 P7 mask 内）。
          calc.bits = {48'd0, operand_a[15:0]};
        end else if (op == FP_OP_ADD || op == FP_OP_SUB || op == FP_OP_MUL ||
                    op == FP_OP_CMP || op == FP_OP_SQRT ||
                    op == FP_OP_FMIN || op == FP_OP_FMAX || op == FP_OP_FMINNM ||
                    op == FP_OP_FMAXNM || op == FP_OP_FRINT ||
                    op == FP_OP_FMADD || op == FP_OP_FMSUB ||
                    op == FP_OP_FNMADD || op == FP_OP_FNMSUB) begin
          // 32-bit 槽内含两个 16-bit lane（向量 4H/8H / 标量 H 复用）。
          calc_lo = half_lane_calc(op, operand_a[15:0],
                                   operand_b[15:0], operand_c[15:0],
                                   fpcr[25], fpcr[19], fpcr[23:22],
                                   rint_mode, compare_zero);
          calc_hi = half_lane_calc(op, operand_a[31:16],
                                   operand_b[31:16], operand_c[31:16],
                                   fpcr[25], fpcr[19], fpcr[23:22],
                                   rint_mode, compare_zero);
          calc.bits = {32'd0, calc_hi.bits[15:0],
                       calc_lo.bits[15:0]};
          calc.flags = calc_lo.flags | calc_hi.flags;
          if (op == FP_OP_CMP) begin
            // FCMEQ/FCMP：每个半 lane 输出全 1/全 0 掩码。
            calc.bits = {32'd0,
                         {16{calc_hi.nzcv == 4'b0110}},
                         {16{calc_lo.nzcv == 4'b0110}}};
          end
          calc.nzcv = calc_lo.nzcv;
          // FP16 运算不置 IDC（QEMU FPST_A64_F16 屏蔽）。
          calc.flags = calc.flags & ~FPSR_IDC;
        end else if (op == FP_OP_FCVT) begin
          if (fcvt_dst_half) begin
            // S/D -> H：输入 flush 用 FZ；输出 flush 被 QEMU helper
            // squash（AHP/IEEE 均不 flush 到零）。
            calc = fcvt_op2(FMT_HALF,
                            is_double ? FMT_DOUBLE : FMT_SINGLE,
                            operand_a, fpcr[25], fpcr[24], 1'b0,
                            fpcr[23:22], fpcr[26]);
          end else begin
            // H -> S/D：输入/输出均不 flush。
            calc = fcvt_op2(is_double ? FMT_DOUBLE : FMT_SINGLE,
                            FMT_HALF, operand_a, fpcr[25], 1'b0,
                            1'b0, fpcr[23:22], fpcr[26]);
          end
        end else begin
          calc = '0;
        end
      end else begin
        fmt = is_double ? FMT_DOUBLE : FMT_SINGLE;
        if (op == FP_OP_MOV) begin
          // Scalar FP writes clear the high portion because FPCR.NEP is
          // not implemented/enabled in the P7 mask (reset value is 0).
          calc.bits = is_double ? operand_a
                                : {32'd0, operand_a[31:0]};
        end else if (op == FP_OP_ADD || op == FP_OP_SUB ||
                    op == FP_OP_MUL) begin
          calc = binary_op(op, fmt, operand_a, operand_b,
                           fpcr[25], fpcr[24], fpcr[23:22]);
        end else if (op == FP_OP_DIV) begin
          if (div_done_lo) begin
            calc = div_finish(fmt, operand_a, operand_b, div_q_lo,
                              div_sticky_lo, fpcr[25], fpcr[24],
                              fpcr[23:22]);
          end
        end else if (op == FP_OP_CMP) begin
          calc = compare_op(fmt, operand_a, operand_b, fpcr[24],
                            compare_zero, signal_all_nans);
        end else if (op == FP_OP_FMADD || op == FP_OP_FMSUB ||
                    op == FP_OP_FNMADD || op == FP_OP_FNMSUB) begin
          calc = fma_op(op, is_double ? FMT_DOUBLE : FMT_SINGLE,
                        operand_a, operand_b, operand_c,
                        fpcr[25], fpcr[24], fpcr[23:22]);
        end else if (op == FP_OP_SQRT) begin
          calc = sqrt_op(fmt, operand_a, fpcr[25], fpcr[24],
                         fpcr[23:22]);
        end else if (op == FP_OP_FMIN || op == FP_OP_FMAX ||
                    op == FP_OP_FMINNM || op == FP_OP_FMAXNM) begin
          calc = minmax_op(op, fmt, operand_a, operand_b, fpcr[25],
                           fpcr[24]);
        end else if (op == FP_OP_FRINT) begin
          calc = frint_op(fmt, operand_a, rint_mode, fpcr[25],
                          fpcr[24], fpcr[23:22]);
        end else if (op == FP_OP_SCVTF || op == FP_OP_UCVTF) begin
          calc = int_to_fp_op(is_double, conv_int, 32'(conv_shift),
                              op == FP_OP_SCVTF, fpcr[24],
                              fpcr[23:22]);
        end else if (op == FP_OP_FCVTZS || op == FP_OP_FCVTZU) begin
          // 结果走 int_result（core 接到 GPR 或 vector lane）。
          calc = '0;
          ic = fp_to_int_op(is_double, operand_a,
                            32'(conv_shift), conv_is_32,
                            op == FP_OP_FCVTZS, fpcr[24]);
          int_result = ic.value;
        end else if (op == FP_OP_FCVT) begin
          calc = fcvt_op2(is_double ? FMT_DOUBLE : FMT_SINGLE,
                          is_double ? FMT_SINGLE : FMT_DOUBLE,
                          operand_a, fpcr[25], fpcr[24], fpcr[24],
                          fpcr[23:22], 1'b0);
        end else begin
          calc = '0;
        end
      end
    end
    result = calc.bits;
    fpsr_flags = (valid && (op == FP_OP_FCVTZS || op == FP_OP_FCVTZU))
                 ? ic.flags : calc.flags;
    cmp_nzcv = calc.nzcv;
    div_busy = is_half ? (div_busy_lo || div_busy_hi) : div_busy_lo;
    div_done = is_half ? (div_done_lo && div_done_hi) : div_done_lo;
  end

  assign iter_busy = 1'b0;
  assign iter_done = 1'b0;

    end else begin : g_iter
      typedef enum logic [3:0] {
        IT_IDLE  = 4'd0,
        IT_DIV   = 4'd1,
        IT_SQRT  = 4'd2,
        IT_PREP  = 4'd3,
        IT_ARITH = 4'd4,
        IT_OTHER = 4'd5,
        IT_MUL   = 4'd6,
        IT_FIN   = 4'd7,
        IT_ALIGN = 4'd8,
        IT_ADD   = 4'd9,
        IT_PACK_SCAN = 4'd10,
        IT_PACK_PRE  = 4'd11,
        IT_PACK      = 4'd12,
        // R20: IT_PACK computes p2 into a private register; this state
        // exposes only that registered result to the slot/response capture.
        IT_PACK_RESULT = 4'd13,
        // R21: FMA alignment is captured by IT_MUL, then the wide add/sub is
        // completed in this FMA-only state before entering the pack path.
        IT_FMA     = 4'd14
      } it_state_t;

      fp_fmt_t it_fmt;
      logic    it_fz;
      logic    it_div_start;
      logic    it_sqrt_start;
      logic    it_div_busy;
      logic    it_div_done;
      logic [FP_W-1:0] it_div_q;
      logic    it_div_sticky;
      logic    it_sqrt_busy;
      logic    it_sqrt_done;
      logic [63:0] it_sqrt_q;
      logic    it_sqrt_sticky;
      logic [FP_W-1:0] it_div_num;
      logic [63:0] it_div_den;
      logic [127:0] it_sqrt_s;
      integer  it_sqrt_exp2e;
      integer  it_sqrt_shift;
      it_state_t it_state_r;
      logic    it_lane_r;
      logic [63:0] it_cur_a;
      logic [63:0] it_cur_b;
      logic        it_div_special;
      logic        it_sqrt_special;
      fp_calc_t calc;
      fp_calc_t calc_lo;
      fp_calc_t calc_hi;
      fp_int_calc_t ic;
      fp_fmt_t fmt;
      fp_parts_t it_div_pa;
      fp_parts_t it_div_pb;
      fp_parts_t it_sqrt_pa;
      fp_calc_t  it_cur_calc;
      // FP-P3T round8: iterative DIV/SQRT round_pack intermediate registers.
      // IT_FIN computes the shifted significand/GRS/special bypass and enters
      // IT_PACK; IT_PACK completes increment/overflow/subnormal/pack.  This
      // splits the remaining div_pre.sig -> slot_result_r 54-level cone.
      fp_round_mid_t it_fin_mid_r;
      fp_round_mid_t it_fin_mid_lo;
      fp_round_mid_t it_fin_mid_hi;
      logic          it_fin_valid_r;
      // FP-P3T pre-round pipeline registers.  They hold the unpacked/effective-
      // add/shift result for the current non-div/sqrt slot and are consumed by
      // the round/pack stage on the following cycle.
      fp_pre_t   pp_pre;
      fp_pre_t   pp_pre_lo;
      fp_pre_t   pp_pre_hi;
      // FP-P3T round2 unpacked-operand pipeline registers for the remaining
      // non-iterative ops (CMP/minmax/FRINT/FP->int).
      fp_other_pre_t pp_other;
      fp_other_pre_t pp_other_lo;
      fp_other_pre_t pp_other_hi;
      // FP-P3T round3 unpacked-operand pipeline registers for the pre-round
      // arithmetic path (ADD/SUB/MUL/FMA/SCVTF/UCVTF).  Stage 1 captures
      // unpacked parts; later states perform alignment/multiply pre-round
      // work before the existing finish stage.
      fp_arith_pre_t ap_pre;
      fp_arith_pre_t ap_pre_lo;
      fp_arith_pre_t ap_pre_hi;
      // FP-P3T round9: ADD/SUB alignment registers.  Written by IT_ARITH,
      // consumed by IT_ALIGN, and cleared on reset/kill; no architectural
      // state is committed until the existing slot/response path fires.
      fp_add_align_t add_align;
      fp_add_align_t add_align_lo;
      fp_add_align_t add_align_hi;
      // FP-P3T round10: effective ADD/SUB result after the alignment
      // register.  IT_ALIGN writes this payload; IT_ADD constructs pp_pre.
      // It is an internal non-architectural state and reset/kill-cleared.
      fp_add_mid_t add_mid;
      fp_add_mid_t add_mid_lo;
      fp_add_mid_t add_mid_hi;
      // FP-P3T round5 multiplier-product pipeline registers.  For MUL/FMA,
      // stage 2 captures only the DSP multiplier output (product, sign,
      // product exponent) and stage 3 performs the remaining align/add and
      // writes pp_pre.  This breaks the DSP MAC output -> pp_pre_hi comb cone.
      fp_pre_t       pm_pre;
      fp_pre_t       pm_pre_lo;
      fp_pre_t       pm_pre_hi;
      // FP-P3T round21: the residual FMA product/addend alignment payload.
      // IT_MUL writes this register; IT_FMA consumes it and writes pp_pre.
      fp_fma_align_t fma_align;
      fp_fma_align_t fma_align_lo;
      fp_fma_align_t fma_align_hi;
      // FP-P3T round4 second-stage registers for pp_other operations.
      fp_other_mid_t ot_mid;
      fp_other_mid_t ot_mid_lo;
      fp_other_mid_t ot_mid_hi;
      // FP-P3T round6 iterative-div/sqrt final pre-round registers.  These
      // capture the unpacked/special-value decision and quotient after the
      // multi-cycle divider/sqrt; the next IT_FIN cycle performs only the
      // architectural round/pack.  This cuts the slot operand mux -> DIV/SQRT
      // finish -> slot_result_r combinational cone.
      fp_pre_t       div_pre;
      fp_pre_t       div_pre_lo;
      fp_pre_t       div_pre_hi;
      fp_pre_t       sqrt_pre;
      fp_pre_t       sqrt_pre_lo;
      fp_pre_t       sqrt_pre_hi;
      // FP-P3T round18: ordinary finite pp_pre round/pack boundaries.  IT_PREP
      // captures the leading-one/zero scan and derived exponent into
      // pack_scan*.  IT_PACK_SCAN classifies tiny/normal into pack_pre*;
      // IT_PACK_PRE constructs the normalized mantissa and GRS payload; and
      // IT_PACK performs round_pack_p2 into the private result registers;
      // IT_PACK_RESULT alone exposes iter_done/result.
      fp_round_scan_t pack_scan;
      fp_round_scan_t pack_scan_lo;
      fp_round_scan_t pack_scan_hi;
      fp_round_pre_t  pack_pre;
      fp_round_pre_t  pack_pre_lo;
      fp_round_pre_t  pack_pre_hi;
      fp_round_mid_t pack_mid;
      fp_round_mid_t pack_mid_lo;
      fp_round_mid_t pack_mid_hi;
      // R20 final result boundary. IT_PACK writes the p2 result and
      // IT_PACK_RESULT supplies the one-cycle result/flags/done window.
      fp_calc_t pack_result_r;
      fp_calc_t pack_result_lo;
      fp_calc_t pack_result_hi;
      logic     pack_result_half_r;
      logic     pack_result_valid_r;

      lcvex_fp_divider it_divider (
          .clk      (clk),
          .rst_n    (rst_n),
          .start    (it_div_start),
          .numerator(it_div_num),
          .divisor  (it_div_den),
          .kill     (iter_kill),
          .pause    (iter_pause),
          .busy     (it_div_busy),
          .done     (it_div_done),
          .quotient (it_div_q),
          .sticky   (it_div_sticky)
      );

      lcvex_fp_iter_sqrt it_sqrt (
          .clk    (clk),
          .rst_n  (rst_n),
          .start  (it_sqrt_start),
          .kill   (iter_kill),
          .pause  (iter_pause),
          .x      (it_sqrt_s),
          .busy   (it_sqrt_busy),
          .done   (it_sqrt_done),
          .q      (it_sqrt_q),
          .sticky (it_sqrt_sticky)
      );

      always_comb begin
        it_fmt = is_half ? FMT_HALF :
                 (is_double ? FMT_DOUBLE : FMT_SINGLE);
        it_fz  = is_half ? fpcr[19] : fpcr[24];
        it_cur_a = 64'd0;
        it_cur_b = 64'd0;
        if (is_half) begin
          if (it_lane_r == 1'b0) begin
            it_cur_a = {48'd0, operand_a[15:0]};
            it_cur_b = {48'd0, operand_b[15:0]};
          end else begin
            it_cur_a = {48'd0, operand_a[31:16]};
            it_cur_b = {48'd0, operand_b[31:16]};
          end
        end else begin
          it_cur_a = operand_a;
          it_cur_b = operand_b;
        end
        it_div_special = 1'b0;
        it_sqrt_special = 1'b0;
        if (valid) begin
          if (op == FP_OP_DIV)
            it_div_special = div_is_special(it_fmt, it_cur_a, it_cur_b, it_fz);
          else if (op == FP_OP_SQRT)
            it_sqrt_special = sqrt_is_special(it_fmt, it_cur_a, it_fz);
        end
      end

      always_comb begin
        it_div_num = '0;
        it_div_den = 64'd0;
        it_div_pa = '0;
        it_div_pb = '0;
        if (valid && op == FP_OP_DIV && !it_div_special) begin
          it_div_pa = unpack_fp(it_fmt, it_cur_a);
          it_div_pb = unpack_fp(it_fmt, it_cur_b);
          it_div_num = it_div_pa.sig << DIV_EXTRA;
          it_div_den = it_div_pb.sig[63:0];
        end
      end

      always_comb begin
        integer i;
        integer h;
        it_sqrt_s = 128'd0;
        it_sqrt_exp2e = 0;
        it_sqrt_shift = 0;
        it_sqrt_pa = '0;
        i = 0;
        h = 0;
        if (valid && op == FP_OP_SQRT && !it_sqrt_special) begin
          it_sqrt_pa = unpack_fp(it_fmt, it_cur_a);
          it_sqrt_exp2e = it_sqrt_pa.exp2;
          if (it_sqrt_exp2e % 2 != 0) begin
            it_sqrt_pa.sig = it_sqrt_pa.sig << 1;
            it_sqrt_exp2e = it_sqrt_exp2e - 1;
          end
          h = -1;
          for (i = FP_W - 1; i >= 0; i = i - 1) begin
            if (h < 0 && it_sqrt_pa.sig[i])
              h = i;
          end
          if (h < 0)
            h = 0;
          it_sqrt_shift = 126 - (h & ~1);
          if (it_sqrt_shift < 0)
            it_sqrt_shift = 0;
          it_sqrt_s = it_sqrt_pa.sig[127:0] << it_sqrt_shift;
        end
      end

      always_comb begin
        it_div_start = 1'b0;
        if (valid && op == FP_OP_DIV && !it_div_special) begin
          if ((it_state_r == IT_IDLE) ||
              (it_state_r == IT_DIV && !it_div_busy && !it_div_done))
            it_div_start = 1'b1;
        end
      end

      always_comb begin
        it_sqrt_start = 1'b0;
        if (valid && op == FP_OP_SQRT && !it_sqrt_special) begin
          if ((it_state_r == IT_IDLE) ||
              (it_state_r == IT_SQRT && !it_sqrt_busy && !it_sqrt_done))
            it_sqrt_start = 1'b1;
        end
      end

      always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
          it_state_r   <= IT_IDLE;
          it_lane_r    <= 1'b0;
          it_fin_mid_r <= '0;
          it_fin_mid_lo <= '0;
          it_fin_mid_hi <= '0;
          it_fin_valid_r <= 1'b0;
          pp_pre       <= '0;
          pp_pre_lo    <= '0;
          pp_pre_hi    <= '0;
          pp_other     <= '0;
          pp_other_lo  <= '0;
          pp_other_hi  <= '0;
          ap_pre       <= '0;
          ap_pre_lo    <= '0;
          ap_pre_hi    <= '0;
          add_align    <= '0;
          add_align_lo <= '0;
          add_align_hi <= '0;
          add_mid      <= '0;
          add_mid_lo   <= '0;
          add_mid_hi   <= '0;
          pm_pre       <= '0;
          pm_pre_lo    <= '0;
          pm_pre_hi    <= '0;
          fma_align    <= '0;
          fma_align_lo <= '0;
          fma_align_hi <= '0;
          ot_mid       <= '0;
          ot_mid_lo    <= '0;
          ot_mid_hi    <= '0;
          div_pre      <= '0;
          div_pre_lo   <= '0;
          div_pre_hi   <= '0;
          sqrt_pre     <= '0;
          sqrt_pre_lo  <= '0;
          sqrt_pre_hi  <= '0;
          pack_scan    <= '0;
          pack_scan_lo <= '0;
          pack_scan_hi <= '0;
          pack_pre     <= '0;
          pack_pre_lo  <= '0;
          pack_pre_hi  <= '0;
          pack_mid     <= '0;
          pack_mid_lo  <= '0;
          pack_mid_hi  <= '0;
          pack_result_r <= '0;
          pack_result_lo <= '0;
          pack_result_hi <= '0;
          pack_result_half_r <= 1'b0;
          pack_result_valid_r <= 1'b0;
        end else if (iter_kill) begin
          it_state_r   <= IT_IDLE;
          it_lane_r    <= 1'b0;
          it_fin_mid_r <= '0;
          it_fin_mid_lo <= '0;
          it_fin_mid_hi <= '0;
          it_fin_valid_r <= 1'b0;
          pp_pre       <= '0;
          pp_pre_lo    <= '0;
          pp_pre_hi    <= '0;
          pp_other     <= '0;
          pp_other_lo  <= '0;
          pp_other_hi  <= '0;
          ap_pre       <= '0;
          ap_pre_lo    <= '0;
          ap_pre_hi    <= '0;
          add_align    <= '0;
          add_align_lo <= '0;
          add_align_hi <= '0;
          add_mid      <= '0;
          add_mid_lo   <= '0;
          add_mid_hi   <= '0;
          pm_pre       <= '0;
          pm_pre_lo    <= '0;
          pm_pre_hi    <= '0;
          fma_align    <= '0;
          fma_align_lo <= '0;
          fma_align_hi <= '0;
          ot_mid       <= '0;
          ot_mid_lo    <= '0;
          ot_mid_hi    <= '0;
          div_pre      <= '0;
          div_pre_lo   <= '0;
          div_pre_hi   <= '0;
          sqrt_pre     <= '0;
          sqrt_pre_lo  <= '0;
          sqrt_pre_hi  <= '0;
          pack_scan    <= '0;
          pack_scan_lo <= '0;
          pack_scan_hi <= '0;
          pack_pre     <= '0;
          pack_pre_lo  <= '0;
          pack_pre_hi  <= '0;
          pack_mid     <= '0;
          pack_mid_lo  <= '0;
          pack_mid_hi  <= '0;
          pack_result_r <= '0;
          pack_result_lo <= '0;
          pack_result_hi <= '0;
          pack_result_half_r <= 1'b0;
          pack_result_valid_r <= 1'b0;
        end else if (!valid && it_state_r == IT_PACK_RESULT) begin
          // A final result is cancellable even while paused: once valid is
          // withdrawn, do not retain a payload that could be resurrected by
          // a later valid assertion.
          it_state_r <= IT_IDLE;
          it_lane_r  <= 1'b0;
          pack_result_r <= '0;
          pack_result_lo <= '0;
          pack_result_hi <= '0;
          pack_result_half_r <= 1'b0;
          pack_result_valid_r <= 1'b0;
        end else if (!iter_pause) begin
          case (it_state_r)
            IT_IDLE: begin
              if (valid && (op == FP_OP_DIV || op == FP_OP_SQRT)) begin
                it_state_r <= (op == FP_OP_DIV) ? IT_DIV : IT_SQRT;
                it_lane_r  <= 1'b0;
              end else if (valid && op == FP_OP_FCVT) begin
                it_state_r <= IT_PREP;
                it_lane_r  <= 1'b0;
                if (fcvt_dst_half) begin
                  pp_pre <= fcvt_pre(FMT_HALF,
                                     is_double ? FMT_DOUBLE : FMT_SINGLE,
                                     operand_a, fpcr[25], fpcr[24], 1'b0,
                                     fpcr[23:22], fpcr[26]);
                end else if (is_half) begin
                  pp_pre <= fcvt_pre(is_double ? FMT_DOUBLE : FMT_SINGLE,
                                     FMT_HALF, operand_a, fpcr[25], 1'b0,
                                     1'b0, fpcr[23:22], fpcr[26]);
                end else begin
                  pp_pre <= fcvt_pre(is_double ? FMT_DOUBLE : FMT_SINGLE,
                                     is_double ? FMT_SINGLE : FMT_DOUBLE,
                                     operand_a, fpcr[25], fpcr[24], fpcr[24],
                                     fpcr[23:22], 1'b0);
                end
              end else if (valid && uses_pre_round(op)) begin
                // Round3 stage 1: capture unpacked/flushed operands only.
                // IT_ARITH/IT_ALIGN then perform the ADD/SUB alignment and
                // effective-add boundary before writing pp_pre.
                it_state_r <= IT_ARITH;
                it_lane_r  <= 1'b0;
                if (is_half) begin
                  ap_pre_lo <= arith_pre(op, FMT_HALF,
                                         {48'd0, operand_a[15:0]},
                                         {48'd0, operand_b[15:0]},
                                         64'd0, 64'd0,
                                         32'(conv_shift), conv_is_32,
                                         fpcr[25], fpcr[19], fpcr[23:22]);
                  ap_pre_hi <= arith_pre(op, FMT_HALF,
                                         {48'd0, operand_a[31:16]},
                                         {48'd0, operand_b[31:16]},
                                         64'd0, 64'd0,
                                         32'(conv_shift), conv_is_32,
                                         fpcr[25], fpcr[19], fpcr[23:22]);
                end else begin
                  ap_pre <= arith_pre(op, is_double ? FMT_DOUBLE : FMT_SINGLE,
                                      operand_a, operand_b, 64'd0,
                                      conv_int, 32'(conv_shift), conv_is_32,
                                      fpcr[25], fpcr[24], fpcr[23:22]);
                end
              end else if (valid && (op == FP_OP_FMADD || op == FP_OP_FMSUB ||
                                     op == FP_OP_FNMADD || op == FP_OP_FNMSUB)) begin
                it_state_r <= IT_ARITH;
                it_lane_r  <= 1'b0;
                if (is_half) begin
                  ap_pre_lo <= arith_pre(op, FMT_HALF,
                                         {48'd0, operand_a[15:0]},
                                         {48'd0, operand_b[15:0]},
                                         {48'd0, operand_c[15:0]},
                                         64'd0,
                                         32'(conv_shift), conv_is_32,
                                         fpcr[25], fpcr[19], fpcr[23:22]);
                  ap_pre_hi <= arith_pre(op, FMT_HALF,
                                         {48'd0, operand_a[31:16]},
                                         {48'd0, operand_b[31:16]},
                                         {48'd0, operand_c[31:16]},
                                         64'd0,
                                         32'(conv_shift), conv_is_32,
                                         fpcr[25], fpcr[19], fpcr[23:22]);
                end else begin
                  ap_pre <= arith_pre(op, is_double ? FMT_DOUBLE : FMT_SINGLE,
                                      operand_a, operand_b, operand_c,
                                      conv_int, 32'(conv_shift), conv_is_32,
                                      fpcr[25], fpcr[24], fpcr[23:22]);
                end
              end else if (valid && uses_other_pre(op)) begin
                // Round2/4: capture unpacked/flushed operands.  CMP remains
                // a two-stage finish; the other pp_other ops pass through
                // IT_OTHER to split the expensive combine/finish cone.
                it_state_r <= (op == FP_OP_CMP) ? IT_PREP : IT_OTHER;
                it_lane_r  <= 1'b0;
                if (is_half) begin
                  pp_other_lo <= other_pre(FMT_HALF,
                                           {48'd0, operand_a[15:0]},
                                           {48'd0, operand_b[15:0]},
                                           32'(conv_shift), conv_is_32,
                                           fpcr[19], fpcr[25], fpcr[23:22],
                                           rint_mode, compare_zero,
                                           signal_all_nans);
                  pp_other_hi <= other_pre(FMT_HALF,
                                           {48'd0, operand_a[31:16]},
                                           {48'd0, operand_b[31:16]},
                                           32'(conv_shift), conv_is_32,
                                           fpcr[19], fpcr[25], fpcr[23:22],
                                           rint_mode, compare_zero,
                                           signal_all_nans);
                end else begin
                  pp_other <= other_pre(is_double ? FMT_DOUBLE : FMT_SINGLE,
                                        operand_a, operand_b,
                                        32'(conv_shift), conv_is_32,
                                        fpcr[24], fpcr[25], fpcr[23:22],
                                        rint_mode, compare_zero,
                                        signal_all_nans);
                end
              end
            end
            IT_ARITH: begin
              if (!valid) begin
                it_state_r <= IT_IDLE;
                it_lane_r  <= 1'b0;
              end else begin
                it_lane_r  <= 1'b0;
                if (is_half) begin
                  if (ap_pre_lo.op == FP_OP_ADD ||
                      ap_pre_lo.op == FP_OP_SUB) begin
                    // Round9 stage 2: capture the exponent-dependent sticky
                    // alignment.  Effective add/sub and special handling are
                    // deferred to IT_ALIGN so pp_pre is no longer driven by
                    // the full ap_pre alignment cone in one cycle.
                    it_state_r <= IT_ALIGN;
                    add_align_lo <= binary_align_parts(ap_pre_lo);
                    add_align_hi <= binary_align_parts(ap_pre_hi);
                  end else if (ap_pre_lo.op == FP_OP_MUL ||
                      ap_pre_lo.op == FP_OP_FMADD ||
                      ap_pre_lo.op == FP_OP_FMSUB ||
                      ap_pre_lo.op == FP_OP_FNMADD ||
                      ap_pre_lo.op == FP_OP_FNMSUB) begin
                    // Round5 stage 2: capture only the DSP multiplier output.
                    // The remaining align/add and pp_pre write happen in IT_MUL.
                    it_state_r <= IT_MUL;
                    pm_pre_lo  <= mul_product_pre(ap_pre_lo);
                    pm_pre_hi  <= mul_product_pre(ap_pre_hi);
                  end else begin
                    it_state_r <= IT_PREP;
                    pp_pre_lo <= binary_pre_parts(ap_pre_lo.op, ap_pre_lo.fmt,
                                                  ap_pre_lo.a_bits, ap_pre_lo.b_bits,
                                                  ap_pre_lo.pa, ap_pre_lo.pb,
                                                  ap_pre_lo.input_flags,
                                                  ap_pre_lo.dn, ap_pre_lo.fz,
                                                  ap_pre_lo.rmode);
                    pp_pre_hi <= binary_pre_parts(ap_pre_hi.op, ap_pre_hi.fmt,
                                                  ap_pre_hi.a_bits, ap_pre_hi.b_bits,
                                                  ap_pre_hi.pa, ap_pre_hi.pb,
                                                  ap_pre_hi.input_flags,
                                                  ap_pre_hi.dn, ap_pre_hi.fz,
                                                  ap_pre_hi.rmode);
                  end
                end else begin
                  // Non-half IT_ARITH is entered only for the three closed
                  // route families below.  Keep this case exhaustive so an
                  // unexpected payload cannot select a wide generic helper.
                  unique case (ap_pre.op)
                    FP_OP_SCVTF, FP_OP_UCVTF: begin
                      it_state_r <= IT_PREP;
                      pp_pre <= int_to_fp_pre(ap_pre.fmt == FMT_DOUBLE,
                                              ap_pre.conv_int,
                                              ap_pre.conv_shift,
                                              ap_pre.op == FP_OP_SCVTF,
                                              ap_pre.fz, ap_pre.rmode);
                    end
                    FP_OP_ADD, FP_OP_SUB: begin
                      // Round9 stage 2: capture aligned operands; IT_ALIGN
                      // writes pp_pre after the register boundary.
                      it_state_r <= IT_ALIGN;
                      add_align <= binary_align_parts(ap_pre);
                    end
                    FP_OP_MUL, FP_OP_FMADD, FP_OP_FMSUB, FP_OP_FNMADD,
                    FP_OP_FNMSUB: begin
                      // Round5 stage 2: capture only the DSP multiplier
                      // output.  The remaining align/add and pp_pre write
                      // happen in IT_MUL.
                      it_state_r <= IT_MUL;
                      pm_pre <= mul_product_pre(ap_pre);
                    end
                    default: begin
                      // IT_ARITH must never see another operation.  Preserve
                      // the existing IT_PREP boundary with a known zero
                      // payload, but do not call a wide arithmetic helper;
                      // the ordinary invalid-op finish observes deterministic
                      // zero result/flags.
                      it_state_r <= IT_PREP;
                      pp_pre <= '0;
                    end
                  endcase
                end
              end
            end
            IT_ALIGN: begin
              if (!valid) begin
                it_state_r <= IT_IDLE;
                it_lane_r  <= 1'b0;
                add_mid    <= '0;
                add_mid_lo <= '0;
                add_mid_hi <= '0;
              end else begin
                // Round10 stage 3: effective add/sub and cancellation consume
                // only the registered alignment result.  Classification and
                // original bits are carried for special resolution in IT_ADD.
                it_state_r <= IT_ADD;
                it_lane_r  <= 1'b0;
                if (is_half) begin
                  add_mid_lo <= binary_add_mid_from_align(ap_pre_lo,
                                                           add_align_lo);
                  add_mid_hi <= binary_add_mid_from_align(ap_pre_hi,
                                                           add_align_hi);
                end else begin
                  add_mid <= binary_add_mid_from_align(ap_pre, add_align);
                end
              end
            end
            IT_ADD: begin
              if (!valid) begin
                it_state_r <= IT_IDLE;
                it_lane_r  <= 1'b0;
                add_mid    <= '0;
                add_mid_lo <= '0;
                add_mid_hi <= '0;
              end else begin
                // Round10 stage 4: assignment-only construction of pp_pre
                // from the registered effective result.  This leaves no
                // wide compare/add/sub logic between add_mid and pp_pre.
                it_state_r <= IT_PREP;
                it_lane_r  <= 1'b0;
                if (is_half) begin
                  pp_pre_lo <= binary_pre_from_add_mid(add_mid_lo);
                  pp_pre_hi <= binary_pre_from_add_mid(add_mid_hi);
                end else begin
                  pp_pre <= binary_pre_from_add_mid(add_mid);
                end
              end
            end
            IT_MUL: begin
              if (!valid) begin
                it_state_r <= IT_IDLE;
                it_lane_r  <= 1'b0;
                fma_align  <= '0;
                fma_align_lo <= '0;
                fma_align_hi <= '0;
              end else begin
                it_lane_r  <= 1'b0;
                if (is_half) begin
                  if (ap_pre_lo.op == FP_OP_FMADD ||
                      ap_pre_lo.op == FP_OP_FMSUB ||
                      ap_pre_lo.op == FP_OP_FNMADD ||
                      ap_pre_lo.op == FP_OP_FNMSUB) begin
                    // R21 stage 3: capture only the residual alignment
                    // shifts.  The wide FMA add/sub is performed by IT_FMA.
                    it_state_r <= IT_FMA;
                    fma_align_lo <= fma_align_from_product(ap_pre_lo,
                                                            pm_pre_lo);
                    fma_align_hi <= fma_align_from_product(ap_pre_hi,
                                                            pm_pre_hi);
                  end else begin
                    // R20 MUL route is unchanged: no FMA-only cycle.
                    it_state_r <= IT_PREP;
                    pp_pre_lo <= mul_pre_from_product(ap_pre_lo, pm_pre_lo);
                    pp_pre_hi <= mul_pre_from_product(ap_pre_hi, pm_pre_hi);
                  end
                end else if (ap_pre.op == FP_OP_FMADD ||
                             ap_pre.op == FP_OP_FMSUB ||
                             ap_pre.op == FP_OP_FNMADD ||
                             ap_pre.op == FP_OP_FNMSUB) begin
                  // R21 stage 3: capture only the residual alignment
                  // shifts.  The wide FMA add/sub is performed by IT_FMA.
                  it_state_r <= IT_FMA;
                  fma_align <= fma_align_from_product(ap_pre, pm_pre);
                end else begin
                  // R20 MUL route is unchanged: no FMA-only cycle.
                  it_state_r <= IT_PREP;
                  pp_pre <= mul_pre_from_product(ap_pre, pm_pre);
                end
              end
            end
            IT_FMA: begin
              if (!valid) begin
                it_state_r <= IT_IDLE;
                it_lane_r  <= 1'b0;
                fma_align  <= '0;
                fma_align_lo <= '0;
                fma_align_hi <= '0;
              end else begin
                // R21 stage 4: complete only the registered FMA wide
                // compare/add/sub and enter the existing pack pipeline.
                it_state_r <= IT_PREP;
                it_lane_r  <= 1'b0;
                if (is_half) begin
                  pp_pre_lo <= fma_pre_from_product(ap_pre_lo, fma_align_lo);
                  pp_pre_hi <= fma_pre_from_product(ap_pre_hi, fma_align_hi);
                end else begin
                  pp_pre <= fma_pre_from_product(ap_pre, fma_align);
                end
                fma_align  <= '0;
                fma_align_lo <= '0;
                fma_align_hi <= '0;
              end
            end
            IT_OTHER: begin
              if (!valid) begin
                it_state_r <= IT_IDLE;
                it_lane_r  <= 1'b0;
              end else begin
                // Round4 stage 2: from pp_other perform the expensive
                // decision/shift/magnitude work and write ot_mid*.
                it_state_r <= IT_PREP;
                it_lane_r  <= 1'b0;
                if (is_half) begin
                  ot_mid_lo <= other_mid(op, pp_other_lo);
                  ot_mid_hi <= other_mid(op, pp_other_hi);
                end else begin
                  ot_mid   <= other_mid(op, pp_other);
                end
              end
            end
            IT_PREP: begin
              if (!valid) begin
                it_state_r <= IT_IDLE;
                it_lane_r  <= 1'b0;
                pack_scan  <= '0;
                pack_scan_lo <= '0;
                pack_scan_hi <= '0;
                pack_pre   <= '0;
                pack_pre_lo <= '0;
                pack_pre_hi <= '0;
                pack_mid   <= '0;
                pack_mid_lo <= '0;
                pack_mid_hi <= '0;
              end else if (uses_round_pack_pre(op)) begin
                // Round18 stage 1: capture only the 256-bit leading-one/zero
                // scan and derived exponent. Tiny classification and the
                // normalization/GRS work are deferred across two registers.
                it_state_r <= IT_PACK_SCAN;
                it_lane_r  <= 1'b0;
                if (op == FP_OP_FCVT) begin
                  // FCVT is always single-lane, including H->S/D where
                  // is_half describes the source format rather than a pair
                  // of packed arithmetic lanes.
                  pack_scan <= round_pack_scan(pp_pre);
                end else if (is_half) begin
                  pack_scan_lo <= round_pack_scan(pp_pre_lo);
                  pack_scan_hi <= round_pack_scan(pp_pre_hi);
                end else begin
                  pack_scan <= round_pack_scan(pp_pre);
                end
              end else begin
                // IT_PREP is also used by the non-rounding pp_other path
                // (CMP/minmax/FRINT/FP->int), whose output is handled by the
                // combinational finish below and must retain its one-cycle
                // latency.
                it_state_r <= IT_IDLE;
                it_lane_r  <= 1'b0;
              end
            end
            IT_PACK_SCAN: begin
              if (!valid) begin
                it_state_r <= IT_IDLE;
                it_lane_r  <= 1'b0;
                pack_scan  <= '0;
                pack_scan_lo <= '0;
                pack_scan_hi <= '0;
                pack_pre   <= '0;
                pack_pre_lo <= '0;
                pack_pre_hi <= '0;
                pack_mid   <= '0;
                pack_mid_lo <= '0;
                pack_mid_hi <= '0;
              end else begin
                // Round18 stage 2: classify tiny/normal from the registered
                // scan payload. No leading-one scan is present on this side.
                it_state_r <= IT_PACK_PRE;
                it_lane_r  <= 1'b0;
                if (op == FP_OP_FCVT) begin
                  pack_pre <= round_pack_pre(pack_scan);
                end else if (is_half) begin
                  pack_pre_lo <= round_pack_pre(pack_scan_lo);
                  pack_pre_hi <= round_pack_pre(pack_scan_hi);
                end else begin
                  pack_pre <= round_pack_pre(pack_scan);
                end
              end
            end
            IT_PACK_PRE: begin
              if (!valid) begin
                it_state_r <= IT_IDLE;
                it_lane_r  <= 1'b0;
                pack_scan  <= '0;
                pack_scan_lo <= '0;
                pack_scan_hi <= '0;
                pack_pre   <= '0;
                pack_pre_lo <= '0;
                pack_pre_hi <= '0;
                pack_mid   <= '0;
                pack_mid_lo <= '0;
                pack_mid_hi <= '0;
              end else begin
                // Round18 stage 3: normalize and construct GRS from the
                // registered tiny/normal metadata. IT_PACK then performs
                // only the existing increment/overflow/subnormal/pack step.
                it_state_r <= IT_PACK;
                it_lane_r  <= 1'b0;
                if (op == FP_OP_FCVT) begin
                  pack_mid <= round_pack_p1(pack_pre);
                end else if (is_half) begin
                  pack_mid_lo <= round_pack_p1(pack_pre_lo);
                  pack_mid_hi <= round_pack_p1(pack_pre_hi);
                end else begin
                  pack_mid <= round_pack_p1(pack_pre);
                end
              end
            end
            IT_PACK: begin
              if (!valid) begin
                it_state_r <= IT_IDLE;
                it_lane_r  <= 1'b0;
                pack_scan  <= '0;
                pack_scan_lo <= '0;
                pack_scan_hi <= '0;
                pack_pre   <= '0;
                pack_pre_lo <= '0;
                pack_pre_hi <= '0;
                pack_mid   <= '0;
                pack_mid_lo <= '0;
                pack_mid_hi <= '0;
                it_fin_valid_r <= 1'b0;
                pack_result_r <= '0;
                pack_result_lo <= '0;
                pack_result_hi <= '0;
                pack_result_half_r <= 1'b0;
                pack_result_valid_r <= 1'b0;
              end else begin
                // R20 stage 4: complete p2 into a private result register.
                // The following IT_PACK_RESULT state is the only state that
                // exposes this payload, keeping the wide p2 cone away from
                // slot_result_r's capture edge.
                if (op == FP_OP_DIV || op == FP_OP_SQRT) begin
                  if (is_half) begin
                    pack_result_lo <= round_pack_p2(it_fin_mid_lo);
                    pack_result_hi <= round_pack_p2(it_fin_mid_hi);
                  end else begin
                    pack_result_r <= round_pack_p2(it_fin_mid_r);
                  end
                end else if (op == FP_OP_FCVT) begin
                  pack_result_r <= round_pack_p2(pack_mid);
                end else if (is_half) begin
                  pack_result_lo <= round_pack_p2(pack_mid_lo);
                  pack_result_hi <= round_pack_p2(pack_mid_hi);
                end else begin
                  pack_result_r <= round_pack_p2(pack_mid);
                end
                // FCVT with an H source is still a single-lane result;
                // every other is_half pack operation has two H lanes.
                pack_result_half_r <= is_half && (op != FP_OP_FCVT);
                pack_result_valid_r <= 1'b1;
                it_state_r <= IT_PACK_RESULT;
                it_lane_r  <= 1'b0;
                pack_scan  <= '0;
                pack_scan_lo <= '0;
                pack_scan_hi <= '0;
                pack_pre   <= '0;
                pack_pre_lo <= '0;
                pack_pre_hi <= '0;
                pack_mid   <= '0;
                pack_mid_lo <= '0;
                pack_mid_hi <= '0;
                it_fin_valid_r <= 1'b0;
              end
            end
            IT_PACK_RESULT: begin
              if (!valid) begin
                // A dropped valid before the capture edge abandons the
                // registered result; no stale result/done is committed.
                it_state_r <= IT_IDLE;
                it_lane_r  <= 1'b0;
                pack_result_r <= '0;
                pack_result_lo <= '0;
                pack_result_hi <= '0;
                pack_result_half_r <= 1'b0;
                pack_result_valid_r <= 1'b0;
              end else begin
                // The result window lasts exactly this state interval.  The
                // caller captures it on this edge; clear the valid marker as
                // ownership returns to IDLE so done cannot repeat.
                it_state_r <= IT_IDLE;
                it_lane_r  <= 1'b0;
                pack_result_valid_r <= 1'b0;
              end
            end
            IT_DIV: begin
              if (!valid) begin
                it_state_r <= IT_IDLE;
                it_lane_r  <= 1'b0;
              end else if (it_div_special || it_div_done) begin
                if (is_half && it_lane_r == 1'b0) begin
                  if (it_div_special) begin
                    div_pre_lo <= div_finish_pre(FMT_HALF,
                        {48'd0, operand_a[15:0]},
                        {48'd0, operand_b[15:0]},
                        '0, 1'b0, fpcr[25], it_fz, fpcr[23:22]);
                  end else begin
                    div_pre_lo <= div_finish_pre(FMT_HALF,
                        {48'd0, operand_a[15:0]},
                        {48'd0, operand_b[15:0]},
                        it_div_q, it_div_sticky,
                        fpcr[25], it_fz, fpcr[23:22]);
                  end
                  it_lane_r <= 1'b1;
                end else if (is_half) begin
                  if (it_div_special) begin
                    div_pre_hi <= div_finish_pre(FMT_HALF,
                        {48'd0, operand_a[31:16]},
                        {48'd0, operand_b[31:16]},
                        '0, 1'b0, fpcr[25], it_fz, fpcr[23:22]);
                  end else begin
                    div_pre_hi <= div_finish_pre(FMT_HALF,
                        {48'd0, operand_a[31:16]},
                        {48'd0, operand_b[31:16]},
                        it_div_q, it_div_sticky,
                        fpcr[25], it_fz, fpcr[23:22]);
                  end
                  it_state_r <= IT_FIN;
                  it_lane_r  <= 1'b0;
                end else begin
                  div_pre <= div_finish_pre(it_fmt, operand_a, operand_b,
                                            it_div_q, it_div_sticky,
                                            fpcr[25], it_fz, fpcr[23:22]);
                  it_state_r <= IT_FIN;
                  it_lane_r  <= 1'b0;
                end
              end
            end
            IT_SQRT: begin
              if (!valid) begin
                it_state_r <= IT_IDLE;
                it_lane_r  <= 1'b0;
              end else if (it_sqrt_special || it_sqrt_done) begin
                if (is_half && it_lane_r == 1'b0) begin
                  if (it_sqrt_special) begin
                    sqrt_pre_lo <= sqrt_finish_pre(FMT_HALF,
                        {48'd0, operand_a[15:0]},
                        0, 0, 64'd0, 1'b0,
                        fpcr[25], it_fz, fpcr[23:22]);
                  end else begin
                    sqrt_pre_lo <= sqrt_finish_pre(FMT_HALF,
                        {48'd0, operand_a[15:0]},
                        it_sqrt_exp2e, it_sqrt_shift,
                        it_sqrt_q, it_sqrt_sticky,
                        fpcr[25], it_fz, fpcr[23:22]);
                  end
                  it_lane_r <= 1'b1;
                end else if (is_half) begin
                  if (it_sqrt_special) begin
                    sqrt_pre_hi <= sqrt_finish_pre(FMT_HALF,
                        {48'd0, operand_a[31:16]},
                        0, 0, 64'd0, 1'b0,
                        fpcr[25], it_fz, fpcr[23:22]);
                  end else begin
                    sqrt_pre_hi <= sqrt_finish_pre(FMT_HALF,
                        {48'd0, operand_a[31:16]},
                        it_sqrt_exp2e, it_sqrt_shift,
                        it_sqrt_q, it_sqrt_sticky,
                        fpcr[25], it_fz, fpcr[23:22]);
                  end
                  it_state_r <= IT_FIN;
                  it_lane_r  <= 1'b0;
                end else begin
                  sqrt_pre <= sqrt_finish_pre(it_fmt, operand_a,
                                              it_sqrt_exp2e, it_sqrt_shift,
                                              it_sqrt_q, it_sqrt_sticky,
                                              fpcr[25], it_fz, fpcr[23:22]);
                  it_state_r <= IT_FIN;
                  it_lane_r  <= 1'b0;
                end
              end
            end
            IT_FIN: begin
              if (!valid) begin
                it_state_r <= IT_IDLE;
                it_lane_r  <= 1'b0;
                it_fin_valid_r <= 1'b0;
              end else if (!it_fin_valid_r) begin
                // First IT_FIN cycle: only compute the shifted significand /
                // GRS / special bypass from the already captured div_pre or
                // sqrt_pre.  The final pack is completed by IT_PACK next
                // cycle; IT_FIN itself never exposes iter_done.
                if (op == FP_OP_DIV) begin
                  if (is_half) begin
                    it_fin_mid_lo <= round_pack_iter_p1(div_pre_lo);
                    it_fin_mid_hi <= round_pack_iter_p1(div_pre_hi);
                  end else begin
                    it_fin_mid_r <= round_pack_iter_p1(div_pre);
                  end
                end else begin
                  if (is_half) begin
                    it_fin_mid_lo <= round_pack_iter_p1(sqrt_pre_lo);
                    it_fin_mid_hi <= round_pack_iter_p1(sqrt_pre_hi);
                  end else begin
                    it_fin_mid_r <= round_pack_iter_p1(sqrt_pre);
                  end
                end
                it_fin_valid_r <= 1'b1;
                it_state_r <= IT_PACK;
              end else begin
                it_state_r <= IT_IDLE;
                it_lane_r  <= 1'b0;
                it_fin_valid_r <= 1'b0;
              end
            end
            default: begin
              it_state_r <= IT_IDLE;
              it_lane_r  <= 1'b0;
            end
          endcase
        end
      end

      // R20 route-closure invariants.  These properties cover only the
      // non-half IT_ARITH lane; the packed-half route above remains an
      // independent two-lane implementation.  A pause/kill/valid drop holds
      // or clears the state before the route is sampled, so it is excluded
      // from the next-state checks below.
`ifndef SYNTHESIS
      /* verilator lint_off SYNCASYNCNET */
      assert property (@(posedge clk) disable iff (!rst_n)
          (it_state_r == IT_ARITH && valid && !is_half &&
           !iter_pause && !iter_kill &&
           (ap_pre.op == FP_OP_ADD || ap_pre.op == FP_OP_SUB))
          |=> (it_state_r == IT_ALIGN));
      assert property (@(posedge clk) disable iff (!rst_n)
          (it_state_r == IT_ARITH && valid && !is_half &&
           !iter_pause && !iter_kill &&
           (ap_pre.op == FP_OP_MUL || ap_pre.op == FP_OP_FMADD ||
            ap_pre.op == FP_OP_FMSUB || ap_pre.op == FP_OP_FNMADD ||
            ap_pre.op == FP_OP_FNMSUB))
          |=> (it_state_r == IT_MUL));
      assert property (@(posedge clk) disable iff (!rst_n)
          (it_state_r == IT_MUL && valid && !is_half && !iter_pause &&
           !iter_kill &&
           (ap_pre.op == FP_OP_FMADD || ap_pre.op == FP_OP_FMSUB ||
            ap_pre.op == FP_OP_FNMADD || ap_pre.op == FP_OP_FNMSUB))
          |=> (it_state_r == IT_FMA));
      assert property (@(posedge clk) disable iff (!rst_n)
          (it_state_r == IT_FMA && valid && !iter_pause && !iter_kill)
          |=> (it_state_r == IT_PREP));
      assert property (@(posedge clk) disable iff (!rst_n)
          (it_state_r == IT_ARITH && valid && !is_half &&
           !iter_pause && !iter_kill &&
           (ap_pre.op == FP_OP_SCVTF || ap_pre.op == FP_OP_UCVTF))
          |=> (it_state_r == IT_PREP));
      assert property (@(posedge clk) disable iff (!rst_n)
          (it_state_r == IT_ARITH && valid && !is_half &&
           !iter_pause && !iter_kill &&
           !(ap_pre.op == FP_OP_ADD || ap_pre.op == FP_OP_SUB ||
             ap_pre.op == FP_OP_MUL || ap_pre.op == FP_OP_FMADD ||
             ap_pre.op == FP_OP_FMSUB || ap_pre.op == FP_OP_FNMADD ||
             ap_pre.op == FP_OP_FNMSUB || ap_pre.op == FP_OP_SCVTF ||
             ap_pre.op == FP_OP_UCVTF))
          |=> (it_state_r == IT_PREP && pp_pre == '0));
      /* verilator lint_on SYNCASYNCNET */
`endif

      always_comb begin
        calc = '0;
        calc_lo = '0;
        calc_hi = '0;
        ic = '0;
        int_result = 64'd0;
        fmt = FMT_SINGLE;
        result = 64'd0;
        fpsr_flags = 32'd0;
        cmp_nzcv = 4'd0;
        iter_busy = (it_state_r != IT_IDLE);
        iter_done = 1'b0;
        div_busy = iter_busy;
        div_done = 1'b0;
        it_cur_calc = '0;

        if (valid) begin
          // In the release FP_ITER shared-lane path, only the bitwise FMOV
          // passthrough consumes current operands combinationally to the
          // scalar result.  All IEEE arithmetic, conversions, compare/minmax/
          // rint and FP->int are staged through pp_pre/pp_other registers;
          // ordinary pp_pre round/pack is staged through IT_PREP/
          // IT_PACK_SCAN/IT_PACK_PRE/IT_PACK/IT_PACK_RESULT;
          // the iterative DIV/SQRT final round is staged through div_pre/
          // sqrt_pre through IT_FIN -> IT_PACK -> IT_PACK_RESULT. Computing the old full
          // combinational result
          // here would leave a multi-hundred-level path from the slot operand
          // mux to the response data/control muxes.
          if (is_half || (op == FP_OP_FCVT && fcvt_dst_half)) begin
            fmt = FMT_HALF;
            if (op == FP_OP_MOV) begin
              calc.bits = {48'd0, operand_a[15:0]};
            end
          end else begin
            fmt = is_double ? FMT_DOUBLE : FMT_SINGLE;
            if (op == FP_OP_MOV) begin
              calc.bits = is_double ? operand_a
                                    : {32'd0, operand_a[31:0]};
            end
          end
        end

        if (valid && it_state_r == IT_PACK_RESULT && pack_result_valid_r) begin
          // R20: both ordinary and iterative p2 results are supplied only by
          // private final-result registers.  The captured lane mode keeps
          // this output stable if live operands or format controls change
          // while the result window is paused.
          if (pack_result_half_r) begin
            result = {32'd0, pack_result_hi.bits[15:0],
                      pack_result_lo.bits[15:0]};
            fpsr_flags = (pack_result_lo.flags | pack_result_hi.flags) &
                         ~FPSR_IDC;
          end else begin
            result = pack_result_r.bits;
            fpsr_flags = pack_result_r.flags;
          end
          iter_done = !iter_pause;
        end else if (valid && it_state_r == IT_PREP && uses_other_pre(op)) begin
          if (is_half) begin
            unique case (op)
              FP_OP_CMP: begin
                calc_lo = compare_finish_parts(pp_other_lo.pa, pp_other_lo.pb,
                                               pp_other_lo.cmp_zero,
                                               pp_other_lo.signal_nans,
                                               pp_other_lo.input_flags);
                calc_hi = compare_finish_parts(pp_other_hi.pa, pp_other_hi.pb,
                                               pp_other_hi.cmp_zero,
                                               pp_other_hi.signal_nans,
                                               pp_other_hi.input_flags);
                result = {32'd0,
                          {16{calc_hi.nzcv == 4'b0110}},
                          {16{calc_lo.nzcv == 4'b0110}}};
                fpsr_flags = (calc_lo.flags | calc_hi.flags) & ~FPSR_IDC;
                cmp_nzcv = calc_lo.nzcv;
              end
              FP_OP_FMIN, FP_OP_FMAX, FP_OP_FMINNM, FP_OP_FMAXNM: begin
                calc_lo = minmax_finish_mid(ot_mid_lo);
                calc_hi = minmax_finish_mid(ot_mid_hi);
                result = {32'd0, calc_hi.bits[15:0],
                          calc_lo.bits[15:0]};
                fpsr_flags = (calc_lo.flags | calc_hi.flags) & ~FPSR_IDC;
              end
              FP_OP_FRINT: begin
                calc_lo = frint_finish_mid(ot_mid_lo);
                calc_hi = frint_finish_mid(ot_mid_hi);
                result = {32'd0, calc_hi.bits[15:0],
                          calc_lo.bits[15:0]};
                fpsr_flags = (calc_lo.flags | calc_hi.flags) & ~FPSR_IDC;
              end
              default: begin
                // H FP->int is not enabled; keep zero.
                result = {32'd0, calc_hi.bits[15:0],
                          calc_lo.bits[15:0]};
                fpsr_flags = 32'd0;
              end
            endcase
          end else begin
            unique case (op)
              FP_OP_CMP: begin
                it_cur_calc = compare_finish_parts(pp_other.pa, pp_other.pb,
                                                   pp_other.cmp_zero,
                                                   pp_other.signal_nans,
                                                   pp_other.input_flags);
                result = it_cur_calc.bits;
                fpsr_flags = it_cur_calc.flags;
                cmp_nzcv = it_cur_calc.nzcv;
              end
              FP_OP_FMIN, FP_OP_FMAX, FP_OP_FMINNM, FP_OP_FMAXNM: begin
                it_cur_calc = minmax_finish_mid(ot_mid);
                result = it_cur_calc.bits;
                fpsr_flags = it_cur_calc.flags;
              end
              FP_OP_FRINT: begin
                it_cur_calc = frint_finish_mid(ot_mid);
                result = it_cur_calc.bits;
                fpsr_flags = it_cur_calc.flags;
              end
              FP_OP_FCVTZS, FP_OP_FCVTZU: begin
                ic = fp_to_int_finish_mid(ot_mid);
                int_result = ic.value;
                result = 64'd0;
                fpsr_flags = ic.flags;
              end
              default: begin
                it_cur_calc = compare_finish_parts(pp_other.pa, pp_other.pb,
                                                   pp_other.cmp_zero,
                                                   pp_other.signal_nans,
                                                   pp_other.input_flags);
                result = it_cur_calc.bits;
                fpsr_flags = it_cur_calc.flags;
                cmp_nzcv = it_cur_calc.nzcv;
              end
            endcase
          end
          iter_done = 1'b1;
        end else if (valid && it_state_r == IT_IDLE &&
                    !uses_pre_round(op) && !uses_other_pre(op) &&
                    op != FP_OP_DIV && op != FP_OP_SQRT &&
                    op != FP_OP_FMADD && op != FP_OP_FMSUB &&
                    op != FP_OP_FNMADD && op != FP_OP_FNMSUB &&
                    op != FP_OP_FCVT) begin
          result = calc.bits;
          fpsr_flags = (op == FP_OP_FCVTZS || op == FP_OP_FCVTZU)
                       ? ic.flags : calc.flags;
          iter_done = 1'b1;
        end

        if (valid && (op == FP_OP_FCVTZS || op == FP_OP_FCVTZU) &&
            !(it_state_r == IT_PREP && uses_other_pre(op)))
          fpsr_flags = ic.flags;
        if (uses_other_pre(op) && it_state_r == IT_PREP) begin
          // cmp_nzcv already set from the pipelined finish above.
        end else if (uses_pre_round(op) || op == FP_OP_FMADD ||
            op == FP_OP_FMSUB || op == FP_OP_FNMADD ||
            op == FP_OP_FNMSUB || op == FP_OP_FCVT)
          cmp_nzcv = 4'd0;
        else
          cmp_nzcv = calc.nzcv;
        div_done = iter_done;
      end
    end
  endgenerate

endmodule
// ---- Multi-cycle bit-serial divider
// 256 iterations are enough for the widest FP64 numerator after DIV_EXTRA.
// Each iteration is a 64-bit compare/subtract; no >64-bit lpm_divide is used.
/* verilator lint_off DECLFILENAME */
module lcvex_fp_divider (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        start,
    input  logic [255:0] numerator,
    input  logic [63:0]  divisor,
    input  logic        kill,
    input  logic        pause,
    output logic        busy,
    output logic        done,
    output logic [255:0] quotient,
    output logic        sticky
);
  localparam integer DW = 256;
  logic [7:0]  bit_idx_r;
  logic [DW-1:0] num_r;
  logic [63:0]   den_r;
  logic [DW-1:0] q_r;
  logic [63:0]   rem_r;
  logic [63:0]   rem_shifted;
  logic [63:0]   rem_next;
  logic          qbit;
  logic [DW-1:0] q_comb;
  logic          busy_r;

  assign rem_shifted = {rem_r[62:0], num_r[bit_idx_r]};
  assign qbit = rem_shifted >= den_r;
  assign rem_next = qbit ? (rem_shifted - den_r) : rem_shifted;
  assign q_comb = {q_r[DW-2:0], qbit};
  assign busy = busy_r;
  assign done = busy_r && (bit_idx_r == 8'd0);
  assign quotient = q_comb;
  assign sticky = |rem_next;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      bit_idx_r <= 8'd0;
      num_r     <= '0;
      den_r     <= 64'd0;
      q_r       <= '0;
      rem_r     <= 64'd0;
      busy_r    <= 1'b0;
    end else if (kill) begin
      bit_idx_r <= 8'd0;
      num_r     <= '0;
      den_r     <= 64'd0;
      q_r       <= '0;
      rem_r     <= 64'd0;
      busy_r    <= 1'b0;
    end else if (!pause && start && !busy_r) begin
      num_r     <= numerator;
      den_r     <= divisor;
      q_r       <= '0;
      rem_r     <= 64'd0;
      bit_idx_r <= 8'd255;
      busy_r    <= 1'b1;
    end else if (!pause && busy_r) begin
      if (bit_idx_r == 8'd0) begin
        busy_r <= 1'b0;
      end else begin
        q_r       <= q_comb;
        rem_r     <= rem_next;
        bit_idx_r <= bit_idx_r - 8'd1;
      end
    end
  end
endmodule

// ---- FP-P3 iterative restoring square root ----
// 64 restoring iterations on a 128-bit radicand produce a 64-bit floor root
// plus a sticky bit.  This replaces the previous combinational 64-round
// isqrt64 expansion in the FP_ITER shared-lane engine.
/* verilator lint_off DECLFILENAME */
module lcvex_fp_iter_sqrt (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        start,
    input  logic        kill,
    input  logic        pause,
    input  logic [127:0] x,
    output logic        busy,
    output logic        done,
    output logic [63:0] q,
    output logic        sticky
);
  localparam integer RW = 256;
  logic [RW-1:0] rem_r;
  logic [63:0]   q_r;
  logic [6:0]    idx_r;
  logic [127:0]  x_r;
  logic          busy_r;
  logic [1:0]    xbits;
  logic [RW-1:0] rem_shifted;
  logic [RW-1:0] rem_next;
  logic [63:0]   q_next;
  logic          qbit;
  logic [RW-1:0] trial;

  assign xbits     = {x_r[2*idx_r + 1], x_r[2*idx_r]};
  assign rem_shifted = (rem_r << 2) | ({254'd0, xbits});
  assign trial     = {190'd0, q_r, 2'b01};
  assign qbit      = (rem_shifted >= trial);
  assign q_next    = {q_r[62:0], qbit};
  assign rem_next  = qbit ? (rem_shifted - trial) : rem_shifted;
  assign q         = q_next;
  assign sticky    = |rem_next;
  assign busy      = busy_r;
  assign done      = busy_r && (idx_r == 7'd0);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rem_r  <= '0;
      q_r    <= 64'd0;
      idx_r  <= 7'd0;
      x_r    <= 128'd0;
      busy_r <= 1'b0;
    end else if (kill) begin
      rem_r  <= '0;
      q_r    <= 64'd0;
      idx_r  <= 7'd0;
      x_r    <= 128'd0;
      busy_r <= 1'b0;
    end else if (!pause && start && !busy_r) begin
      rem_r  <= '0;
      q_r    <= 64'd0;
      idx_r  <= 7'd63;
      x_r    <= x;
      busy_r <= 1'b1;
    end else if (!pause && busy_r) begin
      if (idx_r == 7'd0) begin
        busy_r <= 1'b0;
      end else begin
        rem_r  <= rem_next;
        q_r    <= q_next;
        idx_r  <= idx_r - 7'd1;
      end
    end
  end
endmodule
/* verilator lint_on DECLFILENAME */

/* verilator lint_on UNUSEDSIGNAL */
